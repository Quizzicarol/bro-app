import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../providers/breez_provider_export.dart';
import '../providers/order_provider.dart';
import '../providers/collateral_provider.dart';
import '../models/collateral_tier.dart';
import '../services/local_collateral_service.dart';
import '../services/payment_monitor_service.dart';
import '../services/secure_storage_service.dart';
import '../services/nostr_service.dart';
import '../services/nostr_order_service.dart';
import 'provider_orders_screen.dart';

/// Taxa estimada para claim de depósito on-chain (em sats)
/// Baseado em ~200-400 sats observados na rede, com margem de segurança
const int kEstimatedOnchainClaimFeeSats = 500;

/// Tela para depositar garantia para um tier específico
class TierDepositScreen extends StatefulWidget {
  final CollateralTier tier;
  final String providerId;

  const TierDepositScreen({
    super.key,
    required this.tier,
    required this.providerId,
  });

  @override
  State<TierDepositScreen> createState() => _TierDepositScreenState();
}

class _TierDepositScreenState extends State<TierDepositScreen> {
  String? _lightningInvoice;
  String? _lightningPaymentHash;
  String? _bitcoinAddress;
  bool _isLoading = true;
  String? _error;
  int _currentBalance = 0;
  int _committedSats = 0; // Sats comprometidos com ordens pendentes
  bool _depositCompleted = false;
  int _amountNeededSats = 0; // Valor líquido necessário (colateral)
  int _amountNeededSatsWithFee = 0; // Valor bruto para on-chain (colateral + taxa)
  PaymentMonitorService? _paymentMonitor;
  bool _paymentDetected = false; // Pagamento detectado mas aguardando confirmações
  int _confirmations = 0;
  bool _isRecovering = false; // Estado de recuperação de depósitos

  @override
  void initState() {
    super.initState();
    _generatePaymentOptions();
  }

  /// RECUPERAÇÃO: Tentar recuperar depósitos on-chain não processados
  Future<void> _recoverPendingDeposits() async {
    if (_isRecovering) return;
    
    setState(() {
      _isRecovering = true;
    });
    
    try {
      final breezProvider = context.read<BreezProvider>();
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🔍 Buscando depósitos pendentes...'),
          duration: Duration(seconds: 2),
        ),
      );
      
      final result = await breezProvider.recoverUnclaimedDeposits();
      
      if (!mounted) return;
      
