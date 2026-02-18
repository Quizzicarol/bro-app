import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../providers/collateral_provider.dart';
import '../providers/breez_provider_export.dart';
import '../models/collateral_tier.dart';
import '../config.dart';

/// Tela para provedor depositar garantia em Bitcoin
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final collateralProvider = context.read<CollateralProvider>();
      collateralProvider.initialize(widget.providerId);
    });
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
      ),
      body: Consumer<CollateralProvider>(
        builder: (context, collateralProvider, child) {
          if (collateralProvider.isLoading) {
            return const Center(
              child: CircularProgressIndicator(color: Colors.orange),
            );
          }

          if (collateralProvider.error != null) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, color: Colors.red, size: 48),
                  const SizedBox(height: 16),
                  Text(
                    'Erro: ${collateralProvider.error}',
                    style: const TextStyle(color: Colors.white70),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () {
                      collateralProvider.clearError();
                      collateralProvider.initialize(widget.providerId);
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
                // Status atual
                _buildCurrentStatus(collateralProvider),
                const SizedBox(height: 24),

                // Explicação do sistema
                _buildExplanationCard(),
                const SizedBox(height: 24),

                // Tiers disponíveis
                _buildTiersSection(collateralProvider),
                const SizedBox(height: 24),

                // Botão de depósito
                if (_selectedTier != null && !collateralProvider.hasCollateral)
                  _buildDepositButton(collateralProvider),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildCurrentStatus(CollateralProvider provider) {
    final hasCollateral = provider.hasCollateral;
    final currentTier = provider.getCurrentTier();

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
          if (hasCollateral) ...[
            const SizedBox(height: 16),
            const Divider(color: Colors.white12),
            const SizedBox(height: 16),
            _buildStatusRow(
              'Tier Atual',
              currentTier?.name ?? 'N/A',
              Icons.star,
              Colors.orange,
            ),
            const SizedBox(height: 12),
            _buildStatusRow(
              'Garantia Total',
              '${provider.collateral!['total_collateral'] ?? 0} sats',
              Icons.lock,
              Colors.green,
            ),
            const SizedBox(height: 12),
            _buildStatusRow(
              'Disponível',
              '${provider.collateral!['available_sats'] ?? 0} sats',
              Icons.account_balance_wallet,
              Colors.blue,
            ),
            const SizedBox(height: 12),
            _buildStatusRow(
              'Bloqueado em Ordens',
              '${provider.collateral!['locked_sats'] ?? 0} sats',
              Icons.hourglass_empty,
              Colors.yellow,
            ),
          ] else ...[
            const SizedBox(height: 12),
            const Text(
              'Deposite uma garantia para começar a aceitar ordens e ganhar taxas!',
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
          Row(
            children: [
              const Icon(Icons.lightbulb_outline, color: Colors.blue, size: 24),
              const SizedBox(width: 8),
              const Text(
                'Como Funciona',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildExplanationPoint('1️⃣', 'Deposite Bitcoin como garantia (bloqueado temporariamente)'),
          _buildExplanationPoint('2️⃣', 'Aceite ordens de acordo com seu nível de garantia'),
          _buildExplanationPoint('3️⃣', 'Pague a conta no banco e envie comprovante'),
          _buildExplanationPoint('4️⃣', 'Receba Bitcoin do usuário + 3% de taxa'),
          _buildExplanationPoint('5️⃣', 'Garantia é desbloqueada automaticamente'),
          const SizedBox(height: 12),
          const Divider(color: Colors.white12),
          const SizedBox(height: 12),
          const Text(
            '⚠️ A garantia protege o usuário contra fraude. Em caso de disputa, ela pode ser cortada.',
            style: TextStyle(
              color: Colors.orange,
              fontSize: 12,
              fontStyle: FontStyle.italic,
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
        const SizedBox(height: 16),
        ...provider.availableTiers!.map((tier) => _buildTierCard(tier, provider)),
      ],
    );
  }

  Widget _buildTierCard(CollateralTier tier, CollateralProvider provider) {
    final isSelected = _selectedTier?.id == tier.id;
    final isCurrentTier = provider.getCurrentTier()?.id == tier.id;
    final isAvailable = _isTierAvailable(tier.id);

    return GestureDetector(
      onTap: (!isAvailable || provider.hasCollateral) ? null : () {
        setState(() {
          _selectedTier = tier;
        });
      },
      child: Opacity(
        opacity: isAvailable ? 1.0 : 0.6,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isSelected
                ? Colors.orange.withOpacity(0.2)
                : const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? Colors.orange : (isAvailable ? Colors.white12 : Colors.white10),
              width: isSelected ? 2 : 1,
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
                          ],
                        ),
                        Text(
                          tier.description,
                          style: const TextStyle(color: Colors.white60, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  if (isSelected && !provider.hasCollateral && isAvailable)
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 80), // Espaço para não ficar atrás dos botões de navegação
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: () async {
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

            // Em modo teste, simular depósito
            if (AppConfig.testMode) {
              _showTestDepositDialog();
              return;
            }

            // Em produção, verificar se SDK está disponível
            final breezProvider = context.read<BreezProvider>();
            if (breezProvider.sdk == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('SDK não inicializado. Aguarde...'),
                  backgroundColor: Colors.orange,
                ),
              );
              return;
            }

            // Criar invoice
            final result = await provider.depositCollateral(
              providerId: widget.providerId,
              tierId: _selectedTier!.id,
              sdk: breezProvider.sdk!,
            );

            if (result != null && result['invoice'] != null) {
              if (mounted) {
                _showInvoiceDialog(result);
              }
            } else {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Erro ao criar invoice: ${provider.error ?? "Desconhecido"}'),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            }
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.orange,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Text(
            'Depositar R\$ ${_selectedTier!.requiredCollateralBrl.toStringAsFixed(0)}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
  
  /// Mostrar dialog de depósito em modo teste
  void _showTestDepositDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.science, color: Colors.orange),
            SizedBox(width: 8),
            Text('Modo Teste', style: TextStyle(color: Colors.white)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Depósito de Garantia: R\$ ${_selectedTier!.requiredCollateralBrl.toStringAsFixed(0)}',
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              '≈ ${_selectedTier!.requiredCollateralSats} sats',
              style: const TextStyle(color: Colors.orange, fontSize: 14),
            ),
            const SizedBox(height: 16),
            const Text(
              'Em modo teste, o depósito é simulado. Em produção, você precisará pagar uma invoice Lightning.',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('✅ Garantia de R\$ ${_selectedTier!.requiredCollateralBrl.toStringAsFixed(0)} simulada com sucesso!'),
                  backgroundColor: Colors.green,
                ),
              );
              // Voltar para tela anterior
              Navigator.of(context).pop();
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            child: const Text('Simular Depósito'),
          ),
        ],
      ),
    );
  }

  void _showInvoiceDialog(Map<String, dynamic> result) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121212),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Pagar Garantia',
          style: TextStyle(color: Colors.white),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: QrImageView(
                  data: result['invoice'],
                  version: QrVersions.auto,
                  size: 200,
                  backgroundColor: Colors.white,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '${result['amount_sats']} sats',
                style: const TextStyle(
                  color: Colors.orange,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: result['invoice']));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Invoice copiada!')),
                  );
                },
                icon: const Icon(Icons.copy, size: 16, color: Colors.orange),
                label: const Text('Copiar Invoice'),
              ),
              const SizedBox(height: 16),
              const Text(
                'Pague esta invoice para ativar sua garantia.',
                style: TextStyle(color: Colors.white70, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).pop(); // Volta para tela anterior
            },
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
  }

  IconData _getTierIcon(String tierId) {
    switch (tierId) {
      case 'starter':
        return Icons.emoji_events_outlined;
      case 'basic':
        return Icons.star_outline;
      case 'intermediate':
        return Icons.star_half;
      case 'advanced':
        return Icons.star;
      default:
        return Icons.star_outline;
    }
  }

  Color _getTierColor(String tierId) {
    switch (tierId) {
      case 'starter':
        return Colors.green;
      case 'basic':
        return Colors.orange;
      case 'intermediate':
        return Colors.blue;
      case 'advanced':
        return Colors.purple;
      default:
        return Colors.grey;
    }
  }
  
  /// Verifica se o tier está disponível para seleção
  bool _isTierAvailable(String tierId) {
    // Tiers disponíveis: trial, starter, basic
    return tierId == 'trial' || tierId == 'starter' || tierId == 'basic';
  }
}
