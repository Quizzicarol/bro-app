import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config.dart';
import 'lnaddress_service.dart';
import 'coordinator_service.dart';

/// Serviço para rastrear taxas da plataforma
/// 
/// MODO ATUAL: TRACKING ONLY
/// - Taxas vão 100% para provedores
/// - Este serviço apenas REGISTRA as taxas para análise futura
/// - Quando tivermos servidor próprio ou Breez Spark permitir split,
///   ativaremos a coleta automática via [enableAutoCollection]
/// 
/// MODO FUTURO: AUTO COLLECTION (quando disponível)
/// - Pagamentos passam pela carteira master (PlatformWalletService)
/// - Split automático: 98% provedor / 2% plataforma
class PlatformFeeService {
  static const String _feeRecordsKey = 'platform_fee_records';
  static const String _totalCollectedKey = 'platform_total_collected';
  static const String _autoCollectionKey = 'platform_auto_collection_enabled';
  static const String _paidOrderIdsKey = 'platform_fee_paid_order_ids';
  static const String _feePaymentHashesKey = 'platform_fee_payment_hashes';
  
  /// Taxa da plataforma — centralizada em AppConfig
  static const double platformFeePercent = AppConfig.platformFeePercent;

  // ── Anti re-pagamento (definitivo) ───────────────────────────────────
  // O registro local _paidOrderIds se PERDE quando o app é reinstalado. A
  // descrição "Bro Platform Fee" NÃO chega ao histórico do Spark (o comentário
  // LNURL vai para o servidor do destinatário, não vira description do payment).
  // Então o identificador confiável é o paymentHash, que o Spark guarda.
  // Estratégia: ao pagar, salvamos o paymentHash da taxa na ORDEM (via callback),
  // que vive no Nostr e sobrevive à reinstalação. Antes de re-pagar, checamos se
  // a ordem já tem esse hash E se ele consta no histórico da carteira.
  static Future<List<dynamic>> Function()? _walletHistoryFetcher;

  // Callback para persistir o paymentHash da taxa na ordem (registrado pelo
  // OrderProvider, que tem acesso à ordem e republica no Nostr).
  static Future<void> Function(String orderId, String paymentHash)? _onFeePaidPersist;

  /// Registra a função que busca o histórico de pagamentos da carteira.
  static void setWalletHistoryFetcher(Future<List<dynamic>> Function() fetcher) {
    _walletHistoryFetcher = fetcher;
    broLog('💼 PlatformFeeService: wallet-history fetcher registrado (anti re-pagamento ativo)');
  }

  /// Registra o callback que persiste o paymentHash da taxa na ordem (Nostr).
  static void setOnFeePaidPersist(Future<void> Function(String orderId, String paymentHash) cb) {
    _onFeePaidPersist = cb;
  }

  /// Indica se o acesso ao histórico da carteira já foi registrado (carteira pronta).
  static bool get hasWalletHistoryFetcher => _walletHistoryFetcher != null;

  /// Verifica se um paymentHash consta como pago no histórico REAL da carteira.
  static Future<bool> _hashConfirmedInWallet(String paymentHash) async {
    if (_walletHistoryFetcher == null || paymentHash.isEmpty) return false;
    try {
      final payments = await _walletHistoryFetcher!();
      for (final p in payments) {
        final hash = (p is Map ? (p['paymentHash'] ?? '') : '').toString();
        final type = (p is Map ? (p['type'] ?? p['direction'] ?? '') : '').toString().toLowerCase();
        final isSent = type.contains('send') || type.contains('enviado') || type.contains('outgoing');
        if (isSent && hash == paymentHash) return true;
      }
      return false;
    } catch (e) {
      broLog('⚠️ _hashConfirmedInWallet: $e');
      return false;
    }
  }

