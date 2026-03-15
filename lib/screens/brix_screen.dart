import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:bro_app/services/brix_service.dart';
import 'package:bro_app/services/storage_service.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:convert';

class BrixScreen extends StatefulWidget {
  const BrixScreen({super.key});

  @override
  State<BrixScreen> createState() => _BrixScreenState();
}

enum BrixStep { loading, contact, username, verify, active }

class _BrixScreenState extends State<BrixScreen> {
  final _brixService = BrixService();
  final _storage = StorageService();

  BrixStep _step = BrixStep.loading;
  bool _isLoading = false;
  String? _error;

  // Step 1: Contact
  bool _isPhone = true;
  final _contactController = TextEditingController();

  // Step 2: Username
  final _usernameController = TextEditingController();
  bool? _usernameAvailable;
  bool _checkingUsername = false;
  Timer? _usernameDebounce;

  // Step 3: Verification
  String? _userId;
  String? _devCode;
  final _codeController = TextEditingController();
  int _resendCooldown = 0;

  // Step 4: Active
  String? _brixAddress;
  String? _username;
  String? _pubkey;
  String? _registeredPhone;
  String? _registeredEmail;

  // Modification flow
  bool _isEditing = false;
  bool _editIsPhone = true;
  final _editContactController = TextEditingController();
  final _editCodeController = TextEditingController();
  bool _editWaitingCode = false;
  String? _editDevCode;

  @override
  void initState() {
    super.initState();
    _checkExisting();
  }

  @override
  void dispose() {
    _contactController.dispose();
    _usernameController.dispose();
    _codeController.dispose();
    _editContactController.dispose();
    _editCodeController.dispose();
    _usernameDebounce?.cancel();
    super.dispose();
  }

  Future<void> _checkExisting() async {
    try {
      // First check local cache
      final cached = await _loadBrixLocal();
      if (cached != null) {
        setState(() {
          _brixAddress = cached['address'];
          _username = cached['username'];
          _registeredPhone = cached['phone'];
          _registeredEmail = cached['email'];
          _pubkey = cached['pubkey'];
          _step = BrixStep.active;
        });
        // Refresh from server in background
        _refreshFromServer(cached['pubkey']);
        return;
      }

      final pubkey = await _storage.getNostrPublicKey();
      if (pubkey != null && pubkey.isNotEmpty) {
        _pubkey = pubkey;
        final result = await _brixService.getAddress(pubkey);
        if (result.hasAddress && result.address != null) {
          setState(() {
            _brixAddress = result.address;
            _username = result.username;
            _registeredPhone = result.phone;
            _registeredEmail = result.email;
            _step = BrixStep.active;
          });
          await _saveBrixLocal();
          return;
        }
      }
    } catch (_) {}
    setState(() => _step = BrixStep.contact);
  }

  Future<void> _refreshFromServer(String? pubkey) async {
    if (pubkey == null || pubkey.isEmpty) return;
    try {
      final result = await _brixService.getAddress(pubkey);
      if (result.hasAddress && result.address != null && mounted) {
        setState(() {
          _brixAddress = result.address;
          _username = result.username;
          _registeredPhone = result.phone;
          _registeredEmail = result.email;
        });
        await _saveBrixLocal();
      }
    } catch (_) {}
  }

