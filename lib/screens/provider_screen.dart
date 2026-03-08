import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'dart:io';
import '../services/provider_service.dart';
import '../services/storage_service.dart';
import '../services/local_collateral_service.dart';
import '../services/bitcoin_price_service.dart';
import '../services/notification_service.dart';
import '../services/nostr_service.dart';
import '../providers/collateral_provider.dart';
import '../providers/breez_provider_export.dart';
import '../providers/order_provider.dart';
import '../models/collateral_tier.dart';
import '../widgets/order_card.dart';
import '../config.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';

class ProviderScreen extends StatefulWidget {
  const ProviderScreen({Key? key}) : super(key: key);

  @override
  State<ProviderScreen> createState() => _ProviderScreenState();
}

class _ProviderScreenState extends State<ProviderScreen> with SingleTickerProviderStateMixin {
  final ProviderService _providerService = ProviderService();
  final StorageService _storageService = StorageService();
  final ImagePicker _imagePicker = ImagePicker();
  final LocalCollateralService _collateralService = LocalCollateralService();
  final NotificationService _notificationService = NotificationService();

  late TabController _tabController;
  
  String _providerId = '';
  Map<String, dynamic>? _stats;
  List<Map<String, dynamic>> _availableOrders = [];
  List<Map<String, dynamic>> _myOrders = [];
  List<Map<String, dynamic>> _history = [];
  
  // Tier info
  LocalCollateral? _currentTier;
  double? _btcPrice;
  bool _tierWarning = false; // Se precisa aumentar garantia
  String? _tierWarningMessage;
  
  bool _isLoadingStats = false;
  bool _isLoadingAvailable = false;
  bool _isLoadingMyOrders = false;
  bool _isLoadingHistory = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _initProvider();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _initProvider() async {
    // Usar a pubkey do Nostr como ID do provedor
    final nostrService = NostrService();
    final pubkey = nostrService.publicKey;
    
    if (pubkey != null) {
      _providerId = pubkey;
      broLog('👤 Provider ID (Nostr pubkey): ${_providerId.length >= 16 ? _providerId.substring(0, 16) : _providerId}...');
    } else {
      // Fallback: gera um ID local se não tiver Nostr configurado
      _providerId = await _storageService.getProviderId() ?? _generateProviderId();
      await _storageService.saveProviderId(_providerId);
      broLog('⚠️ Usando provider ID local: $_providerId');
    }
    
    await _loadAll();
    await _checkTierStatus();
  }

  /// Verifica o status do tier e se precisa de atenção
  Future<void> _checkTierStatus() async {
    try {
      // Carregar tier atual
      _currentTier = await _collateralService.getCollateral();
      
      // Atualizar UI mesmo se não tiver tier (para limpar estado)
      if (mounted) setState(() {});
      
      if (_currentTier == null) {
        _tierWarning = false;
        _tierWarningMessage = null;
        return;
      }
      
      // Buscar saldo ATUAL da carteira
      int walletBalance = 0;
      try {
        final breezProvider = context.read<BreezProvider>();
        final balanceInfo = await breezProvider.getBalance();
        walletBalance = int.tryParse(balanceInfo['balance']?.toString() ?? '0') ?? 0;
        broLog('🏷️ Saldo da carteira: $walletBalance sats');
      } catch (e) {
        broLog('⚠️ Erro ao buscar saldo: $e');
      }
      
      // Carregar preço atual do Bitcoin
      final priceService = BitcoinPriceService();
      _btcPrice = await priceService.getBitcoinPrice();
      
      if (_btcPrice == null) {
        _tierWarning = false;
        _tierWarningMessage = null;
        return;
      }
      
      // Verificar se o tier ainda é válido com o preço atual
      final tiers = CollateralTier.getAvailableTiers(_btcPrice!);
      final currentTierDef = tiers.firstWhere(
        (t) => t.id == _currentTier!.tierId,
        orElse: () => tiers.first,
      );
      
      final requiredSats = currentTierDef.requiredCollateralSats;
      // 🔥 Tolerância de 10% para oscilação do Bitcoin
      final minRequiredWithTolerance = (requiredSats * 0.90).round();
      broLog('🏷️ Tier ${currentTierDef.id}: requer $requiredSats sats (mínimo c/ tolerância: $minRequiredWithTolerance), carteira tem $walletBalance sats');
      
      // O tier está em risco se o SALDO DA CARTEIRA for menor que o mínimo com tolerância
      if (walletBalance < minRequiredWithTolerance) {
        final deficit = minRequiredWithTolerance - walletBalance;
        setState(() {
          _tierWarning = true;
          _tierWarningMessage = 'Deposite mais $deficit sats para manter o ${_currentTier!.tierName}';
        });
        broLog('⚠️ Tier em risco! Faltam $deficit sats');
        
        // Enviar notificação
        await _notificationService.notifyTierAtRisk(
          tierName: _currentTier!.tierName,
          missingAmount: deficit,
        );
      } else {
        setState(() {
          _tierWarning = false;
          _tierWarningMessage = null;
        });
        broLog('✅ Tier ativo! Saldo suficiente');
      }
    } catch (e) {
      broLog('Erro ao verificar tier: $e');
      _tierWarning = false;
      _tierWarningMessage = null;
    }
    
    if (mounted) setState(() {});
  }

