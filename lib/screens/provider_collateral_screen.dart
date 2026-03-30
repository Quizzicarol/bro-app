import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:provider/provider.dart';
import '../providers/breez_provider_export.dart';
import '../providers/order_provider.dart';
import '../models/collateral_tier.dart';
import '../services/bitcoin_price_service.dart';
import '../services/local_collateral_service.dart';
import 'tier_deposit_screen.dart';

/// Tela simplificada para selecionar tier de garantia
class ProviderCollateralScreen extends StatefulWidget {
  final String providerId;

  const ProviderCollateralScreen({
    super.key,
    required this.providerId,
  });

  @override
  State<ProviderCollateralScreen> createState() => _ProviderCollateralScreenState();
}

class _ProviderCollateralScreenState extends State<ProviderCollateralScreen> {
  List<CollateralTier>? _tiers;
  LocalCollateral? _currentCollateral;
  int _walletBalance = 0;
  int _committedSats = 0;  // Sats comprometidos com ordens pendentes
  double? _btcPrice;
  bool _isLoading = true;
  String? _error;

  /// Saldo efetivamente disponível para garantia
  int get _availableBalance => (_walletBalance - _committedSats).clamp(0, _walletBalance);

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // Obter preço do Bitcoin
      final priceService = BitcoinPriceService();
      _btcPrice = await priceService.getBitcoinPrice();
      
      if (_btcPrice == null) {
        throw Exception('Não foi possível obter preço do Bitcoin');
      }

      // Carregar tiers
      _tiers = CollateralTier.getAvailableTiers(_btcPrice!);

      // Obter saldo da carteira
      final breezProvider = context.read<BreezProvider>();
      final balanceInfo = await breezProvider.getBalance();
      final balanceStr = balanceInfo['balance']?.toString() ?? '0';
      _walletBalance = int.tryParse(balanceStr) ?? 0;

      // IMPORTANTE: Obter sats comprometidos com ordens pendentes (modo cliente)
      // Isso evita que o usuário use os mesmos sats como garantia E para pagar ordens
      final orderProvider = context.read<OrderProvider>();
      _committedSats = orderProvider.committedSats;
      
      broLog('💰 Saldo total: $_walletBalance sats');
      broLog('🔒 Sats comprometidos: $_committedSats sats');
      broLog('💰 Saldo disponível para garantia: $_availableBalance sats');

