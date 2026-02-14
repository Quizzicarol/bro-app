import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../providers/breez_provider_export.dart';
import '../providers/lightning_provider.dart';
import '../providers/provider_balance_provider.dart';
import '../providers/order_provider.dart';
import '../services/storage_service.dart';
import '../services/nostr_service.dart';
import '../services/lnaddress_service.dart';
import '../services/local_collateral_service.dart';
import '../services/platform_fee_service.dart';
import '../config.dart';

/// Tela de Carteira Lightning - Apenas BOLT11 (invoice)
/// Funções: Ver saldo, Enviar pagamento, Receber (gerar invoice)
class WalletScreen extends StatefulWidget {
  const WalletScreen({Key? key}) : super(key: key);

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  Map<String, dynamic>? _balance;
  List<Map<String, dynamic>> _payments = [];
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadWalletInfo();
  }

  Future<void> _loadWalletInfo() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final breezProvider = context.read<BreezProvider>();
      
      if (!breezProvider.isInitialized) {
        debugPrint('🔄 Inicializando Breez SDK...');
        final success = await breezProvider.initialize();
        if (!success) {
          throw Exception('Falha ao inicializar SDK');
        }
      }

      final balance = await breezProvider.getBalance();
      final payments = await breezProvider.listPayments();
      
      // Carregar transações de ganhos como Bro
      final providerBalanceProvider = context.read<ProviderBalanceProvider>();
      final nostrService = NostrService();
      final providerId = nostrService.publicKey ?? 'unknown';
      await providerBalanceProvider.initialize(providerId);
      
      // Mesclar transações do Bro com pagamentos Lightning
      List<Map<String, dynamic>> allPayments = [...payments];
      
      if (providerBalanceProvider.balance != null) {
        for (var tx in providerBalanceProvider.balance!.transactions) {
          if (tx.type == 'earning') {
            allPayments.add({
              'type': 'received',
              'amountSats': tx.amountSats.toInt(),
              'amount': tx.amountSats.toInt(),
              'createdAt': tx.createdAt,
              'timestamp': tx.createdAt,
              'description': tx.orderDescription ?? 'Ganho como Bro',
              'isBroEarning': true,
              'status': 'Complete',
            });
          }
        }
      }
      
      // Ordenar por data (mais recente primeiro)
      allPayments.sort((a, b) {
        final dateA = a['createdAt'] ?? a['timestamp'];
        final dateB = b['createdAt'] ?? b['timestamp'];
        if (dateA == null && dateB == null) return 0;
        if (dateA == null) return 1;
        if (dateB == null) return -1;
        if (dateA is DateTime && dateB is DateTime) {
          return dateB.compareTo(dateA);
        }
        return 0;
      });
      
      debugPrint('💰 Saldo: ${balance?['balance']} sats');
      debugPrint('📜 Pagamentos: ${allPayments.length} (incluindo ganhos Bro)');

      if (mounted) {
        setState(() {
          _balance = balance;
          _payments = allPayments;
        });
      }
    } catch (e) {
      debugPrint('❌ Erro ao carregar carteira: $e');
      if (mounted) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _showDiagnostics() async {
    final breezProvider = context.read<BreezProvider>();
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: CircularProgressIndicator(color: Color(0xFFFF9800)),
      ),
    );
    
    try {
      final diagnostics = await breezProvider.getFullDiagnostics();
      
      if (!mounted) return;
      Navigator.of(context).pop(); // Fechar loading
      
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          title: const Row(
            children: [
              Icon(Icons.bug_report, color: Color(0xFFFF9800)),
              SizedBox(width: 8),
              Text('Diagnóstico SDK', style: TextStyle(color: Colors.white)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _diagRow('Inicializado', '${diagnostics['isInitialized']}'),
                _diagRow('SDK Disponível', '${diagnostics['sdkAvailable']}'),
                _diagRow('Carteira Nova', '${diagnostics['isNewWallet']}'),
                const Divider(color: Colors.grey),
                _diagRow('Nostr Pubkey', '${diagnostics['nostrPubkey']}...'),
                _diagRow('Seed Words', '${diagnostics['seedWordCount']}'),
                _diagRow('Primeiras 2', '${diagnostics['seedFirst2Words']}'),
                const Divider(color: Colors.grey),
                _diagRow('Storage Dir Existe', '${diagnostics['storageDirExists']}'),
                const Divider(color: Colors.grey),
                _diagRow('💰 SALDO', '${diagnostics['balanceSats'] ?? '?'} sats', highlight: true),
                _diagRow('Total Pagamentos', '${diagnostics['totalPayments'] ?? '?'}'),
                if (diagnostics['recentPayments'] != null) ...[
                  const SizedBox(height: 8),
                  const Text('Últimos pagamentos:', style: TextStyle(color: Colors.white70, fontSize: 12)),
                  for (var p in (diagnostics['recentPayments'] as List))
                    Text(
                      '  ${p['amount']} sats - ${p['status']}',
                      style: const TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                ],
                // NOVO: Mostrar todas as seeds encontradas
                const Divider(color: Colors.orange),
                _diagRow('Seeds encontradas', '${diagnostics['totalSeedsFound'] ?? 0}'),
                if (diagnostics['allSeeds'] != null) ...[
                  const SizedBox(height: 8),
                  const Text('🔐 TODAS AS SEEDS:', style: TextStyle(color: Colors.amber, fontSize: 12, fontWeight: FontWeight.bold)),
                  for (var entry in (diagnostics['allSeeds'] as Map).entries)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${entry.key}:',
                            style: TextStyle(
                              color: entry.key == 'CURRENT_USER' ? Colors.greenAccent : Colors.white70,
                              fontSize: 11,
                              fontWeight: entry.key == 'CURRENT_USER' ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                          Text(
                            '  ${(entry.value as Map)['first2Words']} (${(entry.value as Map)['wordCount']} palavras)',
                            style: const TextStyle(color: Colors.white54, fontSize: 10),
                          ),
                        ],
                      ),
                    ),
                ],
                if (diagnostics['error'] != null) ...[
                  const Divider(color: Colors.red),
                  Text('ERRO: ${diagnostics['error']}', style: const TextStyle(color: Colors.red, fontSize: 12)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('FECHAR', style: TextStyle(color: Color(0xFFFF9800))),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erro: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Widget _diagRow(String label, String value, {bool highlight = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: highlight ? Colors.amber : Colors.white70, fontSize: 12)),
          Text(
            value,
            style: TextStyle(
              color: highlight ? Colors.greenAccent : Colors.white,
              fontSize: 12,
              fontWeight: highlight ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Row(
          children: [
            Icon(Icons.account_balance_wallet, color: Color(0xFFFF9800)),
            SizedBox(width: 8),
            Text('Minha Carteira', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Color(0xFFFF9800)),
            SizedBox(height: 16),
            Text('Carregando carteira...', style: TextStyle(color: Colors.white70)),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 64),
              const SizedBox(height: 16),
              Text(
                'Erro ao carregar carteira',
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _loadWalletInfo,
                icon: const Icon(Icons.refresh),
                label: const Text('Tentar novamente'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF9800),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadWalletInfo,
      color: const Color(0xFFFF9800),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildBalanceCard(),
            const SizedBox(height: 20),
            _buildActionButtons(),
            const SizedBox(height: 24),
            _buildPaymentsHistory(),
            const SizedBox(height: 24),
            _buildPlatformFeesSection(),
            const SizedBox(height: 40), // Extra padding at bottom
          ],
        ),
      ),
    );
  }

  Widget _buildBalanceCard() {
    final balanceSats = int.tryParse(_balance?['balance']?.toString() ?? '0') ?? 0;
    final balanceBtc = balanceSats / 100000000;
    final hasError = _balance?['error'] != null;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: hasError 
              ? [Colors.grey.shade800, Colors.grey.shade700]
              : [const Color(0xFFFF9800), const Color(0xFFFFB74D)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: (hasError ? Colors.grey : const Color(0xFFFF9800)).withOpacity(0.3),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.flash_on, color: Colors.white, size: 24),
              SizedBox(width: 8),
              Text(
                'Saldo Lightning',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (hasError)
            Text(
              'Erro: ${_balance?['error']}',
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            )
          else ...[
            Text(
              _formatSats(balanceSats),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '≈ ${balanceBtc.toStringAsFixed(8)} BTC',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _formatSats(int sats) {
    return '${sats.toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (Match m) => '${m[1]}.')} sats';
  }

  Widget _buildActionButtons() {
    return Row(
      children: [
        Expanded(
          child: _buildActionButton(
            icon: Icons.arrow_upward,
            label: 'Enviar',
            color: const Color(0xFFE53935),
            onTap: _showSendDialog,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildActionButton(
            icon: Icons.arrow_downward,
            label: 'Receber',
            color: const Color(0xFF4CAF50),
            onTap: _showReceiveDialog,
          ),
        ),
      ],
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: color.withOpacity(0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Column(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(22),
              ),
              child: Icon(icon, color: Colors.white, size: 24),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== ENVIAR ====================
  void _showSendDialog() async {
    final invoiceController = TextEditingController();
    final amountController = TextEditingController();
    bool isSending = false;
    bool showAmountField = false;
    String? errorMessage;
    
    // Get current balance
    final balanceSats = int.tryParse(_balance?['balance']?.toString() ?? '0') ?? 0;
    
    // Get committed sats (orders in progress)
    final orderProvider = context.read<OrderProvider>();
    final committedSats = orderProvider.committedSats;
    
    // Get tier locked sats (if any)
    final collateralService = LocalCollateralService();
    final collateral = await collateralService.getCollateral();
    final tierLockedSats = collateral?.lockedSats ?? 0;
    final tierName = collateral?.tierName;
    
    // Total locked = orders + tier
    final totalLockedSats = committedSats + tierLockedSats;
    final availableSats = (balanceSats - totalLockedSats).clamp(0, balanceSats);
    final hasLockedFunds = totalLockedSats > 0;
    final hasTierActive = tierLockedSats > 0;
    
    if (!mounted) return;
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => SafeArea(
          minimum: const EdgeInsets.only(bottom: 20),
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom + 24,
              left: 20,
              right: 20,
              top: 20,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                // Header
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: const Color(0xFFE53935).withOpacity(0.2),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Icon(Icons.arrow_upward, color: Color(0xFFE53935)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Enviar Bitcoin',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (hasLockedFunds) ...[
                            Text(
                              'Disponível: $availableSats sats',
                              style: TextStyle(
                                color: availableSats > 0 ? Colors.green : Colors.orange,
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              'Em ordens: $committedSats sats',
                              style: const TextStyle(
                                color: Colors.orange,
                                fontSize: 13,
                              ),
                            ),
                          ] else ...[
                            Text(
                              'Saldo: $balanceSats sats',
                              style: TextStyle(
                                color: balanceSats > 0 ? Colors.green : Colors.grey,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                
                // Aviso de fundos bloqueados
                if (hasLockedFunds) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.orange.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.orange.withOpacity(0.3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.lock, color: Colors.orange, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '$totalLockedSats sats bloqueados',
                                style: const TextStyle(color: Colors.orange, fontSize: 12, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                        if (hasTierActive) ...[
                          const SizedBox(height: 4),
                          Text(
                            '• $tierLockedSats sats no Tier "$tierName"',
                            style: const TextStyle(color: Colors.orange, fontSize: 11),
                          ),
                        ],
                        if (committedSats > 0) ...[
                          const SizedBox(height: 2),
                          Text(
                            '• $committedSats sats em ordens abertas',
                            style: const TextStyle(color: Colors.orange, fontSize: 11),
                          ),
                        ],
                        if (hasTierActive) ...[
                          const SizedBox(height: 6),
                          Text(
                            '⚠️ Sacar tudo desativará seu Tier!',
                            style: TextStyle(color: Colors.red.shade300, fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
                
                const SizedBox(height: 20),
                
                // Campo de destino (Invoice, LNURL, ou Lightning Address)
                TextField(
                  controller: invoiceController,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  maxLines: 2,
                  enabled: !isSending,
                  onChanged: (value) {
                    // Se for Lightning Address ou LNURL-pay, mostrar campo de valor
                    final trimmed = value.trim().toLowerCase();
                    final isLnAddress = trimmed.contains('@') && trimmed.contains('.');
                    final isLnurl = trimmed.startsWith('lnurl');
                    final needsAmount = isLnAddress || isLnurl;
                    
                    if (needsAmount != showAmountField) {
                      setModalState(() {
                        showAmountField = needsAmount;
                        errorMessage = null;
                      });
                    }
                  },
                  decoration: InputDecoration(
                    labelText: 'Destino',
                    labelStyle: TextStyle(color: Colors.white.withOpacity(0.6)),
                    hintText: 'Invoice, Lightning Address ou LNURL',
                    hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                    helperText: 'Ex: lnbc..., user@wallet.com, LNURL...',
                    helperStyle: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 11),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFF333333)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFF333333)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFFE53935)),
                    ),
                  ),
                ),
                
                // Campo de valor (mostrado para Lightning Address e LNURL)
                if (showAmountField) ...[
                  const SizedBox(height: 16),
                  TextField(
                    controller: amountController,
                    style: const TextStyle(color: Colors.white, fontSize: 18),
                    keyboardType: TextInputType.number,
                    enabled: !isSending,
                    decoration: InputDecoration(
                      labelText: 'Valor a enviar',
                      labelStyle: TextStyle(color: Colors.white.withOpacity(0.6)),
                      hintText: 'Ex: 1000',
                      hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                      prefixIcon: const Icon(Icons.bolt, color: Colors.orange),
                      suffixText: 'sats',
                      suffixStyle: const TextStyle(color: Colors.orange),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFF333333)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFF333333)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFFFF9800)),
                      ),
                    ),
                  ),
                ],
                
                // Mensagem de erro
                if (errorMessage != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.red.withOpacity(0.3)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline, color: Colors.red, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            errorMessage!,
                            style: const TextStyle(color: Colors.red, fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                
                const SizedBox(height: 12),
                
                // Botão Colar
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: isSending ? null : () async {
                      final data = await Clipboard.getData('text/plain');
                      if (data?.text != null) {
                        invoiceController.text = data!.text!.trim();
                        
                        // Verificar se precisa mostrar campo de valor
                        final trimmed = data.text!.trim().toLowerCase();
                        final isLnAddr = trimmed.contains('@') && trimmed.contains('.');
                        final isLnurl = trimmed.startsWith('lnurl');
                        final needsAmount = isLnAddr || isLnurl;
                        
                        setModalState(() {
                          showAmountField = needsAmount;
                          errorMessage = null;
                        });
                        
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(needsAmount 
                                ? '✅ Colado! Digite o valor em sats.'
                                : '✅ Colado!'),
                              duration: const Duration(seconds: 1),
                            ),
                          );
                        }
                      }
                    },
                    icon: const Icon(Icons.paste),
                    label: const Text('Colar da área de transferência'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFFF9800),
                      side: const BorderSide(color: Color(0xFFFF9800)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                
                // Botão Scanear QR
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: isSending ? null : () async {
                      Navigator.pop(context); // Fechar modal atual
                      final scannedInvoice = await _showQRScanner();
                      if (scannedInvoice != null && scannedInvoice.isNotEmpty) {
                        // Reabrir o dialog com a invoice escaneada
                        _showSendDialogWithInvoice(scannedInvoice);
                      }
                    },
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Escanear QR Code'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.green,
                      side: const BorderSide(color: Colors.green),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                
                // Botão Enviar
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: isSending ? null : () async {
                      final destination = invoiceController.text.trim();
                      if (destination.isEmpty) {
                        setModalState(() => errorMessage = 'Digite um destino');
                        return;
                      }
                      
                      final lowerDest = destination.toLowerCase();
                      
                      // Verificar se é endereço Bitcoin (não suportado)
                      if (_isBitcoinAddress(destination)) {
                        setModalState(() => errorMessage = 'Envio para endereço Bitcoin on-chain não disponível. Use Lightning.');
                        return;
                      }
                      
                      // Verificar se é Lightning Address ou LNURL (precisa de valor)
                      final isLnAddress = destination.contains('@') && destination.contains('.');
                      final isLnurl = lowerDest.startsWith('lnurl');
                      final needsAmountInput = isLnAddress || isLnurl;
                      
                      // Atualizar UI se necessário
                      if (needsAmountInput != showAmountField) {
                        setModalState(() {
                          showAmountField = needsAmountInput;
                          errorMessage = needsAmountInput ? 'Digite o valor em sats' : null;
                        });
                        return;
                      }
                      
                      // Se for Lightning Address ou LNURL, precisamos de um valor
                      if (needsAmountInput) {
                        final amountText = amountController.text.trim();
                        final amountSats = int.tryParse(amountText);
                        
                        if (amountSats == null || amountSats <= 0) {
                          setModalState(() => errorMessage = 'Digite um valor válido em sats');
                          return;
                        }
                        
                        if (amountSats > availableSats) {
                          if (hasTierActive && amountSats > balanceSats - tierLockedSats) {
                            setModalState(() => errorMessage = 'Você precisa manter $tierLockedSats sats para o Tier "$tierName". Remova o tier primeiro em Níveis de Garantia.');
                          } else if (hasLockedFunds) {
                            setModalState(() => errorMessage = 'Saldo insuficiente! Disponível: $availableSats sats ($totalLockedSats bloqueados)');
                          } else {
                            setModalState(() => errorMessage = 'Saldo insuficiente! Você tem $balanceSats sats');
                          }
                          return;
                        }
                        
                        setModalState(() {
                          isSending = true;
                          errorMessage = null;
                        });
                        
                        debugPrint('💸 Enviando $amountSats sats para $destination...');
                        
                        try {
                          final breezProvider = context.read<BreezProvider>();
                          final lnAddressService = LnAddressService();
                          
                          // Resolver Lightning Address ou LNURL para invoice BOLT11
                          final invoiceResult = await lnAddressService.getInvoice(
                            lnAddress: destination,
                            amountSats: amountSats,
                          );
                          
                          if (invoiceResult['success'] != true) {
                            setModalState(() {
                              isSending = false;
                              errorMessage = invoiceResult['error'] ?? 'Falha ao resolver endereço';
                            });
                            return;
                          }
                          
                          final invoice = invoiceResult['invoice'] as String;
                          debugPrint('📝 Invoice obtida: ${invoice.substring(0, 50)}...');
                          
                          // Pagar a invoice
                          final result = await breezProvider.payInvoice(invoice);
                          
                          if (result != null && result['success'] == true) {
                            if (context.mounted) {
                              Navigator.pop(context);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('✅ Pagamento enviado com sucesso!'),
                                  backgroundColor: Color(0xFF4CAF50),
                                ),
                              );
                            }
                            _loadWalletInfo();
                          } else {
                            setModalState(() {
                              isSending = false;
                              errorMessage = result?['error'] ?? 'Falha ao enviar pagamento';
                            });
                          }
                        } catch (e) {
                          debugPrint('❌ Erro ao enviar: $e');
                          setModalState(() {
                            isSending = false;
                            errorMessage = 'Erro: $e';
                          });
                        }
                        return;
                      }
                      
                      // Verificar se é Lightning invoice válida
                      if (!lowerDest.startsWith('lnbc') && 
                          !lowerDest.startsWith('lntb') &&
                          !lowerDest.startsWith('lnurl') &&
                          !isLnAddress) {
                        setModalState(() => errorMessage = 'Formato inválido. Use Invoice, Lightning Address ou LNURL.');
                        return;
                      }
                      
                      setModalState(() {
                        isSending = true;
                        errorMessage = null;
                      });
                      debugPrint('💸 Enviando pagamento...');
                      
                      try {
                        final breezProvider = context.read<BreezProvider>();
                        final result = await breezProvider.payInvoice(destination);
                        
                        debugPrint('📦 Resultado pagamento: $result');
                        
                        if (result != null && result['success'] == true) {
                          if (context.mounted) {
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('✅ Pagamento enviado com sucesso!'),
                                backgroundColor: Color(0xFF4CAF50),
                              ),
                            );
                          }
                          _loadWalletInfo(); // Atualizar saldo
                        } else {
                          // Erro específico de saldo insuficiente
                          final errorType = result?['errorType'];
                          final errorMsg = result?['error'] ?? 'Falha ao enviar pagamento';
                          
                          setModalState(() => isSending = false);
                          
                          if (context.mounted) {
                            if (errorType == 'INSUFFICIENT_FUNDS') {
                              // Mostrar dialog específico para saldo insuficiente
                              showDialog(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  backgroundColor: const Color(0xFF1A1A1A),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                  title: const Row(
                                    children: [
                                      Icon(Icons.account_balance_wallet, color: Colors.orange, size: 28),
                                      SizedBox(width: 12),
                                      Text('Saldo Insuficiente', style: TextStyle(color: Colors.white)),
                                    ],
                                  ),
                                  content: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        errorMsg,
                                        style: const TextStyle(color: Colors.white70),
                                      ),
                                      const SizedBox(height: 16),
                                      Container(
                                        padding: const EdgeInsets.all(12),
                                        decoration: BoxDecoration(
                                          color: Colors.orange.withOpacity(0.1),
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(color: Colors.orange.withOpacity(0.3)),
                                        ),
                                        child: Row(
                                          children: [
                                            const Icon(Icons.info_outline, color: Colors.orange, size: 20),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                'Deposite mais sats na sua carteira para fazer este pagamento.',
                                                style: TextStyle(color: Colors.orange.shade200, fontSize: 13),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(ctx),
                                      child: const Text('OK', style: TextStyle(color: Colors.orange)),
                                    ),
                                  ],
                                ),
                              );
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(errorMsg),
                                  backgroundColor: Colors.red,
                                  duration: const Duration(seconds: 4),
                                ),
                              );
                            }
                          }
                        }
                      } catch (e) {
                        debugPrint('❌ Erro ao enviar: $e');
                        setModalState(() => isSending = false);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Erro: $e'),
                              backgroundColor: Colors.red,
                            ),
                          );
                        }
                      }
                    },
                    icon: isSending
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.send),
                    label: Text(isSending ? 'Enviando...' : 'Enviar Pagamento'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFE53935),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Verifica se é um endereço Bitcoin válido (NÃO Lightning Address)
  bool _isBitcoinAddress(String code) {
    final lowerCode = code.toLowerCase().trim();
    
    // ⚡ Lightning Address: contém @ e . (ex: user@wallet.com)
    // NÃO é endereço Bitcoin on-chain!
    if (lowerCode.contains('@') && lowerCode.contains('.')) {
      return false;
    }
    
    // LNURL também NÃO é on-chain
    if (lowerCode.startsWith('lnurl')) {
      return false;
    }
    
    // Lightning Invoice também NÃO é on-chain
    if (lowerCode.startsWith('lnbc') || lowerCode.startsWith('lntb') || lowerCode.startsWith('lnbcrt')) {
      return false;
    }
    
    // Bitcoin mainnet/testnet addresses (on-chain)
    // bc1 = Bech32 SegWit mainnet
    if (lowerCode.startsWith('bc1')) return true;
    // tb1 = Bech32 SegWit testnet  
    if (lowerCode.startsWith('tb1')) return true;
    // 1xxx = Legacy P2PKH (26-35 chars, só números e letras)
    if (lowerCode.startsWith('1') && lowerCode.length >= 26 && lowerCode.length <= 35) return true;
    // 3xxx = P2SH (26-35 chars)
    if (lowerCode.startsWith('3') && lowerCode.length >= 26 && lowerCode.length <= 35) return true;
    // bitcoin: URI
    if (lowerCode.startsWith('bitcoin:')) return true;
    
    return false;
  }

  // Mostra dialog informando que envio para endereço Bitcoin não é suportado
  void _showBitcoinAddressNotSupportedDialog(String address) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.currency_bitcoin, color: Colors.orange, size: 28),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'Endereço Bitcoin',
                style: TextStyle(color: Colors.white, fontSize: 18),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.link, color: Colors.grey, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      address.length > 30 
                          ? '${address.substring(0, 15)}...${address.substring(address.length - 12)}'
                          : address,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.withOpacity(0.3)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.orange, size: 20),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Pagamentos para endereços Bitcoin on-chain ainda não são suportados.\n\nUse uma Lightning Invoice (lnbc/lntb) para enviar pagamentos.',
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('ENTENDI', style: TextStyle(color: Colors.orange)),
          ),
        ],
      ),
    );
  }

  // ==================== QR SCANNER ====================
  Future<String?> _showQRScanner() async {
    String? scannedCode;
    
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        bottom: true,
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.75,
          child: Column(
            children: [
              // Header
              Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                  color: Color(0xFF1A1A1A),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.qr_code_scanner, color: Colors.green, size: 28),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Escanear QR Code',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            'Lightning Invoice ou Endereço Bitcoin',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              
              // Scanner
              Expanded(
                child: MobileScanner(
                  onDetect: (capture) {
                    final List<Barcode> barcodes = capture.barcodes;
                    for (final barcode in barcodes) {
                      final code = barcode.rawValue;
                      if (code != null) {
                        final lowerCode = code.toLowerCase();
                        
                        // Lightning Invoice
                        if (lowerCode.startsWith('lnbc') || 
                            lowerCode.startsWith('lntb') ||
                            lowerCode.startsWith('lightning:')) {
                          scannedCode = lowerCode.startsWith('lightning:') 
                              ? code.substring(10) 
                              : code;
                          Navigator.pop(context);
                          break;
                        }
                        
                        // LNURL (withdraw, pay, etc)
                        if (lowerCode.startsWith('lnurl')) {
                          scannedCode = code;
                          Navigator.pop(context);
                          break;
                        }
                        
                        // Endereço Bitcoin
                        if (_isBitcoinAddress(code)) {
                          // Remover prefixo bitcoin: se existir
                          scannedCode = lowerCode.startsWith('bitcoin:') 
                              ? code.substring(8).split('?')[0]  // Remover parâmetros URI
                              : code;
                          Navigator.pop(context);
                          break;
                        }
                      }
                    }
                  },
                ),
              ),
              
              // Instruções
              Container(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                color: const Color(0xFF1A1A1A),
                child: const Column(
                  children: [
                    Icon(Icons.lightbulb_outline, color: Colors.amber, size: 24),
                    SizedBox(height: 8),
                    Text(
                      'Formatos suportados:\n• Lightning Invoice (lnbc, lntb)\n• Endereço Bitcoin (bc1, 1, 3)',
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    
    return scannedCode;
  }

  // ==================== ENVIAR COM INVOICE PRÉ-PREENCHIDA ====================
  void _showSendDialogWithInvoice(String invoice) {
    debugPrint('📤 Abrindo dialog de envio com invoice: ${invoice.substring(0, 50)}...');
    
    // Verificar se é endereço Bitcoin (não suportado)
    if (_isBitcoinAddress(invoice)) {
      _showBitcoinAddressNotSupportedDialog(invoice);
      return;
    }
    
    // Verificar se é Lightning Address ou LNURL (precisa de valor manual)
    final lowerInvoice = invoice.toLowerCase();
    final isLnAddress = invoice.contains('@') && invoice.contains('.');
    final isLnurl = lowerInvoice.startsWith('lnurl');
    final needsAmountInput = isLnAddress || isLnurl;
    
    final invoiceController = TextEditingController(text: invoice);
    final amountController = TextEditingController();
    bool isSending = false;
    String? errorMessage;
    int? invoiceAmountSats; // Valor da invoice (se BOLT11)
    
    // Get current balance and available balance
    final balanceSats = int.tryParse(_balance?['balance']?.toString() ?? '0') ?? 0;
    final orderProvider = context.read<OrderProvider>();
    final committedSats = orderProvider.committedSats;
    final availableSats = (balanceSats - committedSats).clamp(0, balanceSats);
    final hasLockedFunds = committedSats > 0;
    
    // Tentar decodificar o valor da invoice BOLT11
    if (lowerInvoice.startsWith('lnbc') || lowerInvoice.startsWith('lntb')) {
      // É uma invoice BOLT11 - tentar extrair o valor
      // Formato: lnbc<amount><unit>... onde unit pode ser m (milli), u (micro), n (nano), p (pico)
      try {
        final regex = RegExp(r'^ln[bt]c(\d+)([munp]?)');
        final match = regex.firstMatch(lowerInvoice);
        if (match != null) {
          final amountStr = match.group(1)!;
          final unit = match.group(2) ?? '';
          var amount = int.parse(amountStr);
          
          // Converter para sats baseado na unidade
          switch (unit) {
            case 'm': // milli-bitcoin (0.001 BTC)
              invoiceAmountSats = amount * 100000;
              break;
            case 'u': // micro-bitcoin (0.000001 BTC)
              invoiceAmountSats = amount * 100;
              break;
            case 'n': // nano-bitcoin (0.000000001 BTC)
              invoiceAmountSats = (amount / 10).round();
              break;
            case 'p': // pico-bitcoin (0.000000000001 BTC)
              invoiceAmountSats = (amount / 10000).round();
              break;
            default: // sem unidade = BTC
              invoiceAmountSats = amount * 100000000;
          }
          debugPrint('💰 Valor da invoice decodificado: $invoiceAmountSats sats');
        }
      } catch (e) {
        debugPrint('⚠️ Não foi possível decodificar valor da invoice: $e');
      }
    }
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => SafeArea(
          minimum: const EdgeInsets.only(bottom: 24),
          child: SingleChildScrollView(
            child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom + 24,
              left: 20,
              right: 20,
              top: 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.green.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Icon(Icons.check_circle, color: Colors.green),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Invoice Escaneada!',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (hasLockedFunds) ...[
                            Text(
                              'Disponível: $availableSats sats',
                              style: TextStyle(
                                color: availableSats > 0 ? Colors.green : Colors.orange,
                                fontSize: 12,
                              ),
                            ),
                          ] else ...[
                            Text(
                              'Saldo: $balanceSats sats',
                              style: TextStyle(
                                color: balanceSats > 0 ? Colors.green : Colors.grey,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                
                // Aviso de fundos bloqueados
                if (hasLockedFunds) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.orange.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.orange.withOpacity(0.3)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.lock, color: Colors.orange, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '$committedSats sats estão em ordens abertas',
                            style: const TextStyle(color: Colors.orange, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                
                const SizedBox(height: 20),
                
                // Invoice preview
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2A2A2A),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.green.withOpacity(0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.bolt, color: Colors.amber, size: 16),
                          const SizedBox(width: 6),
                          Text(
                            isLnAddress ? 'Lightning Address' : 
                            isLnurl ? 'LNURL' : 'Lightning Invoice',
                            style: const TextStyle(
                              color: Colors.amber,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          if (invoiceAmountSats != null) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.green.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '$invoiceAmountSats sats',
                                style: const TextStyle(
                                  color: Colors.green,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        invoice.length > 60 
                            ? '${invoice.substring(0, 30)}...${invoice.substring(invoice.length - 25)}'
                            : invoice,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                ),
                
                // Campo de valor (para LNURL ou Lightning Address)
                if (needsAmountInput) ...[
                  const SizedBox(height: 16),
                  TextField(
                    controller: amountController,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(color: Colors.white, fontSize: 18),
                    decoration: InputDecoration(
                      labelText: 'Valor em sats *',
                      labelStyle: const TextStyle(color: Colors.white54),
                      hintText: 'Ex: 1000',
                      hintStyle: const TextStyle(color: Colors.white24),
                      filled: true,
                      fillColor: const Color(0xFF2A2A2A),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      prefixIcon: const Icon(Icons.bolt, color: Colors.amber),
                      suffixText: 'sats',
                      suffixStyle: const TextStyle(color: Colors.white54),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '* Este endereço requer que você informe o valor',
                    style: TextStyle(color: Colors.amber, fontSize: 11),
                  ),
                ],
                
                // Erro
                if (errorMessage != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.red.withOpacity(0.3)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error, color: Colors.red, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            errorMessage!,
                            style: const TextStyle(color: Colors.red, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                
                const SizedBox(height: 20),
                
                // Botão Enviar
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: isSending ? null : () async {
                      debugPrint('🔘 Botão de envio pressionado!');
                      
                      // Validar valor se necessário
                      if (needsAmountInput) {
                        final amountStr = amountController.text.trim();
                        if (amountStr.isEmpty) {
                          setModalState(() => errorMessage = 'Por favor, informe o valor em sats');
                          return;
                        }
                        final amount = int.tryParse(amountStr);
                        if (amount == null || amount <= 0) {
                          setModalState(() => errorMessage = 'Valor inválido');
                          return;
                        }
                        if (amount > availableSats) {
                          setModalState(() => errorMessage = 'Saldo insuficiente (disponível: $availableSats sats)');
                          return;
                        }
                      }
                      
                      // Validar saldo para invoice BOLT11 com valor
                      if (invoiceAmountSats != null && invoiceAmountSats! > availableSats) {
                        setModalState(() => errorMessage = 'Saldo insuficiente! Necessário: $invoiceAmountSats sats, Disponível: $availableSats sats');
                        return;
                      }
                      
                      setModalState(() {
                        isSending = true;
                        errorMessage = null;
                      });
                      
                      debugPrint('💸 Enviando pagamento...');
                      debugPrint('   Input original: ${invoice.length > 50 ? invoice.substring(0, 50) : invoice}...');
                      if (needsAmountInput) {
                        debugPrint('   Valor: ${amountController.text} sats');
                      }
                      
                      try {
                        final breezProvider = context.read<BreezProvider>();
                        String finalInvoice = invoice;
                        
                        // Para Lightning Address ou LNURL, resolver para BOLT11 primeiro
                        if (isLnAddress || isLnurl) {
                          debugPrint('🔄 Resolvendo Lightning Address/LNURL...');
                          setModalState(() => errorMessage = null);
                          
                          final amountSats = int.parse(amountController.text.trim());
                          final lnService = LnAddressService();
                          
                          // Usar getInvoice que funciona tanto para LN Address quanto LNURL
                          final resolveResult = await lnService.getInvoice(
                            lnAddress: invoice,
                            amountSats: amountSats,
                          );
                          
                          if (resolveResult['success'] != true) {
                            setModalState(() {
                              isSending = false;
                              errorMessage = resolveResult['error'] ?? 'Falha ao resolver endereço';
                            });
                            return;
                          }
                          
                          finalInvoice = resolveResult['invoice'] as String;
                          debugPrint('✅ Resolvido para invoice BOLT11: ${finalInvoice.substring(0, 50)}...');
                        }
                        
                        // Agora pagar a invoice BOLT11
                        final result = await breezProvider.payInvoice(finalInvoice);
                        
                        debugPrint('📨 Resultado do pagamento: $result');
                        
                        if (result != null && result['success'] == true) {
                          debugPrint('✅ Pagamento bem sucedido!');
                          if (context.mounted) {
                            Navigator.pop(context);
                            _loadWalletInfo();
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Row(
                                  children: [
                                    Icon(Icons.check_circle, color: Colors.white),
                                    SizedBox(width: 8),
                                    Text('✅ Pagamento enviado com sucesso!'),
                                  ],
                                ),
                                backgroundColor: Colors.green,
                                duration: Duration(seconds: 3),
                              ),
                            );
                          }
                        } else {
                          debugPrint('❌ Pagamento falhou: ${result?['error']}');
                          setModalState(() {
                            isSending = false;
                            errorMessage = result?['error'] ?? 'Falha ao enviar pagamento';
                          });
                        }
                      } catch (e, stack) {
                        debugPrint('❌ Exceção ao enviar: $e');
                        debugPrint('   Stack: $stack');
                        setModalState(() {
                          isSending = false;
                          errorMessage = 'Erro: $e';
                        });
                      }
                    },
                    icon: isSending
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.send),
                    label: Text(isSending ? 'Enviando...' : 'Confirmar e Enviar'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                
                // Botão Cancelar
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text(
                      'Cancelar',
                      style: TextStyle(color: Colors.white54),
                    ),
                  ),
                ),
              ],
            ),
          ),
          ),
        ),
      ),
    );
  }

  // ==================== RECEBER ====================
  void _showReceiveDialog() {
    final amountController = TextEditingController(text: '1000');
    String? generatedInvoice;
    bool isGenerating = false;
    String? errorMsg;
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom + 20,
              left: 20,
              right: 20,
              top: 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: const Color(0xFF4CAF50).withOpacity(0.2),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Icon(Icons.arrow_downward, color: Color(0xFF4CAF50)),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Receber Bitcoin',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                
                if (generatedInvoice == null) ...[
                  // Campo de valor
                  TextField(
                    controller: amountController,
                    keyboardType: TextInputType.number,
                    enabled: !isGenerating,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Quantidade (sats)',
                      labelStyle: TextStyle(color: Colors.white.withOpacity(0.6)),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFF333333)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFF333333)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFF4CAF50)),
                      ),
                      suffixText: 'sats',
                      suffixStyle: const TextStyle(color: Colors.white54),
                    ),
                  ),
                  
                  if (errorMsg != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red.withOpacity(0.3)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline, color: Colors.red, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              errorMsg!,
                              style: const TextStyle(color: Colors.red, fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  
                  const SizedBox(height: 16),
                  
                  // Botão Gerar Invoice
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: isGenerating ? null : () async {
                        final amountText = amountController.text.trim();
                        final amount = int.tryParse(amountText);
                        
                        if (amount == null || amount <= 0) {
                          setModalState(() => errorMsg = 'Digite um valor válido');
                          return;
                        }
                        
                        if (amount < 100) {
                          setModalState(() => errorMsg = 'Mínimo: 100 sats');
                          return;
                        }
                        
                        setModalState(() {
                          isGenerating = true;
                          errorMsg = null;
                        });
                        
                        debugPrint('🎯 Gerando invoice de $amount sats...');
                        
                        try {
                          // Usar LightningProvider com fallback Spark -> Liquid
                          final lightningProvider = context.read<LightningProvider>();
                          final result = await lightningProvider.createInvoice(
                            amountSats: amount,
                            description: 'Receber $amount sats - Bro App',
                          );
                          
                          debugPrint('📦 Resultado createInvoice: $result');
                          
                          // Log se usou Liquid
                          if (result?['isLiquid'] == true) {
                            debugPrint('💧 Invoice criada via LIQUID (fallback)');
                          }
                          
                          if (result != null && result['bolt11'] != null) {
                            final bolt11 = result['bolt11'] as String;
                            debugPrint('✅ Invoice: ${bolt11.substring(0, 50)}...');
                            setModalState(() {
                              generatedInvoice = bolt11;
                              isGenerating = false;
                            });
                          } else {
                            throw Exception(result?['error'] ?? 'Falha ao gerar invoice');
                          }
                        } catch (e) {
                          debugPrint('❌ Erro ao gerar invoice: $e');
                          setModalState(() {
                            isGenerating = false;
                            errorMsg = e.toString();
                          });
                        }
                      },
                      icon: isGenerating
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.qr_code),
                      label: Text(isGenerating ? 'Gerando...' : 'Gerar Invoice (QR Code)'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF4CAF50),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ] else ...[
                  // Mostrar QR Code da Invoice
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: QrImageView(
                        data: generatedInvoice!,
                        version: QrVersions.auto,
                        size: 200,
                        backgroundColor: Colors.white,
                        eyeStyle: const QrEyeStyle(
                          eyeShape: QrEyeShape.square,
                          color: Colors.black,
                        ),
                        dataModuleStyle: const QrDataModuleStyle(
                          dataModuleShape: QrDataModuleShape.square,
                          color: Colors.black,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  
                  // Invoice text (truncada)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${generatedInvoice!.substring(0, 25)}...${generatedInvoice!.substring(generatedInvoice!.length - 10)}',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontFamily: 'monospace',
                              fontSize: 11,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy, color: Color(0xFF4CAF50)),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: generatedInvoice!));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('✅ Invoice copiada!'),
                                backgroundColor: Color(0xFF4CAF50),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  
                  // Botão nova invoice
                  SizedBox(
                    width: double.infinity,
                    child: TextButton.icon(
                      onPressed: () {
                        setModalState(() {
                          generatedInvoice = null;
                          errorMsg = null;
                        });
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Gerar nova invoice'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ==================== HISTÓRICO ====================
  Widget _buildPaymentsHistory() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Histórico de Transações',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        if (_payments.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF333333)),
            ),
            child: Column(
              children: [
                Icon(Icons.history, color: Colors.white.withOpacity(0.3), size: 48),
                const SizedBox(height: 12),
                Text(
                  'Nenhuma transação ainda',
                  style: TextStyle(color: Colors.white.withOpacity(0.5)),
                ),
              ],
            ),
          )
        else
          ...(_payments.take(15).map((payment) => _buildPaymentItem(payment))),
      ],
    );
  }

  Widget _buildPaymentItem(Map<String, dynamic> payment) {
    final isReceived = payment['type'] == 'received' || 
                       payment['direction'] == 'incoming' ||
                       payment['type'] == 'Receive';
    final isBroEarning = payment['isBroEarning'] == true;
    final amount = payment['amountSats'] ?? payment['amount'] ?? 0;
    final status = payment['status']?.toString() ?? '';
    final date = payment['createdAt'] ?? payment['timestamp'];
    final description = payment['description']?.toString() ?? '';
    
    // Verificar se é um ganho de ordem Bro (APENAS ordens completadas)
    // "Bro Payment" = pagamento de ordem completada
    // Excluir: "Garantia Bro" (depósito de garantia, não é ganho)
    final isBroOrderPayment = isReceived && 
      description.contains('Bro Payment') && 
      !description.contains('Garantia');
    
    // Determinar o label e cor baseado no tipo
    String label;
    Color iconColor;
    IconData icon;
    
    if (isBroEarning || isBroOrderPayment) {
      label = '💪 Ganho como Bro';
      iconColor = Colors.green;
      icon = Icons.volunteer_activism;
    } else if (isReceived) {
      label = 'Recebido';
      iconColor = Colors.green;
      icon = Icons.arrow_downward;
    } else {
      // Verificar se é pagamento de conta (descrição contém info de ordem)
      if (description.contains('Ordem') || description.contains('conta')) {
        label = '📄 Pagamento de Conta';
      } else {
        label = 'Enviado';
      }
      iconColor = Colors.red;
      icon = Icons.arrow_upward;
    }
    
    // Usar estilo destacado para ganhos Bro (tanto do provider quanto do Lightning)
    final showBroStyle = isBroEarning || isBroOrderPayment;

    return GestureDetector(
      onTap: () => _showTransactionDetails(payment),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: showBroStyle ? const Color(0xFF1A2A1A) : const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: showBroStyle ? Colors.green.withOpacity(0.3) : const Color(0xFF333333)),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.2),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(
                icon,
                color: iconColor,
                size: 18,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  if (date != null)
                    Text(
                      _formatDateFull(date),
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.5),
                        fontSize: 11,
                      ),
                    ),
                  if (status.isNotEmpty && status != 'Complete' && !status.contains('completed'))
                    Text(
                      status.replaceAll('PaymentStatus.', ''),
                      style: TextStyle(
                        color: Colors.orange.withOpacity(0.8),
                        fontSize: 10,
                      ),
                    ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${isReceived ? '+' : '-'}$amount sats',
                  style: TextStyle(
                    color: isReceived ? Colors.green : Colors.red,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  color: Colors.white.withOpacity(0.3),
                  size: 16,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showTransactionDetails(Map<String, dynamic> payment) {
    final isReceived = payment['type'] == 'received' || 
                       payment['direction'] == 'incoming' ||
                       payment['type'] == 'Receive';
    final isBroEarning = payment['isBroEarning'] == true;
    final amount = payment['amountSats'] ?? payment['amount'] ?? 0;
    final status = payment['status']?.toString() ?? '';
    final date = payment['createdAt'] ?? payment['timestamp'];
    final description = payment['description']?.toString() ?? '';
    final paymentHash = payment['paymentHash']?.toString() ?? '';
    final paymentId = payment['id']?.toString() ?? '';
    
    // Determinar tipo para exibição
    String typeLabel;
    Color typeColor;
    IconData typeIcon;
    
    if (isBroEarning) {
      typeLabel = 'Ganho como Bro';
      typeColor = Colors.green;
      typeIcon = Icons.volunteer_activism;
    } else if (isReceived) {
      typeLabel = 'Recebido via Lightning';
      typeColor = Colors.green;
      typeIcon = Icons.arrow_downward;
    } else {
      typeLabel = 'Enviado via Lightning';
      typeColor = Colors.red;
      typeIcon = Icons.arrow_upward;
    }
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: typeColor.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Icon(typeIcon, color: typeColor, size: 24),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            typeLabel,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            '${isReceived ? '+' : '-'}$amount sats',
                            style: TextStyle(
                              color: typeColor,
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                
                const SizedBox(height: 24),
                const Divider(color: Color(0xFF333333)),
                const SizedBox(height: 16),
                
                // Detalhes
                _buildDetailRow('📅 Data/Hora', date != null ? _formatDateFull(date) : 'Não disponível'),
                _buildDetailRow('📊 Status', status.replaceAll('PaymentStatus.', '').toUpperCase()),
                if (description.isNotEmpty)
                  _buildDetailRow('📝 Descrição', description),
                _buildDetailRow('⚡ Rede', 'Lightning Network'),
                  
                const SizedBox(height: 16),
                const Divider(color: Color(0xFF333333)),
                const SizedBox(height: 16),
                
                // Dados técnicos
                const Text(
                  'Dados Técnicos',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                
                if (paymentHash.isNotEmpty && paymentHash != 'N/A' && paymentHash != 'null')
                  _buildDetailRow('🔑 Payment Hash', paymentHash, copyable: true, monospace: true),
                if (paymentId.isNotEmpty)
                  _buildDetailRow('🆔 ID Transação', paymentId, copyable: true, monospace: true),
                
                const SizedBox(height: 24),
                
                // Botão de copiar tudo
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () => _copyAllDetails(payment),
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Copiar todos os dados'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF333333),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value, {bool copyable = false, bool monospace = false, String? fullText}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white.withOpacity(0.6),
                fontSize: 13,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontFamily: monospace ? 'monospace' : null,
              ),
            ),
          ),
          if (copyable)
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: fullText ?? value));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('$label copiado!'),
                    backgroundColor: const Color(0xFFFF9800),
                    duration: const Duration(seconds: 1),
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Icon(
                  Icons.copy,
                  color: Colors.white.withOpacity(0.4),
                  size: 16,
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _copyAllDetails(Map<String, dynamic> payment) {
    final isReceived = payment['type'] == 'received' || 
                       payment['direction'] == 'incoming';
    final amount = payment['amountSats'] ?? payment['amount'] ?? 0;
    final date = payment['createdAt'] ?? payment['timestamp'];
    final description = payment['description']?.toString() ?? '';
    final paymentHash = payment['paymentHash']?.toString() ?? '';
    final paymentId = payment['id']?.toString() ?? '';
    final status = payment['status']?.toString() ?? '';
    
    final buffer = StringBuffer();
    buffer.writeln('=== Detalhes da Transação ===');
    buffer.writeln('Tipo: ${isReceived ? "Recebido" : "Enviado"}');
    buffer.writeln('Valor: $amount sats');
    if (date != null) buffer.writeln('Data: ${_formatDateFull(date)}');
    buffer.writeln('Status: ${status.replaceAll('PaymentStatus.', '')}');
    buffer.writeln('Rede: Lightning Network');
    if (description.isNotEmpty) buffer.writeln('Descrição: $description');
    buffer.writeln('');
    buffer.writeln('=== Dados Técnicos ===');
    if (paymentId.isNotEmpty) buffer.writeln('ID: $paymentId');
    if (paymentHash.isNotEmpty && paymentHash != 'null') buffer.writeln('Payment Hash: $paymentHash');
    
    Clipboard.setData(ClipboardData(text: buffer.toString()));
    
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Todos os dados copiados!'),
        backgroundColor: Color(0xFFFF9800),
        duration: Duration(seconds: 2),
      ),
    );
    
    Navigator.pop(context);
  }

  String _formatDateFull(dynamic date) {
    if (date == null) return '';
    try {
      DateTime dt;
      if (date is DateTime) {
        dt = date;
      } else {
        final str = date.toString();
        dt = DateTime.parse(str);
      }
      
      final now = DateTime.now();
      final isToday = dt.day == now.day && dt.month == now.month && dt.year == now.year;
      final isYesterday = dt.day == now.day - 1 && dt.month == now.month && dt.year == now.year;
      
      final time = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      
      if (isToday) {
        return 'Hoje às $time';
      } else if (isYesterday) {
        return 'Ontem às $time';
      } else {
        return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year} às $time';
      }
    } catch (e) {
      return date.toString();
    }
  }

  // ============================================
  // SEÇÃO DE TAXAS DA PLATAFORMA (2%)
  // ============================================
  
  Widget _buildPlatformFeesSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.attach_money, color: Colors.purple, size: 20),
            SizedBox(width: 8),
            Text(
              'Taxas da Plataforma (2%)',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.purple.withOpacity(0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Destino das taxas
              Row(
                children: [
                  const Icon(Icons.bolt, color: Colors.amber, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      AppConfig.platformLightningAddress,
                      style: const TextStyle(color: Colors.amber, fontFamily: 'monospace', fontSize: 13),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy, color: Colors.white54, size: 16),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: AppConfig.platformLightningAddress));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('LN Address copiado!'), backgroundColor: Colors.green),
                      );
                    },
                    tooltip: 'Copiar',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              
              // Estatísticas de taxas
              FutureBuilder<Map<String, dynamic>>(
                future: PlatformFeeService.getHistoricalTotals(),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(8.0),
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.purple),
                      ),
                    );
                  }
                  
                  final totals = snapshot.data!;
                  final totalSats = totals['totalSats'] as int? ?? 0;
                  final collectedSats = totals['collectedSats'] as int? ?? 0;
                  final pendingSats = totals['pendingSats'] as int? ?? 0;
                  final totalTx = totals['totalTransactions'] as int? ?? 0;
                  
                  return Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _buildFeeStatItem('Total', '$totalSats', Colors.white),
                          _buildFeeStatItem('Enviado', '$collectedSats', Colors.green),
                          _buildFeeStatItem('Pendente', '$pendingSats', Colors.orange),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '$totalTx transações registradas',
                        style: const TextStyle(color: Colors.white54, fontSize: 11),
                      ),
                    ],
                  );
                },
              ),
              
              const SizedBox(height: 16),
              
              // Botão de teste
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _testPlatformFee,
                  icon: const Icon(Icons.send, size: 16),
                  label: const Text('Testar Envio (1 sat)'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.purple,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
  
  Widget _buildFeeStatItem(String label, String value, Color color) {
    return Column(
      children: [
        Text(
          '$value sats',
          style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 14),
        ),
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 10)),
      ],
    );
  }
  
  Future<void> _testPlatformFee() async {
    setState(() => _isLoading = true);
    
    try {
      debugPrint('🧪 Testando envio de taxa da plataforma...');
      
      final result = await PlatformFeeService.sendPlatformFee(
        orderId: 'test_${DateTime.now().millisecondsSinceEpoch}',
        totalSats: 50, // 2% de 50 = 1 sat
      );
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result ? '✅ Taxa enviada com sucesso!' : '❌ Falha - verifique logs'),
            backgroundColor: result ? Colors.green : Colors.red,
          ),
        );
        
        // Recarregar para mostrar novos dados
        await _loadWalletInfo();
      }
    } catch (e) {
      debugPrint('❌ Erro no teste: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ Erro: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }
}
