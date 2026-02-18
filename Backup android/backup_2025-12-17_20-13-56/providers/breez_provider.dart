import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:breez_sdk_spark_flutter/breez_sdk_spark.dart' as spark;
import 'package:path_provider/path_provider.dart';
import 'package:bip39/bip39.dart' as bip39;
import 'package:shared_preferences/shared_preferences.dart';
import '../config/breez_config.dart';
import '../extensions/breez_extensions.dart';
import '../services/storage_service.dart';

/// Self-custodial Lightning provider using Breez SDK Spark (Nodeless)
class BreezProvider with ChangeNotifier {
  static bool _rustLibInitialized = false;
  spark.BreezSdk? _sdk;
  bool _isInitialized = false;
  bool _isLoading = false;
  String? _error;
  String? _mnemonic;
  StreamSubscription<spark.SdkEvent>? _eventsSub;
  
  // Callback para notificar pagamentos recebidos
  Function(String paymentId, int amountSats)? onPaymentReceived;
  String? _lastPaymentId;
  int? _lastPaymentAmount;
  
  spark.BreezSdk? get sdk => _sdk;
  bool get isInitialized => _isInitialized;
  bool get isLoading => _isLoading;
  String? get error => _error;
  String? get mnemonic => _mnemonic;
  String? get lastPaymentId => _lastPaymentId;
  int? get lastPaymentAmount => _lastPaymentAmount;

  void _setLoading(bool v) {
    _isLoading = v;
    notifyListeners();
  }

  void _setError(String? e) {
    _error = e;
    notifyListeners();
  }

  /// Initialize Breez SDK with mnemonic
  /// If mnemonic is null, generates a new one
  Future<bool> initialize({String? mnemonic}) async {
    // Skip Breez SDK on Windows/Web (not supported)
    if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) {
      debugPrint('?? Breez SDK n�o suportado nesta plataforma (Windows/Web/Linux)');
      _isInitialized = false;
      _setLoading(false);
      return false;
    }
    
    if (_isInitialized) {
      debugPrint('? SDK j� inicializado');
      return true;
    }
    
    if (_isLoading) {
      debugPrint('? SDK j� est� sendo inicializado, aguardando...');
      // Aguardar inicializa��o em andamento
      await Future.doWhile(() async {
        await Future.delayed(const Duration(milliseconds: 100));
        return _isLoading && !_isInitialized;
      });
      return _isInitialized;
    }
    
    _setLoading(true);
    _setError(null);
    
    debugPrint('?? Iniciando Breez SDK Spark...');

