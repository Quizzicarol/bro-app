import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, Platform;
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
  
  // Estado de seguran�a da carteira
  bool _isNewWallet = false;  // True se carteira acabou de ser criada
  bool _seedRecoveryNeeded = false;  // True se houve problema ao recuperar seed
  
  // Callback para notificar pagamentos recebidos
  // Par�metros: paymentId, amountSats, paymentHash (opcional)
  Function(String paymentId, int amountSats, String? paymentHash)? onPaymentReceived;
  
  // Callback para notificar pagamentos ENVIADOS
  // Par�metros: paymentId, amountSats, paymentHash (opcional)
  // Usado para atualizar ordens para 'completed' automaticamente
  Function(String paymentId, int amountSats, String? paymentHash)? onPaymentSent;
  
  String? _lastPaymentId;
  int? _lastPaymentAmount;
  String? _lastPaymentHash;  // PaymentHash do �ltimo pagamento para verifica��o precisa
  
  spark.BreezSdk? get sdk => _sdk;
  bool get isInitialized => _isInitialized;
  bool get isLoading => _isLoading;
  String? get error => _error;
  String? get mnemonic => _mnemonic;
  String? get lastPaymentId => _lastPaymentId;
  int? get lastPaymentAmount => _lastPaymentAmount;
  String? get lastPaymentHash => _lastPaymentHash;  // Getter para verifica��o
  bool get isNewWallet => _isNewWallet;  // Para mostrar alerta de backup
  bool get seedRecoveryNeeded => _seedRecoveryNeeded;  // Para mostrar alerta de erro

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
    
    // Se j� est� inicializado, verificar se a seed � a mesma
    if (_isInitialized && mnemonic != null && _mnemonic != null) {
      // Comparar primeiras 2 palavras para ver se � a mesma seed
      final currentWords = _mnemonic!.split(' ').take(2).join(' ');
      final newWords = mnemonic.split(' ').take(2).join(' ');
      
      if (currentWords != newWords) {
        debugPrint('?? SDK inicializado com seed DIFERENTE!');
        debugPrint('   Atual: $currentWords...');
        debugPrint('   Nova: $newWords...');
        debugPrint('?? Reinicializando com seed correta...');
        
        // For�ar reinicializa��o com a nova seed
        return await reinitializeWithNewSeed(mnemonic);
      } else {
        debugPrint('? SDK j� inicializado com a seed correta');
        return true;
      }
    }
    
    if (_isInitialized) {
      debugPrint('? SDK j� inicializado');
      return true;
    }
    
    if (_isLoading) {
      debugPrint('? SDK j� est� sendo inicializado, aguardando...');
      // Aguardar inicializa��o em andamento COM TIMEOUT
      int waitCount = 0;
      const maxWait = 300; // 30 segundos m�ximo (300 x 100ms)
      await Future.doWhile(() async {
        await Future.delayed(const Duration(milliseconds: 100));
        waitCount++;
        if (waitCount >= maxWait) {
          debugPrint('? TIMEOUT esperando inicializa��o! For�ando reset...');
          _isLoading = false; // For�ar reset do estado
          return false; // Sair do loop
        }
        return _isLoading && !_isInitialized;
      });
      
      if (_isInitialized) {
        return true;
      }
      // Se deu timeout, continuar com nova inicializa��o
      debugPrint('?? Continuando com nova inicializa��o ap�s timeout...');
    }
    
    _setLoading(true);
    _setError(null);
    
    debugPrint('? Iniciando Breez SDK Spark...');

    try {
      // Initialize RustLib (flutter_rust_bridge) if not already initialized
      if (!_rustLibInitialized) {
        debugPrint('?? Inicializando flutter_rust_bridge...');
        await spark.BreezSdkSparkLib.init();
        _rustLibInitialized = true;
        debugPrint('? flutter_rust_bridge inicializado');
      }

      // CR�TICO: A seed do Breez DEVE ser vinculada ao usu�rio Nostr!
      // Se o usu�rio logou com NIP-06 (seed), usamos a MESMA seed para o Breez.
      // Isso garante que: mesma conta Nostr = mesmo saldo Bitcoin = SEMPRE!
      
      if (mnemonic != null) {
        // Seed fornecida explicitamente (derivada da chave Nostr ou NIP-06)
        // USAR SEMPRE A SEED FORNECIDA - ela � determin�stica!
        _mnemonic = mnemonic;
        _isNewWallet = false;
        
        // Salvar a seed (se j� existir igual, n�o faz nada)
        await StorageService().saveBreezMnemonic(_mnemonic!);
        
        debugPrint('?? Usando seed FORNECIDA: ${_mnemonic!.split(' ').take(2).join(' ')}...');
      } else {
        // Buscar seed salva para este usu�rio
        debugPrint('');
        debugPrint('???????????????????????????????????????????????????????????');
        debugPrint('?? BREEZ: Buscando seed do usu�rio atual...');
        debugPrint('???????????????????????????????????????????????????????????');
        
        // BUSCA: Sempre com pubkey do usu�rio atual para evitar pegar seed de outro usu�rio
        final pubkey = await StorageService().getNostrPublicKey();
        String? savedMnemonic;
        
        if (pubkey != null) {
          debugPrint('   Pubkey: ${pubkey.substring(0, 16)}...');
          savedMnemonic = await StorageService().getBreezMnemonic(forPubkey: pubkey);
        } else {
          debugPrint('?? Nenhum pubkey encontrado! Seed n�o ser� carregada.');
        }
        
        if (savedMnemonic != null && savedMnemonic.isNotEmpty && savedMnemonic.split(' ').length == 12) {
          _mnemonic = savedMnemonic;
          _isNewWallet = false;
          debugPrint('? Seed EXISTENTE encontrada!');
          debugPrint('   Seed: ${savedMnemonic.split(' ').take(2).join(' ')}...');
        } else {
          // �LTIMA TENTATIVA: O getBreezMnemonic agora busca em 6 fontes diferentes
          // Se chegou aqui, realmente n�o existe seed
          debugPrint('');
          debugPrint('????????????????????????????????????????');
          debugPrint('?? NENHUMA SEED encontrada em NENHUM local!');
          debugPrint('   Gerando NOVA seed...');
          debugPrint('   Se voc� tinha saldo, precisa IMPORTAR a seed!');
          debugPrint('????????????????????????????????????????');
          debugPrint('');
          _mnemonic = bip39.generateMnemonic();
          await StorageService().saveBreezMnemonic(_mnemonic!);
          _isNewWallet = true;
          _seedRecoveryNeeded = true;
          debugPrint('?? Nova seed: ${_mnemonic!.split(' ').take(2).join(' ')}...');
        }
        debugPrint('???????????????????????????????????????????????????????????');
      }

      // DEBUG: Mostrar primeiras 2 palavras da seed para confirmar
      final seedWords = _mnemonic!.split(' ');
      debugPrint('?? SEED: ${seedWords[0]} ${seedWords[1]} ... (${seedWords.length} palavras)');

      // Create seed from mnemonic
      final seed = spark.Seed.mnemonic(mnemonic: _mnemonic!);
      
      // Get storage directory - �NICO por usu�rio Nostr!
      final appDir = await getApplicationDocumentsDirectory();
      final pubkey = await StorageService().getNostrPublicKey();
      final userDirSuffix = pubkey != null ? '_${pubkey.substring(0, 8)}' : '';
      final storageDir = '${appDir.path}/breez_spark$userDirSuffix';
      
      debugPrint('?? Storage dir: $storageDir');

      // Create config
      final network = BreezConfig.useMainnet ? spark.Network.mainnet : spark.Network.regtest;
      final config = spark.defaultConfig(network: network).copyWith(
        apiKey: BreezConfig.apiKey,
      );

      debugPrint('? Conectando ao Breez SDK ($network)...');
      
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
      
      // Sync wallet in background (n?o await para n?o bloquear)
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

  /// RESETAR SDK para novo usu�rio Nostr
  /// CR�TICO: Chamado quando o usu�rio faz login com outra conta Nostr
  /// Isso DESCONECTA o SDK e PERMITE nova inicializa��o com a seed do novo usu�rio
  Future<void> resetForNewUser() async {
    debugPrint('?? RESETANDO SDK para novo usu�rio Nostr...');
    
    // 1. Cancelar subscription de eventos
    if (_eventsSub != null) {
      await _eventsSub!.cancel();
      _eventsSub = null;
      debugPrint('? Event subscription cancelada');
    }
    
    // 2. Desconectar SDK atual
    if (_sdk != null) {
      try {
        await _sdk!.disconnect();
        debugPrint('? SDK desconectado');
      } catch (e) {
        debugPrint('?? Erro ao desconectar SDK (ignorando): $e');
      }
      _sdk = null;
    }
    
    // 3. Limpar estado - CR�TICO: permite nova inicializa��o
    _isInitialized = false;
    _isLoading = false;
    _error = null;
    _mnemonic = null;
    _lastPaymentId = null;
    _lastPaymentAmount = null;
    _isNewWallet = false;
    _seedRecoveryNeeded = false;
    
    debugPrint('? SDK resetado - pronto para novo usu�rio');
    notifyListeners();
  }
  
  /// REINICIALIZAR SDK com nova seed (for�ado)
  /// Usado quando o usu�rio restaura uma carteira diferente
  Future<bool> reinitializeWithNewSeed(String newMnemonic) async {
    debugPrint('?? REINICIALIZANDO SDK com nova seed...');
    
    // 1. Resetar SDK primeiro
    await resetForNewUser();
    
    // 2. Limpar storage directory antigo para for�ar resync
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final storageDir = Directory('${appDir.path}/breez_spark');
      if (await storageDir.exists()) {
        await storageDir.delete(recursive: true);
        debugPrint('??? Storage directory limpo');
      }
    } catch (e) {
      debugPrint('?? Erro ao limpar storage (ignorando): $e');
    }
    
    // 3. Salvar nova seed COM FOR�A (reinitialize � chamado intencionalmente)
    await StorageService().forceUpdateBreezMnemonic(newMnemonic);
    
    // 4. Reinicializar com a nova seed
    debugPrint('?? Reinicializando SDK com nova seed...');
    return await initialize(mnemonic: newMnemonic);
  }
  
  /// Force sync da carteira atual
  Future<void> forceSyncWallet() async {
    if (_sdk == null) {
      debugPrint('?? SDK n�o inicializado');
      return;
    }
    
    try {
      debugPrint('?? For�ando sincroniza��o da carteira...');
      await _sdk!.syncWallet(request: spark.SyncWalletRequest());
      
      final info = await _sdk!.getInfo(request: spark.GetInfoRequest());
      debugPrint('? Sincroniza��o for�ada conclu�da');
      debugPrint('?? Saldo ap�s sync: ${info.balanceSats} sats');
      
      notifyListeners();
    } catch (e) {
      debugPrint('? Erro ao for�ar sync: $e');
      _setError('Erro ao sincronizar: $e');
    }
  }

  /// Handle SDK events
  void _handleSdkEvent(spark.SdkEvent event) {
    debugPrint('?? Evento do SDK recebido: ${event.runtimeType}');
    
    if (event is spark.SdkEvent_PaymentSucceeded) {
      final payment = event.payment;
      debugPrint('?? PAGAMENTO RECEBIDO! Payment: ${payment.id}, Amount: ${payment.amount} sats');
      
      // Extrair paymentHash do pagamento para identifica��o precisa
      String? paymentHash;
      if (payment.details is spark.PaymentDetails_Lightning) {
        paymentHash = (payment.details as spark.PaymentDetails_Lightning).paymentHash;
        debugPrint('?? PaymentHash: $paymentHash');
      }
      
      // Salvar �ltimo pagamento
      _lastPaymentId = payment.id;
      _lastPaymentAmount = payment.amount.toInt();
      _lastPaymentHash = paymentHash;
      
      // CR�TICO: Persistir pagamento IMEDIATAMENTE para n�o perder
      _persistPayment(payment.id, payment.amount.toInt(), paymentHash: paymentHash);
      
      // CR�TICO: Chamar o callback se estiver registrado!
      // Isso permite que a tela de ordem atualize o status para "payment_received"
      if (onPaymentReceived != null) {
        debugPrint('?? Chamando callback onPaymentReceived com paymentHash!');
        onPaymentReceived!(payment.id, payment.amount.toInt(), paymentHash);
      } else {
        debugPrint('?? Pagamento recebido mas callback n�o registrado - a tela de ordem precisa estar aberta');
      }
      
      // Notificar listeners para atualizar UI
      notifyListeners();
    } else if (event is spark.SdkEvent_PaymentFailed) {
      debugPrint('? PAGAMENTO FALHOU! Payment: ${event.payment.id}');
    } else if (event is spark.SdkEvent_Synced) {
      debugPrint('?? Wallet sincronizada');
      // Verificar saldo ap�s sincroniza��o
      _checkBalanceAfterSync();
    } else if (event is spark.SdkEvent_UnclaimedDeposits) {
      // CR�TICO: H� dep�sitos on-chain n�o reivindicados!
      // Isso acontece quando algu�m envia BTC on-chain para o endere�o de swap
      final deposits = event.unclaimedDeposits;
      debugPrint('?? DEP�SITOS ON-CHAIN N�O REIVINDICADOS: ${deposits.length}');
      _processUnclaimedDepositsFromEvent(deposits);
    }
    
    notifyListeners();
  }
  
  /// Processar dep�sitos on-chain n�o reivindicados (vindos do evento)
  Future<void> _processUnclaimedDepositsFromEvent(List<spark.DepositInfo> deposits) async {
    if (_sdk == null || deposits.isEmpty) return;
    
    try {
      debugPrint('?? Processando ${deposits.length} dep�sitos pendentes!');
      
      for (final deposit in deposits) {
        // DepositInfo tem: txid, vout, amountSats, refundTx?, refundTxId?, claimError?
        debugPrint('   ?? Dep�sito: txid=${deposit.txid}, vout=${deposit.vout}, amount=${deposit.amountSats} sats');
        
        // Verificar se j� teve erro ao tentar claim
        // IMPORTANTE: Se o erro foi "feeExceeded", podemos tentar com fee maior!
        if (deposit.claimError != null) {
          final errorStr = deposit.claimError.toString();
          debugPrint('   ?? Dep�sito com erro anterior: $errorStr');
          
          // Se N�O for erro de fee, pular
          if (!errorStr.contains('FeeExceed')) {
            debugPrint('   ? Erro n�o recuper�vel, pulando...');
            continue;
          }
          debugPrint('   ?? Erro de fee - tentando com fee maior...');
        }
        
        // Processar/claim o dep�sito
        // O SDK s� emite SdkEvent_UnclaimedDeposits quando h� confirma��es suficientes
        try {
          debugPrint('   ? Reivindicando dep�sito de ${deposit.amountSats} sats...');
          
          // Permitir at� 25% do valor como taxa m�xima (m�nimo 500 sats)
          final maxFeeSats = deposit.amountSats ~/ BigInt.from(4);
          final feeLimit = maxFeeSats < BigInt.from(500) ? BigInt.from(500) : maxFeeSats;
          debugPrint('   ?? Fee m�ximo permitido: $feeLimit sats');
          
          final response = await _sdk!.claimDeposit(
            request: spark.ClaimDepositRequest(
              txid: deposit.txid,
              vout: deposit.vout,
              maxFee: spark.Fee.fixed(amount: feeLimit),
            ),
          );
          
          debugPrint('   ? Dep�sito reivindicado! Payment ID: ${response.payment.id}');
          
          // Persistir como pagamento recebido
          _persistPayment(response.payment.id, response.payment.amount.toInt());
          
        } catch (e) {
          debugPrint('   ?? Erro ao reivindicar dep�sito: $e');
        }
      }
      
      // For�ar sync ap�s processar dep�sitos
      await forceSyncWallet();
      
    } catch (e) {
      debugPrint('? Erro ao processar dep�sitos: $e');
    }
  }
  
  /// Persistir pagamento no SharedPreferences para nunca perder
  Future<void> _persistPayment(String paymentId, int amountSats, {String? paymentHash}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // Carregar lista existente
      final paymentsJson = prefs.getString('lightning_payments') ?? '[]';
      final List<dynamic> payments = json.decode(paymentsJson);
      
      // Verificar se j� existe
      if (payments.any((p) => p['id'] == paymentId)) {
        debugPrint('?? Pagamento $paymentId j� registrado');
        return;
      }
      
      // Adicionar novo pagamento com paymentHash para identifica��o precisa
      payments.add({
        'id': paymentId,
        'amountSats': amountSats,
        'paymentHash': paymentHash,  // IMPORTANTE para reconcilia��o precisa
        'receivedAt': DateTime.now().toIso8601String(),
        'reconciled': false,
      });
      
      await prefs.setString('lightning_payments', json.encode(payments));
      debugPrint('?? PAGAMENTO PERSISTIDO: $paymentId ($amountSats sats, hash: ${paymentHash?.substring(0, 8) ?? "N/A"}...)');
    } catch (e) {
      debugPrint('? ERRO CR�TICO ao persistir pagamento: $e');
    }
  }
  
  /// Recuperar pagamentos n�o reconciliados (para reconcilia��o manual)
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
      debugPrint('? Erro ao recuperar pagamentos: $e');
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
        debugPrint('? Pagamento $paymentId marcado como reconciliado');
      }
    } catch (e) {
      debugPrint('? Erro ao marcar pagamento: $e');
    }
  }
  
  /// Verificar saldo ap�s sincroniza��o
  Future<void> _checkBalanceAfterSync() async {
    if (_sdk == null) return;
    try {
      final info = await _sdk!.getInfo(request: spark.GetInfoRequest());
      debugPrint('?? Saldo atual: ${info.balanceSats} sats');
    } catch (e) {
      debugPrint('?? Erro ao verificar saldo: $e');
    }
  }
  
  /// Limpar �ltimo pagamento (ap�s ser processado)
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
      
      // Get initial balance - LOG DETALHADO
      final info = await _sdk!.getInfo(request: spark.GetInfoRequest());
      debugPrint('???????????????????????????????????????');
      debugPrint('?? INFO DO SDK BREEZ SPARK:');
      debugPrint('   balanceSats: ${info.balanceSats}');
      debugPrint('???????????????????????????????????????');
      
      // Listar TODOS os pagamentos para debug
      final paymentsResp = await _sdk!.listPayments(
        request: spark.ListPaymentsRequest(limit: 100),
      );
      debugPrint('?? HIST�RICO DE PAGAMENTOS (${paymentsResp.payments.length} total):');
      for (var p in paymentsResp.payments) {
        debugPrint('   [${p.status}] ${p.amount} sats - ${p.paymentType} - ${p.id.substring(0, 16)}...');
      }
      if (paymentsResp.payments.isEmpty) {
        debugPrint('   ?? NENHUM PAGAMENTO NO HIST�RICO!');
        debugPrint('   ?? Isso significa que esta seed NUNCA recebeu fundos no Breez!');
      }
      debugPrint('???????????????????????????????????????');
      
      // Verificar pagamentos persistidos localmente (que deveriam ter sido recebidos)
      final prefs = await SharedPreferences.getInstance();
      final localPayments = prefs.getString('lightning_payments') ?? '[]';
      debugPrint('?? PAGAMENTOS PERSISTIDOS LOCALMENTE: $localPayments');
      
      notifyListeners();
    } catch (e) {
      debugPrint('? Erro ao sincronizar carteira: $e');
    }
  }

  /// Create a Lightning invoice
  Future<Map<String, dynamic>?> createInvoice({
    required int amountSats,
    String? description,
  }) async {
    // Garantir que SDK est� inicializado
    if (!_isInitialized) {
      debugPrint('?? SDK n�o inicializado, tentando inicializar...');
      final success = await initialize();
      if (!success) {
        _setError('Falha ao inicializar SDK');
        return {'success': false, 'error': 'Falha ao inicializar SDK'};
      }
    }
    
    if (_sdk == null) {
      _setError('SDK n�o dispon�vel ap�s inicializa��o');
      return {'success': false, 'error': 'SDK n�o dispon�vel'};
    }

    _setLoading(true);
    _setError(null);
    
    debugPrint('? Criando invoice de $amountSats sats...');
    debugPrint('?? Descri��o: ${description ?? "Pagamento Bro"}');

    // Retry logic para erros transientes do SDK (como RangeError)
    int retries = 0;
    const maxRetries = 3;
    
    while (retries < maxRetries) {
      try {
        // NOTA: Removido syncWallet antes de criar invoice para acelerar
        // O sync � feito periodicamente em background
        
        final resp = await _sdk!.receivePayment(
          request: spark.ReceivePaymentRequest(
            paymentMethod: spark.ReceivePaymentMethod.bolt11Invoice(
              description: description ?? 'Pagamento Bro',
              amountSats: BigInt.from(amountSats),
            ),
          ),
        );

        final bolt11 = resp.paymentRequest;
        debugPrint('? Invoice BOLT11 criado: ${bolt11.substring(0, 50)}...');

        // Try to parse to extract payment hash for tracking
        String? paymentHash;
        try {
          final parsed = await _sdk!.parse(input: bolt11);
          if (parsed is spark.InputType_Bolt11Invoice) {
            paymentHash = parsed.field0.paymentHash;
            debugPrint('?? Payment Hash: $paymentHash');
          }
        } catch (e) {
          debugPrint('?? Erro ao extrair payment hash: $e');
          // Continua mesmo sem payment hash - n�o � cr�tico
        }

        _setLoading(false);
        return {
          'success': true,
          'bolt11': bolt11,  // Chave esperada pelo wallet_screen
          'invoice': bolt11, // Alias para compatibilidade
          'paymentHash': paymentHash,
          'receiver': 'Breez Spark Wallet',
        };
      } catch (e) {
        retries++;
        final isRangeError = e.toString().contains('RangeError');
        
        debugPrint('?? Tentativa $retries/$maxRetries falhou: $e');
        
        if (isRangeError && retries < maxRetries) {
          // RangeError � erro transiente do SDK - tentar novamente ap�s delay
          debugPrint('?? RangeError detectado - aguardando 500ms antes de retry...');
          await Future.delayed(const Duration(milliseconds: 500));
          continue;
        }
        
        if (retries >= maxRetries) {
          final errMsg = 'Erro ao criar invoice ap�s $maxRetries tentativas: $e';
          _setError(errMsg);
          debugPrint('? $errMsg');
          _setLoading(false);
          return {'success': false, 'error': errMsg};
        }
      }
    }
    
    _setLoading(false);
    return {'success': false, 'error': 'Erro desconhecido ao criar invoice'};
  }

  /// Check payment status by payment hash
  Future<Map<String, dynamic>> checkPaymentStatus(String paymentHash) async {
    if (!_isInitialized || _sdk == null) {
      return {'paid': false, 'error': 'SDK n?o inicializado'};
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
  
  /// Parseia uma invoice BOLT11 e extrai informa��es como paymentHash
  Future<Map<String, dynamic>?> parseInvoice(String bolt11) async {
    if (!_isInitialized || _sdk == null) {
      debugPrint('?? SDK n�o inicializado para parsear invoice');
      return null;
    }

    try {
      final parsed = await _sdk!.parse(input: bolt11);
      
      if (parsed is spark.InputType_Bolt11Invoice) {
        return {
          'paymentHash': parsed.field0.paymentHash,
          'amountSats': parsed.field0.amountMsat != null 
              ? (parsed.field0.amountMsat! ~/ BigInt.from(1000)).toInt()
              : null,
          'description': parsed.field0.description,
          'expiry': parsed.field0.expiry,
        };
      }
      
      debugPrint('?? Input n�o � uma invoice BOLT11 v�lida');
      return null;
    } catch (e) {
      debugPrint('?? Erro ao parsear invoice: $e');
      return null;
    }
  }
  
  /// DIAGN�STICO: Lista todos os pagamentos da carteira para verificar quais ordens foram pagas
  Future<List<Map<String, dynamic>>> getAllPayments() async {
    if (!_isInitialized || _sdk == null) {
      debugPrint('? SDK n�o inicializado para diagn�stico');
      return [];
    }

    try {
      await _sdk!.syncWallet(request: spark.SyncWalletRequest());
      
      final resp = await _sdk!.listPayments(
        request: spark.ListPaymentsRequest(limit: 1000),
      );

      final payments = <Map<String, dynamic>>[];
      
      debugPrint('');
      debugPrint('?????????????????????????????????????????????????????????????????');
      debugPrint('?      DIAGN�STICO COMPLETO DE PAGAMENTOS DA CARTEIRA          ?');
      debugPrint('?????????????????????????????????????????????????????????????????');
      debugPrint('?  Total de pagamentos encontrados: ${resp.payments.length.toString().padLeft(3)}                       ?');
      debugPrint('?????????????????????????????????????????????????????????????????');
      debugPrint('');
      
      for (var p in resp.payments) {
        String? paymentHash;
        String direction = p.paymentType.toString().contains('receive') ? 'RECEBIDO' : 'ENVIADO';
        
        if (p.details is spark.PaymentDetails_Lightning) {
          final details = p.details as spark.PaymentDetails_Lightning;
          paymentHash = details.paymentHash;
        }
        
        final paymentInfo = {
          'id': p.id,
          'amount': p.amount.toInt(),
          'status': p.status.toString(),
          'type': p.paymentType.toString(),
          'direction': direction,
          'paymentHash': paymentHash ?? 'N/A',
        };
        
        payments.add(paymentInfo);
        
        final statusIcon = p.status == spark.PaymentStatus.completed ? '?' : '?';
        debugPrint('$statusIcon [$direction] ${p.amount} sats');
        debugPrint('   PaymentHash: ${paymentHash ?? "N/A"}');
        debugPrint('   Status: ${p.status}');
        debugPrint('');
      }
      
      if (payments.isEmpty) {
        debugPrint('?? NENHUM PAGAMENTO ENCONTRADO NESTA CARTEIRA!');
        debugPrint('   Isso pode significar:');
        debugPrint('   1. A seed est� correta mas nunca recebeu fundos');
        debugPrint('   2. A seed est� errada e deveria ser outra');
      }
      
      return payments;
    } catch (e) {
      debugPrint('? Erro no diagn�stico: $e');
      return [];
    }
  }
  
  /// DIAGN�STICO: Verifica uma lista de paymentHashes para ver quais foram pagos
  Future<Map<String, bool>> checkMultiplePayments(List<String> paymentHashes) async {
    if (!_isInitialized || _sdk == null) {
      debugPrint('? SDK n�o inicializado');
      return {};
    }

    try {
      final resp = await _sdk!.listPayments(
        request: spark.ListPaymentsRequest(limit: 1000),
      );

      // Criar mapa de paymentHash -> pago
      final results = <String, bool>{};
      
      // Extrair todos os paymentHashes da carteira
      final walletHashes = <String>{};
      for (var p in resp.payments) {
        if (p.details is spark.PaymentDetails_Lightning) {
          final hash = (p.details as spark.PaymentDetails_Lightning).paymentHash;
          if (p.status == spark.PaymentStatus.completed) {
            walletHashes.add(hash);
          }
        }
      }
      
      // Verificar quais dos hashes fornecidos est�o na carteira
      for (var hash in paymentHashes) {
        results[hash] = walletHashes.contains(hash);
      }
      
      debugPrint('');
      debugPrint('?? VERIFICA��O DE PAGAMENTOS:');
      for (var entry in results.entries) {
        final icon = entry.value ? '? PAGO' : '? N�O PAGO';
        debugPrint('   ${entry.key.substring(0, 16)}... ? $icon');
      }
      
      return results;
    } catch (e) {
      debugPrint('? Erro verificando pagamentos: $e');
      return {};
    }
  }
  
  /// Wait for payment to be received (blocking call with timeout)
  Future<Map<String, dynamic>> waitForPayment({
    required String paymentHash,
    int timeoutSeconds = 300, // 5 minutos
  }) async {
    if (!_isInitialized || _sdk == null) {
      return {'paid': false, 'error': 'SDK n?o inicializado'};
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
      return {'balance': 0, 'error': 'SDK n?o inicializado'};
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
      return {'success': false, 'error': 'SDK n?o inicializado'};
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

  /// RECUPERA��O: Listar e processar dep�sitos on-chain n�o reivindicados
  /// Use este m�todo para recuperar fundos que foram enviados mas n�o processados
  Future<Map<String, dynamic>> recoverUnclaimedDeposits() async {
    if (!_isInitialized || _sdk == null) {
      return {'success': false, 'error': 'SDK n�o inicializado', 'deposits': []};
    }

    try {
      debugPrint('?? RECUPERA��O: Buscando dep�sitos n�o reivindicados...');
      
      // 1. Sincronizar carteira primeiro
      await _sdk!.syncWallet(request: spark.SyncWalletRequest());
      debugPrint('? Carteira sincronizada');
      
      // 2. Listar dep�sitos n�o reivindicados
      final response = await _sdk!.listUnclaimedDeposits(
        request: const spark.ListUnclaimedDepositsRequest(),
      );
      
      final deposits = response.deposits;
      debugPrint('?? Encontrados ${deposits.length} dep�sitos n�o reivindicados');
      
      if (deposits.isEmpty) {
        // Verificar hist�rico de pagamentos para diagn�stico
        final payments = await _sdk!.listPayments(request: spark.ListPaymentsRequest());
        debugPrint('?? Hist�rico: ${payments.payments.length} pagamentos no total');
        for (final p in payments.payments.take(5)) {
          debugPrint('   - ${p.id}: ${p.amount} sats, status=${p.status}');
        }
        
        return {
          'success': true, 
          'message': 'Nenhum dep�sito pendente encontrado',
          'deposits': [],
          'totalPayments': payments.payments.length,
        };
      }
      
      // 3. Processar cada dep�sito
      int claimed = 0;
      int failed = 0;
      BigInt totalAmount = BigInt.zero;
      List<Map<String, dynamic>> processedDeposits = [];
      
      for (final deposit in deposits) {
        debugPrint('?? Dep�sito: txid=${deposit.txid}, vout=${deposit.vout}, amount=${deposit.amountSats} sats');
        
        // Verificar se j� teve erro ao tentar claim
        // IMPORTANTE: Se o erro foi "feeExceeded", podemos tentar com fee maior!
        bool shouldTry = true;
        if (deposit.claimError != null) {
          final errorStr = deposit.claimError.toString();
          debugPrint('   ?? Dep�sito com erro anterior: $errorStr');
          
          // Se N�O for erro de fee, registrar e pular
          if (!errorStr.contains('FeeExceed')) {
            debugPrint('   ? Erro n�o recuper�vel, pulando...');
            processedDeposits.add({
              'txid': deposit.txid,
              'vout': deposit.vout,
              'amount': deposit.amountSats.toString(),
              'status': 'error',
              'error': errorStr,
            });
            failed++;
            shouldTry = false;
          } else {
            debugPrint('   ?? Erro de fee - tentando com fee maior...');
          }
        }
        
        if (!shouldTry) continue;
        
        try {
          debugPrint('   ? Reivindicando dep�sito de ${deposit.amountSats} sats...');
          
          // Permitir at� 25% do valor como taxa m�xima (m�nimo 500 sats)
          final maxFeeSats = deposit.amountSats ~/ BigInt.from(4);
          final feeLimit = maxFeeSats < BigInt.from(500) ? BigInt.from(500) : maxFeeSats;
          debugPrint('   ?? Fee m�ximo permitido: $feeLimit sats');
          
          final claimResponse = await _sdk!.claimDeposit(
            request: spark.ClaimDepositRequest(
              txid: deposit.txid,
              vout: deposit.vout,
              maxFee: spark.Fee.fixed(amount: feeLimit),
            ),
          );
          
          debugPrint('   ? Dep�sito reivindicado! Payment ID: ${claimResponse.payment.id}');
          
          // Persistir como pagamento recebido
          _persistPayment(claimResponse.payment.id, claimResponse.payment.amount.toInt());
          
          processedDeposits.add({
            'txid': deposit.txid,
            'vout': deposit.vout,
            'amount': deposit.amountSats.toString(),
            'status': 'claimed',
            'paymentId': claimResponse.payment.id,
          });
          
          claimed++;
          totalAmount += deposit.amountSats;
          
        } catch (e) {
          debugPrint('   ? Erro ao reivindicar: $e');
          processedDeposits.add({
            'txid': deposit.txid,
            'vout': deposit.vout,
            'amount': deposit.amountSats.toString(),
            'status': 'failed',
            'error': e.toString(),
          });
          failed++;
        }
      }
      
      // 4. Sincronizar novamente para atualizar saldo
      await _sdk!.syncWallet(request: spark.SyncWalletRequest());
      final info = await _sdk!.getInfo(request: spark.GetInfoRequest());
      
      debugPrint('? RECUPERA��O COMPLETA: $claimed reivindicados, $failed falhas, saldo atual: ${info.balanceSats} sats');
      
      notifyListeners();
      
      return {
        'success': true,
        'claimed': claimed,
        'failed': failed,
        'totalAmount': totalAmount.toString(),
        'newBalance': info.balanceSats.toString(),
        'deposits': processedDeposits,
      };
      
    } catch (e) {
      debugPrint('? Erro na recupera��o: $e');
      return {'success': false, 'error': e.toString(), 'deposits': []};
    }
  }

  /// Pay a Lightning invoice (BOLT11) or LNURL/Lightning Address
  Future<Map<String, dynamic>?> payInvoice(String bolt11, {int? amountSats}) async {
    if (!_isInitialized || _sdk == null) {
      return {'success': false, 'error': 'SDK n�o inicializado'};
    }

    _setLoading(true);
    _setError(null);
    
    debugPrint('?? Pagando invoice...');
    debugPrint('   Input: ${bolt11.substring(0, bolt11.length > 50 ? 50 : bolt11.length)}...');
    if (amountSats != null) {
      debugPrint('   Amount (manual): $amountSats sats');
    }

    try {
      // Verificar se � Lightning Address ou LNURL
      final lowerInput = bolt11.toLowerCase();
      final isLnAddress = bolt11.contains('@') && bolt11.contains('.');
      final isLnurl = lowerInput.startsWith('lnurl');
      
      // Se for LNURL ou Lightning Address, precisa de valor
      if ((isLnAddress || isLnurl) && amountSats == null) {
        return {'success': false, 'error': 'Para Lightning Address/LNURL, informe o valor em sats'};
      }

      // Primeiro, decodificar invoice para ver o valor
      int? invoiceAmount;
      try {
        final parsed = await _sdk!.parse(input: bolt11);
        if (parsed is spark.InputType_Bolt11Invoice) {
          // amountMsat � BigInt? e em milisat, converter para sats
          final amountMsat = parsed.field0.amountMsat;
          if (amountMsat != null) {
            invoiceAmount = (amountMsat ~/ BigInt.from(1000)).toInt();
          }
          debugPrint('?? Valor da invoice: $invoiceAmount sats');
        } else {
          // Para outros tipos, usa amountSats se fornecido
          debugPrint('?? Tipo de input n�o � BOLT11, usando amountSats se fornecido');
          invoiceAmount = amountSats;
        }
      } catch (e) {
        debugPrint('?? N�o foi poss�vel decodificar invoice: $e');
      }

      // Verificar saldo antes de enviar
      final balanceInfo = await getBalance();
      final currentBalance = int.tryParse(balanceInfo?['balance']?.toString() ?? '0') ?? 0;
      debugPrint('?? Saldo atual: $currentBalance sats');

      final requiredAmount = amountSats ?? invoiceAmount;
      if (requiredAmount != null && currentBalance < requiredAmount) {
        final errorMsg = 'Saldo insuficiente. Voc� tem $currentBalance sats mas precisa de $requiredAmount sats';
        _setError(errorMsg);
        debugPrint('? $errorMsg');
        return {
          'success': false, 
          'error': errorMsg,
          'errorType': 'INSUFFICIENT_FUNDS',
          'balance': currentBalance,
          'required': requiredAmount,
        };
      }

      // Step 1: Prepare payment
      final prepareReq = spark.PrepareSendPaymentRequest(
        paymentRequest: bolt11,
        amount: null, // SDK deduz do invoice BOLT11
        tokenIdentifier: null,
      );

      debugPrint('?? Preparando pagamento...');
      final prepareResp = await _sdk!.prepareSendPayment(request: prepareReq)
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () => throw TimeoutException('Timeout ao preparar pagamento (30s)'),
          );
      debugPrint('? Pagamento preparado');

      // Step 2: Send payment (com timeout de 60s para dar tempo ao roteamento)
      final sendReq = spark.SendPaymentRequest(
        prepareResponse: prepareResp,
        options: null,
      );

      debugPrint('?? Enviando pagamento... (aguarde at� 60s para roteamento)');
      final resp = await _sdk!.sendPayment(request: sendReq)
          .timeout(
            const Duration(seconds: 60),
            onTimeout: () => throw TimeoutException('Timeout ao enviar pagamento (60s). A transa��o pode ainda estar em processamento.'),
          );

      debugPrint('? Pagamento enviado!');
      debugPrint('   Payment ID: ${resp.payment.id}');
      debugPrint('   Amount: ${resp.payment.amount} sats');
      debugPrint('   Status: ${resp.payment.status}');

      String? paymentHash;
      if (resp.payment.details is spark.PaymentDetails_Lightning) {
        paymentHash = (resp.payment.details as spark.PaymentDetails_Lightning).paymentHash;
      }

      // NOTIFICAR callback de pagamento enviado (para reconcilia��o autom�tica)
      if (onPaymentSent != null) {
        debugPrint('?? Chamando callback onPaymentSent para reconcilia��o autom�tica');
        onPaymentSent!(resp.payment.id, resp.payment.amount.toInt(), paymentHash);
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
      } else if (errMsg.contains('TimeoutException') || errMsg.contains('timeout') || errMsg.contains('Timeout')) {
        errMsg = 'O pagamento est� demorando mais do que o esperado. Verifique se voc� tem saldo suficiente e se a carteira de destino est� online. A transa��o pode ainda completar em alguns minutos.';
      } else if (errMsg.contains('route') || errMsg.contains('Route') || errMsg.contains('path') || errMsg.contains('Path')) {
        errMsg = 'N�o foi poss�vel encontrar rota para pagamento. Isso pode acontecer se o destino est� offline ou sem liquidez.';
      } else if (errMsg.contains('expired') || errMsg.contains('Expired')) {
        errMsg = 'Invoice expirada. Solicite uma nova.';
      } else if (errMsg.contains('unsupported') || errMsg.contains('Unsupported') ||
                 errMsg.contains('payment method') || errMsg.contains('PaymentMethod')) {
        errMsg = 'Tipo de pagamento n�o suportado. Use uma invoice Lightning (BOLT11) v�lida que comece com "lnbc" ou "lntb".';
      } else if (errMsg.contains('invalid') || errMsg.contains('Invalid')) {
        errMsg = 'Invoice inv�lida. Verifique se copiou corretamente.';
      } else if (errMsg.contains('parse') || errMsg.contains('Parse')) {
        errMsg = 'N�o foi poss�vel interpretar o c�digo. Use uma invoice Lightning v�lida.';
      } else if (errMsg.contains('time lock') || errMsg.contains('time_lock') || errMsg.contains('timelock')) {
        errMsg = 'Fundos temporariamente bloqueados. Aguarde alguns minutos e tente novamente. Se persistir, sincronize a carteira em Configura��es.';
      } else if (errMsg.contains('sparkError') || errMsg.contains('SdkError')) {
        errMsg = 'Erro na rede Lightning. Verifique sua conex�o e tente novamente.';
      }
      
      _setError(errMsg);
      debugPrint('? Erro ao pagar: $errMsg');
      debugPrint('   Erro original: ${e.toString()}');
      return {'success': false, 'error': errMsg};
    } finally {
      _setLoading(false);
    }
  }

  /// Decode a Lightning invoice to get details before paying
  Future<Map<String, dynamic>?> decodeInvoice(String bolt11) async {
    if (!_isInitialized || _sdk == null) {
      return {'success': false, 'error': 'SDK n?o inicializado'};
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

      return {'success': false, 'error': 'Invoice inv?lida'};
    } catch (e) {
      return {'success': false, 'error': 'Erro ao decodificar invoice: $e'};
    }
  }

  /// List payment history with full details
  Future<List<Map<String, dynamic>>> listPayments() async {
    if (!_isInitialized || _sdk == null) {
      debugPrint('?? listPayments: SDK n�o inicializado');
      return [];
    }

    try {
      debugPrint('?? Buscando hist�rico de pagamentos...');
      final resp = await _sdk!.listPayments(
        request: spark.ListPaymentsRequest(),
      );

      debugPrint('?? Total de pagamentos no SDK: ${resp.payments.length}');
      
      for (final p in resp.payments) {
        debugPrint('   ?? Payment: ${p.id.substring(0, 16)}... amount=${p.amount} status=${p.status}');
        // Log dos detalhes para descobrir campos dispon�veis
        if (p.details is spark.PaymentDetails_Lightning) {
          final details = p.details as spark.PaymentDetails_Lightning;
          debugPrint('      ? Lightning: hash=${details.paymentHash?.substring(0, 16) ?? "null"}... description=${details.description ?? "null"}');
        }
      }

      return resp.payments.map((payment) {
        String? paymentHash;
        String? description;
        DateTime? timestamp;
        
        // Extrair timestamp do pagamento (se dispon�vel)
        // O SDK pode retornar timestamp como BigInt (segundos desde epoch)
        try {
          if (payment.timestamp != null) {
            // timestamp � BigInt, converter para int em segundos
            final timestampSecs = payment.timestamp!.toInt();
            timestamp = DateTime.fromMillisecondsSinceEpoch(timestampSecs * 1000);
          }
        } catch (e) {
          debugPrint('?? Erro ao converter timestamp: $e');
        }
        
        // Extrair detalhes espec�ficos do tipo Lightning
        if (payment.details is spark.PaymentDetails_Lightning) {
          final details = payment.details as spark.PaymentDetails_Lightning;
          paymentHash = details.paymentHash;
          description = details.description;
        }
        
        // Determinar dire��o (recebido ou enviado)
        final paymentTypeStr = payment.paymentType.toString().toLowerCase();
        final isReceived = paymentTypeStr.contains('receive');
        
        // amount � BigInt no SDK
        final amountSats = payment.amount.toInt();
        
        return {
          'id': payment.id,
          'paymentType': payment.paymentType.toString(),
          'type': isReceived ? 'received' : 'sent',
          'direction': isReceived ? 'incoming' : 'outgoing',
          'status': payment.status.toString(),
          'amount': amountSats,
          'amountSats': amountSats,
          'paymentHash': paymentHash,
          'description': description ?? '',  // NOVO: Incluir descri��o
          'timestamp': timestamp,
          'createdAt': timestamp,
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
      debugPrint('? Erro ao obter info do n?: $e');
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

  /// Diagn�stico completo do SDK para debug
  Future<Map<String, dynamic>> getFullDiagnostics() async {
    final diagnostics = <String, dynamic>{
      'timestamp': DateTime.now().toIso8601String(),
      'isInitialized': _isInitialized,
      'isLoading': _isLoading,
      'sdkAvailable': _sdk != null,
      'isNewWallet': _isNewWallet,
      'seedRecoveryNeeded': _seedRecoveryNeeded,
    };
    
    try {
      // Seed info (apenas tamanho, n�o expor!)
      final pubkey = await StorageService().getNostrPublicKey();
      diagnostics['nostrPubkey'] = pubkey?.substring(0, 16) ?? 'null';
      
      final seed = await StorageService().getBreezMnemonic();
      diagnostics['seedWordCount'] = seed?.split(' ').length ?? 0;
      diagnostics['seedFirst2Words'] = seed != null ? '${seed.split(' ')[0]} ${seed.split(' ')[1]}' : 'null';
      
      // Storage dir
      final appDir = await getApplicationDocumentsDirectory();
      final userDirSuffix = pubkey != null ? '_${pubkey.substring(0, 8)}' : '';
      final storageDir = '${appDir.path}/breez_spark$userDirSuffix';
      diagnostics['storageDir'] = storageDir;
      
      // Verificar se diret�rio existe
      final dir = Directory(storageDir);
      diagnostics['storageDirExists'] = await dir.exists();
      
      // NOVO: Listar todas as seeds armazenadas para debug
      final allSeeds = await StorageService().debugListAllStoredSeeds();
      diagnostics['totalSeedsFound'] = allSeeds.length;
      diagnostics['allSeeds'] = allSeeds;
      
      if (_sdk != null) {
        // Sync primeiro
        await _sdk!.syncWallet(request: spark.SyncWalletRequest());
        
        // Info do SDK
        final info = await _sdk!.getInfo(request: spark.GetInfoRequest());
        diagnostics['balanceSats'] = info.balanceSats.toInt();
        
        // Pagamentos (resp.payments � a lista)
        final resp = await _sdk!.listPayments(
          request: spark.ListPaymentsRequest(
            limit: 50,
          ),
        );
        final paymentsList = resp.payments;
        diagnostics['totalPayments'] = paymentsList.length;
        
        // Listar �ltimos 5 pagamentos
        final paymentList = <Map<String, dynamic>>[];
        for (var i = 0; i < paymentsList.length && i < 5; i++) {
          final p = paymentsList[i];
          paymentList.add({
            'id': p.id.substring(0, 16),
            'amount': p.amount.toInt(),
            'status': p.status.toString(),
          });
        }
        diagnostics['recentPayments'] = paymentList;
      }
    } catch (e) {
      diagnostics['error'] = e.toString();
    }
    
    debugPrint('?? DIAGN�STICO COMPLETO:');
    diagnostics.forEach((k, v) => debugPrint('   $k: $v'));
    
    return diagnostics;
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
      debugPrint('?? Breez SDK desconectado');
    }
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}
