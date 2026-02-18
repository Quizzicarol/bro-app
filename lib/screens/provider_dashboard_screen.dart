import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/provider_service.dart';
import '../services/storage_service.dart';
import '../widgets/gradient_button.dart';

class ProviderDashboardScreen extends StatefulWidget {
  const ProviderDashboardScreen({Key? key}) : super(key: key);

  @override
  State<ProviderDashboardScreen> createState() => _ProviderDashboardScreenState();
}

class _ProviderDashboardScreenState extends State<ProviderDashboardScreen> {
  final _providerService = ProviderService();
  final _storageService = StorageService();
  
  String? _providerId;
  List<Map<String, dynamic>> _availableOrders = [];
  List<Map<String, dynamic>> _myOrders = [];
  Map<String, dynamic>? _stats;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadProviderData();
  }

  Future<void> _loadProviderData() async {
    setState(() => _isLoading = true);

    try {
      // Buscar providerId do storage
      _providerId = await _storageService.getProviderId();
      
      if (_providerId == null) {
        // Gerar um ID de provedor baseado na publicKey
        final publicKey = await _storageService.getNostrPublicKey();
        _providerId = 'prov_${publicKey?.substring(0, 16) ?? DateTime.now().millisecondsSinceEpoch}';
        await _storageService.saveProviderId(_providerId!);
      }

      // Buscar ordens dispon�veis
      _availableOrders = await _providerService.fetchAvailableOrders();

      // Buscar minhas ordens
      _myOrders = await _providerService.fetchMyOrders(_providerId!);

      // Buscar estat�sticas
      _stats = await _providerService.getStats(_providerId!);

    } catch (e) {
      debugPrint('? Erro ao carregar dados do provedor: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Row(
          children: const [
            Icon(Icons.store, color: Color(0xFF4CAF50)),
            SizedBox(width: 8),
            Text('Modo Provedor', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadProviderData,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFFF6B6B)))
          : RefreshIndicator(
              onRefresh: _loadProviderData,
              color: const Color(0xFFFF6B6B),
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Banner Provedor Ativo
                    _buildProviderBanner(),
                    const SizedBox(height: 24),

                    // Estat�sticas em Grid 2x2
                    _buildStatsGrid(),
                    const SizedBox(height: 24),

                    // Bot�es de A��o
                    _buildActionButtons(),
                    const SizedBox(height: 32),

                    // Ordens Dispon�veis
                    _buildAvailableOrdersSection(),
                    const SizedBox(height: 24),

                    // Minhas Ordens Aceitas
                    _buildMyOrdersSection(),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildProviderBanner() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF4CAF50), Color(0xFF66BB6A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: const [
          Icon(Icons.construction, size: 48, color: Colors.white),
          SizedBox(height: 12),
          Text(
            '?? Modo Provedor Ativo',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Aceite ordens e ajude usu�rios a pagar contas em troca de Bitcoin',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsGrid() {
    final stats = _stats ?? {};
    final availableCount = _availableOrders.length;
    final acceptedCount = _myOrders.where((o) => o['status'] != 'completed').length;
    final completedCount = stats['completedOrders'] ?? 0;
    final totalEarned = stats['totalEarned'] ?? 0.0;

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 16,
      crossAxisSpacing: 16,
      childAspectRatio: 1.2,
      children: [
        _buildStatCard('??', '$availableCount', 'Ordens Dispon�veis'),
        _buildStatCard('??', '$acceptedCount', 'Ordens Aceitas'),
        _buildStatCard('?', '$completedCount', 'Ordens Completas'),
        _buildStatCard('??', 'R\$ ${totalEarned.toStringAsFixed(2)}', 'Total Ganho'),
      ],
    );
  }

  Widget _buildStatCard(String emoji, String value, String label) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        border: Border.all(color: const Color(0xFFFF6B6B).withOpacity(0.2)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 32)),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withOpacity(0.7),
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons() {
    return Column(
      children: [
        GradientButton(
          text: 'Atualizar Ordens',
          onPressed: _loadProviderData,
          icon: Icons.refresh,
        ),
        const SizedBox(height: 12),
        CustomOutlineButton(
          text: 'Ver Ganhos',
          onPressed: _showEarningsDialog,
          icon: Icons.trending_up,
        ),
      ],
    );
  }

  Widget _buildAvailableOrdersSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              '?? Ordens Dispon�veis',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '${_availableOrders.length} ordens',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _availableOrders.isEmpty
            ? _buildEmptyState('Nenhuma ordem dispon�vel no momento')
            : ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _availableOrders.length,
                itemBuilder: (context, index) => _buildOrderCard(
                  _availableOrders[index],
                  isAvailable: true,
                ),
              ),
      ],
    );
  }

  Widget _buildMyOrdersSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '? Minhas Ordens Aceitas',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 16),
        _myOrders.isEmpty
            ? _buildEmptyState('Voc� ainda n�o aceitou nenhuma ordem')
            : ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _myOrders.length,
                itemBuilder: (context, index) => _buildOrderCard(
                  _myOrders[index],
                  isAvailable: false,
                ),
              ),
      ],
    );
  }

  Widget _buildEmptyState(String message) {
    return Container(
      padding: const EdgeInsets.all(40),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFF6B6B).withOpacity(0.2)),
      ),
      child: Column(
        children: [
          const Icon(Icons.inbox, size: 64, color: Color(0xFFFF6B6B)),
          const SizedBox(height: 16),
          Text(
            message,
            style: TextStyle(color: Colors.white.withOpacity(0.7)),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildOrderCard(Map<String, dynamic> order, {required bool isAvailable}) {
    final orderId = order['id'] ?? 'N/A';
    final amount = (order['amount'] ?? 0.0).toDouble();
    final billType = order['billType'] ?? 'PIX';
    final status = order['status'] ?? 'pending';
    final createdAt = order['createdAt'];
    
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        border: Border.all(color: const Color(0xFFFF6B6B).withOpacity(0.3)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  'Ordem #${orderId.substring(0, 8)}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    fontSize: 16,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _buildStatusBadge(status),
            ],
          ),
          const SizedBox(height: 12),

          // Detalhes
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'R\$ ${amount.toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFFF6B6B),
                      ),
                    ),
                    Text(
                      billType.toUpperCase(),
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.6),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (createdAt != null)
                Text(
                  _formatTimeAgo(createdAt),
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.5),
                    fontSize: 12,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),

          // Bot�es de A��o
          if (isAvailable)
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _acceptOrder(orderId),
                    icon: const Icon(Icons.check_circle, size: 18),
                    label: const Text('Aceitar'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4CAF50),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _showOrderDetails(order),
                    icon: const Icon(Icons.visibility, size: 18),
                    label: const Text('Detalhes'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFFF6B6B),
                      side: const BorderSide(color: Color(0xFFFF6B6B)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              ],
            )
          else
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => _completeOrder(orderId),
                icon: const Icon(Icons.upload_file, size: 18),
                label: const Text('Enviar Comprovante'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF6B6B),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStatusBadge(String status) {
    Color color;
    String text;
    IconData icon;

    switch (status) {
      case 'pending':
        color = const Color(0xFFFFC107);
        text = 'Aguardando Pgto';
        icon = Icons.payment;
        break;
      case 'payment_received':
        color = const Color(0xFF009688);
        text = 'Pago ?';
        icon = Icons.check;
        break;
      case 'confirmed':
        color = const Color(0xFF1E88E5);
        text = 'Dispon�vel';
        icon = Icons.hourglass_empty;
        break;
      case 'accepted':
      case 'processing':
        color = const Color(0xFF1E88E5);
        text = 'Processando';
        icon = Icons.sync;
        break;
      case 'awaiting_confirmation':
        color = const Color(0xFF9C27B0);
        text = 'Aguard. Confirm.';
        icon = Icons.receipt_long;
        break;
      case 'completed':
        color = const Color(0xFF4CAF50);
        text = 'Completo ?';
        icon = Icons.check_circle;
        break;
      case 'cancelled':
        color = Colors.red;
        text = 'Cancelado';
        icon = Icons.cancel;
        break;
      case 'disputed':
        color = Colors.deepOrange;
        text = 'Disputa';
        icon = Icons.gavel;
        break;
      default:
        color = Colors.grey;
        text = status;
        icon = Icons.help_outline;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  String _formatTimeAgo(dynamic timestamp) {
    try {
      final date = timestamp is DateTime ? timestamp : DateTime.parse(timestamp.toString());
      final diff = DateTime.now().difference(date);

      if (diff.inDays > 0) return '${diff.inDays}d atr�s';
      if (diff.inHours > 0) return '${diff.inHours}h atr�s';
      if (diff.inMinutes > 0) return '${diff.inMinutes}min atr�s';
      return 'agora';
    } catch (e) {
      return '';
    }
  }

  Future<void> _acceptOrder(String orderId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Aceitar Ordem', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Voc� confirma que vai processar esta ordem e realizar o pagamento PIX/Boleto?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF4CAF50)),
            child: const Text('Aceitar'),
          ),
        ],
      ),
    );

    if (confirm == true && _providerId != null) {
      final success = await _providerService.acceptOrder(orderId, _providerId!);
      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('? Ordem aceita com sucesso!'),
            backgroundColor: Color(0xFF4CAF50),
          ),
        );
        await _loadProviderData();
      }
    }
  }

  Future<void> _completeOrder(String orderId) async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('?? Funcionalidade de upload de comprovante em desenvolvimento'),
        backgroundColor: Color(0xFFFF6B6B),
      ),
    );
  }

  void _showOrderDetails(Map<String, dynamic> order) {
    // Debug: mostrar todos os campos da ordem
    debugPrint('?? Order data: $order');
    debugPrint('?? Order keys: ${order.keys.toList()}');
    
    // Tentar pegar billCode de v�rias fontes poss�veis
    String billCode = order['billCode'] ?? 
                      order['bill_code'] ?? 
                      order['pixCode'] ?? 
                      order['pix_code'] ?? 
                      order['code'] ?? 
                      (order['metadata']?['billCode']) ?? 
                      (order['metadata']?['pixCode']) ?? 
                      (order['metadata']?['code']) ?? 
                      '';
    
    final status = order['status'] ?? '';
    
    // Tentar pegar userPubkey de v�rias fontes
    String userPubkey = order['userPubkey'] ?? 
                        order['user_pubkey'] ?? 
                        order['pubkey'] ?? 
                        order['nostrPubkey'] ?? 
                        (order['metadata']?['userPubkey']) ?? 
                        (order['metadata']?['pubkey']) ?? 
                        '';
    
    debugPrint('?? billCode encontrado: ${billCode.isNotEmpty ? billCode.substring(0, min(20, billCode.length)) + "..." : "VAZIO"}');
    debugPrint('?? userPubkey encontrado: ${userPubkey.isNotEmpty ? userPubkey.substring(0, min(16, userPubkey.length)) + "..." : "VAZIO"}');
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text('Ordem #${order['id']?.substring(0, 8) ?? 'N/A'}', 
          style: const TextStyle(color: Colors.white)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildDetailRow('Valor', 'R\$ ${(order['amount'] ?? 0).toStringAsFixed(2)}'),
              _buildDetailRow('Tipo', order['billType'] ?? 'N/A'),
              _buildDetailRow('Status', status),
              _buildDetailRow('Bitcoin', '${order['btcAmount'] ?? 0} BTC'),
              
              // C�digo da conta - CR�TICO para o provedor
              if (billCode.isNotEmpty) ...[  
                const SizedBox(height: 16),
                const Text(
                  '?? C�digo da Conta (copie para pagar):',
                  style: TextStyle(
                    color: Color(0xFFFF6B35),
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF333333)),
                  ),
                  child: Column(
                    children: [
                      SelectableText(
                        billCode,
                        style: const TextStyle(
                          color: Colors.white,
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: billCode));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('? C�digo copiado!'),
                                backgroundColor: Color(0xFF4CAF50),
                              ),
                            );
                          },
                          icon: const Icon(Icons.copy, size: 18),
                          label: const Text('Copiar C�digo'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFFF6B35),
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                // Mostrar aviso se n�o houver c�digo
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange.withOpacity(0.3)),
                  ),
                  child: const Text(
                    '?? C�digo da conta n�o dispon�vel para esta ordem',
                    style: TextStyle(
                      color: Colors.orange,
                      fontSize: 12,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
              
              // Bot�o para falar com usu�rio - dispon�vel em qualquer ordem com userPubkey
              if (userPubkey.isNotEmpty) ...[  
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      Navigator.pushNamed(
                        context, 
                        '/nostr-messages',
                        arguments: {'recipientPubkey': userPubkey},
                      );
                    },
                    icon: const Icon(Icons.chat, size: 18),
                    label: const Text('Falar com Usu�rio'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2196F3),
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              '$label:',
              style: TextStyle(
                color: Colors.white.withOpacity(0.6),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  void _showEarningsDialog() {
    final stats = _stats ?? {};
    final totalEarned = stats['totalEarned'] ?? 0.0;
    final completedOrders = stats['completedOrders'] ?? 0;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('?? Ganhos Totais', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'R\$ ${totalEarned.toStringAsFixed(2)}',
              style: const TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: Color(0xFF4CAF50),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'De $completedOrders ordens completadas',
              style: TextStyle(color: Colors.white.withOpacity(0.7)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
  }
}
