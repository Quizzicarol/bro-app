import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../providers/breez_provider_export.dart';
import '../services/storage_service.dart';

/// Tela de administração da carteira Lightning
/// Permite ver saldo, gerar endereços e gerenciar fundos
class AdminWalletScreen extends StatefulWidget {
  const AdminWalletScreen({Key? key}) : super(key: key);

  @override
  State<AdminWalletScreen> createState() => _AdminWalletScreenState();
}

class _AdminWalletScreenState extends State<AdminWalletScreen> {
  Map<String, dynamic>? _balance;
  List<Map<String, dynamic>> _payments = [];
  String? _bitcoinAddress;
  String? _lightningInvoice;
  String? _mnemonic;
  bool _isLoading = false;
  bool _showMnemonic = false;
  int _invoiceAmountSats = 1000;
  final _invoiceController = TextEditingController(text: '1000');

  @override
  void initState() {
    super.initState();
    _loadWalletInfo();
  }

  @override
  void dispose() {
    _invoiceController.dispose();
    super.dispose();
  }

  Future<void> _loadWalletInfo() async {
    setState(() => _isLoading = true);

    try {
      final breezProvider = context.read<BreezProvider>();
      
      // Garantir que SDK está inicializado
      if (!breezProvider.isInitialized) {
        await breezProvider.initialize();
      }

      // Carregar saldo
      final balance = await breezProvider.getBalance();
      
      // Carregar histórico de pagamentos
      final payments = await breezProvider.listPayments();

      // Carregar mnemonic
      final mnemonic = await StorageService().getBreezMnemonic();

      setState(() {
        _balance = balance;
        _payments = payments;
        _mnemonic = mnemonic;
      });
    } catch (e) {
      debugPrint('Erro ao carregar info da carteira: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _generateBitcoinAddress() async {
    setState(() => _isLoading = true);

    try {
      final breezProvider = context.read<BreezProvider>();
      final result = await breezProvider.createOnchainAddress();

      if (result?['success'] == true) {
        setState(() {
          _bitcoinAddress = result!['swap']['bitcoinAddress'];
        });
      } else {
        throw Exception(result?['error'] ?? 'Erro desconhecido');
      }
    } catch (e) {
      debugPrint('Erro ao gerar endereço Bitcoin: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _generateLightningInvoice() async {
    setState(() => _isLoading = true);

    try {
      final breezProvider = context.read<BreezProvider>();
      final result = await breezProvider.createInvoice(
        amountSats: _invoiceAmountSats,
        description: 'Admin - Recebimento de Taxas',
      );

      if (result?['success'] == true) {
        setState(() {
          _lightningInvoice = result!['invoice'];
        });
      } else {
        throw Exception(result?['error'] ?? 'Erro desconhecido');
      }
    } catch (e) {
      debugPrint('Erro ao gerar invoice Lightning: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label copiado!'),
        backgroundColor: const Color(0xFFFF6B6B),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        elevation: 0,
        title: const Text('Admin Wallet', style: TextStyle(color: Colors.white)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: _loadWalletInfo,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFFF6B6B)),
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // SALDO
                  _buildSectionTitle('💰 Saldo da Carteira'),
                  _buildBalanceCard(),
                  const SizedBox(height: 24),

                  // ENDEREÇO BITCOIN
                  _buildSectionTitle('₿ Endereço Bitcoin (On-Chain)'),
                  _buildBitcoinAddressCard(),
                  const SizedBox(height: 24),

                  // INVOICE LIGHTNING
                  _buildSectionTitle('⚡ Invoice Lightning'),
                  _buildLightningInvoiceCard(),
                  const SizedBox(height: 24),

                  // HISTÓRICO DE PAGAMENTOS
                  _buildSectionTitle('📜 Histórico de Pagamentos'),
                  _buildPaymentsHistory(),
                  const SizedBox(height: 24),

                  // MNEMONIC (BACKUP)
                  _buildSectionTitle('🔑 Backup da Carteira'),
                  _buildMnemonicCard(),
                  const SizedBox(height: 32),
                ],
              ),
            ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildBalanceCard() {
    final balanceSats = int.tryParse(_balance?['balance']?.toString() ?? '0') ?? 0;
    final balanceBtc = balanceSats / 100000000;
    
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1A1A2E), Color(0xFF16213E)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFF6B6B).withOpacity(0.3)),
      ),
      child: Column(
        children: [
          const Icon(Icons.account_balance_wallet, color: Color(0xFFFF6B6B), size: 48),
          const SizedBox(height: 12),
          Text(
            '$balanceSats sats',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 32,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            '${balanceBtc.toStringAsFixed(8)} BTC',
            style: const TextStyle(color: Colors.white70, fontSize: 16),
          ),
          if (_balance?['error'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Erro: ${_balance!['error']}',
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBitcoinAddressCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF333333)),
      ),
      child: Column(
        children: [
          if (_bitcoinAddress == null) ...[
            const Text(
              'Gere um endereço Bitcoin para receber fundos on-chain.\nDepósitos são convertidos automaticamente para Lightning.',
              style: TextStyle(color: Colors.white70, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _generateBitcoinAddress,
              icon: const Icon(Icons.add, color: Colors.white),
              label: const Text('Gerar Endereço Bitcoin', style: TextStyle(color: Colors.white)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFF7931A),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
            ),
          ] else ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: QrImageView(
                data: _bitcoinAddress!,
                size: 180,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF0A0A0A),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _bitcoinAddress!,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: () => _copyToClipboard(_bitcoinAddress!, 'Endereço'),
                  icon: const Icon(Icons.copy, size: 16, color: Colors.white),
                  label: const Text('Copiar', style: TextStyle(color: Colors.white)),
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFF7931A)),
                ),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: () => setState(() => _bitcoinAddress = null),
                  child: const Text('Novo Endereço', style: TextStyle(color: Colors.white70)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLightningInvoiceCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF333333)),
      ),
      child: Column(
        children: [
          if (_lightningInvoice == null) ...[
            const Text(
              'Gere uma invoice Lightning para receber pagamentos instantâneos.',
              style: TextStyle(color: Colors.white70, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _invoiceController,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Valor em sats',
                      labelStyle: const TextStyle(color: Colors.white70),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFF333333)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFFFF6B6B)),
                      ),
                    ),
                    onChanged: (value) {
                      _invoiceAmountSats = int.tryParse(value) ?? 1000;
                    },
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: _generateLightningInvoice,
                  icon: const Icon(Icons.flash_on, color: Colors.white),
                  label: const Text('Gerar', style: TextStyle(color: Colors.white)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF6B6B),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  ),
                ),
              ],
            ),
          ] else ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: QrImageView(
                data: _lightningInvoice!,
                size: 180,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '$_invoiceAmountSats sats',
              style: const TextStyle(
                color: Color(0xFFFF6B6B),
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF0A0A0A),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${_lightningInvoice!.substring(0, 50)}...',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: () => _copyToClipboard(_lightningInvoice!, 'Invoice'),
                  icon: const Icon(Icons.copy, size: 16, color: Colors.white),
                  label: const Text('Copiar', style: TextStyle(color: Colors.white)),
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF6B6B)),
                ),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: () => setState(() => _lightningInvoice = null),
                  child: const Text('Nova Invoice', style: TextStyle(color: Colors.white70)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPaymentsHistory() {
    if (_payments.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Column(
          children: [
            Icon(Icons.history, color: Colors.white38, size: 48),
            SizedBox(height: 12),
            Text(
              'Nenhum pagamento ainda',
              style: TextStyle(color: Colors.white70),
            ),
          ],
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: _payments.length > 10 ? 10 : _payments.length,
        separatorBuilder: (_, __) => const Divider(color: Color(0xFF333333), height: 1),
        itemBuilder: (context, index) {
          final payment = _payments[index];
          final isReceived = payment['type'] == 'received';
          final amount = payment['amount'] ?? '0';
          final status = payment['status'] ?? 'unknown';
          
          return ListTile(
            leading: Icon(
              isReceived ? Icons.arrow_downward : Icons.arrow_upward,
              color: isReceived ? Colors.green : Colors.red,
            ),
            title: Text(
              '${isReceived ? '+' : '-'}$amount sats',
              style: TextStyle(
                color: isReceived ? Colors.green : Colors.red,
                fontWeight: FontWeight.bold,
              ),
            ),
            subtitle: Text(
              status,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            trailing: Text(
              payment['timestamp'] ?? '',
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          );
        },
      ),
    );
  }

  Widget _buildMnemonicCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _showMnemonic ? Colors.red.withOpacity(0.5) : const Color(0xFF333333),
        ),
      ),
      child: Column(
        children: [
          const Row(
            children: [
              Icon(Icons.warning_amber, color: Colors.amber, size: 20),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'NUNCA compartilhe seu mnemonic! Quem tiver acesso pode roubar seus fundos.',
                  style: TextStyle(color: Colors.amber, fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (!_showMnemonic)
            ElevatedButton.icon(
              onPressed: () => setState(() => _showMnemonic = true),
              icon: const Icon(Icons.visibility, color: Colors.white),
              label: const Text('Mostrar Mnemonic (Backup)', style: TextStyle(color: Colors.white)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade700,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
            )
          else ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF0A0A0A),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.withOpacity(0.3)),
              ),
              child: SelectableText(
                _mnemonic ?? 'Mnemonic não encontrado',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontFamily: 'monospace',
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_mnemonic != null)
                  ElevatedButton.icon(
                    onPressed: () => _copyToClipboard(_mnemonic!, 'Mnemonic'),
                    icon: const Icon(Icons.copy, size: 16, color: Colors.white),
                    label: const Text('Copiar', style: TextStyle(color: Colors.white)),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade700),
                  ),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: () => setState(() => _showMnemonic = false),
                  child: const Text('Esconder', style: TextStyle(color: Colors.white70)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