  String _generateProviderId() {
    return 'provider_${DateTime.now().millisecondsSinceEpoch}';
  }

  Future<void> _loadAll() async {
    await Future.wait([
      _loadStats(),
      _loadAvailableOrders(),
      _loadMyOrders(),
      _loadHistory(),
    ]);
  }

  Future<void> _loadStats() async {
    setState(() => _isLoadingStats = true);
    final stats = await _providerService.getStats(_providerId);
    setState(() {
      _stats = stats;
      _isLoadingStats = false;
    });
  }

  Future<void> _loadAvailableOrders() async {
    setState(() => _isLoadingAvailable = true);
    final orders = await _providerService.fetchAvailableOrders();
    setState(() {
      _availableOrders = orders;
      _isLoadingAvailable = false;
    });
  }

  Future<void> _loadMyOrders() async {
    setState(() => _isLoadingMyOrders = true);
    final orders = await _providerService.fetchMyOrders(_providerId);
    setState(() {
      _myOrders = orders;
      _isLoadingMyOrders = false;
    });
  }

  Future<void> _loadHistory() async {
    setState(() => _isLoadingHistory = true);
    final history = await _providerService.fetchHistory(_providerId);
    setState(() {
      _history = history;
      _isLoadingHistory = false;
    });
  }

  Future<void> _onAcceptOrder(Map<String, dynamic> order) async {
    final l = AppLocalizations.of(context)!;
    final orderId = order['_id'] ?? order['id'];
    if (orderId == null) return;

    final orderAmount = (order['amount'] ?? 0.0).toDouble();
    
    // Validar se pode aceitar esta ordem baseado no tier
    if (!AppConfig.providerTestMode) {
      final collateralProvider = context.read<CollateralProvider>();
      if (!collateralProvider.canAcceptOrder(orderAmount)) {
        final reason = collateralProvider.getCannotAcceptReason(orderAmount);
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: [
                const Icon(Icons.block, color: Colors.orange, size: 28),
                const SizedBox(width: 12),
                Text(l.t('prov_tier_limit'), style: const TextStyle(color: Colors.white)),
              ],
            ),
            content: Text(
              reason ?? l.t('prov_tier_limit_msg'),
              style: const TextStyle(color: Color(0xB3FFFFFF)),
            ),
            actions: [
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                ),
                child: Text(l.t('prov_understood'), style: const TextStyle(color: Colors.white)),
              ),
            ],
          ),
        );
        return;
      }
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.t('prov_accept_order')),
        content: Text(
          l.tp('prov_accept_order_confirm', {'amount': _formatCurrency(orderAmount)}),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.t('cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
            ),
            child: Text(l.t('prov_dash_accept')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      _showLoadingDialog(l.t('prov_accepting_order'));
      
      // Usar OrderProvider que publica no Nostr
      final orderProvider = context.read<OrderProvider>();
      final success = await orderProvider.acceptOrderAsProvider(orderId);
      
      Navigator.pop(context); // Fecha o loading dialog
      
      if (success) {
        _showSnackBar(l.t('prov_order_accepted'), Colors.green);
        await _loadAll(); // Recarrega todas as listas
      } else {
        _showSnackBar(l.t('prov_error_accept_order'), Colors.red);
      }
    }
  }

  Future<void> _onRejectOrder(Map<String, dynamic> order) async {
    final l = AppLocalizations.of(context)!;
    final orderId = order['_id'] ?? order['id'];
    if (orderId == null) return;

    final reason = await showDialog<String>(
      context: context,
      builder: (context) {
        final controller = TextEditingController();
        return AlertDialog(
          title: Text(l.t('prov_reject_order')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l.t('prov_reject_reason')),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                decoration: InputDecoration(
                  hintText: l.t('prov_reason_optional'),
                  border: OutlineInputBorder(),
                ),
                maxLines: 3,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l.t('cancel')),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, controller.text),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              child: Text(l.t('prov_reject')),
            ),
          ],
        );
      },
    );

    if (reason != null) {
      _showLoadingDialog(l.t('prov_rejecting'));
      
      final success = await _providerService.rejectOrder(orderId, reason);
      
      Navigator.pop(context); // Fecha o loading dialog
      
      if (success) {
        _showSnackBar(l.t('prov_order_rejected'), Colors.orange);
        await _loadAvailableOrders();
      } else {
        _showSnackBar(l.t('prov_error_reject_order'), Colors.red);
      }
    }
  }

  Future<void> _onUploadProof(Map<String, dynamic> order) async {
    final l = AppLocalizations.of(context)!;
    final orderId = order['_id'] ?? order['id'];
    if (orderId == null) return;

    final XFile? image = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
    );

    if (image == null) return;

    _showLoadingDialog(l.t('prov_sending_receipt'));

    try {
      final bytes = await File(image.path).readAsBytes();
      final success = await _providerService.uploadProof(orderId, bytes);
      
      Navigator.pop(context); // Fecha o loading dialog
      
      if (success) {
        _showSnackBar(l.t('prov_receipt_sent'), Colors.green);
        await _loadMyOrders();
      } else {
        _showSnackBar(l.t('prov_error_send_receipt'), Colors.red);
      }
    } catch (e) {
      Navigator.pop(context);
      _showSnackBar(l.tp('prov_error_process_image', {'error': e.toString()}), Colors.red);
    }
  }

  void _showLoadingDialog(String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 16),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }

  void _showSnackBar(String message, Color backgroundColor) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: backgroundColor,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  String _formatCurrency(double value) {
    final formatter = NumberFormat.currency(locale: 'pt_BR', symbol: 'R\$');
    return formatter.format(value);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l.t('prov_bro_mode')),
            const SizedBox(width: 8),
            _buildTierBadge(),
          ],
        ),
        elevation: 0,
        actions: [
          // Botão para voltar ao Dashboard principal
          IconButton(
            icon: const Icon(Icons.home, color: Colors.white),
            onPressed: () {
              // Sair do modo Bro e voltar ao dashboard
              final orderProvider = context.read<OrderProvider>();
              orderProvider.exitProviderMode();
              Navigator.pop(context);
            },
            tooltip: l.t('prov_back_dashboard'),
          ),
          // Botão da Carteira Lightning (ícone preenchido como antes)
          IconButton(
            icon: const Icon(Icons.account_balance_wallet, color: Colors.orange),
            onPressed: () {
              Navigator.pushNamed(context, '/wallet');
            },
            tooltip: l.t('prov_wallet'),
          ),
          if (_tierWarning)
            IconButton(
              icon: const Icon(Icons.warning_amber, color: Colors.orange),
              onPressed: _showTierWarningDialog,
              tooltip: l.t('prov_attention_collateral'),
            ),
          // Removido botão refresh - pull-to-refresh já funciona
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: l.t('prov_tab_available'), icon: const Icon(Icons.list_alt)),
            Tab(text: l.t('prov_tab_my_orders'), icon: const Icon(Icons.assignment_ind)),
            Tab(text: l.t('prov_tab_history'), icon: const Icon(Icons.history)),
          ],
        ),
      ),
      body: Column(
        children: [
          // Warning banner só na aba Disponíveis (controlado pelo TabBarView)
          
          // Card de estatísticas
          _buildStatsCard(),
          
          // Lista de ordens com tabs
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildAvailableOrdersTab(),
                _buildMyOrdersList(),
                _buildHistoryList(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Badge compacto do tier - TEXTO CLARO: Ativo ou Inativo
  Widget _buildTierBadge() {
    final l = AppLocalizations.of(context)!;
    broLog('🏷️ _buildTierBadge chamado: _currentTier=${_currentTier?.tierName ?? "null"}, warning=$_tierWarning');
    
    // Se não tem tier, mostra "Sem Tier"
    if (_currentTier == null) {
      broLog('🏷️ Mostrando badge "Sem Tier"');
      return GestureDetector(
        onTap: _showTierDetailsDialog,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.grey.withOpacity(0.2),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey, width: 1),
          ),
          child: Text(
            l.t('prov_no_tier'),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: Colors.grey,
            ),
          ),
        ),
      );
    }
    
    // Calcular déficit se houver
    int? deficit;
    if (_tierWarning && _tierWarningMessage != null) {
      final match = RegExp(r'(\d+)\s*sats').firstMatch(_tierWarningMessage!);
      if (match != null) {
        deficit = int.tryParse(match.group(1) ?? '');
      }
    }
    
    // Tier ativo ou inativo baseado no warning
    final isActive = !_tierWarning;
    final statusText = isActive ? l.t('prov_tier_active') : l.t('prov_tier_inactive');
    final statusColor = isActive ? Colors.green : Colors.orange;
    
    broLog('🏷️ Mostrando badge: $statusText (deficit=$deficit)');
    
    return GestureDetector(
      onTap: () => _showTierStatusExplanation(isActive, deficit),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: statusColor.withOpacity(0.2),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: statusColor, width: 1.5),
        ),
        child: Text(
          statusText,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: statusColor,
          ),
        ),
      ),
    );
  }
  
  /// Dialog explicando status do tier de forma clara
  void _showTierStatusExplanation(bool isActive, int? deficit) {
    final l = AppLocalizations.of(context)!;
    final tierName = _currentTier?.tierName ?? l.t('prov_current_tier_none');
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(
              isActive ? Icons.check_circle : Icons.warning_amber,
              color: isActive ? Colors.green : Colors.orange,
              size: 28,
            ),
            const SizedBox(width: 12),
            Text(
              isActive ? l.t('prov_tier_active') : l.t('prov_tier_inactive'),
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.tp('prov_tier_label', {'name': tierName}),
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 12),
            if (!isActive && deficit != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.t('prov_btc_price_changed'),
                      style: TextStyle(
                        color: Colors.orange,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l.tp('prov_deposit_deficit', {'deficit': deficit.toString()}),
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ] else
              Text(
                l.t('prov_tier_active_msg'),
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.t('close'), style: const TextStyle(color: Colors.white70)),
          ),
          if (!isActive)
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.pushNamed(context, '/provider-collateral');
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
              child: Text(l.t('prov_deposit')),
            ),
        ],
      ),
    );
  }
  
  /// Dialog com detalhes completos do tier
  void _showTierDetailsDialog() {
    final l = AppLocalizations.of(context)!;
    // Calcular valores detalhados
    final lockedSats = _currentTier?.lockedSats ?? 0;
    final tierName = _currentTier?.tierName ?? l.t('prov_current_tier_none');
    final maxTransaction = _currentTier?.maxOrderBrl ?? 0;
    
    // Calcular déficit se houver
    int deficit = 0;
    if (_tierWarning && _tierWarningMessage != null) {
      final match = RegExp(r'(\d+)\s*sats').firstMatch(_tierWarningMessage!);
      if (match != null) {
        deficit = int.tryParse(match.group(1) ?? '') ?? 0;
      }
    }
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(
              _getTierIconById(_currentTier?.tierId ?? 'bronze'),
              color: _getTierColorById(_currentTier?.tierId ?? 'bronze'),
              size: 28,
            ),
            const SizedBox(width: 12),
            Text(tierName, style: const TextStyle(color: Colors.white)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status do tier
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _tierWarning 
                    ? Colors.orange.withOpacity(0.1) 
                    : Colors.green.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _tierWarning 
                      ? Colors.orange.withOpacity(0.3) 
                      : Colors.green.withOpacity(0.3),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _tierWarning ? Icons.warning_amber : Icons.check_circle,
                    color: _tierWarning ? Colors.orange : Colors.green,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _tierWarning ? l.t('prov_tier_at_risk') : l.t('prov_tier_active'),
                    style: TextStyle(
                      color: _tierWarning ? Colors.orange : Colors.green,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            
            // Garantia bloqueada
            _buildDetailRow(
              l.t('prov_collateral_locked'),
              '$lockedSats sats',
              Icons.lock,
            ),
            
            // Limite de transação
            _buildDetailRow(
              l.t('prov_limit_per_tx'),
              'R\$ ${maxTransaction.toStringAsFixed(0)}',
              Icons.attach_money,
            ),
            
            // Déficit se houver
            if (deficit > 0) ...[
              const Divider(color: Colors.white24),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.arrow_downward, color: Colors.red, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l.t('prov_missing_reactivate'),
                            style: TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                          Text(
                            '$deficit sats',
                            style: const TextStyle(
                              color: Colors.red,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        actions: [
          if (_tierWarning)
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                // Navegar para depositar mais
                Navigator.pushNamed(context, '/collateral');
              },
              child: Text(
                l.t('prov_deposit_more'),
                style: const TextStyle(color: Colors.orange),
              ),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.t('close')),
          ),
        ],
      ),
    );
  }
  
  Widget _buildDetailRow(String label, String value, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.white54),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  /// Banner de aviso quando tier está em risco
  Widget _buildTierWarningBanner() {
    final l = AppLocalizations.of(context)!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.orange.withOpacity(0.3), Colors.deepOrange.withOpacity(0.2)],
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber, color: Colors.orange, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _tierWarningMessage ?? l.t('prov_collateral_attention'),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          TextButton(
            onPressed: _showTierWarningDialog,
            child: Text(
              l.t('prov_view'),
              style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  /// Dialog com detalhes do aviso de tier
  void _showTierWarningDialog() {
    final l = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.warning_amber, color: Colors.orange, size: 28),
            const SizedBox(width: 12),
            Text(l.t('prov_collateral_at_risk'), style: const TextStyle(color: Colors.white)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.t('prov_btc_drop_msg'),
              style: const TextStyle(color: Color(0xB3FFFFFF)),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.withOpacity(0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.tp('prov_current_tier', {'name': _currentTier?.tierName ?? l.t('prov_current_tier_none')}),
                    style: const TextStyle(color: Colors.white70),
                  ),
                  if (_tierWarningMessage != null)
                    Text(
                      _tierWarningMessage!,
                      style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              l.t('prov_increase_warning'),
              style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.t('prov_later'), style: const TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.pushNamed(context, '/provider-collateral');
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            child: Text(l.t('prov_increase_collateral'), style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Color _getTierColorById(String tierId) {
    switch (tierId) {
      case 'bronze': return const Color(0xFFCD7F32);
      case 'silver': return Colors.grey.shade400;
      case 'gold': return Colors.amber;
      case 'platinum': return Colors.blueGrey.shade300;
      case 'diamond': return Colors.cyan;
      default: return Colors.orange;
    }
  }

  IconData _getTierIconById(String tierId) {
    switch (tierId) {
      case 'bronze': return Icons.shield_outlined;
      case 'silver': return Icons.shield;
      case 'gold': return Icons.workspace_premium;
      case 'platinum': return Icons.diamond_outlined;
      case 'diamond': return Icons.diamond;
      default: return Icons.verified_user;
    }
  }

  Widget _buildStatsCard() {
    final l = AppLocalizations.of(context)!;
    if (_isLoadingStats) {
      return const Card(
        margin: EdgeInsets.all(16),
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    final earningsToday = (_stats?['earningsToday'] ?? 0.0).toDouble();
    final totalEarnings = (_stats?['totalEarnings'] ?? 0.0).toDouble();
    final billsPaidToday = _stats?['billsPaidToday'] ?? 0;
    final activeOrders = _stats?['activeOrders'] ?? 0;

    return Card(
      margin: const EdgeInsets.all(16),
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.analytics, color: Colors.blue[700]),
                const SizedBox(width: 8),
                Text(
                  l.t('prov_statistics'),
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _buildStatItem(
                    l.t('prov_earnings_today'),
                    _formatCurrency(earningsToday),
                    Icons.today,
                    Colors.green,
                  ),
                ),
                Expanded(
                  child: _buildStatItem(
                    l.t('prov_earnings_total'),
                    _formatCurrency(totalEarnings),
                    Icons.account_balance_wallet,
                    Colors.blue,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildStatItem(
                    l.t('prov_paid_today'),
                    billsPaidToday.toString(),
                    Icons.check_circle,
                    Colors.orange,
                  ),
                ),
                Expanded(
                  child: _buildStatItem(
                    l.t('prov_active_orders'),
                    activeOrders.toString(),
                    Icons.pending_actions,
                    Colors.purple,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatItem(String label, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey[700],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  /// Aba de ordens disponíveis com banner de warning se necessário
  Widget _buildAvailableOrdersTab() {
    return Column(
      children: [
        // Banner de warning só aparece aqui na aba Disponíveis
        if (_tierWarning)
          _buildTierWarningBanner(),
        
        // Lista de ordens disponíveis
        Expanded(child: _buildAvailableOrdersList()),
      ],
    );
  }

  Widget _buildAvailableOrdersList() {
    final l = AppLocalizations.of(context)!;
    if (_isLoadingAvailable) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_availableOrders.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.inbox, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              l.t('prov_no_orders_available'),
              style: TextStyle(fontSize: 16, color: Colors.grey[600]),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _loadAvailableOrders,
              icon: const Icon(Icons.refresh),
              label: Text(l.t('prov_refresh')),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadAvailableOrders,
      child: ListView.builder(
        padding: const EdgeInsets.only(top: 8, bottom: 16),
        itemCount: _availableOrders.length,
        itemBuilder: (context, index) {
          final order = _availableOrders[index];
          return OrderCard(
            order: order,
            showActions: true,
            isMyOrder: false,
            onAccept: () => _onAcceptOrder(order),
            onReject: () => _onRejectOrder(order),
          );
        },
      ),
    );
  }

  Widget _buildMyOrdersList() {
    final l = AppLocalizations.of(context)!;
    if (_isLoadingMyOrders) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_myOrders.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.assignment, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              l.t('prov_no_accepted_orders'),
              style: TextStyle(fontSize: 16, color: Colors.grey[600]),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _loadMyOrders,
              icon: const Icon(Icons.refresh),
              label: Text(l.t('prov_refresh')),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadMyOrders,
      child: ListView.builder(
        padding: const EdgeInsets.only(top: 8, bottom: 16),
        itemCount: _myOrders.length,
        itemBuilder: (context, index) {
          final order = _myOrders[index];
          return OrderCard(
            order: order,
            showActions: true,
            isMyOrder: true,
            onUploadProof: () => _onUploadProof(order),
          );
        },
      ),
    );
  }

  Widget _buildHistoryList() {
    final l = AppLocalizations.of(context)!;
    if (_isLoadingHistory) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_history.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.history, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              l.t('prov_no_completed_orders'),
              style: TextStyle(fontSize: 16, color: Colors.grey[600]),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _loadHistory,
              icon: const Icon(Icons.refresh),
              label: Text(l.t('prov_refresh')),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadHistory,
      child: ListView.builder(
        padding: const EdgeInsets.only(top: 8, bottom: 16),
        itemCount: _history.length,
        itemBuilder: (context, index) {
          final order = _history[index];
          return OrderCard(
            order: order,
            showActions: false,
            isMyOrder: true,
          );
        },
      ),
    );
  }
}
