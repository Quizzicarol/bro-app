import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_breez_liquid/flutter_breez_liquid.dart' as liquid;
import 'package:path_provider/path_provider.dart';
import 'package:bip39/bip39.dart' as bip39;
import '../config.dart';
import '../config/breez_config.dart';
import '../services/storage_service.dart';

/// Self-custodial Lightning provider using Breez SDK Liquid (Nodeless)
/// Usado como FALLBACK quando Spark não está funcionando
/// 
/// Diferenças do Spark:
/// - Saldo fica em L-BTC (Liquid Network) 
/// - Swaps Lightning são feitos via Boltz (não-custodial)
/// - Taxas são maiores (~0.25% + 200 sats fixo)
class BreezLiquidProvider with ChangeNotifier {
  liquid.BreezSdkLiquid? _sdk;
  bool _isInitialized = false;
  bool _isLoading = false;
  String? _error;
  String? _mnemonic;
  StreamSubscription<liquid.SdkEvent>? _eventsSub;
  
  // Callbacks para pagamentos
  Function(String paymentId, int amountSats, String? paymentHash)? onPaymentReceived;
  Function(String paymentId, int amountSats, String? paymentHash)? onPaymentSent;
  
  String? _lastPaymentId;
  int? _lastPaymentAmount;
  String? _lastPaymentHash;
  
  // Limites de Lightning (atualizados do SDK)
  int _minReceiveSats = 1000;
  int _maxReceiveSats = 1000000;
  int _minSendSats = 1000;
  int _maxSendSats = 1000000;
  
  liquid.BreezSdkLiquid? get sdk => _sdk;
  bool get isInitialized => _isInitialized;
  bool get isLoading => _isLoading;
  String? get error => _error;
  String? get mnemonic => _mnemonic;
  String? get lastPaymentId => _lastPaymentId;
  int? get lastPaymentAmount => _lastPaymentAmount;
  String? get lastPaymentHash => _lastPaymentHash;
  
  // Limites
  int get minReceiveSats => _minReceiveSats;
  int get maxReceiveSats => _maxReceiveSats;
  int get minSendSats => _minSendSats;
  int get maxSendSats => _maxSendSats;

  void _setLoading(bool v) {
    _isLoading = v;
    notifyListeners();
  }

  void _setError(String? e) {
    _error = e;
    notifyListeners();
  }

  /// Calcula a taxa total do Liquid em sats para um determinado valor
  /// Usado para embutir no spread da cotação
  static int calculateLiquidFee(int amountSats) {
    // Taxa percentual (0.25%)
    final percentFee = (amountSats * AppConfig.liquidSwapFeePercent).round();
    // Taxa fixa (200 sats base + 50 sats rede)
    final fixedFee = AppConfig.liquidTotalFixedFeeSats;
    return percentFee + fixedFee;
  }
  
  /// Calcula o spread adicional em porcentagem para cobrir taxas Liquid
  /// Retorna valor entre 0.0 e 1.0 (ex: 0.05 = 5%)
  static double calculateLiquidSpread(int amountSats) {
    if (amountSats <= 0) return 0.0;
    final fee = calculateLiquidFee(amountSats);
    return fee / amountSats;
  }
  
  /// Calcula o valor em sats que o usuário deve pagar considerando taxas Liquid
  /// amountSats = valor líquido que quer receber
  /// retorna valor bruto que o usuário precisa enviar
  static int calculateGrossAmount(int netAmountSats) {
    // Fórmula: gross = net + fee(net)
    // Como fee depende do valor, fazemos iteração
    int gross = netAmountSats;
    for (int i = 0; i < 3; i++) {
      gross = netAmountSats + calculateLiquidFee(gross);
    }
    return gross;
  }

  /// Initialize Breez SDK Liquid with mnemonic
  Future<bool> initialize({String? mnemonic}) async {
    if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) {
      debugPrint('🚫 Breez SDK Liquid não suportado nesta plataforma');
      _isInitialized = false;
      _setLoading(false);
      return false;
    }
    
    if (_isInitialized) {
      debugPrint('✅ SDK Liquid já inicializado');
      return true;
    }
    
