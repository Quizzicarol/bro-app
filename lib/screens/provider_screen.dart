import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import '../services/provider_service.dart';
import '../services/storage_service.dart';
import '../widgets/order_card.dart';
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

  late TabController _tabController;
  
  String _providerId = '';
  Map<String, dynamic>? _stats;
  List<Map<String, dynamic>> _availableOrders = [];
  List<Map<String, dynamic>> _myOrders = [];
  List<Map<String, dynamic>> _history = [];
  
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

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Aceitar Ordem'),
        content: Text(
          'Você deseja aceitar esta ordem de ${_formatCurrency((order['amount'] ?? 0.0).toDouble())}?\n\n'
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
        title: const Text('Modo Provedor'),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadAll,
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