    try {
      // Initialize RustLib (flutter_rust_bridge) if not already initialized
      if (!_rustLibInitialized) {
        debugPrint('?? Inicializando flutter_rust_bridge...');
        await spark.BreezSdkSparkLib.init();
        _rustLibInitialized = true;
        debugPrint('? flutter_rust_bridge inicializado');
      }

      // Generate or use provided mnemonic
      // IMPORTANTE: Primeiro tentar carregar seed salva, depois gerar nova
      if (mnemonic != null) {
        // Seed fornecida explicitamente (recuperação)
        _mnemonic = mnemonic;
        await StorageService().saveBreezMnemonic(_mnemonic!);
        debugPrint('🔑 Restaurando carteira com seed fornecida');
      } else {
        // Tentar carregar seed salva
        final savedMnemonic = await StorageService().getBreezMnemonic();
        if (savedMnemonic != null && savedMnemonic.isNotEmpty) {
          _mnemonic = savedMnemonic;
          debugPrint('🔑 Usando seed salva anteriormente');
        } else {
          // Gerar nova seed apenas se não houver salva
          _mnemonic = bip39.generateMnemonic();
          await StorageService().saveBreezMnemonic(_mnemonic!);
          debugPrint('🆕 Nova carteira gerada!');
        }
      }

      // Create seed from mnemonic
      final seed = spark.Seed.mnemonic(mnemonic: _mnemonic!);
      
      // Get storage directory
      final appDir = await getApplicationDocumentsDirectory();
      final storageDir = '${appDir.path}/breez_spark';

      // Create config
      // Network enum only has: mainnet, regtest
      // For testnet, use mainnet with testnet BitcoinNetwork
      final network = BreezConfig.useMainnet ? spark.Network.mainnet : spark.Network.regtest;
      final config = spark.defaultConfig(network: network).copyWith(
        apiKey: BreezConfig.apiKey,
      );

      debugPrint('?? Conectando ao Breez SDK ($network)...');
      debugPrint('?? API Key: ${BreezConfig.apiKey.substring(0, 50)}...');
      
      // Connect to SDK
      _sdk = await spark.connect(
        request: spark.ConnectRequest(
          config: config,
          seed: seed,
          storageDir: storageDir,
        ),
      );

      _isInitialized = true;
      debugPrint('? Breez SDK Spark inicializado com sucesso!');
      
      // Listen to events
      _eventsSub = _sdk!.addEventListener().listen(_handleSdkEvent);
      
      // Sync wallet in background (n�o await para n�o bloquear)
      _syncWalletInBackground();
      
      return true;
    } catch (e) {
      _setError('Erro ao inicializar Breez SDK: $e');
      debugPrint('? Erro inicializando Breez SDK: $e');
      return false;
    } finally {
      _setLoading(false);
    }
  }

  /// Handle SDK events
  void _handleSdkEvent(spark.SdkEvent event) {
    debugPrint('🔔 Evento do SDK recebido: ${event.runtimeType}');
    
    if (event is spark.SdkEvent_PaymentSucceeded) {
      final payment = event.payment;
      debugPrint('💰 PAGAMENTO RECEBIDO! Payment: ${payment.id}, Amount: ${payment.amount} sats');
      
      // Salvar último pagamento
      _lastPaymentId = payment.id;
      _lastPaymentAmount = payment.amount.toInt();
      
      // CRÍTICO: Persistir pagamento IMEDIATAMENTE para não perder
      _persistPayment(payment.id, payment.amount.toInt());
      
      // Chamar callback se definido
      if (onPaymentReceived != null) {
        onPaymentReceived!(payment.id, payment.amount.toInt());
      }
    } else if (event is spark.SdkEvent_PaymentFailed) {
      debugPrint('❌ PAGAMENTO FALHOU! Payment: ${event.payment.id}');
    } else if (event is spark.SdkEvent_Synced) {
      debugPrint('🔄 Wallet sincronizada');
      // Verificar saldo após sincronização
      _checkBalanceAfterSync();
    }
    
    notifyListeners();
  }
  
  /// Persistir pagamento no SharedPreferences para nunca perder
  Future<void> _persistPayment(String paymentId, int amountSats) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // Carregar lista existente
      final paymentsJson = prefs.getString('lightning_payments') ?? '[]';
      final List<dynamic> payments = json.decode(paymentsJson);
      
      // Verificar se já existe
      if (payments.any((p) => p['id'] == paymentId)) {
        debugPrint('💾 Pagamento $paymentId já registrado');
        return;
      }
      
      // Adicionar novo pagamento
      payments.add({
        'id': paymentId,
        'amountSats': amountSats,
        'receivedAt': DateTime.now().toIso8601String(),
        'reconciled': false,
      });
      
      await prefs.setString('lightning_payments', json.encode(payments));
      debugPrint('💾 PAGAMENTO PERSISTIDO: $paymentId ($amountSats sats)');
    } catch (e) {
      debugPrint('❌ ERRO CRÍTICO ao persistir pagamento: $e');
    }
  }
  
  /// Recuperar pagamentos não reconciliados (para reconciliação manual)
  Future<List<Map<String, dynamic>>> getUnreconciledPayments() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final paymentsJson = prefs.getString('lightning_payments') ?? '[]';
      final List<dynamic> payments = json.decode(paymentsJson);
      
      return payments
          .where((p) => p['reconciled'] != true)
          .map((p) => Map<String, dynamic>.from(p))
          .toList();
    } catch (e) {
      debugPrint('❌ Erro ao recuperar pagamentos: $e');
      return [];
    }
  }
  
  /// Marcar pagamento como reconciliado
  Future<void> markPaymentReconciled(String paymentId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final paymentsJson = prefs.getString('lightning_payments') ?? '[]';
      final List<dynamic> payments = json.decode(paymentsJson);
      
      final index = payments.indexWhere((p) => p['id'] == paymentId);
      if (index != -1) {
        payments[index]['reconciled'] = true;
        payments[index]['reconciledAt'] = DateTime.now().toIso8601String();
        await prefs.setString('lightning_payments', json.encode(payments));
        debugPrint('✅ Pagamento $paymentId marcado como reconciliado');
      }
    } catch (e) {
      debugPrint('❌ Erro ao marcar pagamento: $e');
    }
  }
  
  /// Verificar saldo após sincronização
  Future<void> _checkBalanceAfterSync() async {
    if (_sdk == null) return;
    try {
      final info = await _sdk!.getInfo(request: spark.GetInfoRequest());
      debugPrint('?? Saldo atual: ${info.balanceSats} sats');
    } catch (e) {
      debugPrint('?? Erro ao verificar saldo: $e');
    }
  }
  
  /// Limpar último pagamento (após ser processado)
  void clearLastPayment() {
    _lastPaymentId = null;
    _lastPaymentAmount = null;
  }

  /// Sync wallet in background without blocking
  Future<void> _syncWalletInBackground() async {
    if (_sdk == null) return;
    
    try {
      debugPrint('?? Sincronizando carteira em background...');
      await _sdk!.syncWallet(request: spark.SyncWalletRequest());
      debugPrint('? Carteira sincronizada');
      
      // Get initial balance
      final info = await _sdk!.getInfo(request: spark.GetInfoRequest());
      debugPrint('?? Saldo: ${info.balanceSats} sats');
      
      notifyListeners();
    } catch (e) {
      debugPrint('?? Erro ao sincronizar carteira: $e');
    }
  }

  /// Create a Lightning invoice
  Future<Map<String, dynamic>?> createInvoice({
    required int amountSats,
    String? description,
  }) async {
    // Garantir que SDK está inicializado
    if (!_isInitialized) {
      debugPrint('⚠️ SDK não inicializado, tentando inicializar...');
      final success = await initialize();
      if (!success) {
        _setError('Falha ao inicializar SDK');
        return {'success': false, 'error': 'Falha ao inicializar SDK'};
      }
    }
    
    if (_sdk == null) {
      _setError('SDK não disponível após inicialização');
      return {'success': false, 'error': 'SDK não disponível'};
    }

    _setLoading(true);
    _setError(null);
    
    debugPrint('⚡ Criando invoice de $amountSats sats...');
    debugPrint('📝 Descrição: ${description ?? "Pagamento Bro"}');

    try {
      // NOTA: Removido syncWallet antes de criar invoice para acelerar
      // O sync é feito periodicamente em background
      
      final resp = await _sdk!.receivePayment(
        request: spark.ReceivePaymentRequest(
          paymentMethod: spark.ReceivePaymentMethod.bolt11Invoice(
            description: description ?? 'Pagamento Bro',
            amountSats: BigInt.from(amountSats),
          ),
        ),
      );

      final bolt11 = resp.paymentRequest;
      debugPrint('✅ Invoice BOLT11 criado: ${bolt11.substring(0, 50)}...');

      // Try to parse to extract payment hash for tracking
      String? paymentHash;
      try {
        final parsed = await _sdk!.parse(input: bolt11);
        if (parsed is spark.InputType_Bolt11Invoice) {
          paymentHash = parsed.field0.paymentHash;
          debugPrint('🔑 Payment Hash: $paymentHash');
        }
      } catch (e) {
        debugPrint('⚠️ Erro ao extrair payment hash: $e');
      }

      return {
        'success': true,
        'bolt11': bolt11,  // Chave esperada pelo wallet_screen
        'invoice': bolt11, // Alias para compatibilidade
        'paymentHash': paymentHash,
        'receiver': 'Breez Spark Wallet',
      };
    } catch (e) {
      final errMsg = 'Erro ao criar invoice: $e';
      _setError(errMsg);
      debugPrint('? $errMsg');
      return {'success': false, 'error': errMsg};
    } finally {
      _setLoading(false);
    }
  }

  /// Check payment status by payment hash
  Future<Map<String, dynamic>> checkPaymentStatus(String paymentHash) async {
    if (!_isInitialized || _sdk == null) {
      return {'paid': false, 'error': 'SDK n�o inicializado'};
    }

    try {
      // Sync wallet first
      await _sdk!.syncWallet(request: spark.SyncWalletRequest());
      
      final resp = await _sdk!.listPayments(
        request: spark.ListPaymentsRequest(),
      );

      final payments = resp.payments;

      // Find payment by hash from lightning details
      final payment = payments.firstWhere(
        (p) => p.details is spark.PaymentDetails_Lightning &&
            (p.details as spark.PaymentDetails_Lightning).paymentHash == paymentHash,
        orElse: () => throw Exception('Payment not found'),
      );

      final isPaid = payment.status == spark.PaymentStatus.completed;
      debugPrint('?? Payment $paymentHash status: ${payment.status}');

      return {
        'paid': isPaid,
        'status': payment.status.toString(),
        'amountSats': payment.amount.toString(),
      };
    } catch (e) {
      debugPrint('?? Erro checking payment: $e');
      return {'paid': false, 'error': e.toString()};
    }
  }
  
  /// Wait for payment to be received (blocking call with timeout)
  Future<Map<String, dynamic>> waitForPayment({
    required String paymentHash,
    int timeoutSeconds = 300, // 5 minutos
  }) async {
    if (!_isInitialized || _sdk == null) {
      return {'paid': false, 'error': 'SDK n�o inicializado'};
    }

    try {
      debugPrint('? Aguardando pagamento $paymentHash...');
      
      // Use WaitForPaymentIdentifier.paymentRequest with invoice/payment hash
      final resp = await _sdk!.waitForPayment(
        request: spark.WaitForPaymentRequest(
          identifier: spark.WaitForPaymentIdentifier.paymentRequest(paymentHash),
        ),
      );

      final isPaid = resp.payment.status == spark.PaymentStatus.completed;
      debugPrint('? Pagamento recebido! Status: ${resp.payment.status}');

      return {
        'paid': isPaid,
        'status': resp.payment.status.toString(),
        'amountSats': resp.payment.amount.toString(),
        'payment': resp.payment,
      };
    } catch (e) {
      debugPrint('? Erro aguardando pagamento: $e');
      return {'paid': false, 'error': e.toString()};
    }
  }

  /// Get wallet balance
  Future<Map<String, dynamic>> getBalance() async {
    if (!_isInitialized || _sdk == null) {
      return {'balance': 0, 'error': 'SDK n�o inicializado'};
    }

    try {
      final info = await _sdk!.getInfo(request: spark.GetInfoRequest());
      return {
        'balance': info.balanceSats.toString(),
        // Spark SDK GetInfoResponse does not expose pending fields here
        'pendingReceive': '0',
        'pendingSend': '0',
      };
    } catch (e) {
      return {'balance': 0, 'error': e.toString()};
    }
  }

  /// Create on-chain Bitcoin address for receiving
  Future<Map<String, dynamic>?> createOnchainAddress() async {
    if (!_isInitialized || _sdk == null) {
      return {'success': false, 'error': 'SDK n�o inicializado'};
    }

    try {
      final resp = await _sdk!.receivePayment(
        request: spark.ReceivePaymentRequest(
          paymentMethod: const spark.ReceivePaymentMethod.bitcoinAddress(),
        ),
      );

      // Parse to extract address if needed
      String address = resp.paymentRequest;
      try {
        final parsed = await _sdk!.parse(input: resp.paymentRequest);
        if (parsed is spark.InputType_BitcoinAddress) {
          address = parsed.field0.address;
        }
      } catch (_) {}
      
      return {
        'success': true,
        'swap': {
          'bitcoinAddress': address,
        },
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Pay a Lightning invoice (BOLT11)
  Future<Map<String, dynamic>?> payInvoice(String bolt11) async {
    if (!_isInitialized || _sdk == null) {
      return {'success': false, 'error': 'SDK não inicializado'};
    }

    _setLoading(true);
    _setError(null);
    
    debugPrint('💸 Pagando invoice...');

    try {
      // Primeiro, decodificar invoice para ver o valor
      int? invoiceAmount;
      try {
        final parsed = await _sdk!.parse(input: bolt11);
        if (parsed is spark.InputType_Bolt11Invoice) {
          // amountMsat é BigInt? e em milisat, converter para sats
          final amountMsat = parsed.field0.amountMsat;
          if (amountMsat != null) {
            invoiceAmount = (amountMsat ~/ BigInt.from(1000)).toInt();
          }
          debugPrint('📋 Valor da invoice: $invoiceAmount sats');
        }
      } catch (e) {
        debugPrint('⚠️ Não foi possível decodificar invoice: $e');
      }

      // Verificar saldo antes de enviar
      final balanceInfo = await getBalance();
      final currentBalance = int.tryParse(balanceInfo?['balance']?.toString() ?? '0') ?? 0;
      debugPrint('💰 Saldo atual: $currentBalance sats');

      if (invoiceAmount != null && currentBalance < invoiceAmount) {
        final errorMsg = 'Saldo insuficiente. Você tem $currentBalance sats mas a invoice requer $invoiceAmount sats';
        _setError(errorMsg);
        debugPrint('❌ $errorMsg');
        return {
          'success': false, 
          'error': errorMsg,
          'errorType': 'INSUFFICIENT_FUNDS',
          'balance': currentBalance,
          'required': invoiceAmount,
        };
      }

      // Step 1: Prepare payment
      final prepareReq = spark.PrepareSendPaymentRequest(
        paymentRequest: bolt11,
        amount: null,
        tokenIdentifier: null,
      );

      final prepareResp = await _sdk!.prepareSendPayment(request: prepareReq);

      // Step 2: Send payment
      final sendReq = spark.SendPaymentRequest(
        prepareResponse: prepareResp,
        options: null,
      );

      final resp = await _sdk!.sendPayment(request: sendReq);

      debugPrint('✅ Pagamento enviado!');
      debugPrint('   Payment ID: ${resp.payment.id}');
      debugPrint('   Amount: ${resp.payment.amount} sats');
      debugPrint('   Status: ${resp.payment.status}');

      String? paymentHash;
      if (resp.payment.details is spark.PaymentDetails_Lightning) {
        paymentHash = (resp.payment.details as spark.PaymentDetails_Lightning).paymentHash;
      }

      return {
        'success': true,
        'payment': {
          'id': resp.payment.id,
          'amount': resp.payment.amount.toString(),
          'status': resp.payment.status.toString(),
          'paymentHash': paymentHash,
        },
      };
    } catch (e) {
      String errMsg = e.toString();
      
      // Detectar erros comuns e traduzir
      if (errMsg.contains('insufficient') || errMsg.contains('Insufficient') || 
          errMsg.contains('balance') || errMsg.contains('Balance')) {
        errMsg = 'Saldo insuficiente para este pagamento';
      } else if (errMsg.contains('timeout') || errMsg.contains('Timeout')) {
        errMsg = 'Tempo esgotado. Tente novamente.';
      } else if (errMsg.contains('route') || errMsg.contains('Route')) {
        errMsg = 'Não foi possível encontrar rota para pagamento';
      } else if (errMsg.contains('expired') || errMsg.contains('Expired')) {
        errMsg = 'Invoice expirada. Solicite uma nova.';
      }
      
      _setError(errMsg);
      debugPrint('❌ Erro ao pagar: $errMsg');
      return {'success': false, 'error': errMsg};
    } finally {
      _setLoading(false);
    }
  }

  /// Decode a Lightning invoice to get details before paying
  Future<Map<String, dynamic>?> decodeInvoice(String bolt11) async {
    if (!_isInitialized || _sdk == null) {
      return {'success': false, 'error': 'SDK n�o inicializado'};
    }

    try {
      final parsed = await _sdk!.parse(input: bolt11);
      
      if (parsed is spark.InputType_Bolt11Invoice) {
        final invoice = parsed.field0;
        return {
          'success': true,
          'invoice': {
            'bolt11': bolt11,
            'paymentHash': invoice.paymentHash,
            'description': invoice.description,
            'amountSats': invoice.amountMsat != null 
                ? (invoice.amountMsat! ~/ BigInt.from(1000)).toString()
                : null,
            'expiry': invoice.expiry,
            'payeePubkey': invoice.payeePubkey,
          },
        };
      }

      return {'success': false, 'error': 'Invoice inv�lida'};
    } catch (e) {
      return {'success': false, 'error': 'Erro ao decodificar invoice: $e'};
    }
  }

  /// List payment history
  Future<List<Map<String, dynamic>>> listPayments() async {
    if (!_isInitialized || _sdk == null) {
      return [];
    }

    try {
      final resp = await _sdk!.listPayments(
        request: spark.ListPaymentsRequest(),
      );

      return resp.payments.map((payment) {
        String? paymentHash;
        
        if (payment.details is spark.PaymentDetails_Lightning) {
          final details = payment.details as spark.PaymentDetails_Lightning;
          paymentHash = details.paymentHash;
        }

        return {
          'id': payment.id,
          'paymentType': payment.paymentType.toString(),
          'status': payment.status.toString(),
          'amount': payment.amount.toString(),
          'paymentHash': paymentHash,
        };
      }).toList();
    } catch (e) {
      debugPrint('? Erro ao listar pagamentos: $e');
      return [];
    }
  }

  /// Get node information
  Future<Map<String, dynamic>?> getNodeInfo() async {
    if (!_isInitialized || _sdk == null) {
      return null;
    }

    try {
      final info = await _sdk!.getInfo(request: spark.GetInfoRequest());
      return {
        'balanceSats': info.balanceSats.toString(),
      };
    } catch (e) {
      debugPrint('? Erro ao obter info do n�: $e');
      return null;
    }
  }

  /// Compatibility methods for existing screens
  Future<void> refresh() async {
    if (_isInitialized && _sdk != null) {
      await getBalance();
    }
  }

  Future<void> refreshBalance() async => refresh();

  Future<Map<String, dynamic>?> createBitcoinAddress({String? description}) async {
    return createOnchainAddress();
  }

  Future<Map<String, dynamic>> checkAddressStatus(String address) async {
    // TODO: Implement address monitoring via SDK events
    return {'received': false, 'amount': 0};
  }

  /// Reinicializar SDK com nova seed (usado após restauração de backup)
  /// Isso desconecta o SDK atual e reconecta com a nova seed
  Future<bool> reinitializeWithNewSeed(String mnemonic) async {
    debugPrint('🔄 Reinicializando SDK com nova seed...');
    
    // Desconectar SDK atual
    await disconnect();
    
    // Reinicializar com a nova seed
    return await initialize(mnemonic: mnemonic);
  }

  /// Disconnect SDK
  Future<void> disconnect() async {
    if (_sdk != null) {
      await _eventsSub?.cancel();
      _eventsSub = null;
      await _sdk!.disconnect();
      _sdk = null;
      _isInitialized = false;
      _mnemonic = null;
      notifyListeners();
      debugPrint('🔌 Breez SDK desconectado');
    }
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}
