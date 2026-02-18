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
import 'provider_orders_screen.dart';

/// Tela para depositar garantia para um tier espec�fico
/// VERS�O LIGHTNING-ONLY (sem on-chain para evitar taxas altas)
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
  int _initialBalance = 0; // CR�TICO: Saldo inicial ao entrar na tela
  int _committedSats = 0; // Sats comprometidos com ordens pendentes
  bool _depositCompleted = false;
  int _amountNeededSats = 0; // Valor l�quido necess�rio (colateral)
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
      // com ordens pendentes do modo cliente. Portanto, N�O descontamos o saldo existente.
      // O provedor precisa depositar o valor COMPLETO do tier.
      final committedSats = orderProvider.committedSats;
      _currentBalance = totalBalance;
      _committedSats = committedSats;
      
      debugPrint('?? Saldo total: $totalBalance sats');
      debugPrint('?? Sats comprometidos com ordens: $committedSats sats');
      debugPrint('?? MODO BRO: Valor completo do tier � necess�rio');
      
      // Em modo Bro: s� considera dep�sito completo se tiver saldo AL�M do comprometido
      final availableForCollateral = (totalBalance - committedSats).clamp(0, totalBalance);
      
      // CR�TICO: Salvar saldo inicial para detectar NOVOS dep�sitos
      _initialBalance = totalBalance;
      _currentBalance = totalBalance;
      debugPrint('?? Saldo INICIAL salvo: $_initialBalance sats');
      
      if (availableForCollateral >= widget.tier.requiredCollateralSats) {
        // ? IMPORTANTE: Ativar o tier antes de marcar como completo!
        debugPrint('? Saldo suficiente detectado, ativando tier automaticamente...');
        await _activateTier(availableForCollateral);
        
        // ? NAVEGAR DIRETAMENTE PARA A TELA DE ORDENS
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

      // Calcular quanto falta (valor completo do tier, n�o descontar saldo comprometido)
      // O valor necess�rio �: requiredCollateralSats - (saldo dispon�vel livre)
      final amountNeeded = widget.tier.requiredCollateralSats - availableForCollateral;
      _amountNeededSats = amountNeeded;
      
      // Gerar invoice Lightning (�nica op��o agora)
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
    
    debugPrint('?? Iniciando monitoramento de dep�sito: $expectedAmount sats');
    
    // Monitorar Lightning (se invoice dispon�vel)
    if (_lightningInvoice != null && _lightningPaymentHash != null) {
      debugPrint('? Monitorando pagamento Lightning...');
      _paymentMonitor!.monitorPayment(
        paymentId: 'tier_deposit_lightning',
        paymentHash: _lightningPaymentHash!,
        checkInterval: const Duration(seconds: 3),
        onStatusChange: (status, data) async {
          if (status == PaymentStatus.confirmed && mounted) {
            debugPrint('? Pagamento Lightning confirmado para tier!');
            await _onPaymentReceived();
          }
        },
      );
    }
    
    // Tamb�m fazer polling de saldo como fallback
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
      
      // Calcular saldo dispon�vel (total - comprometido)
      final committedSats = orderProvider.committedSats;
      final availableBalance = (totalBalance - committedSats).clamp(0, totalBalance);
      
      // ?? CR�TICO: Verificar se houve AUMENTO REAL de saldo desde entrada na tela
      // Isso evita ativa��o falsa por flutua��es ou estado inicial
      final balanceIncrease = totalBalance - _initialBalance;
      final minRequired = (widget.tier.requiredCollateralSats * 0.90).round();
      
      debugPrint('?? Polling: saldo=$totalBalance, inicial=$_initialBalance, aumento=$balanceIncrease, necess�rio=$_amountNeededSats');
      
      // CONDI��O CORRIGIDA: S� ativa se:
      // 1. O saldo dispon�vel � suficiente para o tier E
      // 2. Houve um aumento real de saldo (dep�sito ocorreu)
      if (availableBalance >= minRequired && balanceIncrease >= (_amountNeededSats * 0.90).round()) {
        // Pagamento recebido! Ativar tier
        debugPrint('? Dep�sito detectado! Aumento de $balanceIncrease sats');
        await _onPaymentReceived();
      } else if (totalBalance > _currentBalance) {
        // Recebeu algo mas ainda n�o � suficiente - mostrar progresso
        if (mounted) {
          setState(() {
            _currentBalance = totalBalance;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('?? Pagamento detectado! Saldo: $totalBalance sats'),
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
    
    // For�ar sync para garantir saldo atualizado
    await breezProvider.forceSyncWallet();
    
    // Obter saldo atualizado
    final balanceInfo = await breezProvider.getBalance();
    final balanceStr = balanceInfo['balance']?.toString() ?? '0';
    final totalBalance = int.tryParse(balanceStr) ?? 0;
    
    // Calcular saldo dispon�vel
    final committedSats = orderProvider.committedSats;
    final availableBalance = (totalBalance - committedSats).clamp(0, totalBalance);
    
    // CR�TICO: Verificar aumento real de saldo
    final balanceIncrease = totalBalance - _initialBalance;
    debugPrint('?? Pagamento detectado! Saldo total: $totalBalance, dispon�vel: $availableBalance, aumento: $balanceIncrease');
    
    // ?? Toler�ncia de 10% para oscila��o do Bitcoin
    final minRequired = (widget.tier.requiredCollateralSats * 0.90).round();
    final minDeposit = (_amountNeededSats * 0.90).round();
    
    // CONDI��O CORRIGIDA: Verificar saldo suficiente E aumento real
    if (availableBalance >= minRequired && balanceIncrease >= minDeposit) {
      // Ativar o tier
      debugPrint('? Condi��es atendidas: dispon�vel=$availableBalance >= $minRequired, aumento=$balanceIncrease >= $minDeposit');
      await _activateTier(availableBalance);
    } else {
      debugPrint('?? Ainda n�o atende: dispon�vel=$availableBalance, minRequired=$minRequired, aumento=$balanceIncrease, minDeposit=$minDeposit');
      // Atualizar UI e continuar esperando
      if (mounted) {
        setState(() {
          _currentBalance = totalBalance;
        });
      }
    }
  }

  Future<void> _activateTier(int balance) async {
    debugPrint('?? Ativando tier ${widget.tier.name} com saldo dispon�vel: $balance sats');
    
    // ? IMPORTANTE: Obter pubkey ANTES de salvar o tier
    final nostrService = NostrService();
    final pubkey = nostrService.publicKey;
    debugPrint('?? Salvando tier para pubkey: ${pubkey?.substring(0, 8) ?? "null"}');
    
    // Usar LocalCollateralService instance COM pubkey
    final localCollateralService = LocalCollateralService();
    localCollateralService.setCurrentUser(pubkey); // CR�TICO: Setar usu�rio antes de salvar
    await localCollateralService.setCollateral(
      tierId: widget.tier.id,
      tierName: widget.tier.name,
      requiredSats: widget.tier.requiredCollateralSats,
      maxOrderBrl: widget.tier.maxOrderValueBrl,
      userPubkey: pubkey, // CR�TICO: Passar pubkey
    );
    
    debugPrint('? Tier salvo localmente para pubkey: ${pubkey?.substring(0, 8) ?? "null"}');

    // ? IMPORTANTE: Marcar como modo provedor para persistir entre sess�es COM PUBKEY
    await SecureStorageService.setProviderMode(true, userPubkey: pubkey);
    debugPrint('? Provider mode ativado e persistido para pubkey: ${pubkey?.substring(0, 8) ?? "null"}');

    // ? IMPORTANTE: Atualizar o CollateralProvider para refletir a mudan�a
    if (mounted) {
      final collateralProvider = context.read<CollateralProvider>();
      await collateralProvider.refreshCollateral('', walletBalance: balance);
      debugPrint('? CollateralProvider atualizado ap�s ativa��o do tier ${widget.tier.name}');
    }

    setState(() {
      _currentBalance = balance;
      _depositCompleted = true;
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('? Tier ${widget.tier.name} ativado com sucesso!'),
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
              'Voc� pode aceitar ordens de at� R\$ ${widget.tier.maxOrderValueBrl.toStringAsFixed(0)}',
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
                // Navegar diretamente para a tela de ordens dispon�veis
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
              child: const Text('Come�ar a Aceitar Ordens'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDepositView() {
    // Usar o valor j� calculado que considera sats comprometidos
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
                  'M�ximo por ordem: R\$ ${widget.tier.maxOrderValueBrl.toStringAsFixed(0)}',
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
                      const Text('Dispon�vel:', style: TextStyle(color: Colors.white70, fontSize: 12)),
                      Text('${(_currentBalance - _committedSats).clamp(0, _currentBalance)} sats', 
                           style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Garantia necess�ria:', style: TextStyle(color: Colors.white70)),
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
                  '? R\$ ${(amountNeeded / 100000000 * 475000).toStringAsFixed(2)}',
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
                  '? Lightning Network',
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
            'Pagamento instant�neo',
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
                  color: Colors.orange,
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