    if (_isLoading) {
      debugPrint('⏳ SDK Liquid já está sendo inicializado...');
      int waitCount = 0;
      const maxWait = 300;
      await Future.doWhile(() async {
        await Future.delayed(const Duration(milliseconds: 100));
        waitCount++;
        if (waitCount >= maxWait) {
          _isLoading = false;
          return false;
        }
        return _isLoading && !_isInitialized;
      });
      
      if (_isInitialized) return true;
    }
    
    _setLoading(true);
    _setError(null);
    
    debugPrint('💧 Iniciando Breez SDK Liquid...');

    try {
      // Determinar mnemonic
      if (mnemonic != null) {
        _mnemonic = mnemonic;
        await StorageService().saveBreezMnemonic(_mnemonic!);
        debugPrint('🔑 Usando seed fornecida para Liquid');
      } else {
        final savedMnemonic = await StorageService().getBreezMnemonic();
        if (savedMnemonic != null) {
          _mnemonic = savedMnemonic;
          debugPrint('🔑 Usando seed salva para Liquid');
        } else {
          _mnemonic = bip39.generateMnemonic(strength: 128);
          await StorageService().saveBreezMnemonic(_mnemonic!);
          debugPrint('🔑 Nova seed gerada para Liquid');
        }
      }
      
      // Configurar diretório de trabalho
      final appDir = await getApplicationDocumentsDirectory();
      final pubkey = await StorageService().getNostrPublicKey();
      final userDirSuffix = pubkey != null ? '_${pubkey.substring(0, 8)}' : '';
      final workingDir = '${appDir.path}/breez_liquid$userDirSuffix';
      
      debugPrint('📁 Liquid working dir: $workingDir');

      // Criar config - defaultConfig já inclui workingDir adequado
      final network = BreezConfig.useMainnet 
          ? liquid.LiquidNetwork.mainnet 
          : liquid.LiquidNetwork.testnet;
      
      final defaultCfg = liquid.defaultConfig(
        network: network,
        breezApiKey: BreezConfig.apiKey,
      );
      
      // Criar novo Config com o workingDir personalizado
      final config = liquid.Config(
        liquidExplorer: defaultCfg.liquidExplorer,
        bitcoinExplorer: defaultCfg.bitcoinExplorer,
        workingDir: workingDir, // Custom workingDir por usuário
        network: defaultCfg.network,
        paymentTimeoutSec: defaultCfg.paymentTimeoutSec,
        syncServiceUrl: defaultCfg.syncServiceUrl,
        zeroConfMaxAmountSat: defaultCfg.zeroConfMaxAmountSat,
        breezApiKey: BreezConfig.apiKey,
        externalInputParsers: defaultCfg.externalInputParsers,
        useDefaultExternalInputParsers: defaultCfg.useDefaultExternalInputParsers,
        onchainFeeRateLeewaySat: defaultCfg.onchainFeeRateLeewaySat,
        assetMetadata: defaultCfg.assetMetadata,
        sideswapApiKey: defaultCfg.sideswapApiKey,
        useMagicRoutingHints: defaultCfg.useMagicRoutingHints,
        onchainSyncPeriodSec: defaultCfg.onchainSyncPeriodSec,
        onchainSyncRequestTimeoutSec: defaultCfg.onchainSyncRequestTimeoutSec,
      );

      debugPrint('💧 Conectando ao Breez SDK Liquid ($network)...');
      
      // Conectar
      final connectRequest = liquid.ConnectRequest(
        config: config,
        mnemonic: _mnemonic!,
      );
      
      _sdk = await liquid.connect(req: connectRequest);

      _isInitialized = true;
      debugPrint('✅ Breez SDK Liquid inicializado com sucesso!');
      
      // Ouvir eventos
      _eventsSub = _sdk!.addEventListener().listen(_handleSdkEvent);
      
      // Buscar limites
      await _fetchLimits();
      
      return true;
    } catch (e) {
      _setError('Erro ao inicializar Breez SDK Liquid: $e');
      debugPrint('❌ Erro inicializando Breez SDK Liquid: $e');
      return false;
    } finally {
      _setLoading(false);
    }
  }

  /// Busca limites de Lightning do Boltz
  Future<void> _fetchLimits() async {
    if (_sdk == null) return;
    
    try {
      final limits = await _sdk!.fetchLightningLimits();
      _minReceiveSats = limits.receive.minSat.toInt();
      _maxReceiveSats = limits.receive.maxSat.toInt();
      _minSendSats = limits.send.minSat.toInt();
      _maxSendSats = limits.send.maxSat.toInt();
      
      debugPrint('📊 Limites Liquid Lightning:');
      debugPrint('   Receber: $_minReceiveSats - $_maxReceiveSats sats');
      debugPrint('   Enviar: $_minSendSats - $_maxSendSats sats');
    } catch (e) {
      debugPrint('⚠️ Erro ao buscar limites: $e');
    }
  }

  /// Handle SDK events
  void _handleSdkEvent(liquid.SdkEvent event) {
    debugPrint('🔔 Evento Liquid SDK: ${event.runtimeType}');
    
    if (event is liquid.SdkEvent_PaymentSucceeded) {
      final payment = event.details;
      final txId = payment.txId ?? 'unknown';
      debugPrint('💰 PAGAMENTO LIQUID SUCESSO! TxID: $txId');
      
      _lastPaymentId = txId;
      _lastPaymentAmount = payment.amountSat.toInt();
      
      // Determinar se é envio ou recebimento
      if (payment.paymentType == liquid.PaymentType.receive) {
        if (onPaymentReceived != null) {
          onPaymentReceived!(txId, payment.amountSat.toInt(), null);
        }
      } else if (payment.paymentType == liquid.PaymentType.send) {
        if (onPaymentSent != null) {
          onPaymentSent!(txId, payment.amountSat.toInt(), null);
        }
      }
      
      notifyListeners();
    } else if (event is liquid.SdkEvent_PaymentFailed) {
      final txId = event.details.txId ?? 'unknown';
      debugPrint('❌ PAGAMENTO LIQUID FALHOU! TxID: $txId');
    } else if (event is liquid.SdkEvent_PaymentPending) {
      debugPrint('⏳ Pagamento Liquid pendente...');
    } else if (event is liquid.SdkEvent_PaymentWaitingConfirmation) {
      debugPrint('⏳ Pagamento Liquid aguardando confirmação...');
    } else if (event is liquid.SdkEvent_Synced) {
      debugPrint('🔄 Liquid wallet sincronizada');
    }
  }

  /// Get wallet balance
  Future<int> getBalance() async {
    if (!_isInitialized || _sdk == null) {
      return 0;
    }

    try {
      final info = await _sdk!.getInfo();
      final balance = info.walletInfo.balanceSat.toInt();
      debugPrint('💰 Saldo Liquid: $balance sats');
      return balance;
    } catch (e) {
      debugPrint('❌ Erro ao obter saldo Liquid: $e');
      return 0;
    }
  }

  /// Create a Lightning invoice (via Boltz swap)
  /// 
  /// IMPORTANTE: O valor do invoice já deve incluir as taxas embutidas!
  /// Use calculateGrossAmount() para calcular o valor bruto.
  Future<Map<String, dynamic>?> createInvoice({
    required int amountSats,
    String? description,
  }) async {
    if (!_isInitialized) {
      debugPrint('⚠️ SDK Liquid não inicializado, tentando inicializar...');
      final success = await initialize();
      if (!success) {
        _setError('Falha ao inicializar SDK Liquid');
        return {'success': false, 'error': 'Falha ao inicializar SDK Liquid'};
      }
    }
    
    if (_sdk == null) {
      _setError('SDK Liquid não disponível');
      return {'success': false, 'error': 'SDK Liquid não disponível'};
    }

    // Verificar limites
    if (amountSats < _minReceiveSats) {
      return {
        'success': false, 
        'error': 'Valor mínimo para Liquid: $_minReceiveSats sats'
      };
    }
    
    if (amountSats > _maxReceiveSats) {
      return {
        'success': false, 
        'error': 'Valor máximo para Liquid: $_maxReceiveSats sats'
      };
    }

    _setLoading(true);
    _setError(null);
    
    debugPrint('💧 Criando invoice Liquid de $amountSats sats...');

    try {
      // Preparar pagamento
      final prepareRequest = liquid.PrepareReceiveRequest(
        paymentMethod: liquid.PaymentMethod.bolt11Invoice,
        amount: liquid.ReceiveAmount_Bitcoin(payerAmountSat: BigInt.from(amountSats)),
      );
      
      final prepareResponse = await _sdk!.prepareReceivePayment(req: prepareRequest);
      final fees = prepareResponse.feesSat.toInt();
      
      debugPrint('📊 Taxas Boltz: $fees sats');

      // Criar invoice
      final receiveRequest = liquid.ReceivePaymentRequest(
        prepareResponse: prepareResponse,
        description: description ?? 'Pagamento Bro (via Liquid)',
      );
      
      final receiveResponse = await _sdk!.receivePayment(req: receiveRequest);
      final bolt11 = receiveResponse.destination;
      
      debugPrint('✅ Invoice Liquid BOLT11 criado: ${bolt11.substring(0, 50)}...');

      _setLoading(false);
      return {
        'success': true,
        'bolt11': bolt11,
        'invoice': bolt11,
        'fees': fees,
        'receiver': 'Breez Liquid Wallet (via Boltz)',
        'isLiquid': true,
      };
    } catch (e) {
      final errMsg = 'Erro ao criar invoice Liquid: $e';
      _setError(errMsg);
      debugPrint('❌ $errMsg');
      _setLoading(false);
      return {'success': false, 'error': errMsg};
    }
  }

  /// Pay a Lightning invoice (via Boltz swap)
  Future<Map<String, dynamic>?> payInvoice(String bolt11) async {
    if (!_isInitialized || _sdk == null) {
      return {'success': false, 'error': 'SDK Liquid não inicializado'};
    }

    _setLoading(true);
    _setError(null);
    
    debugPrint('💧 Pagando invoice via Liquid...');

    try {
      // Preparar pagamento
      final prepareRequest = liquid.PrepareSendRequest(
        destination: bolt11,
      );
      
      final prepareResponse = await _sdk!.prepareSendPayment(req: prepareRequest)
          .timeout(const Duration(seconds: 30), onTimeout: () => throw TimeoutException('Timeout ao preparar pagamento Liquid (30s)'));
      final fees = prepareResponse.feesSat?.toInt() ?? 0;
      
      debugPrint('📊 Taxas para envio: $fees sats');

      // Enviar pagamento
      final sendRequest = liquid.SendPaymentRequest(
        prepareResponse: prepareResponse,
      );
      
      final sendResponse = await _sdk!.sendPayment(req: sendRequest)
          .timeout(const Duration(seconds: 60), onTimeout: () => throw TimeoutException('Timeout ao enviar pagamento Liquid (60s)'));
      final payment = sendResponse.payment;
      final txId = payment.txId ?? 'unknown';
      
      debugPrint('✅ Pagamento Liquid enviado! TxID: $txId');

      _setLoading(false);
      return {
        'success': true,
        'paymentId': txId,
        'amountSats': payment.amountSat.toInt(),
        'fees': fees,
      };
    } catch (e) {
      final errMsg = 'Erro ao pagar invoice via Liquid: $e';
      _setError(errMsg);
      debugPrint('❌ $errMsg');
      _setLoading(false);
      return {'success': false, 'error': errMsg};
    }
  }

  /// Disconnect and cleanup
  Future<void> disconnect() async {
    if (_eventsSub != null) {
      await _eventsSub!.cancel();
      _eventsSub = null;
    }
    
    if (_sdk != null) {
      try {
        await _sdk!.disconnect();
        debugPrint('✅ SDK Liquid desconectado');
      } catch (e) {
        debugPrint('⚠️ Erro ao desconectar SDK Liquid: $e');
      }
      _sdk = null;
    }
    
    _isInitialized = false;
    _mnemonic = null;
    notifyListeners();
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}
