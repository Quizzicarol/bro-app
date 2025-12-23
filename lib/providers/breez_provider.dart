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
  
  // Estado de segurança da carteira
  bool _isNewWallet = false;  // True se carteira acabou de ser criada
  bool _seedRecoveryNeeded = false;  // True se houve problema ao recuperar seed
  
  // Callback para notificar pagamentos recebidos
  // Parâmetros: paymentId, amountSats, paymentHash (opcional)
  Function(String paymentId, int amountSats, String? paymentHash)? onPaymentReceived;
  String? _lastPaymentId;
  int? _lastPaymentAmount;
  String? _lastPaymentHash;  // PaymentHash do último pagamento para verificação precisa
  
  spark.BreezSdk? get sdk => _sdk;
  bool get isInitialized => _isInitialized;
  bool get isLoading => _isLoading;
  String? get error => _error;
  String? get mnemonic => _mnemonic;
  String? get lastPaymentId => _lastPaymentId;
  int? get lastPaymentAmount => _lastPaymentAmount;
  String? get lastPaymentHash => _lastPaymentHash;  // Getter para verificação
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
      debugPrint('🚫 Breez SDK não suportado nesta plataforma (Windows/Web/Linux)');
      _isInitialized = false;
      _setLoading(false);
      return false;
    }
    
    // Se já está inicializado, verificar se a seed é a mesma
    if (_isInitialized && mnemonic != null && _mnemonic != null) {
      // Comparar primeiras 2 palavras para ver se é a mesma seed
      final currentWords = _mnemonic!.split(' ').take(2).join(' ');
      final newWords = mnemonic.split(' ').take(2).join(' ');
      
      if (currentWords != newWords) {
        debugPrint('⚠️ SDK inicializado com seed DIFERENTE!');
        debugPrint('   Atual: $currentWords...');
        debugPrint('   Nova: $newWords...');
        debugPrint('🔄 Reinicializando com seed correta...');
        
        // Forçar reinicialização com a nova seed
        return await reinitializeWithNewSeed(mnemonic);
      } else {
        debugPrint('✅ SDK já inicializado com a seed correta');
        return true;
      }
    }
    
    if (_isInitialized) {
      debugPrint('✅ SDK já inicializado');
      return true;
    }
    
    if (_isLoading) {
      debugPrint('⏳ SDK já está sendo inicializado, aguardando...');
      // Aguardar inicialização em andamento
      await Future.doWhile(() async {
        await Future.delayed(const Duration(milliseconds: 100));
        return _isLoading && !_isInitialized;
      });
      return _isInitialized;
    }
    
    _setLoading(true);
    _setError(null);
    
    debugPrint('⚡ Iniciando Breez SDK Spark...');

    try {
      // Initialize RustLib (flutter_rust_bridge) if not already initialized
      if (!_rustLibInitialized) {
        debugPrint('🔧 Inicializando flutter_rust_bridge...');
        await spark.BreezSdkSparkLib.init();
        _rustLibInitialized = true;
        debugPrint('✅ flutter_rust_bridge inicializado');
      }

      // CRÍTICO: A seed do Breez DEVE ser vinculada ao usuário Nostr!
      // Se o usuário logou com NIP-06 (seed), usamos a MESMA seed para o Breez.
      // Isso garante que: mesma conta Nostr = mesmo saldo Bitcoin = SEMPRE!
      
      if (mnemonic != null) {
        // Seed fornecida explicitamente (recuperação manual ou NIP-06)
        // CRÍTICO: Verificar se já existe uma seed para este usuário
        final existingSeed = await StorageService().getBreezMnemonic();
        
        if (existingSeed != null && existingSeed.isNotEmpty && existingSeed.split(' ').length == 12) {
          // JÁ EXISTE seed - usar a EXISTENTE, não sobrescrever!
          final existingWords = existingSeed.split(' ').take(2).join(' ');
          final newWords = mnemonic.split(' ').take(2).join(' ');
          
          if (existingWords != newWords) {
            debugPrint('⚠️ CONFLITO DE SEEDS DETECTADO!');
            debugPrint('   Seed existente: $existingWords...');
            debugPrint('   Seed fornecida: $newWords...');
            debugPrint('   USANDO SEED EXISTENTE para preservar fundos!');
            debugPrint('   (Para mudar, vá em Configurações > Backup NIP-06)');
          }
          _mnemonic = existingSeed;
          _isNewWallet = false;
          debugPrint('🔑 Usando seed EXISTENTE do usuário');
        } else {
          // Não existe seed - salvar a nova (SEM forceOverwrite para proteger)
          _mnemonic = mnemonic;
          // Verificar novamente se existe seed (proteção extra)
          final doubleCheck = await StorageService().getBreezMnemonic();
          if (doubleCheck == null || doubleCheck.isEmpty) {
            await StorageService().saveBreezMnemonic(_mnemonic!);
            debugPrint('🔑 Primeira seed salva para este usuário');
          } else {
            _mnemonic = doubleCheck;
            debugPrint('🔑 Seed já existia, usando ela');
          }
          _isNewWallet = false;
        }
      } else {
        // Buscar seed salva para este usuário
        debugPrint('🔍 Buscando seed do usuário atual...');
        final savedMnemonic = await StorageService().getBreezMnemonic();
        
        if (savedMnemonic != null && savedMnemonic.isNotEmpty && savedMnemonic.split(' ').length == 12) {
          _mnemonic = savedMnemonic;
          _isNewWallet = false;
          debugPrint('✅ Seed EXISTENTE encontrada para este usuário!');
        } else {
          // ATENÇÃO: Nenhuma seed salva para este usuário!
          // NÃO geramos automaticamente - isso causaria perda de fundos!
          // O usuário PRECISA restaurar via NIP-06 ou configurar uma seed.
          debugPrint('⚠️ ATENÇÃO: Nenhuma seed encontrada para este usuário!');
          debugPrint('⚠️ Uma nova seed será gerada - se você tinha fundos em outra seed,');
          debugPrint('⚠️ vá em Configurações > Backup NIP-06 para restaurar!');
          
          // ÚLTIMA VERIFICAÇÃO: Buscar seed com pubkey explícito
          final pubkey = await StorageService().getNostrPublicKey();
          if (pubkey != null) {
            final seedByPubkey = await StorageService().getBreezMnemonic(forPubkey: pubkey);
            if (seedByPubkey != null && seedByPubkey.isNotEmpty && seedByPubkey.split(' ').length == 12) {
              _mnemonic = seedByPubkey;
              _isNewWallet = false;
              debugPrint('✅ Seed encontrada via pubkey: ${seedByPubkey.split(' ').take(2).join(' ')}...');
            } else {
              // Realmente não existe seed - gerar nova
              _mnemonic = bip39.generateMnemonic();
              await StorageService().saveBreezMnemonic(_mnemonic!);
              _isNewWallet = true;
              _seedRecoveryNeeded = true;
              debugPrint('🆕 Nova seed gerada (nenhuma encontrada)');
            }
          } else {
            // Sem pubkey - gerar nova
            _mnemonic = bip39.generateMnemonic();
            await StorageService().saveBreezMnemonic(_mnemonic!);
            _isNewWallet = true;
            _seedRecoveryNeeded = true;
            debugPrint('🆕 Nova seed gerada (sem pubkey)');
          }
        }
      }

      // DEBUG: Mostrar primeiras 2 palavras da seed para confirmar
      final seedWords = _mnemonic!.split(' ');
      debugPrint('🔐 SEED: ${seedWords[0]} ${seedWords[1]} ... (${seedWords.length} palavras)');

      // Create seed from mnemonic
      final seed = spark.Seed.mnemonic(mnemonic: _mnemonic!);
      
      // Get storage directory - ÚNICO por usuário Nostr!
      final appDir = await getApplicationDocumentsDirectory();
      final pubkey = await StorageService().getNostrPublicKey();
      final userDirSuffix = pubkey != null ? '_${pubkey.substring(0, 8)}' : '';
      final storageDir = '${appDir.path}/breez_spark$userDirSuffix';
      
      debugPrint('📁 Storage dir: $storageDir');

      // Create config
      final network = BreezConfig.useMainnet ? spark.Network.mainnet : spark.Network.regtest;
      final config = spark.defaultConfig(network: network).copyWith(
        apiKey: BreezConfig.apiKey,
      );

      debugPrint('⚡ Conectando ao Breez SDK ($network)...');
      
      // Connect to SDK
      _sdk = await spark.connect(
        request: spark.ConnectRequest(
          config: config,
          seed: seed,
          storageDir: storageDir,
        ),
      );

      _isInitialized = true;
      debugPrint('✅ Breez SDK Spark inicializado com sucesso!');
      
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

  /// RESETAR SDK para novo usuário Nostr
  /// CRÍTICO: Chamado quando o usuário faz login com outra conta Nostr
  /// Isso DESCONECTA o SDK e PERMITE nova inicialização com a seed do novo usuário
  Future<void> resetForNewUser() async {
    debugPrint('🔄 RESETANDO SDK para novo usuário Nostr...');
    
    // 1. Cancelar subscription de eventos
    if (_eventsSub != null) {
      await _eventsSub!.cancel();
      _eventsSub = null;
      debugPrint('✅ Event subscription cancelada');
    }
    
    // 2. Desconectar SDK atual
    if (_sdk != null) {
      try {
        await _sdk!.disconnect();
        debugPrint('✅ SDK desconectado');
      } catch (e) {
        debugPrint('⚠️ Erro ao desconectar SDK (ignorando): $e');
      }
      _sdk = null;
    }
    
    // 3. Limpar estado - CRÍTICO: permite nova inicialização
    _isInitialized = false;
    _isLoading = false;
    _error = null;
    _mnemonic = null;
    _lastPaymentId = null;
    _lastPaymentAmount = null;
    _isNewWallet = false;
    _seedRecoveryNeeded = false;
    
    debugPrint('✅ SDK resetado - pronto para novo usuário');
    notifyListeners();
  }
  
  /// REINICIALIZAR SDK com nova seed (forçado)
  /// Usado quando o usuário restaura uma carteira diferente
  Future<bool> reinitializeWithNewSeed(String newMnemonic) async {
    debugPrint('🔄 REINICIALIZANDO SDK com nova seed...');
    
    // 1. Resetar SDK primeiro
    await resetForNewUser();
    
    // 2. Limpar storage directory antigo para forçar resync
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final storageDir = Directory('${appDir.path}/breez_spark');
      if (await storageDir.exists()) {
        await storageDir.delete(recursive: true);
        debugPrint('🗑️ Storage directory limpo');
      }
    } catch (e) {
      debugPrint('⚠️ Erro ao limpar storage (ignorando): $e');
    }
    
    // 3. Salvar nova seed COM FORÇA (reinitialize é chamado intencionalmente)
    await StorageService().forceUpdateBreezMnemonic(newMnemonic);
    
    // 4. Reinicializar com a nova seed
    debugPrint('🔄 Reinicializando SDK com nova seed...');
    return await initialize(mnemonic: newMnemonic);
  }
  
  /// Force sync da carteira atual
  Future<void> forceSyncWallet() async {
    if (_sdk == null) {
      debugPrint('⚠️ SDK não inicializado');
      return;
    }
    
    try {
      debugPrint('🔄 Forçando sincronização da carteira...');
      await _sdk!.syncWallet(request: spark.SyncWalletRequest());
      
      final info = await _sdk!.getInfo(request: spark.GetInfoRequest());
      debugPrint('✅ Sincronização forçada concluída');
      debugPrint('💰 Saldo após sync: ${info.balanceSats} sats');
      
      notifyListeners();
    } catch (e) {
      debugPrint('❌ Erro ao forçar sync: $e');
      _setError('Erro ao sincronizar: $e');
    }
  }

  /// Handle SDK events
  void _handleSdkEvent(spark.SdkEvent event) {
    debugPrint('🔔 Evento do SDK recebido: ${event.runtimeType}');
    
    if (event is spark.SdkEvent_PaymentSucceeded) {
      final payment = event.payment;
      debugPrint('💰 PAGAMENTO RECEBIDO! Payment: ${payment.id}, Amount: ${payment.amount} sats');
      
      // Extrair paymentHash do pagamento para identificação precisa
      String? paymentHash;
      if (payment.details is spark.PaymentDetails_Lightning) {
        paymentHash = (payment.details as spark.PaymentDetails_Lightning).paymentHash;
        debugPrint('🔑 PaymentHash: $paymentHash');
      }
      
      // Salvar último pagamento
      _lastPaymentId = payment.id;
      _lastPaymentAmount = payment.amount.toInt();
      _lastPaymentHash = paymentHash;
      
      // CRÍTICO: Persistir pagamento IMEDIATAMENTE para não perder
      _persistPayment(payment.id, payment.amount.toInt(), paymentHash: paymentHash);
      
      // CRÍTICO: Chamar o callback se estiver registrado!
      // Isso permite que a tela de ordem atualize o status para "payment_received"
      if (onPaymentReceived != null) {
        debugPrint('🎉 Chamando callback onPaymentReceived com paymentHash!');
        onPaymentReceived!(payment.id, payment.amount.toInt(), paymentHash);
      } else {
        debugPrint('⚠️ Pagamento recebido mas callback não registrado - a tela de ordem precisa estar aberta');
      }
      
      // Notificar listeners para atualizar UI
      notifyListeners();
    } else if (event is spark.SdkEvent_PaymentFailed) {
      debugPrint('❌ PAGAMENTO FALHOU! Payment: ${event.payment.id}');
    } else if (event is spark.SdkEvent_Synced) {
      debugPrint('🔄 Wallet sincronizada');
      // Verificar saldo após sincronização
      _checkBalanceAfterSync();
    } else if (event is spark.SdkEvent_UnclaimedDeposits) {
      // CRÍTICO: Há depósitos on-chain não reivindicados!
      // Isso acontece quando alguém envia BTC on-chain para o endereço de swap
      final deposits = event.unclaimedDeposits;
      debugPrint('💎 DEPÓSITOS ON-CHAIN NÃO REIVINDICADOS: ${deposits.length}');
      _processUnclaimedDepositsFromEvent(deposits);
    }
    
    notifyListeners();
  }
  
  /// Processar depósitos on-chain não reivindicados (vindos do evento)
  Future<void> _processUnclaimedDepositsFromEvent(List<spark.DepositInfo> deposits) async {
    if (_sdk == null || deposits.isEmpty) return;
    
    try {
      debugPrint('💰 Processando ${deposits.length} depósitos pendentes!');
      
      for (final deposit in deposits) {
        // DepositInfo tem: txid, vout, amountSats, refundTx?, refundTxId?, claimError?
        debugPrint('   📦 Depósito: txid=${deposit.txid}, vout=${deposit.vout}, amount=${deposit.amountSats} sats');
        
        // Verificar se já teve erro ao tentar claim
        // IMPORTANTE: Se o erro foi "feeExceeded", podemos tentar com fee maior!
        if (deposit.claimError != null) {
          final errorStr = deposit.claimError.toString();
          debugPrint('   ⚠️ Depósito com erro anterior: $errorStr');
          
          // Se NÃO for erro de fee, pular
          if (!errorStr.contains('FeeExceed')) {
            debugPrint('   ❌ Erro não recuperável, pulando...');
            continue;
          }
          debugPrint('   🔄 Erro de fee - tentando com fee maior...');
        }
        
        // Processar/claim o depósito
        // O SDK só emite SdkEvent_UnclaimedDeposits quando há confirmações suficientes
        try {
          debugPrint('   ⚡ Reivindicando depósito de ${deposit.amountSats} sats...');
          
          // Permitir até 25% do valor como taxa máxima (mínimo 500 sats)
          final maxFeeSats = deposit.amountSats ~/ BigInt.from(4);
          final feeLimit = maxFeeSats < BigInt.from(500) ? BigInt.from(500) : maxFeeSats;
          debugPrint('   💰 Fee máximo permitido: $feeLimit sats');
          
          final response = await _sdk!.claimDeposit(
            request: spark.ClaimDepositRequest(
              txid: deposit.txid,
              vout: deposit.vout,
              maxFee: spark.Fee.fixed(amount: feeLimit),
            ),
          );
          
          debugPrint('   ✅ Depósito reivindicado! Payment ID: ${response.payment.id}');
          
          // Persistir como pagamento recebido
          _persistPayment(response.payment.id, response.payment.amount.toInt());
          
        } catch (e) {
          debugPrint('   ⚠️ Erro ao reivindicar depósito: $e');
        }
      }
      
      // Forçar sync após processar depósitos
      await forceSyncWallet();
      
    } catch (e) {
      debugPrint('❌ Erro ao processar depósitos: $e');
    }
  }
  
  /// Persistir pagamento no SharedPreferences para nunca perder
  Future<void> _persistPayment(String paymentId, int amountSats, {String? paymentHash}) async {
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
      
      // Adicionar novo pagamento com paymentHash para identificação precisa
      payments.add({
        'id': paymentId,
        'amountSats': amountSats,
        'paymentHash': paymentHash,  // IMPORTANTE para reconciliação precisa
        'receivedAt': DateTime.now().toIso8601String(),
        'reconciled': false,
      });
      
      await prefs.setString('lightning_payments', json.encode(payments));
      debugPrint('💾 PAGAMENTO PERSISTIDO: $paymentId ($amountSats sats, hash: ${paymentHash?.substring(0, 8) ?? "N/A"}...)');
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
      debugPrint('🔄 Sincronizando carteira em background...');
      await _sdk!.syncWallet(request: spark.SyncWalletRequest());
      debugPrint('✅ Carteira sincronizada');
      
      // Get initial balance - LOG DETALHADO
      final info = await _sdk!.getInfo(request: spark.GetInfoRequest());
      debugPrint('═══════════════════════════════════════');
      debugPrint('💰 INFO DO SDK BREEZ SPARK:');
      debugPrint('   balanceSats: ${info.balanceSats}');
      debugPrint('═══════════════════════════════════════');
      
      // Listar TODOS os pagamentos para debug
      final paymentsResp = await _sdk!.listPayments(
        request: spark.ListPaymentsRequest(limit: 100),
      );
      debugPrint('📋 HISTÓRICO DE PAGAMENTOS (${paymentsResp.payments.length} total):');
      for (var p in paymentsResp.payments) {
        debugPrint('   [${p.status}] ${p.amount} sats - ${p.paymentType} - ${p.id.substring(0, 16)}...');
      }
      if (paymentsResp.payments.isEmpty) {
        debugPrint('   ⚠️ NENHUM PAGAMENTO NO HISTÓRICO!');
        debugPrint('   ⚠️ Isso significa que esta seed NUNCA recebeu fundos no Breez!');
      }
      debugPrint('═══════════════════════════════════════');
      
      // Verificar pagamentos persistidos localmente (que deveriam ter sido recebidos)
      final prefs = await SharedPreferences.getInstance();
      final localPayments = prefs.getString('lightning_payments') ?? '[]';
      debugPrint('💾 PAGAMENTOS PERSISTIDOS LOCALMENTE: $localPayments');
      
      notifyListeners();
    } catch (e) {
      debugPrint('❌ Erro ao sincronizar carteira: $e');
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

  /// RECUPERAÇÃO: Listar e processar depósitos on-chain não reivindicados
  /// Use este método para recuperar fundos que foram enviados mas não processados
  Future<Map<String, dynamic>> recoverUnclaimedDeposits() async {
    if (!_isInitialized || _sdk == null) {
      return {'success': false, 'error': 'SDK não inicializado', 'deposits': []};
    }

    try {
      debugPrint('🔍 RECUPERAÇÃO: Buscando depósitos não reivindicados...');
      
      // 1. Sincronizar carteira primeiro
      await _sdk!.syncWallet(request: spark.SyncWalletRequest());
      debugPrint('✅ Carteira sincronizada');
      
      // 2. Listar depósitos não reivindicados
      final response = await _sdk!.listUnclaimedDeposits(
        request: const spark.ListUnclaimedDepositsRequest(),
      );
      
      final deposits = response.deposits;
      debugPrint('💎 Encontrados ${deposits.length} depósitos não reivindicados');
      
      if (deposits.isEmpty) {
        // Verificar histórico de pagamentos para diagnóstico
        final payments = await _sdk!.listPayments(request: spark.ListPaymentsRequest());
        debugPrint('📋 Histórico: ${payments.payments.length} pagamentos no total');
        for (final p in payments.payments.take(5)) {
          debugPrint('   - ${p.id}: ${p.amount} sats, status=${p.status}');
        }
        
        return {
          'success': true, 
          'message': 'Nenhum depósito pendente encontrado',
          'deposits': [],
          'totalPayments': payments.payments.length,
        };
      }
      
      // 3. Processar cada depósito
      int claimed = 0;
      int failed = 0;
      BigInt totalAmount = BigInt.zero;
      List<Map<String, dynamic>> processedDeposits = [];
      
      for (final deposit in deposits) {
        debugPrint('📦 Depósito: txid=${deposit.txid}, vout=${deposit.vout}, amount=${deposit.amountSats} sats');
        
        // Verificar se já teve erro ao tentar claim
        // IMPORTANTE: Se o erro foi "feeExceeded", podemos tentar com fee maior!
        bool shouldTry = true;
        if (deposit.claimError != null) {
          final errorStr = deposit.claimError.toString();
          debugPrint('   ⚠️ Depósito com erro anterior: $errorStr');
          
          // Se NÃO for erro de fee, registrar e pular
          if (!errorStr.contains('FeeExceed')) {
            debugPrint('   ❌ Erro não recuperável, pulando...');
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
            debugPrint('   🔄 Erro de fee - tentando com fee maior...');
          }
        }
        
        if (!shouldTry) continue;
        
        try {
          debugPrint('   ⚡ Reivindicando depósito de ${deposit.amountSats} sats...');
          
          // Permitir até 25% do valor como taxa máxima (mínimo 500 sats)
          final maxFeeSats = deposit.amountSats ~/ BigInt.from(4);
          final feeLimit = maxFeeSats < BigInt.from(500) ? BigInt.from(500) : maxFeeSats;
          debugPrint('   💰 Fee máximo permitido: $feeLimit sats');
          
          final claimResponse = await _sdk!.claimDeposit(
            request: spark.ClaimDepositRequest(
              txid: deposit.txid,
              vout: deposit.vout,
              maxFee: spark.Fee.fixed(amount: feeLimit),
            ),
          );
          
          debugPrint('   ✅ Depósito reivindicado! Payment ID: ${claimResponse.payment.id}');
          
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
          debugPrint('   ❌ Erro ao reivindicar: $e');
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
      
      debugPrint('✅ RECUPERAÇÃO COMPLETA: $claimed reivindicados, $failed falhas, saldo atual: ${info.balanceSats} sats');
      
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
      debugPrint('❌ Erro na recuperação: $e');
      return {'success': false, 'error': e.toString(), 'deposits': []};
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
      debugPrint('⚠️ listPayments: SDK não inicializado');
      return [];
    }

    try {
      debugPrint('📋 Buscando histórico de pagamentos...');
      final resp = await _sdk!.listPayments(
        request: spark.ListPaymentsRequest(),
      );

      debugPrint('📋 Total de pagamentos no SDK: ${resp.payments.length}');
      
      for (final p in resp.payments) {
        debugPrint('   💳 Payment: ${p.id.substring(0, 16)}... amount=${p.amount} status=${p.status}');
      }

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
      debugPrint('❌ Erro ao listar pagamentos: $e');
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

  /// Diagnóstico completo do SDK para debug
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
      // Seed info (apenas tamanho, não expor!)
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
      
      // Verificar se diretório existe
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
        
        // Pagamentos (resp.payments é a lista)
        final resp = await _sdk!.listPayments(
          request: spark.ListPaymentsRequest(
            limit: 50,
          ),
        );
        final paymentsList = resp.payments;
        diagnostics['totalPayments'] = paymentsList.length;
        
        // Listar últimos 5 pagamentos
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
    
    debugPrint('🔍 DIAGNÓSTICO COMPLETO:');
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
      debugPrint('🔌 Breez SDK desconectado');
    }
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}
