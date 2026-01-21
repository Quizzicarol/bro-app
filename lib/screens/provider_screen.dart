import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'dart:io';
import '../services/provider_service.dart';
import '../services/storage_service.dart';
import '../services/local_collateral_service.dart';
import '../services/bitcoin_price_service.dart';
import '../services/notification_service.dart';
import '../providers/collateral_provider.dart';
import '../models/collateral_tier.dart';
import '../widgets/order_card.dart';
import '../config.dart';
import 'package:intl/intl.dart';

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
    // Busca ou gera um ID de provedor (você pode adaptar conforme necessário)
    _providerId = await _storageService.getProviderId() ?? _generateProviderId();
    await _storageService.saveProviderId(_providerId);
    
    await _loadAll();
    await _checkTierStatus();
  }

  /// Verifica o status do tier e se precisa de atenção
  Future<void> _checkTierStatus() async {
    try {
      // Carregar tier atual
      _currentTier = await _collateralService.getCollateral();
      
      if (_currentTier == null) return;
      
      // Carregar preço atual do Bitcoin
      final priceService = BitcoinPriceService();
      _btcPrice = await priceService.getBitcoinPrice();
      
      if (_btcPrice == null) return;
      
      // Verificar se o tier ainda é válido com o preço atual
      final tiers = CollateralTier.getAvailableTiers(_btcPrice!);
      final currentTierDef = tiers.firstWhere(
        (t) => t.id == _currentTier!.tierId,
        orElse: () => tiers.first,
      );
      
      // Verificar se o saldo ainda cobre o requisito
      // O requiredSats do tier pode ter aumentado se BTC caiu
      if (currentTierDef.requiredCollateralSats > _currentTier!.lockedSats) {
        final deficit = currentTierDef.requiredCollateralSats - _currentTier!.lockedSats;
        setState(() {
          _tierWarning = true;
          _tierWarningMessage = 'Deposite mais $deficit sats para manter o ${_currentTier!.tierName}';
        });
        
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
      }
    } catch (e) {
      debugPrint('Erro ao verificar tier: $e');
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
                const Text('Limite de Tier', style: TextStyle(color: Colors.white)),
              ],
            ),
            content: Text(
              reason ?? 'Você não pode aceitar esta ordem com seu tier atual.',
              style: const TextStyle(color: Color(0xB3FFFFFF)),
            ),
            actions: [
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                ),
                child: const Text('Entendi', style: TextStyle(color: Colors.white)),
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
        title: const Text('Aceitar Ordem'),
        content: Text(
          'Você deseja aceitar esta ordem de ${_formatCurrency(orderAmount)}?\n\n'
          'Você será responsável por pagar a conta e receberá 7% de taxa.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
            ),
            child: const Text('Aceitar'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      _showLoadingDialog('Aceitando ordem...');
      
      final success = await _providerService.acceptOrder(orderId, _providerId);
      
      Navigator.pop(context); // Fecha o loading dialog
      
      if (success) {
        _showSnackBar('Ordem aceita com sucesso!', Colors.green);
        await _loadAll(); // Recarrega todas as listas
      } else {
        _showSnackBar('Erro ao aceitar ordem', Colors.red);
      }
    }
  }

  Future<void> _onRejectOrder(Map<String, dynamic> order) async {
    final orderId = order['_id'] ?? order['id'];
    if (orderId == null) return;

    final reason = await showDialog<String>(
      context: context,
      builder: (context) {
        final controller = TextEditingController();
        return AlertDialog(
          title: const Text('Rejeitar Ordem'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Por que você está rejeitando esta ordem?'),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  hintText: 'Motivo (opcional)',
                  border: OutlineInputBorder(),
                ),
                maxLines: 3,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, controller.text),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              child: const Text('Rejeitar'),
            ),
          ],
        );
      },
    );

    if (reason != null) {
      _showLoadingDialog('Rejeitando ordem...');
      
      final success = await _providerService.rejectOrder(orderId, reason);
      
      Navigator.pop(context); // Fecha o loading dialog
      
      if (success) {
        _showSnackBar('Ordem rejeitada', Colors.orange);
        await _loadAvailableOrders();
      } else {
        _showSnackBar('Erro ao rejeitar ordem', Colors.red);
      }
    }
  }

  Future<void> _onUploadProof(Map<String, dynamic> order) async {
    final orderId = order['_id'] ?? order['id'];
    if (orderId == null) return;

    final XFile? image = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
    );

    if (image == null) return;

    _showLoadingDialog('Enviando comprovante...');

    try {
      final bytes = await File(image.path).readAsBytes();
      final success = await _providerService.uploadProof(orderId, bytes);
      
      Navigator.pop(context); // Fecha o loading dialog
      
      if (success) {
        _showSnackBar('Comprovante enviado com sucesso!', Colors.green);
        await _loadMyOrders();
      } else {
        _showSnackBar('Erro ao enviar comprovante', Colors.red);
      }
    } catch (e) {
      Navigator.pop(context);
      _showSnackBar('Erro ao processar imagem: $e', Colors.red);
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
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Modo Bro'),
            if (_currentTier != null) ...[
              const SizedBox(width: 8),
              _buildTierBadge(),
            ],
          ],
        ),
        elevation: 0,
        actions: [
          if (_tierWarning)
            IconButton(
              icon: const Icon(Icons.warning_amber, color: Colors.orange),
              onPressed: _showTierWarningDialog,
              tooltip: 'Atenção: Garantia',
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              await _loadAll();
              await _checkTierStatus();
            },
            tooltip: 'Atualizar',
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Disponíveis', icon: Icon(Icons.list_alt)),
            Tab(text: 'Minhas Ordens', icon: Icon(Icons.assignment_ind)),
            Tab(text: 'Histórico', icon: Icon(Icons.history)),
          ],
        ),
      ),
      body: Column(
        children: [
          // Warning banner se tier em risco
          if (_tierWarning)
            _buildTierWarningBanner(),
          
          // Card de estatísticas
          _buildStatsCard(),
          
          // Lista de ordens com tabs
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildAvailableOrdersList(),
                _buildMyOrdersList(),
                _buildHistoryList(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Badge compacto do tier atual
  Widget _buildTierBadge() {
    final tierColor = _getTierColorById(_currentTier!.tierId);
    final tierIcon = _getTierIconById(_currentTier!.tierId);
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: tierColor.withOpacity(0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tierColor, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(tierIcon, size: 14, color: tierColor),
          const SizedBox(width: 4),
          Text(
            _currentTier!.tierName.split(' ').first, // "Bronze", "Silver", etc
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: tierColor,
            ),
          ),
        ],
      ),
    );
  }

  /// Banner de aviso quando tier está em risco
  Widget _buildTierWarningBanner() {
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
              _tierWarningMessage ?? 'Sua garantia precisa de atenção',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          TextButton(
            onPressed: _showTierWarningDialog,
            child: const Text(
              'Ver',
              style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  /// Dialog com detalhes do aviso de tier
  void _showTierWarningDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.warning_amber, color: Colors.orange, size: 28),
            const SizedBox(width: 12),
            const Text('Garantia em Risco', style: TextStyle(color: Colors.white)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'O preço do Bitcoin caiu e sua garantia atual não cobre mais o requisito mínimo do seu tier.',
              style: TextStyle(color: Color(0xB3FFFFFF)),
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
                    'Tier atual: ${_currentTier?.tierName ?? "Nenhum"}',
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
            const Text(
              'Se você não aumentar a garantia, poderá perder acesso a ordens de valores mais altos.',
              style: TextStyle(color: Color(0x99FFFFFF), fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Depois', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.pushNamed(context, '/provider-collateral');
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            child: const Text('Aumentar Garantia', style: TextStyle(color: Colors.white)),
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
                const Text(
                  'Estatísticas',
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
                    'Ganhos Hoje',
                    _formatCurrency(earningsToday),
                    Icons.today,
                    Colors.green,
                  ),
                ),
                Expanded(
                  child: _buildStatItem(
                    'Ganhos Totais',
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
                    'Pagas Hoje',
                    billsPaidToday.toString(),
                    Icons.check_circle,
                    Colors.orange,
                  ),
                ),
                Expanded(
                  child: _buildStatItem(
                    'Ordens Ativas',
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

  Widget _buildAvailableOrdersList() {
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
              'Nenhuma ordem disponível no momento',
              style: TextStyle(fontSize: 16, color: Colors.grey[600]),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _loadAvailableOrders,
              icon: const Icon(Icons.refresh),
              label: const Text('Atualizar'),
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
              'Você ainda não aceitou nenhuma ordem',
              style: TextStyle(fontSize: 16, color: Colors.grey[600]),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _loadMyOrders,
              icon: const Icon(Icons.refresh),
              label: const Text('Atualizar'),
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
              'Nenhuma ordem concluída ainda',
              style: TextStyle(fontSize: 16, color: Colors.grey[600]),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _loadHistory,
              icon: const Icon(Icons.refresh),
              label: const Text('Atualizar'),
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
