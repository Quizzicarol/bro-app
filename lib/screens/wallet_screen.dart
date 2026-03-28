import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../providers/breez_provider_export.dart';
import '../providers/lightning_provider.dart';
import '../providers/provider_balance_provider.dart';
import '../providers/order_provider.dart';
import '../models/order.dart';
import '../services/storage_service.dart';
import '../services/nostr_service.dart';
import '../services/lnaddress_service.dart';
import '../services/local_collateral_service.dart';
import '../services/platform_fee_service.dart';
import '../services/bitcoin_price_service.dart';
import '../config.dart';
import '../l10n/app_localizations.dart';
import '../services/brix_service.dart';
import '../services/brix_relay_service.dart';

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
  List<Map<String, dynamic>> _pendingOutgoing = [];
  bool _isLoading = false;
  String? _error;
  double _btcPrice = 0;

  /// Total sats queued for outgoing BRIX payments (not yet deducted from wallet).
  int get _queuedSats => _pendingOutgoing.fold(0, (sum, p) => sum + ((p['amountSats'] as int?) ?? 0));

  @override
  void initState() {
    super.initState();
    _loadWalletInfo();
    // Listen for queued payment completions
    BrixRelayService().onQueuedPaymentCompleted = (recipient, amount) {
      if (mounted) {
        _loadWalletInfo();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Pagamento de $amount sats para $recipient concluído!'),
            backgroundColor: const Color(0xFF4CAF50),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    };
  }

  Future<void> _loadWalletInfo() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final breezProvider = context.read<BreezProvider>();
      
      if (!breezProvider.isInitialized) {
        broLog('🔄 Inicializando Breez SDK...');
        final success = await breezProvider.initialize();
        if (!success) {
          throw Exception('Falha ao inicializar SDK');
        }
      }

      // Sincronizar carteira ANTES de buscar saldo/pagamentos
      // Sem isso, pagamentos recebidos pelo Spark (cloud) não aparecem
      await breezProvider.forceSyncWallet();

      final balance = await breezProvider.getBalance();
      final payments = await breezProvider.listPayments();
      
      // Buscar preço BTC para equivalência em BRL
      final price = await BitcoinPriceService.getBitcoinPriceWithCache();
      if (price != null) _btcPrice = price;
      
      // NOTA: Ganhos como Bro são recebidos via Lightning (invoice pago pelo usuário)
      // e já aparecem em payments como transações recebidas.
      // NÃO misturar com ProviderBalanceProvider que é apenas TRACKING LOCAL.
      
      // Usar apenas pagamentos Lightning reais, FILTRANDO taxas internas da plataforma
      List<Map<String, dynamic>> allPayments = payments.where((p) {
        final description = p['description']?.toString() ?? '';
        final amount = p['amountSats'] ?? p['amount'] ?? 0;
        final isReceived = p['type'] == 'received' || 
                           p['direction'] == 'incoming' ||
                           p['type'] == 'Receive';
        
        // OCULTAR: Taxas de plataforma (são internas, não devem aparecer para o usuário)
        // 1. Filtrar por payment hash (mais confiável)
        final paymentHash = p['paymentHash']?.toString() ?? '';
        if (paymentHash.isNotEmpty && PlatformFeeService.feePaymentHashes.contains(paymentHash)) {
          broLog('🔇 Ocultando taxa da plataforma (hash): $paymentHash ($amount sats)');
          return false;
        }
        // 2. Fallback: filtrar por descrição
        final descLower = description.toLowerCase();
        if (descLower.contains('platform fee') || 
            descLower.contains('bro platform fee')) {
          broLog('🔇 Ocultando taxa da plataforma (desc): $description ($amount sats)');
          return false;
        }
        
        // OCULTAR: Lado RECEBIDO do auto-pagamento com saldo da carteira
        // É uma transação interna — só queremos mostrar o lado "enviado" como depósito
        if (isReceived && description == 'Bro Wallet Payment') {
          broLog('🔇 Ocultando lado recebido do wallet payment: $amount sats');
          return false;
        }
        
        // OCULTAR: Pagamentos enviados muito pequenos (≤ 10 sats) são provavelmente taxas internas
        // Transações de 1-10 sats que são envio provavelmente são taxas de plataforma (~2%)
        if (!isReceived && amount > 0 && amount <= 10) {
          broLog('🔇 Ocultando pagamento pequeno (provável taxa): $amount sats');
          return false;
        }
        
        // OCULTAR: Pagamentos enviados sem descrição (taxas de plataforma via LNURL)
        // Pagamentos legítimos do usuário sempre têm descrição (Bro - Ordem X, Garantia, etc)
        if (!isReceived && (description.isEmpty || description == 'null')) {
          broLog('🔇 Ocultando pagamento sem descrição (provável taxa interna): $amount sats');
          return false;
        }
        
        return true;
      }).toList();
      
      // REMOVIDO: Não mesclar com ProviderBalanceProvider (era tracking local, não saldo real)
      // Isso evita confusão entre saldo real (Breez) e tracking local
      
      // v257: Incluir pagamentos feitos com saldo da carteira (wallet payments)
      // Esses pagamentos NÃO passam por Lightning, então o SDK não os registra.
      // Identificamos pelo paymentHash começando com 'wallet_'
      try {
        final orderProvider = context.read<OrderProvider>();
        final walletPaidOrders = orderProvider.orders.where((o) =>
          o.paymentHash != null &&
          o.paymentHash!.startsWith('wallet_') &&
          o.status != 'draft' &&
          o.status != 'pending'
        ).toList();
        
        // Verificar se já existe no allPayments (evitar duplicatas)
        final existingHashes = allPayments
            .map((p) => p['paymentHash']?.toString() ?? '')
            .toSet();
        
        for (final order in walletPaidOrders) {
          if (existingHashes.contains(order.paymentHash)) continue;
          
          final satsAmount = (order.btcAmount * 100000000).round();
          final billLabel = order.billType == 'pix' ? 'PIX' : 'Boleto';
          
          allPayments.add({
            'id': order.paymentHash,
            'paymentType': 'Send',
            'type': 'sent',
            'direction': 'outgoing',
            'status': 'Complete',
            'amount': satsAmount,
            'amountSats': satsAmount,
            'paymentHash': order.paymentHash,
            'description': 'Pagamento $billLabel (saldo carteira)',
            'timestamp': order.createdAt,
            'createdAt': order.createdAt,
            'isWalletPayment': true,
          });
          broLog('💰 Adicionado wallet payment ao histórico: ${order.id.substring(0, 8)} $satsAmount sats');
        }
      } catch (e) {
        broLog('⚠️ Erro ao adicionar wallet payments: $e');
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
      
      broLog('💰 Saldo: ${balance?['balance']} sats');
      broLog('📜 Pagamentos: ${allPayments.length} (incluindo ganhos Bro)');

      if (mounted) {
        setState(() {
          _balance = balance;
          _payments = allPayments;
        });
      }

      // Load queued outgoing BRIX payments
      try {
        final pending = await BrixRelayService().getPendingOutgoing();
        if (mounted) {
          setState(() => _pendingOutgoing = pending);
        }
      } catch (_) {}
    } catch (e) {
      broLog('❌ Erro ao carregar carteira: $e');
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
        child: CircularProgressIndicator(color: Color(0xFFFF6B6B)),
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
        title: Row(
          children: [
            const Icon(Icons.account_balance_wallet, color: Color(0xFFFF9800)),
            const SizedBox(width: 8),
            Text(AppLocalizations.of(context).t('wallet_title'), style: const TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(color: Color(0xFFFF6B6B)),
            const SizedBox(height: 16),
            Text(AppLocalizations.of(context).t('wallet_loading'), style: const TextStyle(color: Colors.white70)),
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
                AppLocalizations.of(context).t('wallet_load_error'),
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
                label: Text(AppLocalizations.of(context).t('wallet_retry')),
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
            const SizedBox(height: 40), // Extra padding at bottom
          ],
        ),
      ),
    );
  }

  Widget _buildBalanceCard() {
    final balanceSats = int.tryParse(_balance?['balance']?.toString() ?? '0') ?? 0;
    final hasError = _balance?['error'] != null;
    
    // v257: Deduzir sats travados (wallet payments em andamento)
    final orderProvider = context.read<OrderProvider>();
    final lockedSats = orderProvider.committedSats;
    final availableSats = (balanceSats - lockedSats).clamp(0, balanceSats);
    final availableBtc = availableSats / 100000000;
    final hasLocked = lockedSats > 0;

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
          Row(
            children: [
              const Icon(Icons.flash_on, color: Colors.white, size: 24),
              const SizedBox(width: 8),
              Text(
                AppLocalizations.of(context).t('wallet_balance_lightning'),
                style: const TextStyle(
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
              _formatSats(availableSats),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '≈ ${availableBtc.toStringAsFixed(8)} BTC',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
              ),
            ),
            if (_btcPrice > 0) ...[              const SizedBox(height: 2),
              Text(
                '≈ R\$ ${(availableBtc * _btcPrice).toStringAsFixed(2)}',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                ),
              ),
            ],
            if (hasLocked) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.lock, color: Colors.white70, size: 14),
                    const SizedBox(width: 4),
                    Text(
                      '${_formatSats(lockedSats)} ${AppLocalizations.of(context).t('wallet_locked_in_orders')}',
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
            if (_queuedSats > 0) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.amber.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.schedule, color: Colors.amber, size: 14),
                    const SizedBox(width: 4),
                    Text(
                      '${_formatSats(_queuedSats)} pendente(s)',
                      style: const TextStyle(color: Colors.amber, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
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
            label: AppLocalizations.of(context).t('wallet_send'),
            color: const Color(0xFFE53935),
            onTap: _showSendDialog,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildActionButton(
            icon: Icons.arrow_downward,
            label: AppLocalizations.of(context).t('wallet_receive'),
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
    bool isReaisMode = false;
    double? btcPriceBrl;
    
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
    
    // Fetch BTC price for BRL conversion
    btcPriceBrl = await BitcoinPriceService.getBitcoinPriceWithCache();
    
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
                          Text(
                            AppLocalizations.of(context).t('wallet_send_bitcoin'),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (hasLockedFunds) ...[
                            Text(
                              AppLocalizations.of(context).tp('wallet_available_sats', {'available': availableSats.toString()}),
                              style: TextStyle(
                                color: availableSats > 0 ? Colors.green : Colors.orange,
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              AppLocalizations.of(context).tp('wallet_in_orders_sats', {'committed': committedSats.toString()}),
                              style: const TextStyle(
                                color: Colors.orange,
                                fontSize: 13,
                              ),
                            ),
                          ] else ...[
                            Text(
                              AppLocalizations.of(context).tp('wallet_balance_sats', {'balance': balanceSats.toString()}),
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
                                AppLocalizations.of(context).tp('wallet_sats_locked', {'total': totalLockedSats.toString()}),
                                style: const TextStyle(color: Colors.orange, fontSize: 12, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                        if (hasTierActive) ...[
                          const SizedBox(height: 4),
                          Text(
                            AppLocalizations.of(context).tp('wallet_sats_locked_tier', {'amount': tierLockedSats.toString(), 'tier': tierName ?? ''}),
                            style: const TextStyle(color: Colors.orange, fontSize: 11),
                          ),
                        ],
                        if (committedSats > 0) ...[
                          const SizedBox(height: 2),
                          Text(
                            AppLocalizations.of(context).tp('wallet_sats_in_open_orders', {'amount': committedSats.toString()}),
                            style: const TextStyle(color: Colors.orange, fontSize: 11),
                          ),
                        ],
                        if (hasTierActive) ...[
                          const SizedBox(height: 6),
                          Text(
                            AppLocalizations.of(context).t('wallet_withdraw_all_warning'),
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
                    // Se for Lightning Address, LNURL-pay, phone, email ou username BRIX, mostrar campo de valor
                    final trimmed = value.trim().toLowerCase();
                    final isLnAddress = trimmed.contains('@') && trimmed.contains('.');
                    final isLnurl = trimmed.startsWith('lnurl');
                    final isPhone = RegExp(r'^\+?\d[\d\s\-()]{7,}$').hasMatch(trimmed);
                    final isBrixUser = RegExp(r'^[a-z0-9_]{3,20}$').hasMatch(trimmed) && !trimmed.startsWith('lnbc') && !trimmed.startsWith('lntb');
                    final needsAmount = isLnAddress || isLnurl || isPhone || isBrixUser;
                    
                    if (needsAmount != showAmountField) {
                      setModalState(() {
                        showAmountField = needsAmount;
                        errorMessage = null;
                      });
                    }
                  },
                  decoration: InputDecoration(
                    labelText: AppLocalizations.of(context).t('wallet_destination_label'),
                    labelStyle: TextStyle(color: Colors.white.withOpacity(0.6)),
                    hintText: AppLocalizations.of(context).t('wallet_hint_brix'),
                    hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                    helperText: AppLocalizations.of(context).t('wallet_helper_brix'),
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
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: amountController,
                          style: const TextStyle(color: Colors.white, fontSize: 18),
                          keyboardType: isReaisMode
                              ? const TextInputType.numberWithOptions(decimal: true)
                              : TextInputType.number,
                          enabled: !isSending,
                          onChanged: (_) => setModalState(() {}),
                          decoration: InputDecoration(
                            labelText: isReaisMode ? 'Valor em Reais' : AppLocalizations.of(context).t('wallet_amount_label'),
                            labelStyle: TextStyle(color: Colors.white.withOpacity(0.6)),
                            hintText: isReaisMode ? 'Ex: 10.00' : 'Ex: 1000',
                            hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                            prefixIcon: Icon(
                              isReaisMode ? Icons.attach_money : Icons.bolt,
                              color: isReaisMode ? Colors.green : Colors.orange,
                            ),
                            suffixText: isReaisMode ? 'R\$' : 'sats',
                            suffixStyle: TextStyle(color: isReaisMode ? Colors.green : Colors.orange),
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
                              borderSide: BorderSide(color: isReaisMode ? Colors.green : const Color(0xFFFF9800)),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: isSending ? null : () {
                          setModalState(() {
                            isReaisMode = !isReaisMode;
                            amountController.clear();
                          });
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                          decoration: BoxDecoration(
                            color: (isReaisMode ? Colors.green : Colors.orange).withOpacity(0.15),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: (isReaisMode ? Colors.green : Colors.orange).withOpacity(0.5),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.swap_horiz,
                                color: isReaisMode ? Colors.green : Colors.orange,
                                size: 16,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                isReaisMode ? 'R\$' : 'SAT',
                                style: TextStyle(
                                  color: isReaisMode ? Colors.green : Colors.orange,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  // Conversion preview
                  if (amountController.text.trim().isNotEmpty && btcPriceBrl != null)
                    Builder(builder: (_) {
                      Widget? preview;
                      if (isReaisMode) {
                        final brl = double.tryParse(amountController.text.trim().replaceAll(',', '.'));
                        if (brl != null && brl > 0) {
                          final sats = (brl * 100000000 / btcPriceBrl!).round();
                          preview = Text(
                            '≈ $sats sats  •  1 BTC = R\$ ${btcPriceBrl!.toStringAsFixed(0)}',
                            style: const TextStyle(color: Colors.white54, fontSize: 12),
                          );
                        }
                      } else {
                        final sats = int.tryParse(amountController.text.trim());
                        if (sats != null && sats > 0) {
                          final brl = sats * btcPriceBrl! / 100000000;
                          preview = Text(
                            '≈ R\$ ${brl.toStringAsFixed(2)}  •  1 BTC = R\$ ${btcPriceBrl!.toStringAsFixed(0)}',
                            style: const TextStyle(color: Colors.white54, fontSize: 12),
                          );
                        }
                      }
                      if (preview == null) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.05),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.swap_vert, color: Colors.white38, size: 16),
                              const SizedBox(width: 6),
                              Expanded(child: preview),
                            ],
                          ),
                        ),
                      );
                    }),
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
                        final isPhone = RegExp(r'^\+?\d[\d\s\-()]{7,}$').hasMatch(trimmed);
                        final isBrixUser = RegExp(r'^[a-z0-9_]{3,20}$').hasMatch(trimmed) && !trimmed.startsWith('lnbc') && !trimmed.startsWith('lntb');
                        final needsAmount = isLnAddr || isLnurl || isPhone || isBrixUser;
                        
                        setModalState(() {
                          showAmountField = needsAmount;
                          errorMessage = null;
                        });
                        
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(needsAmount 
                                ? AppLocalizations.of(context).t('wallet_pasted_enter_amount')
                                : AppLocalizations.of(context).t('wallet_pasted')),
                              duration: const Duration(seconds: 1),
                            ),
                          );
                        }
                      }
                    },
                    icon: const Icon(Icons.paste),
                    label: Text(AppLocalizations.of(context).t('wallet_paste_clipboard')),
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
                    label: Text(AppLocalizations.of(context).t('wallet_scan_qr')),
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
                        setModalState(() => errorMessage = AppLocalizations.of(context).t('wallet_enter_destination'));
                        return;
                      }
                      
                      final lowerDest = destination.toLowerCase();
                      
                      // Verificar se é endereço Bitcoin (não suportado)
                      if (_isBitcoinAddress(destination)) {
                        setModalState(() => errorMessage = AppLocalizations.of(context).t('wallet_onchain_not_available'));
                        return;
                      }
                      
                      // Verificar se é Lightning Address ou LNURL (precisa de valor)
                      final isLnAddress = destination.contains('@') && destination.contains('.');
                      final isLnurl = lowerDest.startsWith('lnurl');
                      final isPhone = RegExp(r'^\+?\d[\d\s\-()]{7,}$').hasMatch(destination.trim());
                      final isBrixUser = RegExp(r'^[a-z0-9_]{3,20}$').hasMatch(lowerDest) && !lowerDest.startsWith('lnbc') && !lowerDest.startsWith('lntb');
                      // Detect BRIX Lightning Addresses
                      final isBrixAddress = isLnAddress && (lowerDest.endsWith('@brix.app') || lowerDest.endsWith('@brostr.app') || lowerDest.endsWith('@brix.brostr.app'));
                      // Detect emails that could be BRIX contacts (not already a BRIX domain)
                      final isEmailForBrix = isLnAddress && !isBrixAddress && lowerDest.contains('@');
                      final needsBrixResolve = isPhone || isBrixUser || isBrixAddress || isEmailForBrix;
                      final needsAmountInput = isLnAddress || isLnurl || needsBrixResolve;
                      
                      // Atualizar UI se necessário
                      if (needsAmountInput != showAmountField) {
                        setModalState(() {
                          showAmountField = needsAmountInput;
                          errorMessage = needsAmountInput ? AppLocalizations.of(context).t('wallet_enter_amount_sats') : null;
                        });
                        return;
                      }
                      
                      // Se for Lightning Address, LNURL, phone ou BRIX username, precisamos de um valor
                      if (needsAmountInput) {
                        final amountText = amountController.text.trim();
                        int? amountSats;
                        if (isReaisMode && btcPriceBrl != null) {
                          final brl = double.tryParse(amountText.replaceAll(',', '.'));
                          if (brl != null && brl > 0) {
                            amountSats = (brl * 100000000 / btcPriceBrl!).round();
                          }
                        } else {
                          amountSats = int.tryParse(amountText);
                        }
                        
                        if (amountSats == null || amountSats <= 0) {
                          setModalState(() => errorMessage = AppLocalizations.of(context).t('wallet_enter_valid_amount'));
                          return;
                        }
                        
                        if (amountSats > availableSats) {
                          if (hasTierActive && amountSats > balanceSats - tierLockedSats) {
                            setModalState(() => errorMessage = AppLocalizations.of(context).tp('wallet_tier_locked_error', {'amount': tierLockedSats.toString(), 'tier': tierName ?? ''}));
                          } else if (hasLockedFunds) {
                            setModalState(() => errorMessage = AppLocalizations.of(context).tp('wallet_insufficient_balance_locked', {'available': availableSats.toString(), 'locked': totalLockedSats.toString()}));
                          } else {
                            setModalState(() => errorMessage = AppLocalizations.of(context).tp('wallet_insufficient_balance', {'balance': balanceSats.toString()}));
                          }
                          return;
                        }
                        
                        setModalState(() {
                          isSending = true;
                          errorMessage = null;
                        });
                        
                        broLog('💸 Enviando $amountSats sats para $destination...');
                        
                        try {
                          final breezProvider = context.read<BreezProvider>();
                          final lnAddressService = LnAddressService();
                          
                          // Se for phone, username BRIX, email ou BRIX address, resolver primeiro via BRIX
                          var resolvedDest = destination;
                          if (needsBrixResolve) {
                            final brixService = BrixService();
                            // For BRIX addresses (user@brix.app), extract username for resolve
                            var resolveQuery = destination;
                            if (isBrixAddress) {
                              resolveQuery = destination.split('@').first;
                            }
                            final resolveResult = await brixService.resolve(resolveQuery);
                            if (!resolveResult.found || resolveResult.brixAddress == null) {
                              // If it's an email, don't error — it might be a standard Lightning Address
                              if (!isEmailForBrix) {
                                setModalState(() {
                                  isSending = false;
                                  errorMessage = resolveResult.error ?? 'Nenhum BRIX encontrado para "$destination"';
                                });
                                broLog('🔍 BRIX resolve failed for "$destination": ${resolveResult.error ?? "not found"}');
                                return;
                              }
                              // Fall through to standard LNURL resolution for non-BRIX emails
                              broLog('🔍 Email não encontrado no BRIX, tentando como Lightning Address: $destination');
                            } else {
                              resolvedDest = resolveResult.brixAddress!;
                              broLog('🔍 BRIX resolvido: $destination → $resolvedDest (via ${resolveResult.matchedBy})');
                            }
                          }
                          
                          // Resolver Lightning Address ou LNURL para invoice BOLT11
                          final senderPubkey = await StorageService().getNostrPublicKey();
                          final invoiceResult = await lnAddressService.getInvoice(
                            lnAddress: resolvedDest,
                            amountSats: amountSats,
                            senderPubkey: senderPubkey,
                          );
                          
                          if (invoiceResult['success'] != true) {
                            final errMsg = invoiceResult['error'] ?? '';
                            if (errMsg == 'BRIX_RECIPIENT_OFFLINE' && needsBrixResolve) {
                              // Queue for auto-retry when recipient comes online
                              await BrixRelayService().queueOutgoingPayment(
                                recipient: resolvedDest,
                                amountSats: amountSats,
                                originalDest: destination,
                              );
                              if (context.mounted) {
                                Navigator.pop(context);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('✅ Pagamento agendado! Será enviado automaticamente quando o destinatário abrir o app.'),
                                    backgroundColor: Color(0xFF4CAF50),
                                    duration: Duration(seconds: 4),
                                  ),
                                );
                              }
                              _loadWalletInfo();
                            } else {
                              setModalState(() {
                                isSending = false;
                                errorMessage = errMsg.isNotEmpty ? errMsg : AppLocalizations.of(context).t('wallet_resolve_failed');
                              });
                            }
                            return;
                          }
                          
                          final invoice = invoiceResult['invoice'] as String;
                          broLog('📝 Invoice obtida: ${invoice.substring(0, 50)}...');
                          
                          // Pagar a invoice
                          final result = await breezProvider.payInvoice(invoice);
                          
                          if (result != null && result['success'] == true) {
                            if (context.mounted) {
                              Navigator.pop(context);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(AppLocalizations.of(context).t('wallet_payment_sent_success')),
                                  backgroundColor: const Color(0xFF4CAF50),
                                ),
                              );
                            }
                            _loadWalletInfo();
                          } else {
                            final errStr = result?['error']?.toString() ?? '';
                            // If payInvoice fails with invalidInput on a BRIX dest,
                            // the invoice is likely from LNbits (offline). Queue for retry.
                            if (needsBrixResolve && errStr.contains('invalid')) {
                              await BrixRelayService().queueOutgoingPayment(
                                recipient: resolvedDest,
                                amountSats: amountSats,
                                originalDest: destination,
                              );
                              if (context.mounted) {
                                Navigator.pop(context);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('✅ Pagamento agendado! Será enviado automaticamente quando o destinatário abrir o app.'),
                                    backgroundColor: Color(0xFF4CAF50),
                                    duration: Duration(seconds: 4),
                                  ),
                                );
                              }
                              _loadWalletInfo();
                            } else {
                              setModalState(() {
                                isSending = false;
                                errorMessage = errStr.isNotEmpty ? errStr : AppLocalizations.of(context).t('wallet_send_payment_failed');
                              });
                            }
                          }
                        } catch (e) {
                          broLog('❌ Erro ao enviar: $e');
                          final isTimeout = e.toString().contains('TimeoutException') || e.toString().contains('timeout');
                          final canQueue = needsBrixResolve && amountSats != null && amountSats! > 0;

                          if (isTimeout && canQueue) {
                            // Timeout on BRIX → queue and show as success
                            await BrixRelayService().queueOutgoingPayment(
                              recipient: destination,
                              amountSats: amountSats!,
                              originalDest: destination,
                            );
                            if (context.mounted) {
                              Navigator.pop(context);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('✅ Pagamento agendado! Será enviado automaticamente quando o destinatário abrir o app.'),
                                  backgroundColor: Color(0xFF4CAF50),
                                  duration: Duration(seconds: 4),
                                ),
                              );
                            }
                            _loadWalletInfo();
                          } else {
                            setModalState(() {
                              isSending = false;
                              errorMessage = isTimeout
                                  ? '⚡ O destinatário não está com o app aberto neste momento.\n\nPeça para ele abrir o Bro App e tente novamente.'
                                  : 'Erro: $e';
                            });
                          }
                        }
                        return;
                      }
                      
                      // Verificar se é Lightning invoice válida
                      if (!lowerDest.startsWith('lnbc') && 
                          !lowerDest.startsWith('lntb') &&
                          !lowerDest.startsWith('lnurl') &&
                          !isLnAddress &&
                          !isPhone &&
                          !isBrixUser) {
                        setModalState(() => errorMessage = AppLocalizations.of(context).t('wallet_invalid_format'));
                        return;
                      }
                      
                      setModalState(() {
                        isSending = true;
                        errorMessage = null;
                      });
                      broLog('💸 Enviando pagamento...');
                      
                      try {
                        final breezProvider = context.read<BreezProvider>();
                        final result = await breezProvider.payInvoice(destination);
                        
                        broLog('📦 Resultado pagamento: $result');
                        
                        if (result != null && result['success'] == true) {
                          if (context.mounted) {
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(AppLocalizations.of(context).t('wallet_payment_sent_success')),
                                backgroundColor: const Color(0xFF4CAF50),
                              ),
                            );
                          }
                          _loadWalletInfo(); // Atualizar saldo
                        } else {
                          // Erro específico de saldo insuficiente
                          final errorType = result?['errorType'];
                          final errorMsg = result?['error'] ?? AppLocalizations.of(context).t('wallet_send_payment_failed');
                          
                          setModalState(() => isSending = false);
                          
                          if (context.mounted) {
                            if (errorType == 'INSUFFICIENT_FUNDS') {
                              // Mostrar dialog específico para saldo insuficiente
                              showDialog(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  backgroundColor: const Color(0xFF1A1A1A),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                  title: Row(
                                    children: [
                                      const Icon(Icons.account_balance_wallet, color: Colors.orange, size: 28),
                                      const SizedBox(width: 12),
                                      Text(AppLocalizations.of(context).t('wallet_insufficient_balance_title'), style: const TextStyle(color: Colors.white)),
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
                                                AppLocalizations.of(context).t('wallet_deposit_more_sats'),
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
                        broLog('❌ Erro ao enviar: $e');
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
                    label: Text(isSending ? AppLocalizations.of(context).t('wallet_sending') : AppLocalizations.of(context).t('wallet_send_payment')),
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
        title: Row(
          children: [
            const Icon(Icons.currency_bitcoin, color: Colors.orange, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                AppLocalizations.of(context).t('wallet_bitcoin_address'),
                style: const TextStyle(color: Colors.white, fontSize: 18),
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
              child: Row(
                children: [
                  const Icon(Icons.info_outline, color: Colors.orange, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      AppLocalizations.of(context).t('wallet_onchain_not_supported'),
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
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
            child: Text(AppLocalizations.of(ctx).t('wallet_understood'), style: const TextStyle(color: Colors.orange)),
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
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            AppLocalizations.of(context).t('wallet_scan_qr_title'),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            AppLocalizations.of(context).t('wallet_scan_qr_subtitle'),
                            style: const TextStyle(
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
                child: Column(
                  children: [
                    const Icon(Icons.lightbulb_outline, color: Colors.amber, size: 24),
                    const SizedBox(height: 8),
                    Text(
                      AppLocalizations.of(context).t('wallet_supported_formats'),
                      style: const TextStyle(
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
    broLog('📤 Abrindo dialog de envio com invoice: ${invoice.substring(0, 50)}...');
    
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
    // Detect BRIX addresses for queue-on-offline handling
    final isBrixAddress = isLnAddress && (lowerInvoice.endsWith('@brix.app') || lowerInvoice.endsWith('@brostr.app') || lowerInvoice.endsWith('@brix.brostr.app'));
    
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
          broLog('💰 Valor da invoice decodificado: $invoiceAmountSats sats');
        }
      } catch (e) {
        broLog('⚠️ Não foi possível decodificar valor da invoice: $e');
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
                          Text(
                            AppLocalizations.of(context).t('wallet_invoice_scanned'),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (hasLockedFunds) ...[
                            Text(
                              AppLocalizations.of(context).tp('wallet_available_sats', {'available': availableSats.toString()}),
                              style: TextStyle(
                                color: availableSats > 0 ? Colors.green : Colors.orange,
                                fontSize: 12,
                              ),
                            ),
                          ] else ...[
                            Text(
                              AppLocalizations.of(context).tp('wallet_balance_sats', {'balance': balanceSats.toString()}),
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
                            AppLocalizations.of(context).tp('wallet_sats_in_open_orders_simple', {'amount': committedSats.toString()}),
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
                      labelText: AppLocalizations.of(context).t('wallet_amount_sats_required'),
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
                  Text(
                    AppLocalizations.of(context).t('wallet_address_requires_amount'),
                    style: const TextStyle(color: Colors.amber, fontSize: 11),
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
                      broLog('🔘 Botão de envio pressionado!');
                      
                      // Validar valor se necessário
                      if (needsAmountInput) {
                        final amountStr = amountController.text.trim();
                        if (amountStr.isEmpty) {
                          setModalState(() => errorMessage = AppLocalizations.of(context).t('wallet_please_enter_amount'));
                          return;
                        }
                        final amount = int.tryParse(amountStr);
                        if (amount == null || amount <= 0) {
                          setModalState(() => errorMessage = AppLocalizations.of(context).t('wallet_invalid_amount'));
                          return;
                        }
                        if (amount > availableSats) {
                          setModalState(() => errorMessage = AppLocalizations.of(context).tp('wallet_insufficient_available', {'available': availableSats.toString()}));
                          return;
                        }
                      }
                      
                      // Validar saldo para invoice BOLT11 com valor
                      if (invoiceAmountSats != null && invoiceAmountSats! > availableSats) {
                        setModalState(() => errorMessage = AppLocalizations.of(context).tp('wallet_insufficient_needed', {'needed': invoiceAmountSats.toString(), 'available': availableSats.toString()}));
                        return;
                      }
                      
                      setModalState(() {
                        isSending = true;
                        errorMessage = null;
                      });
                      
                      broLog('💸 Enviando pagamento...');
                      broLog('   Input original: ${invoice.length > 50 ? invoice.substring(0, 50) : invoice}...');
                      if (needsAmountInput) {
                        broLog('   Valor: ${amountController.text} sats');
                      }
                      
                      try {
                        final breezProvider = context.read<BreezProvider>();
                        String finalInvoice = invoice;
                        
                        // Para Lightning Address ou LNURL, resolver para BOLT11 primeiro
                        if (isLnAddress || isLnurl) {
                          broLog('🔄 Resolvendo Lightning Address/LNURL...');
                          setModalState(() => errorMessage = null);
                          
                          final amountSats = int.parse(amountController.text.trim());
                          final lnService = LnAddressService();
                          
                          // Usar getInvoice que funciona tanto para LN Address quanto LNURL
                          final senderPk = await StorageService().getNostrPublicKey();
                          final resolveResult = await lnService.getInvoice(
                            lnAddress: invoice,
                            amountSats: amountSats,
                            senderPubkey: senderPk,
                          );
                          
                          if (resolveResult['success'] != true) {
                            final errMsg = resolveResult['error'] ?? '';
                            // BRIX address + recipient offline → queue for retry
                            if (errMsg == 'BRIX_RECIPIENT_OFFLINE' && isBrixAddress) {
                              await BrixRelayService().queueOutgoingPayment(
                                recipient: invoice,
                                amountSats: amountSats,
                                originalDest: invoice,
                              );
                              if (context.mounted) {
                                Navigator.pop(context);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('✅ Pagamento agendado! Será enviado automaticamente quando o destinatário abrir o app.'),
                                    backgroundColor: Color(0xFF4CAF50),
                                    duration: Duration(seconds: 4),
                                  ),
                                );
                              }
                              _loadWalletInfo();
                              return;
                            }
                            setModalState(() {
                              isSending = false;
                              errorMessage = errMsg.isNotEmpty ? errMsg : AppLocalizations.of(context).t('wallet_resolve_failed');
                            });
                            return;
                          }
                          
                          finalInvoice = resolveResult['invoice'] as String;
                          broLog('✅ Resolvido para invoice BOLT11: ${finalInvoice.substring(0, 50)}...');
                        }
                        
                        // Agora pagar a invoice BOLT11
                        final result = await breezProvider.payInvoice(finalInvoice);
                        
                        broLog('📨 Resultado do pagamento: $result');
                        
                        if (result != null && result['success'] == true) {
                          broLog('✅ Pagamento bem sucedido!');
                          if (context.mounted) {
                            Navigator.pop(context);
                            _loadWalletInfo();
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Row(
                                  children: [
                                    const Icon(Icons.check_circle, color: Colors.white),
                                    const SizedBox(width: 8),
                                    Text(AppLocalizations.of(context).t('wallet_payment_sent_success')),
                                  ],
                                ),
                                backgroundColor: Colors.green,
                                duration: const Duration(seconds: 3),
                              ),
                            );
                          }
                        } else {
                          final errStr = result?['error']?.toString() ?? '';
                          // If payInvoice fails with invalidInput on a BRIX dest, queue for retry
                          if (isBrixAddress && errStr.contains('invalid')) {
                            final amountSats = int.tryParse(amountController.text.trim()) ?? 0;
                            if (amountSats > 0) {
                              await BrixRelayService().queueOutgoingPayment(
                                recipient: invoice,
                                amountSats: amountSats,
                                originalDest: invoice,
                              );
                              if (context.mounted) {
                                Navigator.pop(context);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('✅ Pagamento agendado! Será enviado automaticamente quando o destinatário abrir o app.'),
                                    backgroundColor: Color(0xFF4CAF50),
                                    duration: Duration(seconds: 4),
                                  ),
                                );
                              }
                              _loadWalletInfo();
                              return;
                            }
                          }
                          broLog('❌ Pagamento falhou: ${result?['error']}');
                          setModalState(() {
                            isSending = false;
                            errorMessage = errStr.isNotEmpty ? errStr : AppLocalizations.of(context).t('wallet_send_payment_failed');
                          });
                        }
                      } catch (e, stack) {
                        broLog('❌ Exceção ao enviar: $e');
                        broLog('   Stack: $stack');
                        final isTimeout = e.toString().contains('TimeoutException') || e.toString().contains('timeout');
                        final amountSats = int.tryParse(amountController.text.trim()) ?? 0;
                        if (isTimeout && isBrixAddress && amountSats > 0) {
                          await BrixRelayService().queueOutgoingPayment(
                            recipient: invoice,
                            amountSats: amountSats,
                            originalDest: invoice,
                          );
                          if (context.mounted) {
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('✅ Pagamento agendado! Será enviado automaticamente quando o destinatário abrir o app.'),
                                backgroundColor: Color(0xFF4CAF50),
                                duration: Duration(seconds: 4),
                              ),
                            );
                          }
                          _loadWalletInfo();
                        } else {
                          setModalState(() {
                            isSending = false;
                            errorMessage = 'Erro: $e';
                          });
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
                    label: Text(isSending ? AppLocalizations.of(context).t('wallet_sending') : AppLocalizations.of(context).t('wallet_confirm_and_send')),
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
                    child: Text(
                      AppLocalizations.of(context).t('cancel'),
                      style: const TextStyle(color: Colors.white54),
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
                    Expanded(
                      child: Text(
                        AppLocalizations.of(context).t('wallet_receive_bitcoin'),
                        style: const TextStyle(
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
                      labelText: AppLocalizations.of(context).t('wallet_quantity_sats'),
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
                          setModalState(() => errorMsg = AppLocalizations.of(context).t('wallet_enter_valid_value'));
                          return;
                        }
                        
                        if (amount < 100) {
                          setModalState(() => errorMsg = AppLocalizations.of(context).t('wallet_minimum_100_sats'));
                          return;
                        }
                        
                        setModalState(() {
                          isGenerating = true;
                          errorMsg = null;
                        });
                        
                        broLog('🎯 Gerando invoice de $amount sats...');
                        
                        try {
                          // Usar LightningProvider com fallback Spark -> Liquid
                          final lightningProvider = context.read<LightningProvider>();
                          final result = await lightningProvider.createInvoice(
                            amountSats: amount,
                            description: 'Receber $amount sats - Bro App',
                          );
                          
                          broLog('📦 Resultado createInvoice: $result');
                          
                          // Log se usou Liquid
                          if (result?['isLiquid'] == true) {
                            broLog('💧 Invoice criada via LIQUID (fallback)');
                          }
                          
                          if (result != null && result['bolt11'] != null) {
                            final bolt11 = result['bolt11'] as String;
                            broLog('✅ Invoice: ${bolt11.substring(0, 50)}...');
                            setModalState(() {
                              generatedInvoice = bolt11;
                              isGenerating = false;
                            });
                          } else {
                            throw Exception(result?['error'] ?? 'Falha ao gerar invoice');
                          }
                        } catch (e) {
                          broLog('❌ Erro ao gerar invoice: $e');
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
                      label: Text(isGenerating ? AppLocalizations.of(context).t('wallet_generating') : AppLocalizations.of(context).t('wallet_generate_invoice')),
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
                              SnackBar(
                                content: Text(AppLocalizations.of(context).t('wallet_invoice_copied')),
                                backgroundColor: const Color(0xFF4CAF50),
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
                      label: Text(AppLocalizations.of(context).t('wallet_generate_new_invoice')),
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
        Text(
          AppLocalizations.of(context).t('wallet_transaction_history'),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        if (_payments.isEmpty && _pendingOutgoing.isEmpty)
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
                  AppLocalizations.of(context).t('wallet_no_transactions'),
                  style: TextStyle(color: Colors.white.withOpacity(0.5)),
                ),
              ],
            ),
          )
        else
          ...(_pendingOutgoing.map((p) => _buildPendingOutgoingItem(p))),
          ...(_payments.take(15).map((payment) => _buildPaymentItem(payment))),
      ],
    );
  }

  Widget _buildPendingOutgoingItem(Map<String, dynamic> pending) {
    final amount = (pending['amountSats'] as int?) ?? 0;
    final recipient = pending['originalDest']?.toString() ?? pending['recipient']?.toString() ?? '?';
    final created = DateTime.tryParse(pending['createdAt'] ?? '');
    final retryCount = (pending['retryCount'] as int?) ?? 0;

    return Dismissible(
      key: Key('pending_${pending['id']}'),
      direction: DismissDirection.endToStart,
      background: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: Colors.red.shade800,
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.centerRight,
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      onDismissed: (_) {
        BrixRelayService().cancelOutgoingPayment(pending['id'].toString());
        setState(() => _pendingOutgoing.removeWhere((p) => p['id'] == pending['id']));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Pagamento pendente cancelado'),
            backgroundColor: Color(0xFFFF6B6B),
          ),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2A),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.amber.withOpacity(0.4)),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: Colors.amber.withOpacity(0.2),
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Icon(Icons.schedule, color: Colors.amber, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'envio brix pendente',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  Text(
                    '→ $recipient',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.6),
                      fontSize: 11,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    retryCount > 0
                        ? 'Aguardando destinatário (tentativa $retryCount)'
                        : 'Aguardando destinatário ficar online',
                    style: TextStyle(
                      color: Colors.amber.withOpacity(0.8),
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
                  '-$amount sats',
                  style: const TextStyle(
                    color: Colors.amber,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                if (created != null)
                  Text(
                    _formatDateFull(created),
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.4),
                      fontSize: 10,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
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
    
    // Obter OrderProvider para correlações
    final orderProvider = context.read<OrderProvider>();
    final currentPubkey = orderProvider.currentUserPubkey;
    final paymentHash = payment['paymentHash']?.toString() ?? '';
    
    // CORREÇÃO: Correlacionar por paymentHash (exato) em vez de heurística por valor
    // Cada ordem salva o paymentHash no momento do pagamento
    bool isBroOrderPayment = false;
    String? correlatedOrderId;
    
    // 1. Correlação EXATA por paymentHash (mais confiável)
    if (paymentHash.isNotEmpty) {
      for (final order in orderProvider.orders) {
        if (order.paymentHash == paymentHash) {
          if (order.providerId == currentPubkey && order.userPubkey != currentPubkey) {
            // Eu sou o provedor — é ganho como Bro
            isBroOrderPayment = true;
          }
          correlatedOrderId = order.id;
          break;
        }
      }
    }
    
    // 2. Fallback: Correlação por descrição
    // Suporta múltiplos formatos: "Bro - Ordem XXXXXXXX" e "Bro XXXXXXXX"
    if (correlatedOrderId == null && 
        !description.contains('Garantia') &&
        !description.contains('Platform Fee')) {
      String? orderIdFromDesc;
      if (description.contains('Bro - Ordem ')) {
        orderIdFromDesc = description.split('Bro - Ordem ').last.trim();
      } else if (description.startsWith('Bro ') && description.length >= 12) {
        // Formato: "Bro {orderId}" (usado ao criar invoice)
        orderIdFromDesc = description.substring(4).trim();
      }
      
      if (orderIdFromDesc != null && orderIdFromDesc.isNotEmpty) {
        final order = orderProvider.orders.cast<Order?>().firstWhere(
          (o) => o!.id.startsWith(orderIdFromDesc!) || 
                 orderIdFromDesc!.startsWith(o.id.substring(0, 8)) ||
                 o.id == orderIdFromDesc,
          orElse: () => null,
        );
        if (order != null) {
          isBroOrderPayment = order.providerId == currentPubkey && order.userPubkey != currentPubkey;
          if (!isBroOrderPayment) {
            correlatedOrderId = order.id;
          }
        } else if (orderIdFromDesc.length >= 8) {
          // Ordem não encontrada no cache local, mas temos o ID da descrição
          // Usar o ID extraído da descrição como fallback
          correlatedOrderId = orderIdFromDesc;
        }
      }
    }
    
    // 3. Fallback final: Se a descrição contém padrões conhecidos do Bro mas não correlacionou,
    // ainda marcar como pagamento Bro (heurística da v1.0.107 que sempre funcionou)
    if (!isBroOrderPayment && correlatedOrderId == null && isReceived &&
        !description.contains('Garantia')) {
      if (description.contains('Bro Payment') || 
          description.contains('Bro - Ordem') || 
          description.contains('Bro Ordem') ||
          (description.startsWith('Bro ') && description.length >= 12)) {
        isBroOrderPayment = true;
      }
    }
    
    // v246: Detectar transações do Marketplace pela descrição do invoice
    final isMarketplace = description.contains('Bro Marketplace');
    String marketplaceProduct = '';
    if (isMarketplace) {
      marketplaceProduct = description.replaceFirst('Bro Marketplace: ', '').replaceFirst('Bro Marketplace:', '').trim();
      if (marketplaceProduct.isEmpty) marketplaceProduct = 'Produto';
    }
    
    // Determinar o label e cor baseado no tipo
    String label;
    Color iconColor;
    IconData icon;
    
    if (isMarketplace) {
      // v246: Transação do Marketplace
      if (isReceived) {
        label = AppLocalizations.of(context).tp('wallet_marketplace_sale', {'product': marketplaceProduct});
        iconColor = Colors.green;
        icon = Icons.storefront;
      } else {
        label = AppLocalizations.of(context).tp('wallet_marketplace_purchase', {'product': marketplaceProduct});
        iconColor = Colors.orange;
        icon = Icons.shopping_cart;
      }
    } else if (description == 'BRIX Payment' || description.toLowerCase().contains('brix payment')) {
      // BRIX recebido
      label = 'pagamento brix';
      iconColor = Colors.amber;
      icon = Icons.flash_on;
    } else if (!isReceived && (description.toLowerCase().contains('@brostr.app') || description.toLowerCase().contains('@brix.app'))) {
      // BRIX enviado (description from LNURL metadata: "Payment to user@brix.brostr.app")
      label = 'envio brix';
      iconColor = Colors.amber;
      icon = Icons.flash_on;
    } else if (isBroEarning || isBroOrderPayment) {
      label = AppLocalizations.of(context).t('wallet_bro_earning');
      iconColor = Colors.green;
      icon = Icons.volunteer_activism;
    } else if (isReceived) {
      // Se temos uma ordem correlacionada para este depósito
      if (correlatedOrderId != null) {
        label = AppLocalizations.of(context).tp('wallet_deposit_for_order_id', {'orderId': correlatedOrderId.substring(0, 8)});
        iconColor = Colors.amber;
        icon = Icons.receipt_long;
      } else if (description.contains('Depósito Bro') || description.contains('Deposito Bro')) {
        // Depósito manual na carteira
        label = '📥 $description';
        iconColor = Colors.blue;
        icon = Icons.account_balance_wallet;
      } else if (description.contains('Receber') && description.contains('sats')) {
        // Recebimento manual via invoice
        label = '📥 $description';
        iconColor = Colors.green;
        icon = Icons.arrow_downward;
      } else if (description.contains('Garantia Bro')) {
        // Depósito de garantia para tier do provedor Bro
        label = '🔒 $description';
        iconColor = Colors.amber;
        icon = Icons.shield;
      } else {
        label = AppLocalizations.of(context).t('wallet_received');
        iconColor = Colors.green;
        icon = Icons.arrow_downward;
      }
    } else {
      // Verificar se é pagamento com saldo da carteira ou depósito Lightning
      final isWalletPayment = payment['isWalletPayment'] == true;
      if (isWalletPayment) {
        // v257: Pagamento feito com saldo da carteira
        if (correlatedOrderId != null) {
          label = AppLocalizations.of(context).tp('wallet_payment_wallet_id', {'orderId': correlatedOrderId.substring(0, 8)});
        } else {
          label = '💰 $description';
        }
        iconColor = Colors.orange;
        icon = Icons.account_balance_wallet;
      } else if (description == 'Bro Wallet Payment' || description == 'Bro Payment') {
        // Já correlacionado por paymentHash acima
        if (correlatedOrderId != null) {
          label = AppLocalizations.of(context).tp('wallet_deposit_for_order_id', {'orderId': correlatedOrderId.substring(0, 8)});
        } else {
          label = AppLocalizations.of(context).t('wallet_deposit_for_order');
        }
        iconColor = Colors.amber;
        icon = Icons.receipt_long;
      } else if (description.contains('Ordem') || description.contains('conta')) {
        // Pagamento de conta (descrição contém info de ordem)
        label = AppLocalizations.of(context).t('wallet_bill_payment');
        iconColor = Colors.red;
        icon = Icons.arrow_upward;
      } else {
        label = AppLocalizations.of(context).t('wallet_sent');
        iconColor = Colors.red;
        icon = Icons.arrow_upward;
      }
    }
    
    // Usar estilo destacado para ganhos Bro e marketplace
    final showBroStyle = isBroEarning || isBroOrderPayment;
    final showMarketplaceStyle = isMarketplace;

    // Integrar taxa da plataforma ao valor exibido (spread) para não aparecer separada
    // Quando é um pagamento enviado correlacionado com uma ordem, o total inclui a taxa
    int displayAmount = (amount is int) ? amount : (amount as num).toInt();
    if (!isReceived && correlatedOrderId != null && PlatformFeeService.isFeePaid(correlatedOrderId!)) {
      final feeRaw = (displayAmount * AppConfig.platformFeePercent).round();
      final fee = feeRaw < 1 ? 1 : feeRaw;
      displayAmount = displayAmount + fee;
    }
    // Ganho como Bro: incluir taxa de 3% do provedor no valor exibido
    if (isBroEarning || isBroOrderPayment) {
      final providerFeeRaw = (displayAmount * AppConfig.providerFeePercent).round();
      displayAmount = displayAmount + (providerFeeRaw < 1 ? 1 : providerFeeRaw);
    }

    return GestureDetector(
      onTap: () => _showTransactionDetails(payment),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: showBroStyle ? const Color(0xFF1A2A1A) : showMarketplaceStyle ? const Color(0xFF1A1A2A) : const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: showBroStyle ? Colors.green.withOpacity(0.3) : showMarketplaceStyle ? Colors.orange.withOpacity(0.3) : const Color(0xFF333333)),
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
                  '${isReceived ? '+' : '-'}$displayAmount sats',
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
    
    // Correlacionar com ordem se possível
    final orderProvider = context.read<OrderProvider>();
    final currentPubkey = orderProvider.currentUserPubkey;
    String? correlatedOrderId;
    Order? correlatedOrder;
    
    // Verificar se é depósito para uma ordem que eu criei
    if (isReceived && (description.contains('Bro Payment') || description.contains('Bro - Ordem'))) {
      String? orderIdFromDesc;
      if (description.contains('Bro - Ordem ')) {
        orderIdFromDesc = description.split('Bro - Ordem ').last.trim();
      }
      
      if (orderIdFromDesc != null && orderIdFromDesc.isNotEmpty) {
        try {
          correlatedOrder = orderProvider.orders.firstWhere(
            (o) => o.id.startsWith(orderIdFromDesc!) || orderIdFromDesc!.startsWith(o.id.substring(0, 8)),
          );
          correlatedOrderId = correlatedOrder.id;
        } catch (_) {}
      }
      
      // Se não encontrou pelo ID, tentar correlação por valor
      if (correlatedOrderId == null) {
        final myOrders = orderProvider.myCreatedOrders;
        final paymentDate = date is DateTime ? date : DateTime.now();
        
        for (final order in myOrders) {
          final orderSats = (order.btcAmount * 100000000).round();
          final tolerance = (orderSats * 0.05).round();
          
          if ((amount - orderSats).abs() <= tolerance) {
            final orderDate = order.createdAt;
            final diff = paymentDate.difference(orderDate).abs();
            if (diff.inHours <= 24) {
              correlatedOrderId = order.id;
              correlatedOrder = order;
              break;
            }
          }
        }
      }
    }
    
    // v406: Correlacionar pagamentos ENVIADOS com ordens que eu criei (modo usuário)
    // Quando o usuário cria uma ordem, ele ENVIA sats para o escrow
    if (!isReceived && correlatedOrder == null) {
      // Tentar correlação por paymentHash
      if (paymentHash.isNotEmpty) {
        try {
          correlatedOrder = orderProvider.orders.firstWhere(
            (o) => o.paymentHash == paymentHash,
          );
          correlatedOrderId = correlatedOrder.id;
        } catch (_) {}
      }
      
      // Tentar correlação por descrição
      if (correlatedOrder == null && description.contains('Bro')) {
        String? orderIdFromDesc;
        if (description.contains('Bro - Ordem ')) {
          orderIdFromDesc = description.split('Bro - Ordem ').last.trim();
        }
        if (orderIdFromDesc != null && orderIdFromDesc.isNotEmpty) {
          try {
            correlatedOrder = orderProvider.orders.firstWhere(
              (o) => o.id.startsWith(orderIdFromDesc!) || orderIdFromDesc!.startsWith(o.id.substring(0, 8)),
            );
            correlatedOrderId = correlatedOrder.id;
          } catch (_) {}
        }
      }
      
      // Tentar correlação por valor/data com ordens que eu criei
      if (correlatedOrder == null) {
        final myOrders = orderProvider.myCreatedOrders;
        final paymentDate = date is DateTime ? date : DateTime.now();
        
        for (final order in myOrders) {
          final totalSats = (order.total / order.btcPrice * 100000000).round();
          final tolerance = (totalSats * 0.05).round();
          
          if ((amount - totalSats).abs() <= tolerance) {
            final orderDate = order.createdAt;
            final diff = paymentDate.difference(orderDate).abs();
            if (diff.inHours <= 24) {
              correlatedOrderId = order.id;
              correlatedOrder = order;
              break;
            }
          }
        }
      }
    }
    
    // Determinar tipo para exibição
    String typeLabel;
    Color typeColor;
    IconData typeIcon;
    
    // Verificar se é ganho Bro (sou o provedor, não o criador)
    bool isGanhoBro = isBroEarning;
    if (correlatedOrder != null && correlatedOrder.providerId == currentPubkey && correlatedOrder.userPubkey != currentPubkey) {
      isGanhoBro = true;
    }
    
    if (isGanhoBro) {
      typeLabel = AppLocalizations.of(context).t('wallet_type_bro_earning');
      typeColor = Colors.green;
      typeIcon = Icons.volunteer_activism;
    } else if (isReceived && correlatedOrderId != null) {
      typeLabel = AppLocalizations.of(context).t('wallet_type_deposit_order');
      typeColor = Colors.amber;
      typeIcon = Icons.receipt_long;
    } else if (isReceived) {
      typeLabel = AppLocalizations.of(context).t('wallet_type_received_lightning');
      typeColor = Colors.green;
      typeIcon = Icons.arrow_downward;
    } else {
      typeLabel = AppLocalizations.of(context).t('wallet_type_sent_lightning');
      typeColor = Colors.red;
      typeIcon = Icons.arrow_upward;
    }
    
    // Integrar taxa no valor exibido (mesmo spread do histórico)
    int detailAmount = (amount is int) ? amount : (amount as num).toInt();
    final int baseSats = detailAmount; // Valor original do pagamento Lightning (sats do PIX)
    if (!isReceived && correlatedOrderId != null && PlatformFeeService.isFeePaid(correlatedOrderId!)) {
      final feeRaw = (detailAmount * AppConfig.platformFeePercent).round();
      detailAmount = detailAmount + (feeRaw < 1 ? 1 : feeRaw);
    }
    // Ganho como Bro: incluir taxa de 3% do provedor no valor exibido
    if (isGanhoBro) {
      final providerFeeRaw = (baseSats * AppConfig.providerFeePercent).round();
      detailAmount = baseSats + (providerFeeRaw < 1 ? 1 : providerFeeRaw);
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
                            '${isReceived ? '+' : '-'}$detailAmount sats',
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
                _buildDetailRow(AppLocalizations.of(context).t('wallet_date_time'), date != null ? _formatDateFull(date) : AppLocalizations.of(context).t('wallet_not_available')),
                _buildDetailRow(AppLocalizations.of(context).t('wallet_status'), status.replaceAll('PaymentStatus.', '').toUpperCase()),
                if (description.isNotEmpty)
                  _buildDetailRow(AppLocalizations.of(context).t('wallet_description'), description),
                _buildDetailRow(AppLocalizations.of(context).t('wallet_network'), 'Lightning Network'),
                
                // NOVO: Mostrar dados da ordem correlacionada
                if (correlatedOrder != null) ...[
                  const SizedBox(height: 16),
                  const Divider(color: Color(0xFF333333)),
                  const SizedBox(height: 16),
                  
                  Text(
                    AppLocalizations.of(context).t('wallet_order_data'),
                    style: const TextStyle(
                      color: Colors.amber,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  
                  _buildDetailRow(AppLocalizations.of(context).t('wallet_order_number'), '#${correlatedOrder.id.substring(0, 8).toUpperCase()}'),
                  _buildDetailRow(AppLocalizations.of(context).t('payment_type'), correlatedOrder.billType),
                  _buildDetailRow(AppLocalizations.of(context).t('wallet_value_brl'), 'R\$ ${correlatedOrder.amount.toStringAsFixed(2)}'),
                  _buildDetailRow(AppLocalizations.of(context).t('wallet_value_btc'), '${correlatedOrder.btcAmount.toStringAsFixed(8)} BTC'),
                  _buildDetailRow(AppLocalizations.of(context).t('wallet_order_status'), correlatedOrder.status.toUpperCase()),
                  if (correlatedOrder.billCode.isNotEmpty)
                    _buildDetailRow(AppLocalizations.of(context).t('wallet_code'), correlatedOrder.billCode, monospace: true),
                  // v406: Detalhamento de custos para o USUÁRIO (pagamento enviado)
                  if (!isReceived && !isGanhoBro) ...[
                    const SizedBox(height: 12),
                    const Divider(color: Color(0xFF333333)),
                    const SizedBox(height: 12),
                    Text(
                      AppLocalizations.of(context).t('wallet_cost_breakdown'),
                      style: const TextStyle(
                        color: Colors.amber,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Builder(builder: (context) {
                      final billSats = correlatedOrder!.btcPrice > 0
                          ? (correlatedOrder.amount / correlatedOrder.btcPrice * 100000000).round()
                          : 0;
                      final provFeeBrl = correlatedOrder.providerFee;
                      final provFeeSats = correlatedOrder.btcPrice > 0
                          ? (provFeeBrl / correlatedOrder.btcPrice * 100000000).round()
                          : 0;
                      final totalBrl = correlatedOrder.total;
                      final totalSats = correlatedOrder.btcPrice > 0
                          ? (totalBrl / correlatedOrder.btcPrice * 100000000).round()
                          : 0;
                      return Column(
                        children: [
                          _buildDetailRow(
                            AppLocalizations.of(context).t('wallet_bill_value'),
                            'R\$ ${correlatedOrder.amount.toStringAsFixed(2)}  (~$billSats sats)',
                          ),
                          _buildDetailRow(
                            AppLocalizations.of(context).t('wallet_provider_fee'),
                            'R\$ ${provFeeBrl.toStringAsFixed(2)}  (~$provFeeSats sats)',
                          ),
                          const Divider(color: Color(0xFF333333)),
                          _buildDetailRow(
                            AppLocalizations.of(context).t('wallet_total_paid'),
                            'R\$ ${totalBrl.toStringAsFixed(2)}  (~$totalSats sats)',
                          ),
                        ],
                      );
                    }),
                  ],
                  // Provider fee breakdown for Bro earnings
                  if (isGanhoBro) ...[                    
                    const SizedBox(height: 12),
                    const Divider(color: Color(0xFF333333)),
                    const SizedBox(height: 12),
                    Text(
                      AppLocalizations.of(context).t('wallet_earnings_breakdown'),
                      style: const TextStyle(
                        color: Colors.green,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _buildDetailRow(
                      AppLocalizations.of(context).t('wallet_pix_cost'),
                      'R\$ ${correlatedOrder.amount.toStringAsFixed(2)} (~$baseSats sats)',
                    ),
                    Builder(builder: (context) {
                      final providerFeeSats = detailAmount - baseSats;
                      final providerFeeBrl = correlatedOrder!.amount * AppConfig.providerFeePercent;
                      return _buildDetailRow(
                        '💰 ${AppLocalizations.of(context).t('wallet_your_profit')} (${(AppConfig.providerFeePercent * 100).toStringAsFixed(0)}%)',
                        '+ $providerFeeSats sats (~R\$ ${providerFeeBrl.toStringAsFixed(2)})',
                      );
                    }),
                    const Divider(color: Color(0xFF333333)),
                    _buildDetailRow(
                      AppLocalizations.of(context).t('wallet_total_received'),
                      '$detailAmount sats',
                    ),
                  ],
                ],
                  
                const SizedBox(height: 16),
                const Divider(color: Color(0xFF333333)),
                const SizedBox(height: 16),
                
                // Dados técnicos
                Text(
                  AppLocalizations.of(context).t('wallet_technical_data'),
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                
                if (paymentHash.isNotEmpty && paymentHash != 'N/A' && paymentHash != 'null')
                  _buildDetailRow(AppLocalizations.of(context).t('wallet_payment_hash'), paymentHash, copyable: true, monospace: true),
                if (paymentId.isNotEmpty)
                  _buildDetailRow(AppLocalizations.of(context).t('wallet_transaction_id'), paymentId, copyable: true, monospace: true),
                
                const SizedBox(height: 24),
                
                // Botão de copiar tudo
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () => _copyAllDetails(payment),
                    icon: const Icon(Icons.copy, size: 18),
                    label: Text(AppLocalizations.of(context).t('wallet_copy_all_data')),
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
                    content: Text(AppLocalizations.of(context).tp('nip06_copied', {'label': label})),
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
    buffer.writeln(AppLocalizations.of(context).t('wallet_copy_header'));
    buffer.writeln('${AppLocalizations.of(context).t('payment_type')}: ${isReceived ? AppLocalizations.of(context).t('wallet_received') : AppLocalizations.of(context).t('wallet_sent')}');
    buffer.writeln('${AppLocalizations.of(context).t('payment_value_label')}: $amount sats');
    if (date != null) buffer.writeln('${AppLocalizations.of(context).t('wallet_date_time')}: ${_formatDateFull(date)}');
    buffer.writeln('${AppLocalizations.of(context).t('wallet_status')}: ${status.replaceAll('PaymentStatus.', '')}');
    buffer.writeln('${AppLocalizations.of(context).t('wallet_network')}: Lightning Network');
    if (description.isNotEmpty) buffer.writeln('${AppLocalizations.of(context).t('wallet_description')}: $description');
    buffer.writeln('');
    buffer.writeln(AppLocalizations.of(context).t('wallet_copy_technical_header'));
    if (paymentId.isNotEmpty) buffer.writeln('ID: $paymentId');
    if (paymentHash.isNotEmpty && paymentHash != 'null') buffer.writeln('Payment Hash: $paymentHash');
    
    Clipboard.setData(ClipboardData(text: buffer.toString()));
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context).t('wallet_all_data_copied')),
        backgroundColor: const Color(0xFFFF9800),
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
}