  /// Chamado pelo OrderProvider: verifica se a taxa da ordem já foi paga,
  /// usando o paymentHash salvo na ordem (se houver) confirmado na carteira.
  static Future<bool> isFeePaidVerified(String orderId, String? orderFeeHash) async {
    if (_paidOrderIds.contains(orderId)) return true;
    if (orderFeeHash != null && orderFeeHash.isNotEmpty) {
      if (await _hashConfirmedInWallet(orderFeeHash)) {
        _paidOrderIds.add(orderId);
        await _savePaidOrderIds();
        return true;
      }
    }
    return false;
  }

  /// ETAPA 2 (roteamento de taxa p/ coordinator): resolve para qual endereço
  /// Lightning a taxa vai.
  /// - Se o usuário escolheu um coordinator específico (não "Automático") e ele
  ///   tem endereço Lightning válido, a taxa vai para ELE.
  /// - Senão (Automático), usa o endereço fixo atual (Bro original) — mesmo
  ///   comportamento de sempre.
  ///
  /// NOTA: enquanto a Etapa 2 não for ligada na UI, a seleção fica "Automático"
  /// e este método sempre retorna o endereço padrão (zero mudança de hoje).
  static Future<String> _resolveFeeDestination() async {
    try {
      final svc = CoordinatorService();
      await svc.loadSelection();
      if (!svc.isAutomatic) {
        // Tenta o cache (rápido). Se estiver vazio (ex.: usuário escolheu mas a
        // tela fechou antes de gravar o cache), busca da rede para não cair no
        // padrão por um detalhe de timing.
        var cards = await svc.loadCachedCards();
        var card = svc.selectedCard(cards);
        if (card == null) {
          cards = await svc.fetchCoordinatorCards();
          card = svc.selectedCard(cards);
        }
        if (card != null && card.lnAddress.isNotEmpty) {
          broLog('💼 Taxa roteada para coordinator escolhido: ${card.name} (${card.lnAddress})');
          return card.lnAddress;
        }
      }
    } catch (e) {
      broLog('⚠️ _resolveFeeDestination: fallback p/ padrão ($e)');
    }
    return AppConfig.platformLightningAddress;
  }
  
  /// Inicializa o serviço carregando ordens já pagas do storage
  static Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final paidIds = prefs.getStringList(_paidOrderIdsKey) ?? [];
    _paidOrderIds.clear();
    _paidOrderIds.addAll(paidIds);
    final hashes = prefs.getStringList(_feePaymentHashesKey) ?? [];
    _feePaymentHashes.clear();
    _feePaymentHashes.addAll(hashes);
    broLog('💼 PlatformFeeService inicializado com ${_paidOrderIds.length} ordens já pagas, ${_feePaymentHashes.length} hashes');