      if (result['success'] == true) {
        final claimed = result['claimed'] ?? 0;
        final totalAmount = result['totalAmount'] ?? '0';
        final newBalance = result['newBalance'] ?? '0';
        
        if (claimed > 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('✅ Recuperados $claimed depósitos! Total: $totalAmount sats'),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 4),
            ),
          );
          
          // Atualizar saldo e verificar se atingiu o tier
          setState(() {
            _currentBalance = int.tryParse(newBalance) ?? _currentBalance;
          });
          
          // Verificar se já pode ativar o tier
          final orderProvider = context.read<OrderProvider>();
          final committedSats = orderProvider.committedSats;
          final availableBalance = (_currentBalance - committedSats).clamp(0, _currentBalance);
          
          if (availableBalance >= widget.tier.requiredCollateralSats) {
            await _activateTier(availableBalance);
          }
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(result['message'] ?? 'Nenhum depósito pendente encontrado'),
              backgroundColor: Colors.orange,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Erro: ${result['error']}'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Erro: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isRecovering = false;
        });
      }
    }
  }

  Future<void> _generatePaymentOptions() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final breezProvider = context.read<BreezProvider>();
      final orderProvider = context.read<OrderProvider>();
      
      // Obter saldo atual
      final balanceInfo = await breezProvider.getBalance();
      final balanceStr = balanceInfo['balance']?.toString() ?? '0';
      final totalBalance = int.tryParse(balanceStr) ?? 0;
      
      // IMPORTANTE: Em modo Bro (provedor), o saldo existente pode estar comprometido
      // com ordens pendentes do modo cliente. Portanto, NÃO descontamos o saldo existente.
      // O provedor precisa depositar o valor COMPLETO do tier.
      final committedSats = orderProvider.committedSats;
      _currentBalance = totalBalance;
      _committedSats = committedSats;
      
      debugPrint('💰 Saldo total: $totalBalance sats');
      debugPrint('💰 Sats comprometidos com ordens: $committedSats sats');
      debugPrint('💰 MODO BRO: Valor completo do tier é necessário');
      
      // Em modo Bro: só considera depósito completo se tiver saldo ALÉM do comprometido
      final availableForCollateral = (totalBalance - committedSats).clamp(0, totalBalance);
      
      if (availableForCollateral >= widget.tier.requiredCollateralSats) {
        // ✅ IMPORTANTE: Ativar o tier antes de marcar como completo!
        debugPrint('✅ Saldo suficiente detectado, ativando tier automaticamente...');
        await _activateTier(availableForCollateral);
        
        // ✅ NAVEGAR DIRETAMENTE PARA A TELA DE ORDENS
        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => ProviderOrdersScreen(providerId: widget.providerId),
            ),
          );
        }
        return;
      }

      // Calcular quanto falta (valor completo do tier, não descontar saldo comprometido)
      // O valor necessário é: requiredCollateralSats - (saldo disponível livre)
      final amountNeeded = widget.tier.requiredCollateralSats - availableForCollateral;
      _amountNeededSats = amountNeeded;
      
      // Para on-chain: adicionar taxa estimada de claim
      // Isso garante que após a taxa, o usuário terá o valor necessário de colateral
      _amountNeededSatsWithFee = amountNeeded + kEstimatedOnchainClaimFeeSats;
      
      // Gerar invoice Lightning (sem taxa extra - Lightning é mais eficiente)
      final invoiceResult = await breezProvider.createInvoice(
        amountSats: amountNeeded,
        description: 'Garantia Bro - Tier ${widget.tier.name}',
      );
      
      if (invoiceResult != null && invoiceResult['invoice'] != null) {
        _lightningInvoice = invoiceResult['invoice'];
        _lightningPaymentHash = invoiceResult['paymentHash'];
      }

      // Gerar endereço Bitcoin on-chain
      final addressResult = await breezProvider.createOnchainAddress();
      if (addressResult != null && addressResult['success'] == true) {
        _bitcoinAddress = addressResult['swap']?['bitcoinAddress'];
      }

      setState(() {
        _isLoading = false;
      });

      // Iniciar monitoramento de pagamento
      _startPaymentMonitoring(amountNeeded);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _paymentMonitor?.stopAll();
    super.dispose();
  }

  void _startPaymentMonitoring(int expectedAmount) {
    final breezProvider = context.read<BreezProvider>();
    _paymentMonitor = PaymentMonitorService(breezProvider);
    
    debugPrint('🔍 Iniciando monitoramento de depósito: $expectedAmount sats');
    
    // Monitorar Lightning (se invoice disponível)
    if (_lightningInvoice != null && _lightningPaymentHash != null) {
      debugPrint('⚡ Monitorando pagamento Lightning...');
      _paymentMonitor!.monitorPayment(
        paymentId: 'tier_deposit_lightning',
        paymentHash: _lightningPaymentHash!,
        checkInterval: const Duration(seconds: 3),
        onStatusChange: (status, data) async {
          if (status == PaymentStatus.confirmed && mounted) {
            debugPrint('✅ Pagamento Lightning confirmado para tier!');
            await _onPaymentReceived();
          }
        },
      );
    }
    
    // Monitorar On-chain (se endereço disponível)
    if (_bitcoinAddress != null) {
      debugPrint('🔗 Monitorando pagamento On-chain...');
      _paymentMonitor!.monitorOnchainAddress(
        paymentId: 'tier_deposit_onchain',
        address: _bitcoinAddress!,
        expectedSats: expectedAmount,
        checkInterval: const Duration(seconds: 15), // On-chain mais lento
        onStatusChange: (status, data) async {
          if (!mounted) return;
          
          if (status == PaymentStatus.confirmed) {
            debugPrint('✅ Pagamento On-chain confirmado para tier!');
            await _onPaymentReceived();
          } else if (status == PaymentStatus.pending && !_paymentDetected) {
            // Pode mostrar status intermediário
            debugPrint('⏳ Aguardando confirmações on-chain...');
          }
        },
      );
    }
    
    // Também fazer polling de saldo como fallback
    _listenForBalanceChange();
  }

  void _listenForBalanceChange() {
    // Verificar periodicamente se o saldo aumentou (fallback)
    Future.delayed(const Duration(seconds: 10), () async {
      if (!mounted || _depositCompleted) return;
      
      final breezProvider = context.read<BreezProvider>();
      final orderProvider = context.read<OrderProvider>();
      
      final balanceInfo = await breezProvider.getBalance();
      final balanceStr = balanceInfo['balance']?.toString() ?? '0';
      final totalBalance = int.tryParse(balanceStr) ?? 0;
      
      // Calcular saldo disponível (total - comprometido)
      final committedSats = orderProvider.committedSats;
      final availableBalance = (totalBalance - committedSats).clamp(0, totalBalance);
      
      if (availableBalance >= widget.tier.requiredCollateralSats) {
        // Pagamento recebido! Ativar tier
        await _onPaymentReceived();
      } else if (totalBalance > _currentBalance) {
        // Recebeu algo mas ainda não é suficiente - mostrar progresso
        if (mounted) {
          setState(() {
            _currentBalance = totalBalance;
            _paymentDetected = true;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('💰 Pagamento detectado! Saldo: $totalBalance sats'),
              backgroundColor: Colors.blue,
              duration: const Duration(seconds: 3),
            ),
          );
        }
        _listenForBalanceChange(); // Continuar ouvindo
      } else {
        _listenForBalanceChange(); // Continuar ouvindo
      }
    });
  }

  Future<void> _onPaymentReceived() async {
    if (_depositCompleted) return; // Evita chamadas duplicadas
    
    final breezProvider = context.read<BreezProvider>();
    final orderProvider = context.read<OrderProvider>();
    
    // Forçar sync para garantir saldo atualizado
    await breezProvider.forceSyncWallet();
    
    final balanceInfo = await breezProvider.getBalance();
    final balanceStr = balanceInfo['balance']?.toString() ?? '0';
    final totalBalance = int.tryParse(balanceStr) ?? 0;
    
    final committedSats = orderProvider.committedSats;
    final availableBalance = (totalBalance - committedSats).clamp(0, totalBalance);
    
    // Parar monitoramento
    _paymentMonitor?.stopAll();
    
    // Ativar tier
    await _activateTier(availableBalance);
  }

  Future<void> _activateTier(int balance) async {
    final collateralService = LocalCollateralService();
    final nostrService = NostrService();
    final nostrOrderService = NostrOrderService();
    
    // Salvar tier localmente
    await collateralService.setCollateral(
      tierId: widget.tier.id,
      tierName: widget.tier.name,
      requiredSats: widget.tier.requiredCollateralSats,
      maxOrderBrl: widget.tier.maxOrderValueBrl,
    );

    // ✅ IMPORTANTE: Publicar tier no Nostr para persistência entre logins
    final privateKey = nostrService.privateKey;
    if (privateKey != null) {
      try {
        final published = await nostrOrderService.publishProviderTier(
          privateKey: privateKey,
          tierId: widget.tier.id,
          tierName: widget.tier.name,
          depositedSats: widget.tier.requiredCollateralSats,
          maxOrderValue: widget.tier.maxOrderValueBrl.round(),
          activatedAt: DateTime.now().toIso8601String(),
        );
        
        if (published) {
          debugPrint('✅ Tier publicado no Nostr com sucesso!');
        } else {
          debugPrint('⚠️ Falha ao publicar tier no Nostr (salvo apenas localmente)');
        }
      } catch (e) {
        debugPrint('⚠️ Erro ao publicar tier no Nostr: $e');
      }
    } else {
      debugPrint('⚠️ Private key não disponível, tier salvo apenas localmente');
    }

    // ✅ IMPORTANTE: Marcar como modo provedor para persistir entre sessões
    await SecureStorageService.setProviderMode(true);
    debugPrint('✅ Provider mode ativado e persistido');

    // ✅ IMPORTANTE: Atualizar o CollateralProvider para refletir a mudança
    if (mounted) {
      final collateralProvider = context.read<CollateralProvider>();
      await collateralProvider.refreshCollateral('', walletBalance: balance);
      debugPrint('✅ CollateralProvider atualizado após ativação do tier ${widget.tier.name}');
    }

    setState(() {
      _currentBalance = balance;
      _depositCompleted = true;
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ Tier ${widget.tier.name} ativado com sucesso!'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text('Depositar - ${widget.tier.name}'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context, _depositCompleted),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.orange))
          : _error != null
              ? _buildErrorView()
              : _depositCompleted
                  ? _buildSuccessView()
                  : _buildDepositView(),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 64),
            const SizedBox(height: 16),
            Text(
              'Erro: $_error',
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _generatePaymentOptions,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
              child: const Text('Tentar Novamente'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSuccessView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.2),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check, color: Colors.green, size: 64),
            ),
            const SizedBox(height: 24),
            Text(
              'Tier ${widget.tier.name} Ativado!',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Você pode aceitar ordens de até R\$ ${widget.tier.maxOrderValueBrl.toStringAsFixed(0)}',
              style: const TextStyle(color: Colors.white70, fontSize: 16),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Saldo atual: $_currentBalance sats',
              style: const TextStyle(color: Colors.orange, fontSize: 14),
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: () {
                // Navegar diretamente para a tela de ordens disponíveis
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(
                    builder: (context) => ProviderOrdersScreen(providerId: widget.providerId),
                  ),
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 16),
              ),
              child: const Text('Começar a Aceitar Ordens'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDepositView() {
    // Usar o valor já calculado que considera sats comprometidos
    final amountNeeded = _amountNeededSats;
    
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Info do tier
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.orange.withOpacity(0.3)),
            ),
            child: Column(
              children: [
                Text(
                  widget.tier.name,
                  style: const TextStyle(
                    color: Colors.orange,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Máximo por ordem: R\$ ${widget.tier.maxOrderValueBrl.toStringAsFixed(0)}',
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Status atual
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Saldo total:', style: TextStyle(color: Colors.white70)),
                    Text('$_currentBalance sats', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  ],
                ),
                if (_committedSats > 0) ...[
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Comprometido (ordens):', style: TextStyle(color: Colors.red, fontSize: 12)),
                      Text('-$_committedSats sats', style: const TextStyle(color: Colors.red, fontSize: 12)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Disponível:', style: TextStyle(color: Colors.white70, fontSize: 12)),
                      Text('${(_currentBalance - _committedSats).clamp(0, _currentBalance)} sats', 
                           style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Garantia necessária:', style: TextStyle(color: Colors.white70)),
                    Text('${widget.tier.requiredCollateralSats} sats', style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold)),
                  ],
                ),
                const Divider(color: Colors.white24, height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Depositar:', style: TextStyle(color: Colors.white70)),
                    Text('$amountNeeded sats', style: const TextStyle(color: Colors.green, fontSize: 18, fontWeight: FontWeight.bold)),
                  ],
                ),
                Text(
                  '≈ R\$ ${(amountNeeded / 100000000 * 475000).toStringAsFixed(2)}',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Tabs para Lightning/On-chain
          DefaultTabController(
            length: 2,
            child: Column(
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1E1E),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const TabBar(
                    indicatorColor: Colors.orange,
                    labelColor: Colors.orange,
                    unselectedLabelColor: Colors.white54,
                    tabs: [
                      Tab(icon: Icon(Icons.flash_on), text: 'Lightning'),
                      Tab(icon: Icon(Icons.link), text: 'On-chain'),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                // Altura fixa mas com margem de segurança
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: 350,
                    maxHeight: 500,
                  ),
                  child: SizedBox(
                    height: 420,
                    child: TabBarView(
                      children: [
                        _buildLightningTab(),
                        _buildOnchainTab(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Espaçamento extra no final para evitar overflow
          const SizedBox(height: 16),
          
          // BOTÃO DE RECUPERAÇÃO DE DEPÓSITOS
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.blue.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.blue.withOpacity(0.3)),
            ),
            child: Column(
              children: [
                const Text(
                  'Já fez um depósito mas não foi detectado?',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  onPressed: _isRecovering ? null : _recoverPendingDeposits,
                  icon: _isRecovering 
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.refresh, size: 18),
                  label: Text(_isRecovering ? 'Recuperando...' : 'Recuperar Depósitos Pendentes'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildLightningTab() {
    if (_lightningInvoice == null) {
      return const Center(
        child: Text('Erro ao gerar invoice', style: TextStyle(color: Colors.red)),
      );
    }

    return SingleChildScrollView(
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: QrImageView(
              data: _lightningInvoice!,
              version: QrVersions.auto,
              size: 180,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '⚡ Pagamento instantâneo',
            style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          const Text(
            'Escaneie o QR code com sua carteira Lightning',
            style: TextStyle(color: Colors.white70, fontSize: 12),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _lightningInvoice!));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Invoice copiada!')),
              );
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copiar Invoice'),
            style: OutlinedButton.styleFrom(foregroundColor: Colors.orange),
          ),
        ],
      ),
    );
  }

  Widget _buildOnchainTab() {
    if (_bitcoinAddress == null) {
      return const Center(
        child: Text('Erro ao gerar endereço', style: TextStyle(color: Colors.red)),
      );
    }

    // Para on-chain: usar valor COM taxa para garantir colateral suficiente após claim
    final amountToSend = _amountNeededSatsWithFee;
    // Converter sats para BTC para o URI BIP21
    final amountBtc = amountToSend / 100000000.0;
    // URI BIP21: bitcoin:<address>?amount=<btc>&label=<label>
    final bitcoinUri = 'bitcoin:$_bitcoinAddress?amount=${amountBtc.toStringAsFixed(8)}&label=Garantia%20Bro%20${widget.tier.name}';
    
    return SingleChildScrollView(
      child: Column(
        children: [
          // AVISO IMPORTANTE SOBRE TAXA
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.withOpacity(0.5)),
            ),
            child: Column(
              children: [
                const Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.orange, size: 20),
                    SizedBox(width: 8),
                    Text(
                      'Taxa de Rede Bitcoin',
                      style: TextStyle(
                        color: Colors.orange,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Colateral necessário:', style: TextStyle(color: Colors.white70, fontSize: 12)),
                    Text('$_amountNeededSats sats', style: const TextStyle(color: Colors.white, fontSize: 12)),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Taxa estimada (rede):', style: TextStyle(color: Colors.white70, fontSize: 12)),
                    Text('+$kEstimatedOnchainClaimFeeSats sats', style: const TextStyle(color: Colors.red, fontSize: 12)),
                  ],
                ),
                const Divider(color: Colors.orange, height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('ENVIAR:', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                    Text('$amountToSend sats', style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 14)),
                  ],
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: QrImageView(
              data: bitcoinUri,
              version: QrVersions.auto,
              size: 160,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '🔗 Bitcoin On-chain',
            style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(
            'Enviar: $amountToSend sats (${amountBtc.toStringAsFixed(8)} BTC)',
            style: const TextStyle(color: Colors.green, fontSize: 14, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 2),
          Text(
            'Você receberá ~$_amountNeededSats sats após taxa',
            style: const TextStyle(color: Colors.white54, fontSize: 11),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          if (_paymentDetected)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blue),
                  ),
                  SizedBox(width: 8),
                  Text(
                    'Aguardando confirmações...',
                    style: TextStyle(color: Colors.blue, fontSize: 12),
                  ),
                ],
              ),
            )
          else
            const Text(
              'Pode demorar até 30 min para confirmar',
              style: TextStyle(color: Colors.white70, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: bitcoinUri));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('URI Bitcoin copiado (com valor)!')),
              );
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copiar URI (com valor)'),
            style: OutlinedButton.styleFrom(foregroundColor: Colors.blue),
          ),
          const SizedBox(height: 6),
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _bitcoinAddress!));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Endereço copiado!')),
              );
            },
            child: const Text('Copiar só o endereço', style: TextStyle(color: Colors.white54, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