  Future<void> _saveBrixLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = jsonEncode({
        'address': _brixAddress,
        'username': _username,
        'phone': _registeredPhone,
        'email': _registeredEmail,
        'pubkey': _pubkey,
      });
      await prefs.setString('brix_cached', data);
    } catch (_) {}
  }

  Future<Map<String, String?>?> _loadBrixLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('brix_cached');
      if (raw == null) return null;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (data['address'] == null || data['username'] == null) return null;
      return {
        'address': data['address'] as String?,
        'username': data['username'] as String?,
        'phone': data['phone'] as String?,
        'email': data['email'] as String?,
        'pubkey': data['pubkey'] as String?,
      };
    } catch (_) {
      return null;
    }
  }

  void _goToUsername() {
    final contact = _contactController.text.trim();
    if (contact.isEmpty) {
      setState(() => _error = _isPhone ? 'Informe seu celular' : 'Informe seu email');
      return;
    }
    setState(() {
      _error = null;
      _step = BrixStep.username;
    });
  }

  void _onUsernameChanged(String value) {
    _usernameDebounce?.cancel();
    final clean = value.toLowerCase().trim();
    if (clean.length < 3) {
      setState(() {
        _usernameAvailable = null;
        _checkingUsername = false;
      });
      return;
    }
    setState(() => _checkingUsername = true);
    _usernameDebounce = Timer(const Duration(milliseconds: 500), () async {
      if (!mounted) return;
      final result = await _brixService.checkUsername(clean);
      if (!mounted) return;
      setState(() {
        _checkingUsername = false;
        if (result.isConnectionError) {
          // On connection error, don't block — assume available
          _usernameAvailable = null;
          _error = null;
        } else {
          _usernameAvailable = result.available;
          if (!result.available && result.error != null) {
            _error = result.error;
          } else {
            _error = null;
          }
        }
      });
    });
  }

  String _previewAddress() {
    final raw = _usernameController.text.toLowerCase().trim();
    if (raw.isEmpty) return '...@brostr.app';
    return '$raw@brostr.app';
  }

  Future<void> _register() async {
    final username = _usernameController.text.toLowerCase().trim();
    final contact = _contactController.text.trim();

    if (username.length < 3) {
      setState(() => _error = 'Apelido precisa ter pelo menos 3 caracteres');
      return;
    }
    if (_usernameAvailable == false) {
      setState(() => _error = 'Apelido não disponível');
      return;
    }

    final pubkey = await _storage.getNostrPublicKey();

    setState(() {
      _isLoading = true;
      _error = null;
    });

    final result = await _brixService.register(
      username: username,
      phone: _isPhone ? contact : null,
      email: !_isPhone ? contact : null,
      nostrPubkey: pubkey,
    );

    setState(() => _isLoading = false);

    if (result.success && result.userId != null) {
      if (result.verified && result.brixAddress != null) {
        // Auto-verified (no SMTP on server)
        setState(() {
          _brixAddress = result.brixAddress;
          _username = result.username;
          _pubkey = pubkey;
          _registeredPhone = _isPhone ? contact : null;
          _registeredEmail = !_isPhone ? contact : null;
          _step = BrixStep.active;
        });
        await _saveBrixLocal();
      } else {
        setState(() {
          _userId = result.userId;
          _devCode = result.devCode;
          _username = result.username;
          _step = BrixStep.verify;
        });
        _startResendCooldown();
      }
    } else {
      setState(() => _error = result.error ?? 'Erro ao registrar');
    }
  }

  Future<void> _verify() async {
    final code = _codeController.text.trim();
    if (code.length != 6) {
      setState(() => _error = 'Digite o código de 6 dígitos');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    final result = await _brixService.verify(
      userId: _userId!,
      code: code,
    );

    setState(() => _isLoading = false);

    if (result.success && result.brixAddress != null) {
      setState(() {
        _brixAddress = result.brixAddress;
        _username = result.username;
        _step = BrixStep.active;
      });
      await _saveBrixLocal();
    } else {
      setState(() => _error = result.error ?? 'Código inválido');
    }
  }

  Future<void> _resend() async {
    if (_resendCooldown > 0 || _userId == null) return;

    setState(() => _isLoading = true);

    final result = await _brixService.resend(userId: _userId!);

    setState(() {
      _isLoading = false;
      if (result.success) {
        _devCode = result.devCode;
        _error = null;
      } else {
        _error = result.error ?? 'Erro ao reenviar';
      }
    });

    if (result.success) _startResendCooldown();
  }

  void _startResendCooldown() {
    _resendCooldown = 60;
    _tick();
  }

  void _tick() {
    if (_resendCooldown <= 0 || !mounted) return;
    Future.delayed(const Duration(seconds: 1), () {
      if (!mounted) return;
      setState(() => _resendCooldown--);
      _tick();
    });
  }
  // Modification flow methods
  Future<void> _requestContactUpdate() async {
    final contact = _editContactController.text.trim();
    if (contact.isEmpty) {
      setState(() => _error = 'Informe o novo contato');
      return;
    }
    if (_pubkey == null) return;

    setState(() { _isLoading = true; _error = null; });

    final result = await _brixService.updateContact(
      phone: _editIsPhone ? contact : null,
      email: !_editIsPhone ? contact : null,
      pubkey: _pubkey!,
    );

    setState(() {
      _isLoading = false;
      if (result.success) {
        _editWaitingCode = true;
        _editDevCode = result.devCode;
      } else {
        _error = result.error ?? 'Erro ao solicitar atualização';
      }
    });
  }

  Future<void> _confirmContactUpdate() async {
    final code = _editCodeController.text.trim();
    if (code.length != 6) {
      setState(() => _error = 'Digite o código de 6 dígitos');
      return;
    }
    if (_pubkey == null) return;

    final contact = _editContactController.text.trim();
    setState(() { _isLoading = true; _error = null; });

    final result = await _brixService.confirmUpdate(
      code: code,
      pubkey: _pubkey!,
      phone: _editIsPhone ? contact : null,
      email: !_editIsPhone ? contact : null,
    );

    setState(() {
      _isLoading = false;
      if (result.success) {
        if (_editIsPhone) {
          _registeredPhone = contact.replaceAll(RegExp(r'\D'), '');
        } else {
          _registeredEmail = contact.trim().toLowerCase();
        }
        _isEditing = false;
        _editWaitingCode = false;
        _editContactController.clear();
        _editCodeController.clear();
        _editDevCode = null;
        _error = null;
      } else {
        _error = result.error ?? 'Código inválido';
      }
    });
  }

  void _cancelEdit() {
    setState(() {
      _isEditing = false;
      _editWaitingCode = false;
      _editContactController.clear();
      _editCodeController.clear();
      _editDevCode = null;
      _error = null;
    });
  }

  String _maskPhone(String phone) {
    if (phone.length <= 4) return '****${phone.substring(phone.length - 2)}';
    return '${phone.substring(0, 3)}****${phone.substring(phone.length - 2)}';
  }

  String _maskEmail(String email) {
    final parts = email.split('@');
    if (parts.length != 2) return '****';
    final name = parts[0];
    final domain = parts[1];
    if (name.length <= 2) return '**@$domain';
    return '${name.substring(0, 2)}****@$domain';
  }

  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF121212),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.home, color: Colors.white),
          onPressed: () => Navigator.pushNamedAndRemoveUntil(context, '/home', (route) => false),
          tooltip: 'Início',
        ),
        title: const Text('⚡ BRIX', style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.account_balance_wallet, color: Colors.orange),
            onPressed: () => Navigator.pushNamed(context, '/wallet'),
            tooltip: 'Carteira',
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    switch (_step) {
      case BrixStep.loading:
        return const Center(child: CircularProgressIndicator(color: Colors.amber));
      case BrixStep.contact:
        return _buildContactStep();
      case BrixStep.username:
        return _buildUsernameStep();
      case BrixStep.verify:
        return _buildVerifyStep();
      case BrixStep.active:
        return _buildActiveStep();
    }
  }

  // ─── STEP 1: Contact ───────────────────────────────────────
  Widget _buildContactStep() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.amber.withOpacity(0.15), Colors.orange.withOpacity(0.05)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.amber.withOpacity(0.3)),
            ),
            child: Column(
              children: [
                const Text('⚡', style: TextStyle(fontSize: 48)),
                const SizedBox(height: 8),
                const Text(
                  'Receba Bitcoin\ncomo recebe PIX',
                  style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Crie sua chave BRIX usando seu celular ou email.',
                  style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 14),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),

          const SizedBox(height: 28),

          // Phone / Email selector
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                _buildContactTab('📱 Celular', true),
                _buildContactTab('📧 Email', false),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Contact input
          TextField(
            controller: _contactController,
            keyboardType: _isPhone ? TextInputType.phone : TextInputType.emailAddress,
            style: const TextStyle(color: Colors.white, fontSize: 18),
            decoration: InputDecoration(
              labelText: _isPhone ? 'Seu celular' : 'Seu email',
              labelStyle: const TextStyle(color: Colors.white38),
              hintText: _isPhone ? '+55 11 99988-7766' : 'seu@email.com',
              hintStyle: const TextStyle(color: Colors.white24),
              prefixIcon: Icon(
                _isPhone ? Icons.phone : Icons.email,
                color: Colors.amber,
              ),
              filled: true,
              fillColor: const Color(0xFF1A1A1A),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Colors.amber),
              ),
            ),
          ),

          const SizedBox(height: 6),
          Text(
            _isPhone
                ? 'Usaremos para verificar sua conta'
                : 'Enviaremos um código de confirmação',
            style: TextStyle(color: Colors.white.withOpacity(0.35), fontSize: 12),
          ),

          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
          ],

          const SizedBox(height: 28),

          // Next button
          SizedBox(
            height: 52,
            child: ElevatedButton(
              onPressed: _goToUsername,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.amber,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              child: const Text('Continuar'),
            ),
          ),

          const SizedBox(height: 20),
          Text(
            'Grátis • Sem KYC • Sem banco',
            style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildContactTab(String label, bool isPhoneTab) {
    final selected = _isPhone == isPhoneTab;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() {
          _isPhone = isPhoneTab;
          _contactController.clear();
          _error = null;
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: selected ? Colors.amber.withOpacity(0.2) : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: selected ? Border.all(color: Colors.amber.withOpacity(0.5)) : null,
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: selected ? Colors.amber : Colors.white54,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  // ─── STEP 2: Username ──────────────────────────────────────
  Widget _buildUsernameStep() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Step indicator
          Row(
            children: [
              GestureDetector(
                onTap: () => setState(() { _step = BrixStep.contact; _error = null; }),
                child: const Icon(Icons.arrow_back_ios, color: Colors.white38, size: 18),
              ),
              const SizedBox(width: 8),
              Text(
                'Passo 2 de 3',
                style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 16),

          const Text(
            'Escolha seu apelido',
            style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(
            'Esse será seu endereço para receber Bitcoin. Igual a uma chave PIX.',
            style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 14),
          ),

          const SizedBox(height: 24),

          // Username input
          TextField(
            controller: _usernameController,
            keyboardType: TextInputType.text,
            style: const TextStyle(color: Colors.white, fontSize: 18),
            onChanged: _onUsernameChanged,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9_]')),
              LengthLimitingTextInputFormatter(20),
            ],
            decoration: InputDecoration(
              labelText: 'Apelido',
              labelStyle: const TextStyle(color: Colors.white38),
              hintText: 'fulano',
              hintStyle: const TextStyle(color: Colors.white24),
              prefixIcon: const Icon(Icons.alternate_email, color: Colors.amber),
              suffixIcon: _checkingUsername
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.amber)),
                    )
                  : _usernameAvailable == true
                      ? const Icon(Icons.check_circle, color: Colors.green)
                      : _usernameAvailable == false
                          ? const Icon(Icons.cancel, color: Colors.redAccent)
                          : null,
              filled: true,
              fillColor: const Color(0xFF1A1A1A),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Colors.amber),
              ),
            ),
          ),

          const SizedBox(height: 12),

          // Preview address
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _usernameAvailable == true ? Colors.amber.withOpacity(0.4) : Colors.white.withOpacity(0.05)),
            ),
            child: Row(
              children: [
                const Text('⚡ ', style: TextStyle(fontSize: 18)),
                Expanded(
                  child: Text(
                    _previewAddress(),
                    style: TextStyle(
                      color: _usernameAvailable == true ? Colors.amber : Colors.white38,
                      fontFamily: 'monospace',
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),

          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
          ],

          const SizedBox(height: 28),

          // Create BRIX button
          SizedBox(
            height: 52,
            child: ElevatedButton(
              onPressed: _isLoading ? null : _register,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.amber,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              child: _isLoading
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                  : const Text('⚡ Criar meu BRIX'),
            ),
          ),
        ],
      ),
    );
  }

  // ─── STEP 3: Verify ────────────────────────────────────────
  Widget _buildVerifyStep() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 20),
          const Icon(Icons.verified_user, color: Colors.amber, size: 56),
          const SizedBox(height: 16),
          const Text(
            'Verificação',
            style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            _isPhone
                ? 'Enviamos um código de 6 dígitos para seu celular'
                : 'Enviamos um código de 6 dígitos para seu email',
            style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 14),
            textAlign: TextAlign.center,
          ),

          // Dev code hint
          if (_devCode != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.amber.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.amber.withOpacity(0.3)),
              ),
              child: Text(
                '🔧 Modo dev — código: $_devCode',
                style: const TextStyle(color: Colors.amber, fontSize: 13, fontFamily: 'monospace'),
                textAlign: TextAlign.center,
              ),
            ),
          ],

          const SizedBox(height: 24),

          // Code input
          TextField(
            controller: _codeController,
            keyboardType: TextInputType.number,
            maxLength: 6,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 32,
              fontWeight: FontWeight.bold,
              letterSpacing: 12,
              fontFamily: 'monospace',
            ),
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              counterText: '',
              hintText: '000000',
              hintStyle: TextStyle(color: Colors.white.withOpacity(0.15), fontSize: 32, letterSpacing: 12),
              filled: true,
              fillColor: const Color(0xFF1A1A1A),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Colors.amber),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Colors.amber, width: 2),
              ),
            ),
          ),

          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13), textAlign: TextAlign.center),
          ],

          const SizedBox(height: 24),

          // Verify button
          SizedBox(
            height: 52,
            child: ElevatedButton(
              onPressed: _isLoading ? null : _verify,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.amber,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              child: _isLoading
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                  : const Text('Verificar'),
            ),
          ),

          const SizedBox(height: 16),

          // Resend
          TextButton(
            onPressed: _resendCooldown > 0 ? null : _resend,
            child: Text(
              _resendCooldown > 0 ? 'Reenviar código (${_resendCooldown}s)' : 'Reenviar código',
              style: TextStyle(
                color: _resendCooldown > 0 ? Colors.white24 : Colors.amber,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── STEP 4: Active ────────────────────────────────────────
  Widget _buildActiveStep() {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── BRIX Address card ──
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.amber.withOpacity(0.2), Colors.orange.withOpacity(0.08)],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.amber.withOpacity(0.3)),
              ),
              child: Column(
                children: [
                  const Text('⚡', style: TextStyle(fontSize: 48)),
                  const SizedBox(height: 4),
                  const Text('BRIX Ativo', style: TextStyle(color: Colors.amber, fontSize: 22, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            _brixAddress ?? '',
                            style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 16, fontWeight: FontWeight.w600),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () {
                            if (_brixAddress != null) {
                              Clipboard.setData(ClipboardData(text: _brixAddress!));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Endereço copiado!'), backgroundColor: Colors.amber, duration: Duration(seconds: 2)),
                              );
                            }
                          },
                          child: const Icon(Icons.copy, color: Colors.amber, size: 20),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // ── Action buttons: Copy + Share ──
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        if (_brixAddress != null) {
                          Clipboard.setData(ClipboardData(text: _brixAddress!));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Endereço copiado!'), backgroundColor: Colors.amber),
                          );
                        }
                      },
                      icon: const Icon(Icons.copy, size: 18),
                      label: const Text('Copiar'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.amber,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        if (_brixAddress != null) {
                          Share.share('Me envie Bitcoin pelo meu endereço BRIX: $_brixAddress ⚡');
                        }
                      },
                      icon: const Icon(Icons.share, color: Colors.amber, size: 18),
                      label: const Text('Compartilhar', style: TextStyle(color: Colors.amber)),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.amber),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),

            // ── Registered contact info ──
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A1A),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white.withOpacity(0.06)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.person, color: Colors.amber, size: 20),
                      const SizedBox(width: 8),
                      const Text('Dados cadastrados', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15)),
                      const Spacer(),
                      if (!_isEditing)
                        GestureDetector(
                          onTap: () => setState(() { _isEditing = true; _error = null; }),
                          child: Row(
                            children: [
                              const Icon(Icons.edit, color: Colors.amber, size: 16),
                              const SizedBox(width: 4),
                              Text('Modificar', style: TextStyle(color: Colors.amber.withOpacity(0.8), fontSize: 13)),
                            ],
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Phone info
                  if (_registeredPhone != null && _registeredPhone!.isNotEmpty) ...[
                    _buildInfoRow(Icons.phone, 'Celular', _maskPhone(_registeredPhone!)),
                    const SizedBox(height: 8),
                  ],

                  // Email info
                  if (_registeredEmail != null && _registeredEmail!.isNotEmpty) ...[
                    _buildInfoRow(Icons.email, 'Email', _maskEmail(_registeredEmail!)),
                    const SizedBox(height: 8),
                  ],

                  // Username
                  _buildInfoRow(Icons.alternate_email, 'Username', _username ?? ''),

                  if (!_isEditing) ...[
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.amber.withOpacity(0.06),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        'Qualquer pessoa pode te enviar Bitcoin usando seu celular, email ou endereço BRIX.',
                        style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 12, height: 1.4),
                      ),
                    ),
                  ],
                ],
              ),
            ),

            // ── Edit flow ──
            if (_isEditing) ...[
              const SizedBox(height: 16),
              _buildEditSection(),
            ],

            const SizedBox(height: 20),

            // ── Info cards ──
            _buildInfoCard(
              icon: Icons.flash_on,
              title: 'Receba Bitcoin de qualquer lugar',
              description: 'Funciona com qualquer wallet Lightning. Basta compartilhar seu endereço BRIX.',
            ),
            const SizedBox(height: 10),
            _buildInfoCard(
              icon: Icons.phone_android,
              title: 'Funciona como um PIX',
              description: 'O app recebe os pagamentos automaticamente em segundo plano.',
            ),

            if (_error != null && !_isEditing) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13), textAlign: TextAlign.center),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, color: Colors.white24, size: 16),
        const SizedBox(width: 8),
        Text('$label: ', style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 13)),
        Expanded(
          child: Text(value, style: const TextStyle(color: Colors.white70, fontSize: 13, fontFamily: 'monospace')),
        ),
      ],
    );
  }

  Widget _buildEditSection() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.amber.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.edit, color: Colors.amber, size: 18),
              const SizedBox(width: 8),
              const Text('Alterar contato', style: TextStyle(color: Colors.amber, fontWeight: FontWeight.w600, fontSize: 15)),
              const Spacer(),
              GestureDetector(
                onTap: _cancelEdit,
                child: const Icon(Icons.close, color: Colors.white38, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 14),

          if (!_editWaitingCode) ...[
            // Phone/Email selector
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF0A0A0A),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  _buildEditTab('📱 Celular', true),
                  _buildEditTab('📧 Email', false),
                ],
              ),
            ),
            const SizedBox(height: 12),

            TextField(
              controller: _editContactController,
              keyboardType: _editIsPhone ? TextInputType.phone : TextInputType.emailAddress,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              decoration: InputDecoration(
                hintText: _editIsPhone ? '+55 11 99988-7766' : 'novo@email.com',
                hintStyle: const TextStyle(color: Colors.white24),
                prefixIcon: Icon(_editIsPhone ? Icons.phone : Icons.email, color: Colors.amber, size: 20),
                filled: true,
                fillColor: const Color(0xFF0A0A0A),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.white.withOpacity(0.1))),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.white.withOpacity(0.1))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Colors.amber)),
              ),
            ),

            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ],

            const SizedBox(height: 14),
            SizedBox(
              height: 44,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _requestContactUpdate,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.amber,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: _isLoading
                    ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                    : const Text('Enviar código de verificação', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ] else ...[
            // Verification code input
            Text(
              'Enviamos um código para ${_editIsPhone ? "o novo celular" : "o novo email"}',
              style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 13),
            ),

            if (_editDevCode != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.amber.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('🔧 DEV código: $_editDevCode', style: const TextStyle(color: Colors.amber, fontSize: 12, fontFamily: 'monospace'), textAlign: TextAlign.center),
              ),
            ],

            const SizedBox(height: 12),
            TextField(
              controller: _editCodeController,
              keyboardType: TextInputType.number,
              maxLength: 6,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold, letterSpacing: 8, fontFamily: 'monospace'),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                counterText: '',
                hintText: '000000',
                hintStyle: TextStyle(color: Colors.white.withOpacity(0.15), fontSize: 24, letterSpacing: 8),
                filled: true,
                fillColor: const Color(0xFF0A0A0A),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Colors.amber)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.white.withOpacity(0.1))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Colors.amber, width: 2)),
              ),
            ),

            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12), textAlign: TextAlign.center),
            ],

            const SizedBox(height: 14),
            SizedBox(
              height: 44,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _confirmContactUpdate,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.amber,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: _isLoading
                    ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                    : const Text('Confirmar', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEditTab(String label, bool isPhoneTab) {
    final selected = _editIsPhone == isPhoneTab;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() {
          _editIsPhone = isPhoneTab;
          _editContactController.clear();
          _error = null;
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? Colors.amber.withOpacity(0.15) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: selected ? Border.all(color: Colors.amber.withOpacity(0.4)) : null,
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(color: selected ? Colors.amber : Colors.white54, fontWeight: FontWeight.w600, fontSize: 13),
          ),
        ),
      ),
    );
  }

  Widget _buildInfoCard({
    required IconData icon,
    required String title,
    required String description,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.amber.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: Colors.amber, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
                const SizedBox(height: 4),
                Text(description, style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
