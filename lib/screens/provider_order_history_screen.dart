import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'package:provider/provider.dart';
import '../providers/order_provider.dart';
import '../models/order.dart';
import '../config.dart';

/// Tela de histórico de ordens completadas pelo provedor
/// Mostra todas as ordens finalizadas para verificação futura ou disputas
class ProviderOrderHistoryScreen extends StatefulWidget {
  final String providerId;

  const ProviderOrderHistoryScreen({
    super.key,
    required this.providerId,
  });

  @override
  State<ProviderOrderHistoryScreen> createState() => _ProviderOrderHistoryScreenState();
}

class _ProviderOrderHistoryScreenState extends State<ProviderOrderHistoryScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshOrders();
    });
  }

  Future<void> _refreshOrders() async {
    if (mounted) {
      setState(() {});
    }
  }

  List<Order> _getCompletedOrders(OrderProvider orderProvider) {
    // Filtrar ordens completadas por este provedor
    return orderProvider.orders.where((order) {
      return order.providerId == widget.providerId && 
             (order.status == 'completed' || order.status == 'liquidated');
    }).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt)); // Mais recentes primeiro
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text(l.t('prov_hist_title')),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refreshOrders,
            tooltip: l.t('prov_refresh'),
          ),
        ],
      ),
      body: Consumer<OrderProvider>(
        builder: (context, orderProvider, child) {
          final completedOrders = _getCompletedOrders(orderProvider);

          if (completedOrders.isEmpty) {
            return _buildEmptyView(l);
          }

          // Calcular estatísticas
          final totalEarned = completedOrders.fold<double>(
            0.0,
            (sum, order) => sum + (order.amount * AppConfig.providerFeePercent),
          );
          final totalVolume = completedOrders.fold<double>(
            0.0,
            (sum, order) => sum + order.amount,
          );

          return Column(
            children: [
              _buildStatsCard(completedOrders.length, totalEarned, totalVolume, l),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _refreshOrders,
                  color: Colors.orange,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: completedOrders.length,
                    itemBuilder: (context, index) {
                      final order = completedOrders[index];
                      return _buildOrderCard(order, l);
                    },
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildStatsCard(int count, double earned, double volume, AppLocalizations l) {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.green.withOpacity(0.2),
            Colors.green.withOpacity(0.05),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.green.withOpacity(0.3)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.analytics, color: Colors.green, size: 24),
              const SizedBox(width: 8),
              Text(
                l.t('prov_statistics'),
                style: const TextStyle(
                  color: Colors.white,
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
                  l.t('prov_hist_completed'),
                  count.toString(),
                  Icons.check_circle,
                ),
              ),
              Container(
                width: 1,
                height: 40,
                color: Colors.white12,
              ),
              Expanded(
                child: _buildStatItem(
                  l.t('prov_hist_total_earned'),
                  'R\$ ${earned.toStringAsFixed(2)}',
                  Icons.monetization_on,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(color: Colors.white12),
          const SizedBox(height: 12),
          _buildStatItem(
            l.t('prov_hist_total_volume'),
            'R\$ ${volume.toStringAsFixed(2)}',
            Icons.account_balance_wallet,
            large: true,
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(String label, String value, IconData icon, {bool large = false}) {
    return Column(
      children: [
        Icon(icon, color: Colors.green, size: large ? 28 : 20),
        const SizedBox(height: 6),
        Text(
          value,
          style: TextStyle(
            color: Colors.white,
            fontSize: large ? 24 : 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 11,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildEmptyView(AppLocalizations l) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.history, size: 64, color: Colors.white38),
            const SizedBox(height: 16),
            Text(
              l.t('prov_hist_no_completed'),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l.t('prov_hist_completed_hint'),
              style: const TextStyle(color: Colors.white70, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pushReplacementNamed(
                  context,
                  '/provider-orders',
                  arguments: widget.providerId,
                );
              },
              icon: const Icon(Icons.search),
              label: Text(l.t('prov_my_view_available')),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOrderCard(Order order, AppLocalizations l) {
    final earnedAmount = order.amount * AppConfig.providerFeePercent;
    final completedDate = _formatDate(order.createdAt);
    final isLiquidated = order.status == 'liquidated';
    final statusColor = isLiquidated ? Colors.purple : Colors.green;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: statusColor.withOpacity(0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      isLiquidated ? Icons.bolt : Icons.check_circle,
                      color: statusColor,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      order.billType.toUpperCase(),
                      style: TextStyle(
                        color: statusColor,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    if (isLiquidated) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.purple.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'Auto ⚡',
                          style: TextStyle(color: Colors.purple, fontSize: 10, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ],
                ),
                Text(
                  completedDate,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.t('prov_hist_bill_value'),
                      style: const TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'R\$ ${order.amount.toStringAsFixed(2)}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: statusColor.withOpacity(0.5)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        isLiquidated ? 'Auto ⚡' : l.t('prov_hist_earning'),
                        style: TextStyle(color: statusColor, fontSize: 10),
                      ),
                      Text(
                        'R\$ ${earnedAmount.toStringAsFixed(2)}',
                        style: TextStyle(
                          color: statusColor,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  const Icon(Icons.tag, color: Colors.white38, size: 14),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'ID: ${order.id.substring(0, 16)}...',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime dateTime) {
    final day = dateTime.day.toString().padLeft(2, '0');
    final month = dateTime.month.toString().padLeft(2, '0');
    final year = dateTime.year;
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    
    return '$day/$month/$year às $hour:$minute';
  }
}