      // Carregar collateral atual
      final collateralService = LocalCollateralService();
      _currentCollateral = await collateralService.getCollateral();

      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text(l.t('prov_coll_title')),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFFF6B6B)))
          : _error != null
              ? _buildErrorView()
              : _buildContent(),
    );
  }

  Widget _buildErrorView() {
    final l = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 64),
            const SizedBox(height: 16),
            Text(
              '$_error',
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _loadData,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
              child: Text(l.t('prov_coll_try_again')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    final l = AppLocalizations.of(context)!;
    // 🔐 SEGURANÇA: Se saldo é 0, NÃO mostrar valores comprometidos
    // Isso evita mostrar dados inconsistentes de sessões anteriores
    final effectiveWalletBalance = _walletBalance;
    
    // Se saldo é 0, tier não pode estar ativo
    final effectiveTierLocked = effectiveWalletBalance > 0 
        ? (_currentCollateral?.lockedSats ?? 0) 
        : 0;
    
    // Se saldo é 0, não há sats comprometidos
    final effectiveCommittedSats = effectiveWalletBalance > 0 
        ? _committedSats 
        : 0;
    
    // Calcular valores para o breakdown
    final totalCommitted = effectiveTierLocked + effectiveCommittedSats;
    final freeBalance = (effectiveWalletBalance - totalCommitted).clamp(0, effectiveWalletBalance);
    
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: Column(
      children: [
        // Aviso se saldo zerou e tier estava ativo
        if (_walletBalance == 0 && _currentCollateral != null) ...[
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.red.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.red.withOpacity(0.5)),
            ),
            child: Row(
              children: [
                const Icon(Icons.warning, color: Colors.red, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    l.tp('prov_coll_zero_balance', {'name': _currentCollateral!.tierName}),
                    style: TextStyle(color: Colors.red.shade300, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
        
        // Card principal de saldo com breakdown detalhado
        Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.orange.withOpacity(0.2), Colors.deepOrange.withOpacity(0.1)],
            ),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.orange.withOpacity(0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Saldo total
              Row(
                children: [
                  const Icon(Icons.account_balance_wallet, color: Colors.orange, size: 28),
                  const SizedBox(width: 12),
                  Text(
                    l.t('prov_coll_total_balance'),
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                  const Spacer(),
                  Text(
                    '$effectiveWalletBalance sats',
                    style: const TextStyle(
                      color: Colors.white, 
                      fontSize: 18, 
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              
              const SizedBox(height: 16),
              const Divider(color: Colors.white24),
              const SizedBox(height: 12),
              
              // Breakdown detalhado
              Text(
                l.t('prov_coll_distribution'),
                style: const TextStyle(
                  color: Colors.white54, 
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 12),
              
              // 1. Bloqueado em tier (garantia)
              _buildBreakdownRow(
                icon: Icons.lock,
                iconColor: effectiveTierLocked > 0 ? Colors.purple : Colors.grey,
                label: l.t('prov_coll_guarantee_tier'),
                value: effectiveTierLocked,
                subtitle: effectiveTierLocked > 0 
                    ? _currentCollateral?.tierName ?? l.t('prov_coll_none')
                    : (_currentCollateral != null ? l.t('prov_coll_inactive_label') : l.t('prov_coll_none')),
              ),
              
              const SizedBox(height: 8),
              
              // 2. Comprometido com ordens
              _buildBreakdownRow(
                icon: Icons.pending_actions,
                iconColor: effectiveCommittedSats > 0 ? Colors.blue : Colors.grey,
                label: l.t('prov_coll_pending_orders'),
                value: effectiveCommittedSats,
                subtitle: effectiveCommittedSats > 0 ? l.t('prov_coll_processing') : l.t('prov_coll_none_pending'),
              ),
              
              const SizedBox(height: 8),
              
              // 3. Disponível
              _buildBreakdownRow(
                icon: Icons.check_circle,
                iconColor: freeBalance > 0 ? Colors.green : Colors.grey,
                label: l.t('prov_coll_available'),
                value: freeBalance,
                subtitle: l.t('prov_coll_free_use'),
                highlight: true,
              ),
              
              // Aviso se tier estiver consumindo muito
              if (effectiveTierLocked > 0 && effectiveCommittedSats > 0) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue.withOpacity(0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.info, color: Colors.blue, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          l.t('prov_coll_same_balance_note'),
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.7),
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),

        // Tier atual (se houver)
        if (_currentCollateral != null) ...[
          // 🔥 RECALCULAR valor do tier com preço ATUAL do Bitcoin
          // Isso evita que oscilações de preço desativem o tier indevidamente
          Builder(
            builder: (context) {
              // Buscar o tier atual na lista atualizada (com preço atual do BTC)
              final currentTierDef = _tiers?.firstWhere(
                (t) => t.id == _currentCollateral!.tierId,
                orElse: () => _tiers!.first,
              );
              
              // Usar o valor ATUALIZADO do tier, não o valor salvo
              final requiredSatsNow = currentTierDef?.requiredCollateralSats ?? _currentCollateral!.lockedSats;
              final minRequiredWithTolerance = (requiredSatsNow * 0.90).round(); // 10% tolerância
              final showWarning = _walletBalance < minRequiredWithTolerance;
              
              broLog('📊 Tier ${_currentCollateral!.tierName}: salvo=${_currentCollateral!.lockedSats}, atualizado=$requiredSatsNow, mínimo=$minRequiredWithTolerance, saldo=$_walletBalance');
              
              if (!showWarning) return const SizedBox.shrink();
              
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.red.withOpacity(0.5)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber, color: Colors.red, size: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l.t('prov_coll_insufficient'),
                            style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            l.tp('prov_coll_insufficient_msg', {'required': requiredSatsNow.toString(), 'min': minRequiredWithTolerance.toString(), 'balance': _walletBalance.toString()}),
                            style: const TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          
          // Status do tier atual - considerar saldo zero como INATIVO
          // 🔥 Com tolerância de 10% + preço ATUALIZADO do Bitcoin
          Builder(
            builder: (context) {
              // Buscar o tier atual na lista atualizada (com preço atual do BTC)
              final currentTierDef = _tiers?.firstWhere(
                (t) => t.id == _currentCollateral!.tierId,
                orElse: () => _tiers!.first,
              );
              
              // Usar o valor ATUALIZADO do tier, não o valor salvo
              final requiredSatsNow = currentTierDef?.requiredCollateralSats ?? _currentCollateral!.lockedSats;
              final minRequired = (requiredSatsNow * 0.90).round(); // 10% tolerância
              final isTierActive = _walletBalance > 0 && _walletBalance >= minRequired;
              final isTierAtRisk = _walletBalance > 0 && _walletBalance < minRequired;
              final isTierInactive = _walletBalance == 0;
              
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: isTierActive 
                      ? Colors.green.withOpacity(0.1) 
                      : isTierAtRisk 
                          ? Colors.orange.withOpacity(0.1)
                          : Colors.red.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isTierActive 
                        ? Colors.green.withOpacity(0.3) 
                        : isTierAtRisk 
                            ? Colors.orange.withOpacity(0.3)
                            : Colors.red.withOpacity(0.3),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      isTierActive 
                          ? Icons.check_circle 
                          : isTierAtRisk 
                              ? Icons.warning 
                              : Icons.cancel,
                      color: isTierActive 
                          ? Colors.green 
                          : isTierAtRisk 
                              ? Colors.orange 
                              : Colors.red,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isTierActive 
                                ? l.t('prov_coll_tier_active') 
                                : isTierAtRisk 
                                    ? l.t('prov_coll_tier_at_risk')
                                    : l.t('prov_coll_tier_inactive_label'),
                            style: TextStyle(
                              color: isTierActive 
                                  ? Colors.green 
                                  : isTierAtRisk 
                                      ? Colors.orange 
                                      : Colors.red,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            isTierInactive 
                                ? l.t('prov_coll_deposit_reactivate')
                                : l.tp('prov_coll_max_order_brl', {'max': _currentCollateral!.maxOrderBrl.toStringAsFixed(0)}),
                            style: const TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: _removeTier,
                      child: Text(l.t('prov_coll_remove'), style: const TextStyle(color: Colors.red)),
                    ),
                  ],
                ),
              );
            },
          ),
        ],

        const SizedBox(height: 16),

        // Título
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Text(
                l.t('prov_coll_select_tier'),
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              Text(
                'BTC: R\$ ${_btcPrice?.toStringAsFixed(0) ?? "?"}',
                style: const TextStyle(color: Colors.orange, fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),

        // Lista de tiers (inline, sem scroll separado)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              for (int index = 0; index < (_tiers?.length ?? 0); index++)
                _buildTierCard(
                  _tiers![index],
                  _currentCollateral?.tierId == _tiers![index].id,
                  _walletBalance >= (_tiers![index].requiredCollateralSats * 0.90).round(),
                ),
            ],
          ),
        ),
        // Espaço extra no final para garantir scroll completo
        const SizedBox(height: 40),
      ],
      ),
    );
  }

  Widget _buildTierCard(CollateralTier tier, bool isCurrentTier, bool hasEnoughBalance) {
    final l = AppLocalizations.of(context)!;
    return GestureDetector(
      onTap: isCurrentTier ? null : () => _openDepositScreen(tier),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isCurrentTier 
              ? Colors.green.withOpacity(0.1) 
              : const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isCurrentTier ? Colors.green : Colors.white12,
            width: isCurrentTier ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _getTierIcon(tier.id),
                  color: _getTierColor(tier.id),
                  size: 28,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            tier.name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (isCurrentTier) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.green,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                l.t('prov_coll_active_label'),
                                style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ],
                      ),
                      Text(
                        tier.description,
                        style: const TextStyle(color: Colors.white60, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (!isCurrentTier)
                  const Icon(Icons.chevron_right, color: Colors.white38),
              ],
            ),
            const SizedBox(height: 12),
            const Divider(color: Colors.white12),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l.t('prov_coll_guarantee'), style: const TextStyle(color: Colors.white38, fontSize: 11)),
                    Text(
                      '${tier.requiredCollateralSats} sats',
                      style: TextStyle(
                        color: hasEnoughBalance ? Colors.green : Colors.orange,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '≈ R\$ ${tier.requiredCollateralBrl.toStringAsFixed(2)}',
                      style: const TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(l.t('prov_coll_max_per_order'), style: const TextStyle(color: Colors.white38, fontSize: 11)),
                    Text(
                      'R\$ ${tier.maxOrderValueBrl.toStringAsFixed(0)}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            if (!isCurrentTier && !hasEnoughBalance) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  l.tp('prov_coll_deposit_more_sats', {'amount': (tier.requiredCollateralSats - _walletBalance).toString()}),
                  style: const TextStyle(color: Colors.orange, fontSize: 11),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _openDepositScreen(CollateralTier tier) async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) => TierDepositScreen(
          tier: tier,
          providerId: widget.providerId,
        ),
      ),
    );

    if (result == true) {
      _loadData(); // Recarregar dados se houve depósito
    }
  }

  /// Widget para linha do breakdown de saldo
  Widget _buildBreakdownRow({
    required IconData icon,
    required Color iconColor,
    required String label,
    required int value,
    required String subtitle,
    bool highlight = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      decoration: BoxDecoration(
        color: highlight 
            ? Colors.green.withOpacity(0.1) 
            : Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(8),
        border: highlight 
            ? Border.all(color: Colors.green.withOpacity(0.3))
            : null,
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: iconColor.withOpacity(0.2),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(icon, color: iconColor, size: 16),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: highlight ? Colors.green : Colors.white,
                    fontSize: 13,
                    fontWeight: highlight ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.5),
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
          Text(
            '$value sats',
            style: TextStyle(
              color: highlight ? Colors.green : Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  void _removeTier() async {
    final l = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text(l.t('prov_coll_remove_tier_title'), style: const TextStyle(color: Colors.white)),
        content: Text(
          l.t('prov_coll_remove_tier_msg'),
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.t('cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: Text(l.t('prov_coll_remove')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final collateralService = LocalCollateralService();
      await collateralService.withdrawAll();
      _loadData();
    }
  }

  IconData _getTierIcon(String tierId) {
    switch (tierId) {
      case 'trial': return Icons.play_arrow;
      case 'starter': return Icons.star_outline;
      case 'basic': return Icons.star_half;
      case 'pro': return Icons.star;
      case 'elite': return Icons.diamond_outlined;
      case 'ultimate': return Icons.diamond;
      default: return Icons.star_outline;
    }
  }

  Color _getTierColor(String tierId) {
    switch (tierId) {
      case 'trial': return Colors.teal;
      case 'starter': return Colors.green;
      case 'basic': return Colors.orange;
      case 'pro': return Colors.blue;
      case 'elite': return Colors.purple;
      case 'ultimate': return Colors.amber;
      default: return Colors.grey;
    }
  }
}
