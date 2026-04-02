import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:flutter/services.dart';
import '../providers/order_provider.dart';
import '../services/provider_service.dart';
import '../services/storage_service.dart';
import '../services/billcode_crypto_service.dart';
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

      // Buscar ordens disponíveis
      _availableOrders = await _providerService.fetchAvailableOrders();

      // Buscar minhas ordens
      _myOrders = await _providerService.fetchMyOrders(_providerId!);

      // Buscar estatísticas
      _stats = await _providerService.getStats(_providerId!);

    } catch (e) {
      broLog('❌ Erro ao carregar dados do provedor: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Row(
          children: [
            const Icon(Icons.store, color: Color(0xFF4CAF50)),
            const SizedBox(width: 8),
            Text(l.t('prov_dash_title'), style: const TextStyle(fontWeight: FontWeight.bold)),
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

                    // Estatísticas em Grid 2x2
                    _buildStatsGrid(),
                    const SizedBox(height: 24),

                    // Botões de Ação
                    _buildActionButtons(),
                    const SizedBox(height: 32),

                    // Ordens Disponíveis
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
    final l = AppLocalizations.of(context)!;
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
        children: [
          const Icon(Icons.construction, size: 48, color: Colors.white),
          const SizedBox(height: 12),
          Text(
            l.t('prov_dash_active'),
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l.t('prov_dash_desc'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsGrid() {
    final l = AppLocalizations.of(context)!;
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
        _buildStatCard('📦', '$availableCount', l.t('prov_dash_available_orders')),
        _buildStatCard('🤝', '$acceptedCount', l.t('prov_dash_accepted_orders')),
        _buildStatCard('✅', '$completedCount', l.t('prov_dash_completed_orders')),
        _buildStatCard('💰', 'R\$ ${totalEarned.toStringAsFixed(2)}', l.t('prov_dash_total_earned')),
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
    final l = AppLocalizations.of(context)!;
    return Column(
      children: [
        GradientButton(
          text: l.t('prov_dash_refresh_orders'),
          onPressed: _loadProviderData,
          icon: Icons.refresh,
        ),
        const SizedBox(height: 12),
        CustomOutlineButton(
          text: l.t('prov_dash_view_earnings'),
          onPressed: _showEarningsDialog,
          icon: Icons.trending_up,
        ),
      ],
    );
  }

  Widget _buildAvailableOrdersSection() {
    final l = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              l.t('prov_dash_available_title'),
              style: const TextStyle(
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
                l.tp('prov_dash_count_orders', {'count': _availableOrders.length.toString()}),
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _availableOrders.isEmpty
            ? _buildEmptyState(l.t('prov_dash_no_orders'))
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
    final l = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l.t('prov_dash_my_accepted'),
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 16),
        _myOrders.isEmpty
            ? _buildEmptyState(l.t('prov_dash_no_accepted'))
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
    final l = AppLocalizations.of(context)!;
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
                  l.tp('prov_dash_order_num', {'id': orderId.substring(0, 8)}),
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

          // Botões de Ação
          if (isAvailable)
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _acceptOrder(orderId),
                    icon: const Icon(Icons.check_circle, size: 18),
                    label: Text(l.t('prov_dash_accept')),
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
                    label: Text(l.t('prov_dash_details')),
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
                label: Text(l.t('prov_dash_send_receipt')),
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
    final l = AppLocalizations.of(context)!;
    Color color;
    String text;
    IconData icon;

    switch (status) {
      case 'pending':
        color = const Color(0xFFFFC107);
        text = l.t('prov_dash_waiting_pmt');
        icon = Icons.payment;
        break;
      case 'payment_received':
        color = const Color(0xFF009688);
        text = l.t('prov_dash_paid');
        icon = Icons.check;
        break;
      case 'confirmed':
        color = const Color(0xFF1E88E5);
        text = l.t('prov_dash_available_status');
        icon = Icons.hourglass_empty;
        break;
      case 'accepted':
      case 'processing':
        color = const Color(0xFF1E88E5);
        text = l.t('prov_dash_processing');
        icon = Icons.sync;
        break;
      case 'awaiting_confirmation':
        color = const Color(0xFF9C27B0);
        text = l.t('prov_dash_wait_confirm');
        icon = Icons.receipt_long;
        break;
      case 'completed':
        color = const Color(0xFF4CAF50);
        text = l.t('prov_dash_complete');
        icon = Icons.check_circle;
        break;
      case 'cancelled':
        color = Colors.red;
        text = l.t('prov_dash_cancelled');
        icon = Icons.cancel;
        break;
      case 'disputed':
        color = Colors.deepOrange;
        text = l.t('prov_dash_dispute');
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
    final l = AppLocalizations.of(context)!;
    try {
      final date = timestamp is DateTime ? timestamp : DateTime.parse(timestamp.toString());
      final diff = DateTime.now().difference(date);

      if (diff.inDays > 0) return l.tp('prov_dash_days_ago', {'n': diff.inDays.toString()});
      if (diff.inHours > 0) return l.tp('prov_dash_hours_ago', {'n': diff.inHours.toString()});
      if (diff.inMinutes > 0) return l.tp('prov_dash_minutes_ago', {'n': diff.inMinutes.toString()});
      return l.t('prov_dash_now');
    } catch (e) {
      return '';
    }
  }

  Future<void> _acceptOrder(String orderId) async {
    final l = AppLocalizations.of(context)!;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text(l.t('prov_dash_accept_order'), style: const TextStyle(color: Colors.white)),
        content: Text(
          l.t('prov_dash_accept_confirm'),
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.t('cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF4CAF50)),
            child: Text(l.t('prov_dash_accept')),
          ),
        ],
      ),
    );

    if (confirm == true && _providerId != null) {
      // v437: Aceitar via Nostr (API /orders/accept está morta)
      final orderProvider = context.read<OrderProvider>();
      final success = await orderProvider.acceptOrderAsProvider(orderId);
      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l.t('prov_dash_order_accepted')),
            backgroundColor: Color(0xFF4CAF50),
          ),
        );
        await _loadProviderData();
      } else if (!success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l.t('prov_dash_accept_error')),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _completeOrder(String orderId) async {
    final l = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l.t('prov_dash_receipt_dev')),
        backgroundColor: Color(0xFFFF6B6B),
      ),
    );
  }

  void _showOrderDetails(Map<String, dynamic> order) {
    final l = AppLocalizations.of(context)!;
    // Debug: mostrar todos os campos da ordem
    broLog('📦 Order data: $order');
    broLog('📦 Order keys: ${order.keys.toList()}');
    
    // Tentar pegar billCode de várias fontes possíveis
    String rawBillCode = order['billCode'] ?? 
                      order['bill_code'] ?? 
                      order['pixCode'] ?? 
                      order['pix_code'] ?? 
                      order['code'] ?? 
                      (order['metadata']?['billCode']) ?? 
                      (order['metadata']?['pixCode']) ?? 
                      (order['metadata']?['code']) ?? 
                      '';
    String billCode = BillCodeCryptoService().decrypt(rawBillCode);
    
    final status = order['status'] ?? '';
    
    // Tentar pegar userPubkey de várias fontes
    String userPubkey = order['userPubkey'] ?? 
                        order['user_pubkey'] ?? 
                        order['pubkey'] ?? 
                        order['nostrPubkey'] ?? 
                        (order['metadata']?['userPubkey']) ?? 
                        (order['metadata']?['pubkey']) ?? 
                        '';
    
    broLog('📋 billCode encontrado: ${billCode.isNotEmpty ? billCode.substring(0, min(20, billCode.length)) + "..." : "VAZIO"}');
    broLog('👤 userPubkey encontrado: ${userPubkey.isNotEmpty ? userPubkey.substring(0, min(16, userPubkey.length)) + "..." : "VAZIO"}');
    
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
              _buildDetailRow(l.t('prov_dash_value_label'), 'R\$ ${(order['amount'] ?? 0).toStringAsFixed(2)}'),
              _buildDetailRow(l.t('prov_dash_type_label'), order['billType'] ?? 'N/A'),
              _buildDetailRow(l.t('prov_dash_status_label'), status),
              _buildDetailRow(l.t('prov_dash_btc_label'), '${order['btcAmount'] ?? 0} BTC'),
              
              // Código da conta - CRÍTICO para o provedor
              if (billCode.isNotEmpty) ...[  
                const SizedBox(height: 16),
                Text(
                  l.t('prov_dash_bill_code'),
                  style: const TextStyle(
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
                              SnackBar(
                                content: Text(l.t('prov_dash_code_copied')),
                                backgroundColor: Color(0xFF4CAF50),
                              ),
                            );
                          },
                          icon: const Icon(Icons.copy, size: 18),
                          label: Text(l.t('prov_dash_copy_code')),
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
                // Mostrar aviso se não houver código
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange.withOpacity(0.3)),
                  ),
                  child: Text(
                    l.t('prov_dash_code_unavailable'),
                    style: const TextStyle(
                      color: Colors.orange,
                      fontSize: 12,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
              
              // Botão para falar com usuário - disponível em qualquer ordem com userPubkey
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
                    label: Text(l.t('prov_dash_talk_user')),
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
            child: Text(l.t('close')),
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
    final l = AppLocalizations.of(context)!;
    final stats = _stats ?? {};
    final totalEarned = stats['totalEarned'] ?? 0.0;
    final completedOrders = stats['completedOrders'] ?? 0;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text(l.t('prov_dash_total_earnings'), style: const TextStyle(color: Colors.white)),
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
              l.tp('prov_dash_from_orders', {'count': completedOrders.toString()}),
              style: TextStyle(color: Colors.white.withOpacity(0.7)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.t('close')),
          ),
        ],
      ),
    );
  }
}
