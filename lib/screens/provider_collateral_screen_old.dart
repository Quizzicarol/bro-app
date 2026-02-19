import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import '../providers/collateral_provider.dart';
import '../providers/breez_provider_export.dart';
import '../models/collateral_tier.dart';

/// Tela para provedor configurar garantia local em Bitcoin
/// Os fundos ficam na carteira do provedor (não são enviados para escrow)
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
  CollateralTier? _selectedTier;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadData();
    });
  }
  
  Future<void> _loadData() async {
    final collateralProvider = context.read<CollateralProvider>();
    final breezProvider = context.read<BreezProvider>();
    
    // Obter saldo da carteira
    int walletBalance = 0;
    try {
      final balanceInfo = await breezProvider.getBalance();
      debugPrint('📊 Balance info: $balanceInfo');
      // A chave pode ser 'balance' ou 'balanceSat'
      final balanceStr = balanceInfo['balance']?.toString() ?? balanceInfo['balanceSat']?.toString() ?? '0';
      walletBalance = int.tryParse(balanceStr) ?? 0;
      debugPrint('💳 Saldo da carteira obtido: $walletBalance sats');
    } catch (e) {
      debugPrint('⚠️ Erro ao obter saldo: $e');
    }
    
    await collateralProvider.initialize(
      widget.providerId,
      walletBalance: walletBalance,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Garantia do Provedor'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              await _loadData();
            },
          ),
        ],
      ),
      body: Consumer<CollateralProvider>(
        builder: (context, collateralProvider, child) {
          if (collateralProvider.isLoading) {
            return const Center(
              child: CircularProgressIndicator(color: Color(0xFFFF6B6B)),
            );
          }

          if (collateralProvider.error != null) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, color: Colors.red, size: 48),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      '${collateralProvider.error}',
                      style: const TextStyle(color: Colors.white70),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () async {
                      collateralProvider.clearError();
                      await _loadData();
                    },
                    child: const Text('Tentar Novamente'),
                  ),
                ],
              ),
            );
          }

          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Saldo da carteira
                _buildWalletBalance(collateralProvider),
                const SizedBox(height: 16),
                
                // Status atual
                _buildCurrentStatus(collateralProvider),
                const SizedBox(height: 24),

                // Explicação do sistema
                _buildExplanationCard(),
                const SizedBox(height: 24),

                // Tiers disponíveis
                _buildTiersSection(collateralProvider),
                const SizedBox(height: 24),

                // Botão de depósito ou remover
                if (_selectedTier != null && !collateralProvider.hasCollateral)
                  _buildDepositButton(collateralProvider),
                  
                if (collateralProvider.hasCollateral)
                  _buildRemoveCollateralButton(collateralProvider),
              ],
            ),
          );
        },
      ),
    );
  }
  
  Widget _buildWalletBalance(CollateralProvider provider) {
    final btcPrice = provider.btcPriceBrl ?? 0;
    final balanceSats = provider.walletBalanceSats;
    final balanceBrl = btcPrice > 0 ? (balanceSats / 100000000) * btcPrice : 0.0;
    
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.orange.withOpacity(0.2), Colors.deepOrange.withOpacity(0.1)],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.account_balance_wallet, color: Colors.orange, size: 28),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Sua Carteira',
                  style: TextStyle(color: Colors.white60, fontSize: 12),
                ),
                const SizedBox(height: 4),
                Text(
                  '$balanceSats sats',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  '≈ R\$ ${balanceBrl.toStringAsFixed(2)}',
                  style: const TextStyle(color: Colors.orange, fontSize: 14),
                ),
              ],
            ),
          ),
          if (provider.hasCollateral) ...[
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const Text(
                  'Travado',
                  style: TextStyle(color: Colors.white60, fontSize: 12),
                ),
                Text(
                  '${provider.localCollateral?.lockedSats ?? 0} sats',
                  style: const TextStyle(color: Colors.red, fontSize: 14, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCurrentStatus(CollateralProvider provider) {
    final hasCollateral = provider.hasCollateral;
    final localCollateral = provider.localCollateral;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: hasCollateral ? Colors.green.withOpacity(0.1) : Colors.orange.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: hasCollateral ? Colors.green.withOpacity(0.3) : Colors.orange.withOpacity(0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                hasCollateral ? Icons.check_circle : Icons.info_outline,
                color: hasCollateral ? Colors.green : Colors.orange,
                size: 28,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  hasCollateral ? 'Garantia Ativa' : 'Sem Garantia',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          if (hasCollateral && localCollateral != null) ...[
            const SizedBox(height: 16),
            const Divider(color: Colors.white12),
            const SizedBox(height: 16),
            _buildStatusRow(
              'Tier Atual',
              localCollateral.tierName,
              Icons.star,
              Colors.orange,
            ),
            const SizedBox(height: 12),
            _buildStatusRow(
              'Garantia Travada',
              '${localCollateral.lockedSats} sats',
              Icons.lock,
              Colors.green,
            ),
            const SizedBox(height: 12),
            _buildStatusRow(
              'Máximo por Ordem',
              'R\$ ${localCollateral.maxOrderBrl.toStringAsFixed(0)}',
              Icons.attach_money,
              Colors.blue,
            ),
            const SizedBox(height: 12),
            _buildStatusRow(
              'Ordens Ativas',
              '${localCollateral.activeOrders}',
              Icons.list_alt,
              localCollateral.activeOrders > 0 ? Colors.yellow : Colors.white60,
            ),
            if (localCollateral.activeOrders > 0) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.yellow.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.info, color: Colors.yellow, size: 16),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Finalize as ordens em aberto para poder sacar ou alterar a garantia.',
                        style: TextStyle(color: Colors.yellow, fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ] else ...[
            const SizedBox(height: 12),
            const Text(
              'Selecione um nível de garantia para começar a aceitar ordens e ganhar com pagamentos!',
              style: TextStyle(color: Colors.white70),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatusRow(String label, String value, IconData icon, Color color) {
    return Row(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Text(
          '$label: ',
          style: const TextStyle(color: Colors.white60, fontSize: 14),
        ),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildExplanationCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.blue.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blue.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.lightbulb_outline, color: Colors.blue, size: 24),
              SizedBox(width: 8),
              Text(
                'Como Funciona a Garantia Local',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildExplanationPoint('💳', 'Seus sats ficam na SUA carteira (auto-custódia)'),
          _buildExplanationPoint('🔒', 'Parte do saldo fica "travada" como garantia'),
          _buildExplanationPoint('📊', 'O nível de garantia define o valor máximo das ordens'),
          _buildExplanationPoint('✅', 'Ao completar ordens, a garantia continua na sua carteira'),
          _buildExplanationPoint('💰', 'Você pode sacar quando não tiver ordens em aberto'),
          const SizedBox(height: 12),
          const Divider(color: Colors.white12),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.green.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Row(
              children: [
                Icon(Icons.security, color: Colors.green, size: 16),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Diferente de outros sistemas, seus fundos NUNCA saem da sua carteira!',
                    style: TextStyle(
                      color: Colors.green,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExplanationPoint(String emoji, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 16)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTiersSection(CollateralProvider provider) {
    if (provider.availableTiers == null || provider.availableTiers!.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Níveis de Garantia',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Seu saldo: ${provider.walletBalanceSats} sats',
          style: const TextStyle(color: Colors.orange, fontSize: 14),
        ),
        const SizedBox(height: 16),
        ...provider.availableTiers!.map((tier) => _buildTierCard(tier, provider)),
      ],
    );
  }

  Widget _buildTierCard(CollateralTier tier, CollateralProvider provider) {
    final isSelected = _selectedTier?.id == tier.id;
    final isCurrentTier = provider.localCollateral?.tierId == tier.id;
    final isAvailable = _isTierAvailable(tier.id);
    final hasEnoughBalance = provider.walletBalanceSats >= tier.requiredCollateralSats;

    return GestureDetector(
      onTap: (!isAvailable || provider.hasCollateral || !hasEnoughBalance) ? null : () {
        setState(() {
          _selectedTier = tier;
        });
      },
      child: Opacity(
        opacity: (isAvailable && hasEnoughBalance) ? 1.0 : 0.6,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isSelected
                ? Colors.orange.withOpacity(0.2)
                : isCurrentTier
                    ? Colors.green.withOpacity(0.1)
                    : const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected 
                  ? Colors.orange 
                  : isCurrentTier 
                      ? Colors.green 
                      : (isAvailable ? Colors.white12 : Colors.white10),
              width: isSelected || isCurrentTier ? 2 : 1,
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
                                  color: Colors.green.withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(color: Colors.green),
                                ),
                                child: const Text(
                                  'ATIVO',
                                  style: TextStyle(
                                    color: Colors.green,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                            if (!isAvailable) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.grey.withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(color: Colors.grey),
                                ),
                                child: const Text(
                                  'EM BREVE',
                                  style: TextStyle(
                                    color: Colors.grey,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                            if (isAvailable && !hasEnoughBalance && !isCurrentTier) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.red.withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(color: Colors.red),
                                ),
                                child: const Text(
                                  'SALDO BAIXO',
                                  style: TextStyle(
                                    color: Colors.red,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
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
                  if (isSelected && !provider.hasCollateral && isAvailable && hasEnoughBalance)
                    const Icon(Icons.check_circle, color: Colors.orange),
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
                      const Text(
                        'Garantia Necessária',
                        style: TextStyle(color: Colors.white38, fontSize: 11),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'R\$ ${tier.requiredCollateralBrl.toStringAsFixed(2)}',
                        style: const TextStyle(
                          color: Colors.orange,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        '${tier.requiredCollateralSats} sats',
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Text(
                        'Valor Máximo',
                        style: TextStyle(color: Colors.white38, fontSize: 11),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        tier.maxOrderValueBrl == double.infinity
                            ? 'Ilimitado'
                            : 'R\$ ${tier.maxOrderValueBrl.toStringAsFixed(2)}',
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
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: tier.benefits.map((benefit) => _buildBenefitChip(benefit)).toList(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBenefitChip(String benefit) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.green.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.green.withOpacity(0.3)),
      ),
      child: Text(
        benefit,
        style: const TextStyle(color: Colors.green, fontSize: 11),
      ),
    );
  }

  Widget _buildDepositButton(CollateralProvider provider) {
    final hasEnoughBalance = provider.walletBalanceSats >= _selectedTier!.requiredCollateralSats;
    
    return Padding(
      padding: const EdgeInsets.only(bottom: 80),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: hasEnoughBalance ? () async {
            if (_selectedTier == null) return;
            
            // Verificar se tier está disponível
            if (!_isTierAvailable(_selectedTier!.id)) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Este nível estará disponível em breve!'),
                  backgroundColor: Colors.orange,
                ),
              );
              return;
            }

            // Verificar saldo
            if (!hasEnoughBalance) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Saldo insuficiente. Você precisa de ${_selectedTier!.requiredCollateralSats} sats.'),
                  backgroundColor: Colors.red,
                ),
              );
              return;
            }

            // Mostrar confirmação
            _showConfirmDepositDialog(provider);
          } : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: hasEnoughBalance ? Colors.orange : Colors.grey,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Column(
            children: [
              Text(
                hasEnoughBalance 
                    ? 'Travar ${_selectedTier!.requiredCollateralSats} sats como Garantia'
                    : 'Saldo Insuficiente',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (hasEnoughBalance)
                Text(
                  '≈ R\$ ${_selectedTier!.requiredCollateralBrl.toStringAsFixed(2)}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              if (!hasEnoughBalance)
                Text(
                  'Precisa de ${_selectedTier!.requiredCollateralSats - provider.walletBalanceSats} sats a mais',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
            ],
          ),
        ),
      ),
    );
  }
  
  Widget _buildRemoveCollateralButton(CollateralProvider provider) {
    final canWithdraw = provider.canWithdraw();
    
    return Padding(
      padding: const EdgeInsets.only(bottom: 80),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          onPressed: canWithdraw ? () async {
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: const Color(0xFF1E1E1E),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                title: const Row(
                  children: [
                    Icon(Icons.warning, color: Colors.orange),
                    SizedBox(width: 8),
                    Text('Remover Garantia', style: TextStyle(color: Colors.white)),
                  ],
                ),
                content: const Text(
                  'Ao remover a garantia, você não poderá mais aceitar novas ordens até configurar uma nova garantia.\n\nSeus sats continuarão na sua carteira.',
                  style: TextStyle(color: Colors.white70),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: const Text('Cancelar'),
                  ),
                  ElevatedButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                    child: const Text('Remover'),
                  ),
                ],
              ),
            );
            
            if (confirmed == true) {
              final success = await provider.removeCollateral();
              if (success && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('✅ Garantia removida! Seus sats estão disponíveis.'),
                    backgroundColor: Colors.green,
                  ),
                );
              }
            }
          } : null,
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: canWithdraw ? Colors.red : Colors.grey),
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Text(
            canWithdraw 
                ? 'Remover Garantia' 
                : 'Finalize as ordens para remover',
            style: TextStyle(
              color: canWithdraw ? Colors.red : Colors.grey,
              fontSize: 16,
            ),
          ),
        ),
      ),
    );
  }
  
  /// Mostrar dialog de confirmação para travar garantia
  void _showConfirmDepositDialog(CollateralProvider provider) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.lock, color: Colors.orange),
            SizedBox(width: 8),
            Text('Confirmar Garantia', style: TextStyle(color: Colors.white)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Tier: ${_selectedTier!.name}',
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              'Garantia: ${_selectedTier!.requiredCollateralSats} sats',
              style: const TextStyle(color: Colors.orange, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            Text(
              '≈ R\$ ${_selectedTier!.requiredCollateralBrl.toStringAsFixed(2)}',
              style: const TextStyle(color: Colors.white60, fontSize: 14),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.green.withOpacity(0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.security, color: Colors.green, size: 16),
                      SizedBox(width: 8),
                      Text(
                        'Auto-custódia',
                        style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Os sats ficam na SUA carteira. Apenas "travados" enquanto você aceita ordens.',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Máximo por ordem: R\$ ${_selectedTier!.maxOrderValueBrl.toStringAsFixed(0)}',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              
              // Obter saldo da carteira
              final breezProvider = context.read<BreezProvider>();
              int walletBalance = 0;
              try {
                final balanceInfo = await breezProvider.getBalance();
                final balanceStr = balanceInfo['balance']?.toString() ?? balanceInfo['balanceSat']?.toString() ?? '0';
                walletBalance = int.tryParse(balanceStr) ?? 0;
                debugPrint('💳 Saldo para depósito: $walletBalance sats');
              } catch (e) {
                debugPrint('⚠️ Erro ao obter saldo: $e');
              }
              
              if (walletBalance == 0) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Carteira não inicializada ou sem saldo.'),
                      backgroundColor: Colors.orange,
                    ),
                  );
                }
                return;
              }

              final result = await provider.depositCollateral(
                providerId: widget.providerId,
                tierId: _selectedTier!.id,
                walletBalanceSats: walletBalance,
              );

              if (result != null && result['success'] == true) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('✅ Garantia ${result['tier']} ativada! Máximo R\$ ${(result['max_order_brl'] as double).toStringAsFixed(0)}/ordem'),
                      backgroundColor: Colors.green,
                      duration: const Duration(seconds: 3),
                    ),
                  );
                  setState(() {
                    _selectedTier = null;
                  });
                }
              } else {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Erro: ${provider.error ?? "Desconhecido"}'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            child: const Text('Confirmar'),
          ),
        ],
      ),
    );
  }
  IconData _getTierIcon(String tierId) {
    switch (tierId) {
      case 'trial':
        return Icons.play_arrow;
      case 'starter':
        return Icons.emoji_events_outlined;
      case 'basic':
        return Icons.star_outline;
      case 'pro':
        return Icons.star_half;
      case 'elite':
        return Icons.star;
      case 'ultimate':
        return Icons.diamond;
      default:
        return Icons.star_outline;
    }
  }

  Color _getTierColor(String tierId) {
    switch (tierId) {
      case 'trial':
        return Colors.teal;
      case 'starter':
        return Colors.green;
      case 'basic':
        return Colors.orange;
      case 'pro':
        return Colors.blue;
      case 'elite':
        return Colors.purple;
      case 'ultimate':
        return Colors.amber;
      default:
        return Colors.grey;
    }
  }
  
  /// Verifica se o tier está disponível para seleção
  bool _isTierAvailable(String tierId) {
    // Tiers disponíveis: trial, starter, basic, pro, elite, ultimate
    return true; // Todos disponíveis no sistema local
  }
}