    // MIGRAÇÃO ÚNICA (remover depois de rodar 1x): marca as 3 ordens de teste que
    // foram re-pagas durante o debug do FeeReconcile, para o teste da correção
    // começar limpo SEM re-pagar. Essas ordens já tiveram a taxa paga várias
    // vezes; não podem ser pagas de novo. Roda uma vez (guardada por flag).
    const migrationFlag = 'fee_reconcile_migration_20260824_done';
    final alreadyMigrated = prefs.getBool(migrationFlag) ?? false;
    if (!alreadyMigrated) {
      const legacyOrders = [
        '7553fb25-29f8-4cd4-ae1d-5b49e7bdef99',
        'b620259f',
        '9a656378-1366-49a4-abdd-4b6ba04e297a',
      ];
      for (final id in legacyOrders) {
        _paidOrderIds.add(id);
      }
      await _savePaidOrderIds();
      await prefs.setBool(migrationFlag, true);
      broLog('💼 [migração] ordens de teste marcadas como pagas (não re-pagar): ${legacyOrders.length}');
    }
  }

  /// Verifica se uma ordem é uma das ordens de teste legadas (por prefixo).
  /// Usado no filtro do FeeReconcile para pular mesmo se o ID tiver variação.
  static bool isLegacyTestOrder(String orderId) {
    return orderId.startsWith('7553fb25') ||
        orderId.startsWith('b620259f') ||
        orderId.startsWith('9a656378');
  }
  
  /// Salva o registro de ordens pagas no storage
  static Future<void> _savePaidOrderIds() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_paidOrderIdsKey, _paidOrderIds.toList());
  }
  
  /// Verifica se a coleta automática está habilitada
  /// DESABILITADO até termos infraestrutura própria
  static Future<bool> isAutoCollectionEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoCollectionKey) ?? false;
  }
  
  /// Habilita/desabilita coleta automática
  /// USE APENAS quando tivermos servidor próprio ou Breez permitir
  static Future<void> setAutoCollection(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoCollectionKey, enabled);
  }

  /// Registra uma taxa de transação (TRACKING ONLY)
  /// Chamado quando um pagamento é confirmado
  /// A taxa é registrada mas NÃO cobrada do provedor
  static Future<void> recordFee({
    required String orderId,
    required double transactionBrl,
    required int transactionSats,
    required String providerPubkey,
    required String clientPubkey,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    
    // Calcular taxa
    final feeBrl = transactionBrl * platformFeePercent;
    final feeSats = (transactionSats * platformFeePercent).round();
    
    // Criar registro
    final record = {
      'orderId': orderId,
      'timestamp': DateTime.now().toIso8601String(),
      'transactionBrl': transactionBrl,
      'transactionSats': transactionSats,
      'feeBrl': feeBrl,
      'feeSats': feeSats,
      'providerPubkey': providerPubkey,
      'clientPubkey': clientPubkey,
      'collected': false, // Marca se a taxa foi efetivamente transferida
    };
    
    // Carregar registros existentes
    final existingJson = prefs.getString(_feeRecordsKey);
    List<Map<String, dynamic>> records = [];
    if (existingJson != null) {
      records = List<Map<String, dynamic>>.from(jsonDecode(existingJson));
    }
    
    // Adicionar novo registro
    records.add(record);
    
    // Salvar
    await prefs.setString(_feeRecordsKey, jsonEncode(records));
  }

  /// Obtém todos os registros de taxas
  static Future<List<Map<String, dynamic>>> getAllFeeRecords() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_feeRecordsKey);
    if (json == null) return [];
    return List<Map<String, dynamic>>.from(jsonDecode(json));
  }

  /// Obtém taxas pendentes (não coletadas)
  static Future<List<Map<String, dynamic>>> getPendingFees() async {
    final records = await getAllFeeRecords();
    return records.where((r) => r['collected'] != true).toList();
  }

  /// Calcula total de taxas pendentes
  static Future<Map<String, dynamic>> getPendingTotals() async {
    final pending = await getPendingFees();
    
    double totalBrl = 0;
    int totalSats = 0;
    
    for (final record in pending) {
      totalBrl += (record['feeBrl'] as num?)?.toDouble() ?? 0;
      totalSats += (record['feeSats'] as num?)?.toInt() ?? 0;
    }
    
    return {
      'totalBrl': totalBrl,
      'totalSats': totalSats,
      'count': pending.length,
      'records': pending,
    };
  }

  /// Calcula total histórico (todas as taxas)
  static Future<Map<String, dynamic>> getHistoricalTotals() async {
    final records = await getAllFeeRecords();
    
    double totalBrl = 0;
    int totalSats = 0;
    double collectedBrl = 0;
    int collectedSats = 0;
    
    for (final record in records) {
      final feeBrl = (record['feeBrl'] as num?)?.toDouble() ?? 0;
      final feeSats = (record['feeSats'] as num?)?.toInt() ?? 0;
      
      totalBrl += feeBrl;
      totalSats += feeSats;
      
      if (record['collected'] == true) {
        collectedBrl += feeBrl;
        collectedSats += feeSats;
      }
    }
    
    return {
      'totalBrl': totalBrl,
      'totalSats': totalSats,
      'collectedBrl': collectedBrl,
      'collectedSats': collectedSats,
      'pendingBrl': totalBrl - collectedBrl,
      'pendingSats': totalSats - collectedSats,
      'totalTransactions': records.length,
    };
  }

  /// Marca taxas como coletadas
  static Future<void> markAsCollected(List<String> orderIds) async {
    final prefs = await SharedPreferences.getInstance();
    final records = await getAllFeeRecords();
    
    for (var record in records) {
      if (orderIds.contains(record['orderId'])) {
        record['collected'] = true;
        record['collectedAt'] = DateTime.now().toIso8601String();
      }
    }
    
    await prefs.setString(_feeRecordsKey, jsonEncode(records));
  }

  /// Marca todas as taxas pendentes como coletadas
  static Future<int> markAllAsCollected() async {
    final pending = await getPendingFees();
    final orderIds = pending.map((r) => r['orderId'] as String).toList();
    await markAsCollected(orderIds);
    return orderIds.length;
  }

  /// Limpa todos os registros (use com cuidado!)
  static Future<void> clearAllRecords() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_feeRecordsKey);
    await prefs.remove(_totalCollectedKey);
  }

  /// Exporta registros para JSON (backup)
  static Future<String> exportToJson() async {
    final records = await getAllFeeRecords();
    final totals = await getHistoricalTotals();
    
    return jsonEncode({
      'exportDate': DateTime.now().toIso8601String(),
      'totals': totals,
      'records': records,
    });
  }

  // ========== ENVIO REAL DA TAXA ==========
  
  // Callback para efetuar o pagamento (será injetado pelo LightningProvider)
  static Future<Map<String, dynamic>?> Function(String invoice)? _payInvoiceCallback;
  static String _currentBackend = 'unknown';
  
  // IMPORTANTE: Registro de ordens que já tiveram a taxa paga para evitar duplicação
  static final Set<String> _paidOrderIds = {};
  static final Set<String> _feePaymentHashes = {};

  /// Configura o callback de pagamento (chamar na inicialização do app)
  static void setPaymentCallback(
    Future<Map<String, dynamic>?> Function(String invoice) callback,
    String backend,
  ) {
    _payInvoiceCallback = callback;
    _currentBackend = backend;
    broLog('💼 PlatformFeeService configurado com backend: $backend');
  }
  
  /// Verifica se a taxa já foi paga para uma ordem específica
  static bool isFeePaid(String orderId) {
    return _paidOrderIds.contains(orderId);
  }

  /// Retorna os payment hashes de taxas da plataforma (para filtrar no histórico)
  static Set<String> get feePaymentHashes => Set.unmodifiable(_feePaymentHashes);

  /// Registra um payment hash de taxa para que seja ocultado do histórico da carteira.
  /// Usado por taxas internas (ex.: taxa BRIX de 0,5%) que devem ser invisíveis ao usuário.
  static Future<void> registerFeePaymentHash(String hash) async {
    if (hash.isEmpty) return;
    await _saveFeePaymentHash(hash);
  }

  /// Salva um payment hash de taxa no storage
  static Future<void> _saveFeePaymentHash(String hash) async {
    _feePaymentHashes.add(hash);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_feePaymentHashesKey, _feePaymentHashes.toList());
  }
  
  /// Limpa o registro de ordens pagas (usar apenas em casos especiais)
  static Future<void> clearPaidOrders() async {
    _paidOrderIds.clear();
    await _savePaidOrderIds();
    broLog('💼 Registro de taxas pagas limpo');
  }
  
  /// Registra uma ordem como tendo taxa paga (e persiste no storage)
  static Future<void> _markOrderAsPaid(String orderId) async {
    _paidOrderIds.add(orderId);
    await _savePaidOrderIds();
  }

  /// Envia a taxa da plataforma para o Lightning Address configurado
  /// Retorna true se o pagamento foi bem sucedido OU se já foi pago anteriormente
  static Future<bool> sendPlatformFee({
    required String orderId,
    required int totalSats,
    String? knownFeeHash, // paymentHash da taxa salvo na ordem (se já paga antes)
  }) async {
    // VERIFICAÇÃO CRÍTICA: Evitar pagamento duplicado
    if (_paidOrderIds.contains(orderId)) {
      broLog('💼 Taxa já foi paga para ordem ${orderId.length > 8 ? orderId.substring(0, 8) : orderId} - ignorando');
      return true; // Retorna true pois já foi pago
    }

    // ANTI RE-PAGAMENTO (definitivo): se a ordem já tem um paymentHash de taxa
    // salvo (persistido no Nostr, sobrevive à reinstalação) E ele consta no
    // histórico real da carteira, a taxa JÁ foi paga — re-marca e NÃO re-paga.
    if (knownFeeHash != null && knownFeeHash.isNotEmpty) {
      if (await _hashConfirmedInWallet(knownFeeHash)) {
        broLog('💼 Taxa da ordem ${orderId.length > 8 ? orderId.substring(0, 8) : orderId} confirmada no histórico (hash) — SEM re-pagar');
        _paidOrderIds.add(orderId);
        await _savePaidOrderIds();
        return true;
      }
    }
    
    // CORREÇÃO v1.0.129+224: LOCK IMEDIATO para prevenir race condition
    // Adicionar ao Set SINCRONAMENTE antes de qualquer await.
    // Sem isso, duas chamadas concorrentes (order_status_screen + onPaymentSent)
    // passam o contains() check acima antes de qualquer uma completar o pagamento,
    // resultando em taxa duplicada.
    _paidOrderIds.add(orderId);
    broLog('💼 Lock adquirido para ordem ${orderId.length > 8 ? orderId.substring(0, 8) : orderId}');
    
    // Calcular taxa da plataforma: 2% do valor total (mínimo 1 sat)
    final platformFeeRaw = (totalSats * AppConfig.platformFeePercent).round();
    final platformFeeSats = platformFeeRaw < 1 ? 1 : platformFeeRaw;
    
    if (platformFeeSats <= 0) {
      broLog('💼 Taxa da plataforma = 0 sats, ignorando...');
      return true;
    }

    if (!AppConfig.isPlatformLightningAddressValid) {
      // vSEC: validação de FORMATO (não só isNotEmpty) — endereço malformado
      // no env.json falhava só em runtime, derrubando a taxa silenciosamente.
      broLog('⚠️ platformLightningAddress ausente ou malformado!');
      _paidOrderIds.remove(orderId); // Liberar lock para retry
      return false;
    }

    broLog('');
    broLog('💼 ════════════════════════════════════════════════');
    broLog('💼 ENVIANDO TAXA DA PLATAFORMA');
    broLog('💼 Ordem: ${orderId.length > 8 ? orderId.substring(0, 8) : orderId}...');
    broLog('💼 Valor total: $totalSats sats');
    broLog('💼 Taxa (${(AppConfig.platformFeePercent * 100).toStringAsFixed(0)}%): $platformFeeSats sats');
    broLog('💼 Destino: ${await _resolveFeeDestination()}');
    broLog('💼 Backend: $_currentBackend');
    broLog('💼 ════════════════════════════════════════════════');
    broLog('');

    if (_payInvoiceCallback == null) {
      broLog('❌ ERRO: Callback de pagamento não configurado!');
      broLog('   Certifique-se de chamar PlatformFeeService.setPaymentCallback() na inicialização');
      _paidOrderIds.remove(orderId); // Liberar lock para retry
      return false;
    }

    try {
      final platformAddress = await _resolveFeeDestination();

      // Detectar tipo de endereço Lightning
      if (platformAddress.contains('@')) {
        // Lightning Address (user@domain.com)
        broLog('💼 Resolvendo Lightning Address: $platformAddress');
        
        final lnAddressService = LnAddressService();
        final result = await lnAddressService.getInvoice(
          lnAddress: platformAddress,
          amountSats: platformFeeSats,
          comment: 'Bro Platform Fee - ${orderId.length > 8 ? orderId.substring(0, 8) : orderId}',
        );

        broLog('💼 Resultado LNURL: success=${result['success']}, hasInvoice=${result['invoice'] != null}');

        if (result['success'] != true || result['invoice'] == null) {
          broLog('❌ Falha ao obter invoice do LN Address: ${result['error'] ?? 'unknown'}');
          _paidOrderIds.remove(orderId); // Liberar lock para retry
          return false;
        }

        final invoice = result['invoice'] as String;
        broLog('💼 Invoice obtido: ${invoice.substring(0, 50)}...');
        broLog('💼 Pagando via $_currentBackend...');

        final payResult = await _payInvoiceCallback!(invoice);
        
        if (payResult != null && payResult['success'] == true) {
          // Lock já foi adquirido - apenas persistir no storage
          await _savePaidOrderIds();
          
          // Salvar payment hash para filtrar do histórico da carteira
          final payHash = payResult['payment']?['paymentHash'] as String?;
          if (payHash != null && payHash.isNotEmpty) {
            await _saveFeePaymentHash(payHash);
            // ANTI RE-PAGAMENTO: persistir o hash NA ORDEM (Nostr) — sobrevive à
            // reinstalação. Assim o FeeReconcile consegue confirmar que a taxa
            // já foi paga mesmo com o app reinstalado, e nunca re-paga.
            if (_onFeePaidPersist != null) {
              try { await _onFeePaidPersist!(orderId, payHash); } catch (_) {}
            }
          }
          
          broLog('');
          broLog('✅ ════════════════════════════════════════════════');
          broLog('✅ TAXA DA PLATAFORMA PAGA COM SUCESSO!');
          broLog('✅ Valor: $platformFeeSats sats');
          broLog('✅ Destino: $platformAddress');
          broLog('✅ Backend: $_currentBackend');
          broLog('✅ ════════════════════════════════════════════════');
          broLog('');
          
          // Marcar como coletada no tracking
          await markAsCollected([orderId]);
          
          return true;
        } else {
          broLog('❌ Falha no pagamento: $payResult');
          _paidOrderIds.remove(orderId); // Liberar lock para retry
          return false;
        }

      } else if (platformAddress.toLowerCase().startsWith('lno1')) {
        // BOLT12 Offer - ainda não suportado
        broLog('⚠️ BOLT12 Offer detectado - não suportado ainda');
        _paidOrderIds.remove(orderId); // Liberar lock para retry
        return false;

      } else if (platformAddress.toLowerCase().startsWith('ln')) {
        // Invoice BOLT11 direto
        broLog('💼 Pagando invoice BOLT11 direto...');
        
        final payResult = await _payInvoiceCallback!(platformAddress);
        
        if (payResult != null && payResult['success'] == true) {
          // Lock já foi adquirido - apenas persistir no storage
          await _savePaidOrderIds();
          
          // Salvar payment hash para filtrar do histórico
          final payHash = payResult['payment']?['paymentHash'] as String?;
          if (payHash != null && payHash.isNotEmpty) {
            await _saveFeePaymentHash(payHash);
          }
          
          broLog('✅ TAXA DA PLATAFORMA PAGA COM SUCESSO via $_currentBackend!');
          await markAsCollected([orderId]);
          return true;
        } else {
          broLog('❌ Falha no pagamento: $payResult');
          _paidOrderIds.remove(orderId); // Liberar lock para retry
          return false;
        }
      }

      broLog('⚠️ Tipo de endereço não reconhecido: $platformAddress');
      _paidOrderIds.remove(orderId); // Liberar lock para retry
      return false;

    } catch (e, stack) {
      broLog('❌ ERRO ao pagar taxa da plataforma: $e');
      broLog('   Stack: $stack');
      _paidOrderIds.remove(orderId); // Liberar lock para retry
      return false;
    }
  }
}
