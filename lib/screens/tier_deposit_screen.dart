import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../providers/breez_provider_export.dart';
import '../providers/order_provider.dart';
import '../providers/collateral_provider.dart';
import '../models/collateral_tier.dart';
import '../services/local_collateral_service.dart';
import '../services/payment_monitor_service.dart';
import '../services/secure_storage_service.dart';
import '../services/nostr_service.dart';
import 'provider_orders_screen.dart';

/// Tela para depositar garantia para um tier específico
/// VERSÃO LIGHTNING-ONLY (sem on-chain para evitar taxas altas)
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
  bool _isLoading = true;
  String? _error;
  int _currentBalance = 0;
  int _initialBalance = 0; // CRÍTICO: Saldo inicial ao entrar na tela
  int _committedSats = 0; // Sats comprometidos com ordens pendentes
  bool _depositCompleted = false;
  int _amountNeededSats = 0; // Valor líquido necessário (colateral)
  PaymentMonitorService? _paymentMonitor;

  @override
  void initState() {
    super.initState();
    _generatePaymentOptions();
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
      
      broLog('💰 Saldo total: $totalBalance sats');
      broLog('💰 Sats comprometidos com ordens: $committedSats sats');
      broLog('💰 MODO BRO: Valor completo do tier é necessário');
      
      // Em modo Bro: só considera depósito completo se tiver saldo ALÉM do comprometido
      final availableForCollateral = (totalBalance - committedSats).clamp(0, totalBalance);
      
      // CRÍTICO: Salvar saldo inicial para detectar NOVOS depósitos
      _initialBalance = totalBalance;
      _currentBalance = totalBalance;
      broLog('💰 Saldo INICIAL salvo: $_initialBalance sats');
      
      if (availableForCollateral >= widget.tier.requiredCollateralSats) {
        // ✅ IMPORTANTE: Ativar o tier antes de marcar como completo!
        broLog('✅ Saldo suficiente detectado, ativando tier automaticamente...');
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
      
      // Gerar invoice Lightning (única opção agora)
      final invoiceResult = await breezProvider.createInvoice(
        amountSats: amountNeeded,
        description: 'Garantia Bro - Tier ${widget.tier.name}',
      );
      
      if (invoiceResult != null && invoiceResult['invoice'] != null) {
        _lightningInvoice = invoiceResult['invoice'];
        _lightningPaymentHash = invoiceResult['paymentHash'];
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
    
    broLog('🔍 Iniciando monitoramento de depósito: $expectedAmount sats');
    
    // Monitorar Lightning (se invoice disponível)
    if (_lightningInvoice != null && _lightningPaymentHash != null) {
      broLog('⚡ Monitorando pagamento Lightning...');
      _paymentMonitor!.monitorPayment(
        paymentId: 'tier_deposit_lightning',
        paymentHash: _lightningPaymentHash!,
        checkInterval: const Duration(seconds: 3),
        onStatusChange: (status, data) async {
          if (status == PaymentStatus.confirmed && mounted) {
            broLog('✅ Pagamento Lightning confirmado para tier!');
            await _onPaymentReceived();
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
      
      // 🔥 CRÍTICO: Verificar se houve AUMENTO REAL de saldo desde entrada na tela
      // Isso evita ativação falsa por flutuações ou estado inicial
      final balanceIncrease = totalBalance - _initialBalance;
      final minRequired = (widget.tier.requiredCollateralSats * 0.90).round();
      
      broLog('🔍 Polling: saldo=$totalBalance, inicial=$_initialBalance, aumento=$balanceIncrease, necessário=$_amountNeededSats');
      
      // CONDIÇÃO CORRIGIDA: Só ativa se:
      // 1. O saldo disponível é suficiente para o tier E
      // 2. Houve um aumento real de saldo (depósito ocorreu)
      if (availableBalance >= minRequired && balanceIncrease >= (_amountNeededSats * 0.90).round()) {
        // Pagamento recebido! Ativar tier
        broLog('✅ Depósito detectado! Aumento de $balanceIncrease sats');
        await _onPaymentReceived();
      } else if (totalBalance > _currentBalance) {
        // Recebeu algo mas ainda não é suficiente - mostrar progresso
        if (mounted) {
          setState(() {
            _currentBalance = totalBalance;
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
    
    // Obter saldo atualizado
    final balanceInfo = await breezProvider.getBalance();
    final balanceStr = balanceInfo['balance']?.toString() ?? '0';
    final totalBalance = int.tryParse(balanceStr) ?? 0;
    
    // Calcular saldo disponível
    final committedSats = orderProvider.committedSats;
    final availableBalance = (totalBalance - committedSats).clamp(0, totalBalance);
    
    // CRÍTICO: Verificar aumento real de saldo
    final balanceIncrease = totalBalance - _initialBalance;
    broLog('💰 Pagamento detectado! Saldo total: $totalBalance, disponível: $availableBalance, aumento: $balanceIncrease');
    
    // 🔥 Tolerância de 10% para oscilação do Bitcoin
    final minRequired = (widget.tier.requiredCollateralSats * 0.90).round();
    final minDeposit = (_amountNeededSats * 0.90).round();
    
    // CONDIÇÃO CORRIGIDA: Verificar saldo suficiente E aumento real
    if (availableBalance >= minRequired && balanceIncrease >= minDeposit) {
      // Ativar o tier
      broLog('✅ Condições atendidas: disponível=$availableBalance >= $minRequired, aumento=$balanceIncrease >= $minDeposit');
      await _activateTier(availableBalance);
    } else {
      broLog('⚠️ Ainda não atende: disponível=$availableBalance, minRequired=$minRequired, aumento=$balanceIncrease, minDeposit=$minDeposit');
      // Atualizar UI e continuar esperando
      if (mounted) {
        setState(() {
          _currentBalance = totalBalance;
        });
      }
    }
  }

  Future<void> _activateTier(int balance) async {
    broLog('🎯 Ativando tier ${widget.tier.name} com saldo disponível: $balance sats');
    
    // ✅ IMPORTANTE: Obter pubkey ANTES de salvar o tier
    final nostrService = NostrService();
    final pubkey = nostrService.publicKey;
    broLog('🔑 Salvando tier para pubkey: ${pubkey?.substring(0, 8) ?? "null"}');
    
    // Usar LocalCollateralService instance COM pubkey
    final localCollateralService = LocalCollateralService();
    localCollateralService.setCurrentUser(pubkey); // CRÍTICO: Setar usuário antes de salvar
    await localCollateralService.setCollateral(
      tierId: widget.tier.id,
      tierName: widget.tier.name,
      requiredSats: widget.tier.requiredCollateralSats,
      maxOrderBrl: widget.tier.maxOrderValueBrl,
      userPubkey: pubkey, // CRÍTICO: Passar pubkey
    );
    
    broLog('✅ Tier salvo localmente para pubkey: ${pubkey?.substring(0, 8) ?? "null"}');

    // ✅ IMPORTANTE: Marcar como modo provedor para persistir entre sessões COM PUBKEY
    await SecureStorageService.setProviderMode(true, userPubkey: pubkey);
    broLog('✅ Provider mode ativado e persistido para pubkey: ${pubkey?.substring(0, 8) ?? "null"}');

    // ✅ IMPORTANTE: Atualizar o CollateralProvider para refletir a mudança
    if (mounted) {
      final collateralProvider = context.read<CollateralProvider>();
      await collateralProvider.refreshCollateral('', walletBalance: balance);
      broLog('✅ CollateralProvider atualizado após ativação do tier ${widget.tier.name}');
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
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFFF6B6B)))
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

          // Lightning Payment Section
          _buildLightningSection(),
          
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildLightningSection() {
    if (_lightningInvoice == null) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Column(
          children: [
            Icon(Icons.error_outline, color: Colors.red, size: 48),
            SizedBox(height: 8),
            Text('Erro ao gerar invoice', style: TextStyle(color: Colors.red)),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          // Lightning header
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.flash_on, color: Colors.orange),
                SizedBox(width: 8),
                Text(
                  '⚡ Lightning Network',
                  style: TextStyle(
                    color: Colors.orange,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          
          // QR Code
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: QrImageView(
              data: _lightningInvoice!,
              version: QrVersions.auto,
              size: 200,
            ),
          ),
          const SizedBox(height: 16),
          
          const Text(
            'Pagamento instantâneo',
            style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          const Text(
            'Escaneie o QR code com sua carteira Lightning',
            style: TextStyle(color: Colors.white70, fontSize: 12),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          
          // Copy button
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
          const SizedBox(height: 16),
          
          // Waiting indicator
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFFFF6B6B),
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'Aguardando pagamento...',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
