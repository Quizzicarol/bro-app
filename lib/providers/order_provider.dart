import 'dart:async';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../services/api_service.dart';
import '../services/nostr_service.dart';
import '../services/nostr_order_service.dart';
import '../services/local_collateral_service.dart';
import '../services/platform_fee_service.dart';
import '../models/order.dart';
import '../config.dart';

class OrderProvider with ChangeNotifier {
  final ApiService _apiService = ApiService();
  final NostrService _nostrService = NostrService();
  final NostrOrderService _nostrOrderService = NostrOrderService();

  List<Order> _orders = [];  // APENAS ordens do usuÃÂ¡rio atual
  List<Order> _availableOrdersForProvider = [];  // Ordens disponÃÂ­veis para Bros (NUNCA salvas)
  Order? _currentOrder;
  bool _isLoading = false;
  String? _error;
  bool _isInitialized = false;
  String? _currentUserPubkey;
  bool _isProviderMode = false;  // Modo provedor ativo (para UI, nÃÂ£o para filtro de ordens)

  // PERFORMANCE: Throttle para evitar syncs/saves/notifies excessivos
  Completer<void>? _providerSyncCompleter; // v252: Permite pull-to-refresh aguardar sync em andamento
  bool _isSyncingUser = false; // Guard contra syncs concorrentes (modo usuÃÂ¡rio)
  bool _isSyncingProvider = false; // Guard contra syncs concorrentes (modo provedor)
  bool _autoRepairDoneThisSession = false; // v256: Auto-repair roda apenas UMA VEZ por sessao
  DateTime? _syncUserStartedAt; // v259: Timestamp de quando sync user iniciou (para detectar lock stale)
  DateTime? _syncProviderStartedAt; // v259: Timestamp de quando sync provider iniciou
  static const int _maxSyncDurationSeconds = 120; // v259: Max 2 min de sync antes de forcar reset
  static const int _maxRepairBatchSize = 5; // v259: Max 5 ordens reparadas por sessao
  final Set<String> _ordersNeedingUserPubkeyFix = {}; // v257: Ordens com userPubkey corrompido
  DateTime? _lastUserSyncTime; // Timestamp do ÃÂºltimo sync de usuÃÂ¡rio
  DateTime? _lastProviderSyncTime; // Timestamp do ÃÂºltimo sync de provedor
  static const int _minSyncIntervalSeconds = 15; // Intervalo mÃÂ­nimo entre syncs automÃÂ¡ticos
  Timer? _saveDebounceTimer; // Debounce para _saveOrders
  Timer? _notifyDebounceTimer; // Debounce para notifyListeners
  Timer? _backgroundSyncTimer; // Sync periódico para billCode_nip44_provider
  bool _notifyPending = false; // Flag para notify pendente

  // v132: Callback para auto-pagamento de ordens liquidadas
  // Setado pelo main.dart com acesso aos providers Lightning
  Future<bool> Function(String orderId, Order order)? onAutoPayLiquidation;

  // v133: Callback para gerar invoice Lightning (provider side)
  // Usado para renovar invoices expirados em ordens liquidadas
  Future<String?> Function(int amountSats, String orderId)? onGenerateProviderInvoice;

  // Prefixo para salvar no SharedPreferences (serÃÂ¡ combinado com pubkey)
  static const String _ordersKeyPrefix = 'orders_';

  // SEGURANÃâ¡A CRÃÂTICA: Filtrar ordens por usuÃÂ¡rio - NUNCA mostrar ordens de outros!
  // Esta lista ÃÂ© usada por TODOS os getters (orders, pendingOrders, etc)
  List<Order> get _filteredOrders {
    // SEGURANÃâ¡A ABSOLUTA: Sem pubkey = sem ordens
    if (_currentUserPubkey == null || _currentUserPubkey!.isEmpty) {
      return [];
    }
    
    // SEMPRE filtrar por usuÃÂ¡rio - mesmo no modo provedor!
    // No modo provedor, mostramos ordens disponÃÂ­veis em tela separada, nÃÂ£o aqui
    final filtered = _orders.where((o) {
      // REGRA 1: Ordens SEM userPubkey sÃÂ£o rejeitadas (dados corrompidos/antigos)
      if (o.userPubkey == null || o.userPubkey!.isEmpty) {
        return false;
      }
      
      // REGRA 2: Ordem criada por este usuÃÂ¡rio
      final isOwner = o.userPubkey == _currentUserPubkey;
      
      // REGRA 3: Ordem que este usuÃÂ¡rio aceitou como Bro (providerId)
      final isMyProviderOrder = o.providerId == _currentUserPubkey;

      // REGRA 4 (v348): Se sou 'provedor' mas metadata indica que participei
      // apenas como mediador/admin, NAO mostrar na lista
      if (isMyProviderOrder && !isOwner) {
        final meta = o.metadata;
        if (meta != null && meta['disputeProviderPaidBy'] == 'admin') {
          return false;
        }
      }

      if (!isOwner && !isMyProviderOrder) {
      }

      return isOwner || isMyProviderOrder;
    }).toList();
    
    // Log apenas quando hÃÂ¡ filtros aplicados
    if (_orders.length != filtered.length) {
    }
    return filtered;
  }

  // Getters - USAM _filteredOrders para SEGURANÃâ¡A
  // NOTA: orders NÃÆO inclui draft (ordens nÃÂ£o pagas nÃÂ£o aparecem na lista do usuÃÂ¡rio)
  List<Order> get orders => _filteredOrders.where((o) => o.status != 'draft').toList();
  List<Order> get pendingOrders => _filteredOrders.where((o) => o.status == 'pending' || o.status == 'payment_received').toList();
  List<Order> get activeOrders => _filteredOrders.where((o) => ['payment_received', 'confirmed', 'accepted', 'processing'].contains(o.status)).toList();
  List<Order> get completedOrders => _filteredOrders.where((o) => o.status == 'completed').toList();
  
  /// v338: Ordens com pagamento pendente pós-resolução de disputa
  List<Order> get disputePaymentPendingOrders => _filteredOrders.where((o) =>
    o.metadata?['disputePaymentPending'] == true &&
    o.metadata?['disputeProviderPaid'] != true
  ).toList();
  
  bool get isProviderMode => _isProviderMode;
  Order? get currentOrder => _currentOrder;
  bool get isLoading => _isLoading;
  String? get error => _error;
  
  /// Getter pÃÂºblico para a pubkey do usuÃÂ¡rio atual (usado para verificaÃÂ§ÃÂµes externas)
  String? get currentUserPubkey => _currentUserPubkey;
  
  /// Getter publico para a chave privada Nostr (usado para publicar disputas)
  String? get nostrPrivateKey => _nostrService.privateKey;

  /// SEGURANÃâ¡A: Getter para ordens que EU CRIEI (modo usuÃÂ¡rio)
  /// Retorna APENAS ordens onde userPubkey == currentUserPubkey
  /// Usado na tela "Minhas Trocas" do modo usuÃÂ¡rio
  List<Order> get myCreatedOrders {
    // Se nÃÂ£o temos pubkey, tentar buscar do NostrService
    if (_currentUserPubkey == null || _currentUserPubkey!.isEmpty) {
      final fallbackPubkey = _nostrService.publicKey;
      if (fallbackPubkey != null && fallbackPubkey.isNotEmpty) {
        _currentUserPubkey = fallbackPubkey;
      } else {
        return [];
      }
    }
    
    final result = _orders.where((o) {
      // Apenas ordens que EU criei (nÃÂ£o ordens aceitas como provedor)
      return o.userPubkey == _currentUserPubkey && o.status != 'draft';
    }).toList();
    
    return result;
  }
  
  /// SEGURANÃâ¡A: Getter para ordens que EU ACEITEI como Bro (modo provedor)
  /// Retorna APENAS ordens onde providerId == currentUserPubkey
  /// Usado na tela "Minhas Ordens" do modo provedor
  List<Order> get myAcceptedOrders {
    // Se nÃÂ£o temos pubkey, tentar buscar do NostrService
    if (_currentUserPubkey == null || _currentUserPubkey!.isEmpty) {
      final fallbackPubkey = _nostrService.publicKey;
      if (fallbackPubkey != null && fallbackPubkey.isNotEmpty) {
        _currentUserPubkey = fallbackPubkey;
      } else {
        return [];
      }
    }
    

    final result = _orders.where((o) {
      // Apenas ordens que EU aceitei como provedor (nÃÂ£o ordens que criei)
      return o.providerId == _currentUserPubkey && o.userPubkey != _currentUserPubkey;
    }).toList();
    
    return result;
  }

  /// CRÃÂTICO: MÃÂ©todo para sair do modo provedor e limpar ordens de outros
  /// Deve ser chamado quando o usuÃÂ¡rio sai da tela de modo Bro
  void exitProviderMode() {
    _isProviderMode = false;
    
    // Limpar lista de ordens disponÃÂ­veis para provedor (NUNCA eram salvas)
    _availableOrdersForProvider = [];
    
    // IMPORTANTE: NÃÆO remover ordens que este usuÃÂ¡rio aceitou como provedor!
    // Mesmo que userPubkey seja diferente, se providerId == _currentUserPubkey,
    // essa ordem deve ser mantida para aparecer em "Minhas Ordens" do provedor
    final before = _orders.length;
    _orders = _orders.where((o) {
      // Sempre manter ordens que este usuÃÂ¡rio criou
      final isOwner = o.userPubkey == _currentUserPubkey;
      // SEMPRE manter ordens que este usuÃÂ¡rio aceitou como provedor
      final isProvider = o.providerId == _currentUserPubkey;
      
      if (isProvider) {
      }
      
      return isOwner || isProvider;
    }).toList();
    
    final removed = before - _orders.length;
    if (removed > 0) {
    }
    
    // Salvar lista limpa
    _saveOnlyUserOrders();
    
    _throttledNotify();
  }
  
  /// Getter para ordens disponÃÂ­veis para Bros (usadas na tela de provedor)
  /// Esta lista NUNCA ÃÂ© salva localmente!
  /// IMPORTANTE: Retorna uma CÃâPIA para evitar ConcurrentModificationException
  /// quando o timer de polling modifica a lista durante iteraÃÂ§ÃÂ£o na UI
  List<Order> get availableOrdersForProvider {
    // CORREÇÃO v1.0.129+223: Cross-check com _orders para eliminar ordens stale
    // Se uma ordem já existe em _orders com status terminal, NÃO mostrar como disponível
    const terminalStatuses = ['accepted', 'awaiting_confirmation', 'completed', 'cancelled', 'liquidated', 'disputed'];
    return List<Order>.from(_availableOrdersForProvider.where((o) {
      if (o.userPubkey == _currentUserPubkey) return false;
      // Se a ordem já foi movida para _orders e tem status não-pendente, excluir
      final inOrders = _orders.cast<Order?>().firstWhere(
        (ord) => ord?.id == o.id,
        orElse: () => null,
      );
      if (inOrders != null && terminalStatuses.contains(inOrders.status)) {
        return false;
      }
      return true;
    }));
  }

  /// Calcula o total de sats comprometidos com ordens pendentes/ativas (modo cliente)
  /// Este valor deve ser SUBTRAÃÂDO do saldo total para calcular saldo disponÃÂ­vel para garantia
  /// 
  /// IMPORTANTE: SÃÂ³ conta ordens que ainda NÃÆO foram pagas via Lightning!
  /// - 'draft': Invoice ainda nÃÂ£o pago - COMPROMETIDO
  /// - 'pending': Invoice pago, aguardando Bro aceitar - JÃÂ SAIU DA CARTEIRA
  /// - 'payment_received': Invoice pago, aguardando Bro - JÃÂ SAIU DA CARTEIRA
  /// - 'accepted', 'awaiting_confirmation', 'completed': JÃÂ PAGO
  /// 
  /// Na prÃÂ¡tica, APENAS ordens 'draft' deveriam ser contadas, mas removemos
  /// esse status ao refatorar o fluxo (invoice ÃÂ© pago antes de criar ordem)
  int get committedSats {
    // v257: Contar sats de ordens pagas com saldo da carteira (wallet payments)
    // Ordens com paymentHash 'wallet_*' NAO saem via Lightning - sats continuam na carteira
    // Precisamos travar esses sats para o saldo exibido ser correto
    //
    // Para pagamentos Lightning normais, sats JA sairam da carteira (return 0 para eles)
    
    const terminalStatuses = ['completed', 'cancelled', 'liquidated'];
    
    int locked = 0;
    for (final o in _filteredOrders) {
      // So contar ordens com wallet payment (nao-Lightning)
      if (o.paymentHash == null || !o.paymentHash!.startsWith('wallet_')) continue;
      
      // Nao contar ordens terminais (ja foram resolvidas)
      if (terminalStatuses.contains(o.status)) continue;
      
      // Converter btcAmount para sats
      final sats = (o.btcAmount * 100000000).round();
      if (sats > 0) {
        locked += sats;
        broLog('LOCKED: ordem=\${o.id.substring(0, 8)} status=\${o.status} sats=\$sats');
      }
    }
    
    if (locked > 0) {
      broLog('TOTAL LOCKED (wallet payments): \$locked sats');
    }
    
    return locked;
  }

  // Chave ÃÂºnica para salvar ordens deste usuÃÂ¡rio
  String get _ordersKey => '${_ordersKeyPrefix}${_currentUserPubkey ?? 'anonymous'}';

  /// PERFORMANCE: notifyListeners throttled Ã¢â¬â coalesce calls within 100ms
  void _throttledNotify() {
    _notifyPending = true;
    if (_notifyDebounceTimer?.isActive ?? false) return;
    _notifyDebounceTimer = Timer(const Duration(milliseconds: 100), () {
      if (_notifyPending) {
        _notifyPending = false;
        notifyListeners();
      }
    });
  }


  /// Immediate notify - for loading/error state transitions that must reach UI instantly
  void _immediateNotify() {
    _notifyDebounceTimer?.cancel();
    _notifyPending = false;
    notifyListeners();
  }
  // Cache de ordens salvas localmente Ã¢â¬â usado para proteger contra regressÃÂ£o de status
  // quando o relay nÃÂ£o retorna o evento de conclusÃÂ£o mais recente
  final Map<String, Order> _savedOrdersCache = {};
  
  /// PERFORMANCE: Debounced save Ã¢â¬â coalesce rapid writes into one 500ms later
  void _debouncedSave() {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = Timer(const Duration(milliseconds: 500), () {
      _saveOnlyUserOrders();
    });
  }

  // Inicializar com a pubkey do usuÃÂ¡rio
  Future<void> initialize({String? userPubkey}) async {
    // Se passou uma pubkey, usar ela
    if (userPubkey != null && userPubkey.isNotEmpty) {
      _currentUserPubkey = userPubkey;
    } else {
      // Tentar pegar do NostrService
      _currentUserPubkey = _nostrService.publicKey;
    }
    
    // SEGURANÃâ¡A: Fornecer chave privada para descriptografar proofImage NIP-44
    _nostrOrderService.setDecryptionKey(_nostrService.privateKey);
    
    // Ã°Å¸Â§Â¹ SEGURANÃâ¡A: Limpar storage 'orders_anonymous' que pode conter ordens vazadas
    await _cleanupAnonymousStorage();
    
    // Resetar estado - CRÃÂTICO: Limpar AMBAS as listas de ordens!
    _orders = [];
    _availableOrdersForProvider = [];
    _isInitialized = false;
    
    // SEMPRE carregar ordens locais primeiro (para preservar status atualizados)
    // Antes estava sÃÂ³ em testMode, mas isso perdia status como payment_received
    // NOTA: SÃÂ³ carrega se temos pubkey vÃÂ¡lida (prevenÃÂ§ÃÂ£o de vazamento)
    await _loadSavedOrders();
    
    // Ã°Å¸Â§Â¹ LIMPEZA: Remover ordens DRAFT antigas (nÃÂ£o pagas em 1 hora)
    await _cleanupOldDraftOrders();
    
    // CORREÃâ¡ÃÆO AUTOMÃÂTICA: Identificar ordens marcadas incorretamente como pagas
    // Se temos mÃÂºltiplas ordens "payment_received" com valores pequenos e criadas quase ao mesmo tempo,
    // ÃÂ© provÃÂ¡vel que a reconciliaÃÂ§ÃÂ£o automÃÂ¡tica tenha marcado incorretamente.
    // A ordem 4c805ae7 foi marcada incorretamente - ela foi criada DEPOIS da primeira ordem
    // e nunca recebeu pagamento real.
    await _fixIncorrectlyPaidOrders();
    
    // Depois sincronizar do Nostr (em background)
    if (_currentUserPubkey != null) {
      _syncFromNostrBackground();
    }
    
    _isInitialized = true;
    _immediateNotify();
  }
  
  /// Ã°Å¸Â§Â¹ SEGURANÃâ¡A: Limpar storage 'orders_anonymous' que pode conter ordens de usuÃÂ¡rios anteriores
  /// TambÃÂ©m limpa qualquer cache global que possa ter ordens vazadas
  Future<void> _cleanupAnonymousStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // 1. Remover ordens do usuÃÂ¡rio 'anonymous'
      if (prefs.containsKey('orders_anonymous')) {
        await prefs.remove('orders_anonymous');
      }
      
      // 2. Remover cache global de ordens (pode conter ordens de outros usuÃÂ¡rios)
      if (prefs.containsKey('cached_orders')) {
        await prefs.remove('cached_orders');
      }
      
      // 3. Remover chave legada 'saved_orders'
      if (prefs.containsKey('saved_orders')) {
        await prefs.remove('saved_orders');
      }
      
      // 4. Remover cache de ordens do cache_service
      if (prefs.containsKey('cache_orders')) {
        await prefs.remove('cache_orders');
      }
      
    } catch (e) {
    }
  }
  
  /// Ã°Å¸Â§Â¹ Remove ordens draft que nÃÂ£o foram pagas em 1 hora
  /// Isso evita acÃÂºmulo de ordens "fantasma" que o usuÃÂ¡rio abandonou
  Future<void> _cleanupOldDraftOrders() async {
    final now = DateTime.now();
    final draftCutoff = now.subtract(const Duration(hours: 1));
    
    final oldDrafts = _orders.where((o) => 
      o.status == 'draft' && 
      o.createdAt != null && 
      o.createdAt!.isBefore(draftCutoff)
    ).toList();
    
    if (oldDrafts.isEmpty) return;
    
    for (final draft in oldDrafts) {
      _orders.remove(draft);
    }
    
    await _saveOrders();
  }

  // Recarregar ordens para novo usuÃÂ¡rio (apÃÂ³s login)
  Future<void> loadOrdersForUser(String userPubkey) async {
    
    // Ã°Å¸âÂ SEGURANÃâ¡A CRÃÂTICA: Limpar TUDO antes de carregar novo usuÃÂ¡rio
    // Isso previne que ordens de usuÃÂ¡rio anterior vazem para o novo
    await _cleanupAnonymousStorage();
    
    // Ã¢Å¡Â Ã¯Â¸Â NÃÆO limpar cache de collateral aqui!
    // O CollateralProvider gerencia isso prÃÂ³prio e verifica se usuÃÂ¡rio mudou
    // Limpar aqui causa problema de tier "caindo" durante a sessÃÂ£o
    
    _currentUserPubkey = userPubkey;
    _orders = [];
    _availableOrdersForProvider = [];  // Limpar tambÃÂ©m lista de disponÃÂ­veis
    _isInitialized = false;
    _isProviderMode = false;  // Reset modo provedor ao trocar de usuÃÂ¡rio
    
    // SEGURANÃâ¡A: Atualizar chave de descriptografia NIP-44
    _nostrOrderService.setDecryptionKey(_nostrService.privateKey);
    
    // Notificar IMEDIATAMENTE que ordens foram limpas
    // Isso garante que committedSats retorne 0 antes de carregar novas ordens
    _immediateNotify();
    
    // Carregar ordens locais primeiro (SEMPRE, para preservar status atualizados)
    await _loadSavedOrders();
    
    // SEGURANÃâ¡A: Filtrar ordens que nÃÂ£o pertencem a este usuÃÂ¡rio
    // (podem ter vazado de sincronizaÃÂ§ÃÂµes anteriores)
    // IMPORTANTE: Manter ordens que este usuÃÂ¡rio CRIOU ou ACEITOU como Bro!
    final originalCount = _orders.length;
    _orders = _orders.where((order) {
      // Manter ordens deste usuÃÂ¡rio (criador)
      if (order.userPubkey == userPubkey) return true;
      // Manter ordens que este usuÃÂ¡rio aceitou como Bro
      if (order.providerId == userPubkey) return true;
      // Manter ordens sem pubkey definido (legado, mas marcar como deste usuÃÂ¡rio)
      if (order.userPubkey == null || order.userPubkey!.isEmpty) {
        return false; // Remover ordens sem dono identificado
      }
      // Remover ordens de outros usuÃÂ¡rios
      return false;
    }).toList();
    
    if (_orders.length < originalCount) {
      await _saveOrders(); // Salvar lista limpa
    }
    
    
    _isInitialized = true;
    _immediateNotify();
    
    // Sincronizar do Nostr IMEDIATAMENTE (nÃÂ£o em background)
    try {
      await syncOrdersFromNostr();
    } catch (e) {
    }
  }
  
  // Sincronizar ordens do Nostr em background
  void _syncFromNostrBackground() {
    if (_currentUserPubkey == null) return;
    
    
    // Executar em background sem bloquear a UI
    Future.microtask(() async {
      try {
        // PERFORMANCE: Republicar e sincronizar EM PARALELO (nÃÂ£o sequencial)
        final privateKey = _nostrService.privateKey;
        await Future.wait([
          if (privateKey != null) republishLocalOrdersToNostr(),
          syncOrdersFromNostr(),
        ]);
      } catch (e) {
      }
    });
    
    // Iniciar sync periódico (30s) para detectar aceitação e republicar billCode_nip44_provider
    // Isso garante que o buyer republica MESMO se order_status_screen não estiver aberta
    _startBackgroundSyncTimer();
  }

  /// Sync periódico a cada 30s enquanto houver ordens ativas (não-terminais)
  void _startBackgroundSyncTimer() {
    _backgroundSyncTimer?.cancel();
    _backgroundSyncTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (_currentUserPubkey == null) return;
      final hasActiveOrders = _orders.any((o) =>
        o.status == 'pending' || o.status == 'payment_received' ||
        o.status == 'accepted' || o.status == 'awaiting_confirmation'
      );
      if (!hasActiveOrders) return;
      try {
        await syncOrdersFromNostr();
      } catch (_) {}
    });
  }

  // Limpar ordens ao fazer logout - SEGURANÃâ¡A CRÃÂTICA
  void clearOrders() {
    _backgroundSyncTimer?.cancel();
    _orders = [];
    _availableOrdersForProvider = [];  // TambÃÂ©m limpar lista de disponÃÂ­veis
    _currentOrder = null;
    _currentUserPubkey = null;
    _isProviderMode = false;  // Reset modo provedor
    _isInitialized = false;
    _immediateNotify();
  }

  // Carregar ordens do SharedPreferences
  Future<void> _loadSavedOrders() async {
    // SEGURANÃâ¡A CRÃÂTICA: NÃÂ£o carregar ordens de 'orders_anonymous'
    // Isso previne vazamento de ordens de outros usuÃÂ¡rios para contas novas
    if (_currentUserPubkey == null || _currentUserPubkey!.isEmpty) {
      return;
    }
    
    try {
      final prefs = await SharedPreferences.getInstance();
      final ordersJson = prefs.getString(_ordersKey);
      
      if (ordersJson != null) {
        final List<dynamic> ordersList = json.decode(ordersJson);
        _orders = ordersList.map((data) {
          try {
            return Order.fromJson(data);
          } catch (e) {
            return null;
          }
        }).whereType<Order>().toList(); // Remove nulls
        
        // PROTEÃâ¡ÃÆO: Cachear ordens salvas para proteger contra regressÃÂ£o de status
        // Quando o relay nÃÂ£o retorna o evento 'completed', o cache local preserva o status correto
        for (final order in _orders) {
          _savedOrdersCache[order.id] = order;
        }
        
        
        // SEGURANÃâ¡A CRÃÂTICA: Filtrar ordens de OUTROS usuÃÂ¡rios que vazaram para este storage
        // Isso pode acontecer se o modo provedor salvou ordens incorretamente
        final beforeFilter = _orders.length;
        _orders = _orders.where((o) {
          // REGRA ESTRITA: Ordem DEVE ter userPubkey igual ao usuÃÂ¡rio atual
          // NÃÂ£o aceitar mais ordens sem pubkey (eram causando vazamento)
          final isOwner = o.userPubkey == _currentUserPubkey;
          // Ordem que este usuÃÂ¡rio aceitou como provedor
          final isProvider = o.providerId == _currentUserPubkey;
          
          if (isOwner || isProvider) {
            return true;
          }
          
          // Log ordens removidas
          if (o.userPubkey == null || o.userPubkey!.isEmpty) {
          } else {
          }
          return false;
        }).toList();
        
        final removedOtherUsers = beforeFilter - _orders.length;
        if (removedOtherUsers > 0) {
          // Salvar storage limpo
          await _saveOnlyUserOrders();
        }
        
        // CORREÃâ¡ÃÆO: Remover providerId falso (provider_test_001) de ordens
        // Este valor foi setado erroneamente por migraÃÂ§ÃÂ£o antiga
        // O providerId correto serÃÂ¡ recuperado do Nostr durante o sync
        bool needsMigration = false;
        for (int i = 0; i < _orders.length; i++) {
          final order = _orders[i];
          
          // Se ordem tem o providerId de teste antigo, REMOVER (serÃÂ¡ corrigido pelo Nostr)
          if (order.providerId == 'provider_test_001') {
            // Setar providerId como null para que seja recuperado do Nostr
            _orders[i] = order.copyWith(providerId: null);
            needsMigration = true;
          }
        }
        
        // v257: Corrigir userPubkey corrompido em ordens aceitas como provedor
        // Quando a ordem tem userPubkey == currentUserPubkey E providerId == currentUserPubkey,
        // o userPubkey esta errado (deveria ser o criador, nao o provedor)
        if (_currentUserPubkey != null) {
          for (int i = 0; i < _orders.length; i++) {
            final order = _orders[i];
            if (order.userPubkey == _currentUserPubkey &&
                order.providerId == _currentUserPubkey) {
              // userPubkey == providerId == eu => userPubkey esta errado
              // Marcar para correcao durante proximo sync
              broLog('v257-FIX: ordem  tem userPubkey corrompido (== providerId)');
              needsMigration = true;
              // Flag para republish posterior
              _ordersNeedingUserPubkeyFix.add(order.id);
            }
          }
        }
        
        // Se houve migracao, salvar
        if (needsMigration) {
          await _saveOrders();
        }
      } else {
      }
    } catch (e) {
      // Em caso de erro, limpar dados corrompidos
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_ordersKey);
      } catch (e2) {
      }
    }
  }

  /// Corrigir ordens que foram marcadas incorretamente como "payment_received"
  /// pela reconciliaÃÂ§ÃÂ£o automÃÂ¡tica antiga (baseada apenas em saldo).
  /// 
  /// Corrigir ordens marcadas incorretamente como "payment_received"
  /// 
  /// REGRA SIMPLES: Se a ordem tem status "payment_received" mas NÃÆO tem paymentHash,
  /// ÃÂ© um falso positivo e deve voltar para "pending".
  /// 
  /// Ordens COM paymentHash foram verificadas pelo SDK Breez e sÃÂ£o vÃÂ¡lidas.
  Future<void> _fixIncorrectlyPaidOrders() async {
    // Buscar ordens com payment_received
    final paidOrders = _orders.where((o) => o.status == 'payment_received').toList();
    
    if (paidOrders.isEmpty) {
      return;
    }
    
    
    bool needsCorrection = false;
    
    for (final order in paidOrders) {
      // Se NÃÆO tem paymentHash, ÃÂ© falso positivo!
      if (order.paymentHash == null || order.paymentHash!.isEmpty) {
        
        final index = _orders.indexWhere((o) => o.id == order.id);
        if (index != -1) {
          _orders[index] = _orders[index].copyWith(status: 'pending');
          needsCorrection = true;
        }
      } else {
      }
    }
    
    if (needsCorrection) {
      await _saveOrders();
      
      // Republicar no Nostr com status correto
      for (final order in _orders.where((o) => o.status == 'pending')) {
        try {
          await _publishOrderToNostr(order);
        } catch (e) {
        }
      }
    }
  }

  /// Expirar ordens pendentes antigas (> 2 horas sem aceite)
  /// Ordens que ficam muito tempo pendentes provavelmente foram abandonadas
  // Salvar ordens no SharedPreferences (SEMPRE salva, nÃÂ£o sÃÂ³ em testMode)
  // SEGURANÃâ¡A: Agora sÃÂ³ salva ordens do usuÃÂ¡rio atual (igual _saveOnlyUserOrders)
  Future<void> _saveOrders() async {
    // SEGURANÃâ¡A CRÃÂTICA: NÃÂ£o salvar se nÃÂ£o temos pubkey definida
    // Isso previne salvar ordens de outros usuÃÂ¡rios no storage 'orders_anonymous'
    if (_currentUserPubkey == null || _currentUserPubkey!.isEmpty) {
      return;
    }
    
    try {
      // SEGURANÃâ¡A: Filtrar apenas ordens do usuÃÂ¡rio atual antes de salvar
      final userOrders = _orders.where((o) {
        final isMine = o.userPubkey == _currentUserPubkey ||
            o.providerId == _currentUserPubkey;
        if (!isMine) return false;
        // v348: Excluir ordens onde admin participou apenas como mediador
        if (o.providerId == _currentUserPubkey && o.userPubkey != _currentUserPubkey) {
          final meta = o.metadata;
          if (meta != null && meta['disputeProviderPaidBy'] == 'admin') return false;
        }
        return true;
      }).toList();
      
      final prefs = await SharedPreferences.getInstance();
      final ordersJson = json.encode(userOrders.map((o) => o.toJson()).toList());
      await prefs.setString(_ordersKey, ordersJson);
      
      // Log de cada ordem salva
      for (var order in userOrders) {
      }
    } catch (e) {
    }
  }
  
  /// SEGURANÃâ¡A: Salvar APENAS ordens do usuÃÂ¡rio atual no SharedPreferences
  /// Ordens de outros usuÃÂ¡rios (visualizadas no modo provedor) ficam apenas em memÃÂ³ria
  Future<void> _saveOnlyUserOrders() async {
    // SEGURANÃâ¡A CRÃÂTICA: NÃÂ£o salvar se nÃÂ£o temos pubkey definida
    // Isso previne que ordens de outros usuÃÂ¡rios sejam salvas em 'orders_anonymous'
    if (_currentUserPubkey == null || _currentUserPubkey!.isEmpty) {
      return;
    }
    
    try {
      // Filtrar apenas ordens do usuario atual
      // v348: Excluir ordens onde admin participou apenas como mediador
      final userOrders = _orders.where((o) {
        final isMine = o.userPubkey == _currentUserPubkey ||
            o.providerId == _currentUserPubkey;
        if (!isMine) return false;
        if (o.providerId == _currentUserPubkey && o.userPubkey != _currentUserPubkey) {
          final meta = o.metadata;
          if (meta != null && meta['disputeProviderPaidBy'] == 'admin') return false;
        }
        return true;
      }).toList();
      
      final prefs = await SharedPreferences.getInstance();
      final ordersJson = json.encode(userOrders.map((o) => o.toJson()).toList());
      await prefs.setString(_ordersKey, ordersJson);
      
      // PROTEÃâ¡ÃÆO: Atualizar cache local para proteger contra regressÃÂ£o de status
      for (final order in userOrders) {
        _savedOrdersCache[order.id] = order;
      }
    } catch (e) {
    }
  }

  /// Corrigir status de uma ordem manualmente
  /// Usado para corrigir ordens que foram marcadas incorretamente
  Future<bool> fixOrderStatus(String orderId, String newStatus) async {
    final index = _orders.indexWhere((o) => o.id == orderId);
    if (index == -1) {
      return false;
    }
    
    final oldStatus = _orders[index].status;
    _orders[index] = _orders[index].copyWith(status: newStatus);
    
    await _saveOrders();
    _throttledNotify();
    return true;
  }

  /// Cancelar uma ordem pendente
  /// Apenas ordens com status 'pending' podem ser canceladas
  /// SEGURANÃâ¡A: Apenas o dono da ordem pode cancelÃÂ¡-la!
  Future<bool> cancelOrder(String orderId) async {
    final index = _orders.indexWhere((o) => o.id == orderId);
    if (index == -1) {
      return false;
    }
    
    final order = _orders[index];
    
    // VERIFICAÃâ¡ÃÆO DE SEGURANÃâ¡A: Apenas o dono pode cancelar
    if (order.userPubkey != null && 
        _currentUserPubkey != null && 
        order.userPubkey != _currentUserPubkey) {
      return false;
    }
    
    if (order.status != 'pending') {
      return false;
    }
    
    _orders[index] = order.copyWith(status: 'cancelled');
    
    await _saveOrders();
    
    // Publicar cancelamento no Nostr
    // v257: SEMPRE incluir providerId e orderUserPubkey para tags #p corretas
    try {
      final privateKey = _nostrService.privateKey;
      if (privateKey != null) {
        await _nostrOrderService.updateOrderStatus(
          privateKey: privateKey,
          orderId: orderId,
          newStatus: 'cancelled',
          providerId: order.providerId,
          orderUserPubkey: order.userPubkey,
        );
      }
    } catch (e) {
    }
    
    _throttledNotify();
    return true;
  }

  /// Verificar se um pagamento especÃÂ­fico corresponde a uma ordem pendente
  /// Usa match por valor quando paymentHash nÃÂ£o estÃÂ¡ disponÃÂ­vel (ordens antigas)
  /// IMPORTANTE: Este mÃÂ©todo deve ser chamado manualmente pelo usuÃÂ¡rio para evitar falsos positivos
  Future<bool> verifyAndFixOrderPayment(String orderId, List<dynamic> breezPayments) async {
    final index = _orders.indexWhere((o) => o.id == orderId);
    if (index == -1) {
      return false;
    }
    
    final order = _orders[index];
    if (order.status != 'pending') {
      return false;
    }
    
    final expectedSats = (order.btcAmount * 100000000).toInt();
    
    // Primeiro tentar por paymentHash (mais seguro)
    if (order.paymentHash != null && order.paymentHash!.isNotEmpty) {
      for (var payment in breezPayments) {
        final paymentHash = payment['paymentHash'] as String?;
        if (paymentHash == order.paymentHash) {
          _orders[index] = order.copyWith(status: 'payment_received');
          await _saveOrders();
          _throttledNotify();
          return true;
        }
      }
    }
    
    // Fallback: verificar por valor (menos seguro, mas ÃÂºtil para ordens antigas)
    // Tolerar diferenÃÂ§a de atÃÂ© 5 sats (taxas de rede podem variar ligeiramente)
    for (var payment in breezPayments) {
      final paymentAmount = (payment['amount'] is int) 
          ? payment['amount'] as int 
          : int.tryParse(payment['amount']?.toString() ?? '0') ?? 0;
      
      final diff = (paymentAmount - expectedSats).abs();
      if (diff <= 5) {
        _orders[index] = order.copyWith(
          status: 'payment_received',
          metadata: {
            ...?order.metadata,
            'verifiedManually': true,
            'verifiedAt': DateTime.now().toIso8601String(),
            'paymentAmount': paymentAmount,
          },
        );
        await _saveOrders();
        _throttledNotify();
        return true;
      }
    }
    
    return false;
  }

  // Criar ordem LOCAL (NÃÆO publica no Nostr!)
  // A ordem sÃÂ³ serÃÂ¡ publicada no Nostr APÃâS pagamento confirmado
  // Isso evita que Bros vejam ordens sem depÃÂ³sito
  Future<Order?> createOrder({
    required String billType,
    required String billCode,
    required double amount,
    required double btcAmount,
    required double btcPrice,
  }) async {
    // VALIDAÃâ¡ÃÆO CRÃÂTICA: Nunca criar ordem com amount = 0
    if (amount <= 0) {
      _error = 'Valor da ordem invÃÂ¡lido';
      _immediateNotify();
      return null;
    }
    
    if (btcAmount <= 0) {
      _error = 'Valor em BTC invÃÂ¡lido';
      _immediateNotify();
      return null;
    }
    
    _isLoading = true;
    _error = null;
    _immediateNotify();

    try {
      
      // Calcular taxas (1% provider + 2% platform)
      final providerFee = amount * 0.01;
      final platformFee = amount * 0.02;
      final total = amount + providerFee + platformFee;
      
      // Ã°Å¸âÂ¥ SIMPLIFICADO: Status 'pending' = Aguardando Bro
      // A ordem jÃÂ¡ estÃÂ¡ paga (invoice/endereÃÂ§o jÃÂ¡ foi criado)
      final order = Order(
        id: const Uuid().v4(),
        userPubkey: _currentUserPubkey,
        billType: billType,
        billCode: billCode,
        amount: amount,
        btcAmount: btcAmount,
        btcPrice: btcPrice,
        providerFee: providerFee,
        platformFee: platformFee,
        total: total,
        status: 'pending',  // Ã¢Åâ¦ Direto para pending = Aguardando Bro
        createdAt: DateTime.now(),
      );
      
      // LOG DE VALIDAÃâ¡ÃÆO
      
      _orders.insert(0, order);
      _currentOrder = order;
      
      // Salvar localmente - USAR _saveOrders() para garantir filtro de seguranÃÂ§a!
      await _saveOrders();
      
      _immediateNotify();
      
      // Ã°Å¸âÂ¥ PUBLICAR NO NOSTR IMEDIATAMENTE
      // A ordem jÃÂ¡ estÃÂ¡ com pagamento sendo processado
      _publishOrderToNostr(order);
      
      return order;
    } catch (e) {
      _error = e.toString();
      return null;
    } finally {
      _isLoading = false;
      _immediateNotify();
    }
  }
  
  /// CRÃÂTICO: Publicar ordem no Nostr SOMENTE APÃâS pagamento confirmado
  /// Este mÃÂ©todo transforma a ordem de 'draft' para 'pending' e publica no Nostr
  /// para que os Bros possam vÃÂª-la e aceitar
  Future<bool> publishOrderAfterPayment(String orderId) async {
    
    final index = _orders.indexWhere((o) => o.id == orderId);
    if (index == -1) {
      return false;
    }
    
    final order = _orders[index];
    
    // Validar que ordem estÃÂ¡ em draft (nÃÂ£o foi publicada ainda)
    if (order.status != 'draft') {
      // Se jÃÂ¡ foi publicada, apenas retornar sucesso
      if (order.status == 'pending' || order.status == 'payment_received') {
        return true;
      }
      return false;
    }
    
    try {
      // Atualizar status para 'pending' (agora visÃÂ­vel para Bros)
      _orders[index] = order.copyWith(status: 'pending');
      await _saveOrders();
      _throttledNotify();
      
      // AGORA SIM publicar no Nostr
      await _publishOrderToNostr(_orders[index]);
      
      // Pequeno delay para propagaÃÂ§ÃÂ£o
      await Future.delayed(const Duration(milliseconds: 500));
      
      return true;
    } catch (e) {
      return false;
    }
  }

  // Listar ordens (para usuÃÂ¡rio normal ou provedor)
  Future<void> fetchOrders({String? status, bool forProvider = false}) async {
    _isLoading = true;
    
    // SEGURANÃâ¡A: Definir modo provedor ANTES de sincronizar
    _isProviderMode = forProvider;
    
    // Se SAINDO do modo provedor (ou em modo usuÃÂ¡rio), limpar ordens de outros usuÃÂ¡rios
    if (!forProvider && _orders.isNotEmpty) {
      final before = _orders.length;
      _orders = _orders.where((o) {
        // REGRA ESTRITA: Apenas ordens deste usuÃÂ¡rio
        final isOwner = o.userPubkey == _currentUserPubkey;
        // Ou ordens que este usuÃÂ¡rio aceitou como provedor
        final isProvider = o.providerId == _currentUserPubkey;
        return isOwner || isProvider;
      }).toList();
      final removed = before - _orders.length;
      if (removed > 0) {
        // Salvar storage limpo
        await _saveOnlyUserOrders();
      }
    }
    
    _throttledNotify();
    
    try {
      if (forProvider) {
        // MODO PROVEDOR: Buscar TODAS as ordens pendentes de TODOS os usuÃÂ¡rios
        // force: true Ã¢â¬â aÃÂ§ÃÂ£o explÃÂ­cita do usuÃÂ¡rio, bypass throttle
        // PERFORMANCE: Timeout de 60s Ã¢â¬â prefetch + parallelization makes it faster
        await syncAllPendingOrdersFromNostr(force: true).timeout(
          const Duration(seconds: 60),
          onTimeout: () {
            broLog('Ã¢ÂÂ° fetchOrders: timeout externo de 60s atingido');
          },
        );
      } else {
        // MODO USUÃÂRIO: Buscar apenas ordens do prÃÂ³prio usuÃÂ¡rio
        // force: true Ã¢â¬â aÃÂ§ÃÂ£o explÃÂ­cita do usuÃÂ¡rio, bypass throttle
        await syncOrdersFromNostr(force: true).timeout(
          const Duration(seconds: 15),
          onTimeout: () {
          },
        );
      }
    } catch (e) {
    } finally {
      _isLoading = false;
      _throttledNotify();
    }
  }
  
  /// Buscar TODAS as ordens pendentes do Nostr (para modo Provedor/Bro)
  /// SEGURANÃâ¡A: Ordens de outros usuÃÂ¡rios vÃÂ£o para _availableOrdersForProvider
  /// e NUNCA sÃÂ£o adicionadas ÃÂ  lista principal _orders!
  Future<void> syncAllPendingOrdersFromNostr({bool force = false}) async {
    // v252: Se sync em andamento e force=true (pull-to-refresh), aguardar sync atual
    // v259: Detectar lock stale no provider sync
    if (_isSyncingProvider && _syncProviderStartedAt != null) {
      final elapsed = DateTime.now().difference(_syncProviderStartedAt!).inSeconds;
      if (elapsed > _maxSyncDurationSeconds) {
        broLog('v259: syncProvider LOCK STALE detectado (${elapsed}s) - resetando');
        _isSyncingProvider = false;
        _syncProviderStartedAt = null;
        _providerSyncCompleter?.complete();
        _providerSyncCompleter = null;
      }
    }
    if (_isSyncingProvider) {
      if (force && _providerSyncCompleter != null) {
        broLog('syncAllPending: sync em andamento, aguardando (pull-to-refresh)...');
        try {
          await _providerSyncCompleter!.future.timeout(const Duration(seconds: 15));
        } catch (_) {
          broLog('syncAllPending: timeout aguardando sync atual');
        }
      }
      return;
    }
    
    _providerSyncCompleter = Completer<void>();
    _isSyncingProvider = true;
    _syncProviderStartedAt = DateTime.now(); // v259: track start time
    
    try {
      
      // CORREÃâ¡ÃÆO v1.0.129: Pre-fetch status updates para que estejam em cache
      // ANTES das 3 buscas paralelas. Sem isso, as 3 funÃÂ§ÃÂµes chamam
      // _fetchAllOrderStatusUpdates simultaneamente, criando 18+ conexÃÂµes WebSocket
      // que saturam a rede e causam timeouts.
      try {
        await _nostrOrderService.prefetchStatusUpdates();
      } catch (_) {}
      
      // Helper para busca segura (captura exceÃÂ§ÃÂµes e retorna lista vazia)
      // CORREÃâ¡ÃÆO v1.0.129: Aumentado de 15s para 30s Ã¢â¬â com runZonedGuarded cada relay
      // tem 8s timeout + 10s zone timeout, 15s era insuficiente para 3 estratÃÂ©gias
      Future<List<Order>> safeFetch(Future<List<Order>> Function() fetcher, String name) async {
        try {
          return await fetcher().timeout(const Duration(seconds: 30), onTimeout: () {
            broLog('Ã¢ÂÂ° safeFetch timeout: $name');
            return <Order>[];
          });
        } catch (e) {
          broLog('Ã¢ÂÅ safeFetch error $name: $e');
          return <Order>[];
        }
      }
      
      // Executar buscas EM PARALELO com tratamento de erro individual
      // PERFORMANCE v1.0.219+220: Pular fetchUserOrders se todas ordens são terminais
      // (mesma otimização já aplicada no syncOrdersFromNostr)
      const terminalOnly = ['completed', 'cancelled', 'liquidated'];
      final hasActiveUserOrders = _orders.isEmpty || _orders.any((o) => 
        (o.userPubkey == _currentUserPubkey || o.providerId == _currentUserPubkey) && 
        !terminalOnly.contains(o.status)
      );
      
      if (!hasActiveUserOrders) {
        broLog('⚡ syncProvider: todas ordens do user são terminais, pulando fetchUserOrders');
      }
      
      final results = await Future.wait([
        safeFetch(() => _nostrOrderService.fetchPendingOrders(), 'fetchPendingOrders'),
        if (hasActiveUserOrders)
          safeFetch(() => _currentUserPubkey != null 
              ? _nostrOrderService.fetchUserOrders(_currentUserPubkey!)
              : Future.value(<Order>[]), 'fetchUserOrders')
        else
          Future.value(<Order>[]),
        safeFetch(() => _currentUserPubkey != null
            ? _nostrOrderService.fetchProviderOrders(_currentUserPubkey!)
            : Future.value(<Order>[]), 'fetchProviderOrders'),
      ]);
      
      final allPendingOrders = results[0];
      final userOrders = results[1];
      final providerOrders = results[2];
      
      broLog('Ã°Å¸ââ syncProvider: pending=${allPendingOrders.length}, user=${userOrders.length}, provider=${providerOrders.length}');
      
      // PROTEÃâ¡ÃÆO: Se TODAS as buscas retornaram vazio, provavelmente houve timeout/erro
      // NÃÂ£o limpar a lista anterior para nÃÂ£o perder dados
      if (allPendingOrders.isEmpty && userOrders.isEmpty && providerOrders.isEmpty) {
        broLog('Ã¢Å¡Â Ã¯Â¸Â syncProvider: TODAS as buscas retornaram vazio - mantendo dados anteriores');
        _lastProviderSyncTime = DateTime.now();
        _isSyncingProvider = false;
        _syncProviderStartedAt = null; // v259: clear stale tracker
        _providerSyncCompleter?.complete();
        _providerSyncCompleter = null;
        return;
      }
      
      // SEGURANÃâ¡A: Separar ordens em duas listas:
      // 1. Ordens do usuÃÂ¡rio atual -> _orders
      // 2. Ordens de outros (disponÃÂ­veis para aceitar) -> _availableOrdersForProvider
      
      // CORREÃâ¡ÃÆO: Acumular em lista temporÃÂ¡ria, sÃÂ³ substituir no final
      final newAvailableOrders = <Order>[];
      final seenAvailableIds = <String>{}; // Para evitar duplicatas
      int addedToAvailable = 0;
      int updated = 0;
      
      for (var pendingOrder in allPendingOrders) {
        // Ignorar ordens com amount=0
        if (pendingOrder.amount <= 0) continue;
        
        // DEDUPLICAÃâ¡ÃÆO: Ignorar se jÃÂ¡ vimos esta ordem
        if (seenAvailableIds.contains(pendingOrder.id)) {
          continue;
        }
        seenAvailableIds.add(pendingOrder.id);
        
        // Verificar se ÃÂ© ordem do usuÃÂ¡rio atual OU ordem que ele aceitou como provedor
        final isMyOrder = pendingOrder.userPubkey == _currentUserPubkey;
        final isMyProviderOrder = pendingOrder.providerId == _currentUserPubkey;
        
        // Se NÃÆO ÃÂ© minha ordem e NÃÆO ÃÂ© ordem que aceitei, verificar status
        // Ordens de outros com status final nÃÂ£o interessam
        if (!isMyOrder && !isMyProviderOrder) {
          if (pendingOrder.status == 'cancelled' || pendingOrder.status == 'completed' || 
              pendingOrder.status == 'liquidated' || pendingOrder.status == 'disputed') continue;
        }
        
        if (isMyOrder || isMyProviderOrder) {
          // Ordem do usuÃÂ¡rio OU ordem aceita como provedor: atualizar na lista _orders
          final existingIndex = _orders.indexWhere((o) => o.id == pendingOrder.id);
          if (existingIndex == -1) {
            // SEGURANÃâ¡A CRÃÂTICA: SÃÂ³ adicionar se realmente ÃÂ© minha ordem ou aceitei como provedor
            // NUNCA adicionar ordem de outro usuÃÂ¡rio aqui!
            if (isMyOrder || (isMyProviderOrder && pendingOrder.providerId == _currentUserPubkey)) {
              _orders.add(pendingOrder);
            } else {
            }
          } else {
            final existing = _orders[existingIndex];
            // SEGURANÃâ¡A: Verificar que ordem pertence ao usuÃÂ¡rio atual antes de atualizar
            final isOwnerExisting = existing.userPubkey == _currentUserPubkey;
            final isProviderExisting = existing.providerId == _currentUserPubkey;
            
            if (!isOwnerExisting && !isProviderExisting) {
              continue;
            }
            
            // CORREÃâ¡ÃÆO: Apenas status FINAIS devem ser protegidos
            // accepted e awaiting_confirmation podem evoluir para completed
            const protectedStatuses = ['cancelled', 'completed', 'liquidated'];
            if (protectedStatuses.contains(existing.status)) {
              continue;
            }
            
            // CORREÃâ¡ÃÆO: Sempre atualizar se status do Nostr ÃÂ© mais recente
            // Mesmo para ordens completed (para que provedor veja completed)
            if (_isStatusMoreRecent(pendingOrder.status, existing.status)) {
              _orders[existingIndex] = existing.copyWith(
                providerId: existing.providerId ?? pendingOrder.providerId,
                status: pendingOrder.status,
                completedAt: pendingOrder.status == 'completed' ? DateTime.now() : existing.completedAt,
              );
              updated++;
            }
          }
        } else {
          // Ordem de OUTRO usuÃÂ¡rio: adicionar apenas ÃÂ  lista de disponÃÂ­veis
          // NUNCA adicionar ÃÂ  lista principal _orders!
          
          // CORREÃâ¡ÃÆO CRÃÂTICA: Verificar se essa ordem jÃÂ¡ existe em _orders com status avanÃÂ§ado
          // (significa que EU jÃÂ¡ aceitei essa ordem, mas o evento Nostr ainda estÃÂ¡ como pending)
          final existingInOrders = _orders.cast<Order?>().firstWhere(
            (o) => o?.id == pendingOrder.id,
            orElse: () => null,
          );
          
          if (existingInOrders != null) {
            // Ordem jÃÂ¡ existe - NÃÆO adicionar ÃÂ  lista de disponÃÂ­veis
            const protectedStatuses = ['accepted', 'awaiting_confirmation', 'completed', 'liquidated', 'cancelled', 'disputed'];
            if (protectedStatuses.contains(existingInOrders.status)) {
              continue;
            }
          }
          
          newAvailableOrders.add(pendingOrder);
          addedToAvailable++;
        }
      }
      
      // v1.0.129+223: SEMPRE atualizar _availableOrdersForProvider
      // A proteção contra falha de rede já foi feita acima (return early se TODAS as buscas vazias).
      // Se chegamos aqui, pelo menos uma busca retornou dados → rede OK → 0 pendentes é genuíno.
      // BUG ANTERIOR: "if (allPendingOrders.isNotEmpty)" impedia limpeza quando
      // a única ordem pendente era aceita, causando gasto duplo.
      {
        final previousCount = _availableOrdersForProvider.length;
        _availableOrdersForProvider = newAvailableOrders;
        
        if (previousCount > 0 && newAvailableOrders.isEmpty) {
          broLog('✅ Lista de disponiveis limpa: $previousCount -> 0 (todas aceitas/concluidas)');
        } else if (previousCount != newAvailableOrders.length) {
          broLog('Disponiveis: $previousCount -> ${newAvailableOrders.length}');
        }
      }
      
      broLog('Ã°Å¸ââ syncProvider: $addedToAvailable disponÃÂ­veis, $updated atualizadas, _orders total=${_orders.length}');
      
      // Processar ordens do prÃÂ³prio usuÃÂ¡rio (jÃÂ¡ buscadas em paralelo)
      int addedFromUser = 0;
      int addedFromProviderHistory = 0;
      
      // 1. Processar ordens criadas pelo usuÃÂ¡rio
      for (var order in userOrders) {
        final existingIndex = _orders.indexWhere((o) => o.id == order.id);
        if (existingIndex == -1 && order.amount > 0) {
          _orders.add(order);
          addedFromUser++;
        }
      }
      
      // 2. CRÃÂTICO: Processar ordens onde este usuÃÂ¡rio ÃÂ© o PROVEDOR (histÃÂ³rico de ordens aceitas)
      // Estas ordens foram buscadas em paralelo acima
      
      for (var provOrder in providerOrders) {
        // SEGURANCA: Ignorar ordens proprias (nao sou meu proprio Bro)
        if (provOrder.userPubkey == _currentUserPubkey) continue;
        final existingIndex = _orders.indexWhere((o) => o.id == provOrder.id);
        if (existingIndex == -1 && provOrder.amount > 0) {
          // Nova ordem do histÃÂ³rico - adicionar
          // NOTA: O status agora jÃÂ¡ vem correto de fetchProviderOrders (que busca updates)
          // SÃÂ³ forÃÂ§ar "accepted" se vier como "pending" E nÃÂ£o houver outro status mais avanÃÂ§ado
          if (provOrder.status == 'pending') {
            // Se status ainda ÃÂ© pending, significa que nÃÂ£o houve evento de update
            // EntÃÂ£o esta ÃÂ© uma ordem aceita mas ainda nÃÂ£o processada
            provOrder = provOrder.copyWith(status: 'accepted');
          }
          
          // CORREÃâ¡ÃÆO BUG: Verificar se esta ordem existe no cache local com status mais avanÃÂ§ado
          // CenÃÂ¡rio: app reinicia, cache tem 'completed', mas relay nÃÂ£o retornou o evento completed
          // Sem isso, a ordem reaparece como 'awaiting_confirmation'
          // IMPORTANTE: NUNCA sobrescrever status 'cancelled' do relay Ã¢â¬â cancelamento ÃÂ© aÃÂ§ÃÂ£o explÃÂ­cita
          final savedOrder = _savedOrdersCache[provOrder.id];
          if (savedOrder != null && 
              provOrder.status != 'cancelled' &&
              _isStatusMoreRecent(savedOrder.status, provOrder.status)) {
            broLog('Ã°Å¸âºÂ¡Ã¯Â¸Â PROTEÃâ¡ÃÆO: Ordem ${provOrder.id.substring(0, 8)} no cache=${ savedOrder.status}, relay=${provOrder.status} - mantendo cache');
            provOrder = provOrder.copyWith(
              status: savedOrder.status,
              completedAt: savedOrder.completedAt,
            );
          }
          
          _orders.add(provOrder);
          addedFromProviderHistory++;
        } else if (existingIndex != -1) {
          // Ordem jÃÂ¡ existe - atualizar se status do Nostr ÃÂ© mais avanÃÂ§ado
          final existing = _orders[existingIndex];
          
          // CORREÃâ¡ÃÆO: Se Nostr diz 'cancelled', SEMPRE aceitar Ã¢â¬â cancelamento ÃÂ© aÃÂ§ÃÂ£o explÃÂ­cita
          if (provOrder.status == 'cancelled' && existing.status != 'cancelled') {
            _orders[existingIndex] = existing.copyWith(status: 'cancelled');
            continue;
          }
          
          // CORREÃâ¡ÃÆO: Status "accepted" NÃÆO deve ser protegido pois pode evoluir para completed
          // Apenas status finais devem ser protegidos
          const protectedStatuses = ['cancelled', 'completed', 'liquidated'];
          if (protectedStatuses.contains(existing.status)) {
            continue;
          }
          
          // Atualizar se o status do Nostr ÃÂ© mais avanÃÂ§ado
          if (_isStatusMoreRecent(provOrder.status, existing.status)) {
            _orders[existingIndex] = existing.copyWith(
              status: provOrder.status,
              completedAt: provOrder.status == 'completed' ? DateTime.now() : existing.completedAt,
            );
          }
        }
      }
      
      
      // 3. CRÃÂTICO: Buscar updates de status para ordens que este provedor aceitou
      // Isso permite que o Bro veja quando o usuÃÂ¡rio confirmou (status=completed)
      if (_currentUserPubkey != null && _currentUserPubkey!.isNotEmpty) {
        
        // PERFORMANCE: SÃÂ³ buscar updates para ordens com status NÃÆO-FINAL
        // Ordens completed/cancelled/liquidated nao precisam de updates
        // NOTA: 'disputed' NAO e final - pode transicionar para completed via resolucao
        const finalStatuses = ['completed', 'cancelled', 'liquidated'];
        final myOrderIds = _orders
            .where((o) => o.providerId == _currentUserPubkey && !finalStatuses.contains(o.status))
            .map((o) => o.id)
            .toList();
        
        // TambÃÂ©m buscar ordens em awaiting_confirmation que podem ter sido atualizadas
        final awaitingOrderIds = _orders
            .where((o) => o.providerId == _currentUserPubkey && o.status == 'awaiting_confirmation')
            .map((o) => o.id)
            .toList();
        
        broLog('Ã°Å¸âÂ Provider status check: ${myOrderIds.length} ordens nÃÂ£o-finais, ${awaitingOrderIds.length} aguardando confirmaÃÂ§ÃÂ£o');
        if (awaitingOrderIds.isNotEmpty) {
          broLog('   Aguardando: ${awaitingOrderIds.map((id) => id.substring(0, 8)).join(", ")}');
        }
        
        if (myOrderIds.isNotEmpty) {
          final providerUpdates = await _nostrOrderService.fetchOrderUpdatesForProvider(
            _currentUserPubkey!,
            orderIds: myOrderIds,
          );
          
          broLog('Ã°Å¸âÂ Provider updates encontrados: ${providerUpdates.length}');
          for (final entry in providerUpdates.entries) {
            broLog('   Update: orderId=${entry.key.substring(0, 8)} status=${entry.value['status']}');
          }
          
          int statusUpdated = 0;
          for (final entry in providerUpdates.entries) {
            final orderId = entry.key;
            final update = entry.value;
            final newStatus = update['status'] as String?;
            
            if (newStatus == null) {
              broLog('   Ã¢Å¡Â Ã¯Â¸Â Update sem status para orderId=${orderId.substring(0, 8)}');
              continue;
            }
            
            final existingIndex = _orders.indexWhere((o) => o.id == orderId);
            if (existingIndex == -1) {
              broLog('   Ã¢Å¡Â Ã¯Â¸Â Ordem ${orderId.substring(0, 8)} nÃÂ£o encontrada em _orders');
              continue;
            }
            
            final existing = _orders[existingIndex];
            broLog('   Comparando: orderId=${orderId.substring(0, 8)} local=${existing.status} nostr=$newStatus');
            
            // Verificar se ÃÂ© completed e local ÃÂ© awaiting_confirmation
            if (newStatus == 'completed' && existing.status == 'awaiting_confirmation') {
              _orders[existingIndex] = existing.copyWith(
                status: 'completed',
                completedAt: DateTime.now(),
              );
              statusUpdated++;
              broLog('   Ã¢Åâ¦ Atualizado ${orderId.substring(0, 8)} para completed!');
            } else if (_isStatusMoreRecent(newStatus, existing.status)) {
              // Caso genÃÂ©rico
              _orders[existingIndex] = existing.copyWith(
                status: newStatus,
                completedAt: newStatus == 'completed' ? DateTime.now() : existing.completedAt,
              );
              statusUpdated++;
              broLog('   Ã¢Åâ¦ Atualizado ${orderId.substring(0, 8)} para $newStatus');
            } else {
              broLog('   Ã¢ÂÂ­Ã¯Â¸Â Sem mudanÃÂ§a para ${orderId.substring(0, 8)}: $newStatus nÃÂ£o ÃÂ© mais recente que ${existing.status}');
            }
          }
          
          broLog('Ã°Å¸ââ Provider sync: $statusUpdated ordens atualizadas');
        }
      }
      
      // Ordenar por data (mais recente primeiro)
      _orders.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      
      // v253: AUTO-REPAIR: Republicar status de ordens que existem localmente
      // mas nao foram encontradas em nenhuma busca dos relays (eventos perdidos)
      // v253: AUTO-REPAIR: Republicar status de ordens com eventos perdidos
      // v259: Timeout global no auto-repair para nao travar sync
      try {
        await _autoRepairMissingOrderEvents(
          allPendingOrders: allPendingOrders,
          userOrders: userOrders,
          providerOrders: providerOrders,
        ).timeout(const Duration(seconds: 30), onTimeout: () {
          broLog('v259: AUTO-REPAIR timeout (30s) no provider sync - continuando');
        });
      } catch (e) {
        broLog('v259: AUTO-REPAIR exception no provider sync: \$e');
      }
      
      // v257/v259: Corrigir ordens com userPubkey corrompido (com timeout)
      try {
        await _fixCorruptedUserPubkeys().timeout(const Duration(seconds: 20), onTimeout: () {
          broLog('v259: _fixCorruptedUserPubkeys timeout (20s) - continuando');
        });
      } catch (e) {
        broLog('v259: _fixCorruptedUserPubkeys exception: $e');
      }
      
      // AUTO-LIQUIDAÃâ¡ÃÆO: Verificar ordens awaiting_confirmation com prazo expirado
      await _checkAutoLiquidation();
      
      // v133: Renovar invoices para ordens liquidadas (provider side)
      await _renewInvoicesForLiquidatedAsProvider();
      
      // SEGURANÃâ¡A: NÃÆO salvar ordens de outros usuÃÂ¡rios no storage local!
      // Apenas salvar as ordens que pertencem ao usuÃÂ¡rio atual
      // As ordens de outros ficam apenas em memÃÂ³ria (para visualizaÃÂ§ÃÂ£o do provedor)
      _debouncedSave();
      _lastProviderSyncTime = DateTime.now();
      _immediateNotify(); // v269: provider sync sempre notifica imediatamente
      
    } catch (e) {
    } finally {
      _isSyncingProvider = false;
      _syncProviderStartedAt = null; // v259: clear stale tracker
      _providerSyncCompleter?.complete();
      _providerSyncCompleter = null;
    }
  }

  // Buscar ordem especÃÂ­fica
  Future<Order?> fetchOrder(String orderId) async {
    _isLoading = true;
    _error = null;
    _immediateNotify();

    try {
      final orderData = await _apiService.getOrder(orderId);
      
      if (orderData != null) {
        final order = Order.fromJson(orderData);
        
        // SEGURANÃâ¡A: SÃÂ³ inserir se for ordem do usuÃÂ¡rio atual ou modo provedor ativo
        final isUserOrder = order.userPubkey == _currentUserPubkey;
        final isProviderOrder = order.providerId == _currentUserPubkey;
        
        if (!_isProviderMode && !isUserOrder && !isProviderOrder) {
          return null;
        }
        
        // Atualizar na lista
        final index = _orders.indexWhere((o) => o.id == orderId);
        if (index != -1) {
          _orders[index] = order;
        } else {
          _orders.insert(0, order);
        }
        
        _currentOrder = order;
        _immediateNotify();
        return order;
      }

      return null;
    } catch (e) {
      _error = e.toString();
      return null;
    } finally {
      _isLoading = false;
      _immediateNotify();
    }
  }

  // Aceitar ordem (provider)
  Future<bool> acceptOrder(String orderId, String providerId) async {
    _isLoading = true;
    _error = null;
    _immediateNotify();

    try {
      final success = await _apiService.acceptOrder(orderId, providerId);
      
      if (success) {
        await fetchOrder(orderId); // Atualizar ordem
      }

      return success;
    } catch (e) {
      _error = e.toString();
      return false;
    } finally {
      _isLoading = false;
      _immediateNotify();
    }
  }

  /// v261: Re-publica o evento kind 30078 com status terminal no relay.
  /// Isso SUBSTITUI o evento original (status=pending) pelo novo (status=accepted/completed/etc).
  /// Garante que outros provedores NAO vejam a ordem como disponivel,
  /// mesmo se a query de status updates (kind 30079/30080/30081) falhar.
  /// CRÍTICO para status 'accepted': inclui billCode_nip44_provider que o provedor precisa
  /// para descriptografar o código PIX. Faz retry em caso de falha.
  /// So deve ser chamado pelo DONO da ordem.
  Future<void> _republishOrderEventWithTerminalStatus(Order order, String newStatus) async {
    // So re-publicar para status terminal-ish
    const terminalStatuses = ['accepted', 'awaiting_confirmation', 'completed', 'cancelled', 'liquidated', 'disputed'];
    if (!terminalStatuses.contains(newStatus)) return;
    
    // So re-publicar se EU sou o dono da ordem
    if (order.userPubkey != _currentUserPubkey) return;
    
    final privateKey = _nostrService.privateKey;
    if (privateKey == null || privateKey.isEmpty) return;
    
    // Para status 'accepted', o republish é CRÍTICO — inclui billCode_nip44_provider
    // que o provedor precisa para ver o código PIX. Fazemos retry.
    final isAccepted = newStatus == 'accepted';
    final maxAttempts = isAccepted ? 3 : 1;
    
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final success = await _nostrOrderService.republishOrderWithStatus(
          privateKey: privateKey,
          order: order,
          newStatus: newStatus,
          providerId: order.providerId,
        );
        if (success) {
          if (isAccepted) {
            broLog('🔑 [REPUBLISH] billCode_nip44_provider publicado (tentativa $attempt) para ordem ${order.id.substring(0, 8)}');
          }
          return;
        }
        if (isAccepted) {
          broLog('⚠️ [REPUBLISH] Tentativa $attempt/$maxAttempts falhou para ${order.id.substring(0, 8)}');
        }
      } catch (e) {
        broLog('❌ [REPUBLISH] Erro tentativa $attempt/$maxAttempts: $e');
      }
      if (attempt < maxAttempts) {
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    if (isAccepted) {
      broLog('❌ [REPUBLISH] FALHOU todas as $maxAttempts tentativas para ordem ${order.id.substring(0, 8)}!');
    }
  }

  /// Atualiza o billCode de uma ordem localmente (usado pelo provedor após descriptografar do Nostr)
  void updateOrderBillCodeLocal(String orderId, String billCode) {
    final index = _orders.indexWhere((o) => o.id == orderId);
    if (index != -1) {
      _orders[index] = _orders[index].copyWith(billCode: billCode);
      _debouncedSave();
      _throttledNotify();
      broLog('💾 updateOrderBillCodeLocal: ${orderId.substring(0, 8)} → ${billCode.length} chars');
    }
  }

  /// v259: Atualizar status APENAS localmente, SEM publicar no Nostr.
  /// Usado para wallet payments onde o status local (payment_received) não deve
  /// ser publicado no relay, pois a ordem precisa permanecer 'pending' para provedores.
  void updateOrderStatusLocalOnly({
    required String orderId,
    required String status,
  }) {
    final index = _orders.indexWhere((o) => o.id == orderId);
    if (index != -1) {
      final currentStatus = _orders[index].status;
      if (status != 'cancelled' && status != 'disputed' && !_isStatusMoreRecent(status, currentStatus)) {
        broLog('updateOrderStatusLocalOnly: bloqueado $currentStatus -> $status');
        return;
      }
      _orders[index] = _orders[index].copyWith(status: status);
      _debouncedSave();
      _throttledNotify();
      broLog('v259: updateOrderStatusLocalOnly: $orderId -> $status (SEM publicar no Nostr)');
    }
  }

  /// v337: Atualizar apenas metadata local (sem publicar no Nostr)
  /// MERGE: Mantém metadata existente e adiciona/sobrescreve as chaves passadas
  void updateOrderMetadataLocal(String orderId, Map<String, dynamic> metadata) {
    final index = _orders.indexWhere((o) => o.id == orderId);
    if (index != -1) {
      final existingMeta = Map<String, dynamic>.from(_orders[index].metadata ?? {});
      existingMeta.addAll(metadata);
      _orders[index] = _orders[index].copyWith(metadata: existingMeta);
      _debouncedSave();
      _throttledNotify();
      broLog('v337: updateOrderMetadataLocal: $orderId metadata atualizado (merge)');
    }
  }

  // Atualizar status local E publicar no Nostr
  Future<void> updateOrderStatusLocal(String orderId, String status) async {
    final index = _orders.indexWhere((o) => o.id == orderId);
    if (index != -1) {
      // CORREÃâ¡ÃÆO v1.0.129: Verificar se o novo status ÃÂ© progressÃÂ£o vÃÂ¡lida
      // ExceÃÂ§ÃÂ£o: 'cancelled' e 'disputed' sempre sÃÂ£o aceitos (aÃÂ§ÃÂµes explÃÂ­citas)
      final currentStatus = _orders[index].status;
      if (status != 'cancelled' && status != 'disputed' && !_isStatusMoreRecent(status, currentStatus)) {
        broLog('Ã¢Å¡Â Ã¯Â¸Â updateOrderStatusLocal: bloqueado $currentStatus Ã¢â â $status (regressÃÂ£o)');
        return;
      }
      _orders[index] = _orders[index].copyWith(status: status);
      await _saveOrders();
      _throttledNotify();
      
      // IMPORTANTE: Publicar no Nostr para sincronizacao P2P
      // v257: SEMPRE incluir providerId e orderUserPubkey para tags #p corretas
      final orderForUpdate = _orders[index];
      final privateKey = _nostrService.privateKey;
      if (privateKey != null) {
        try {
          final success = await _nostrOrderService.updateOrderStatus(
            privateKey: privateKey,
            orderId: orderId,
            newStatus: status,
            providerId: orderForUpdate.providerId,
            orderUserPubkey: orderForUpdate.userPubkey,
          );
          if (success) {
            // v261: Re-publicar o evento 30078 com status terminal para remover da marketplace
            _republishOrderEventWithTerminalStatus(orderForUpdate, status);
          } else {
          }
        } catch (e) {
        }
      } else {
      }
    }
  }

  // Atualizar status
  Future<bool> updateOrderStatus({
    required String orderId,
    required String status,
    String? providerId,
    Map<String, dynamic>? metadata,
  }) async {
    _isLoading = true;
    _error = null;
    _immediateNotify();

    try {
      // GUARDA v1.0.129+232: 'completed' SÓ pode ser publicado se a ordem está num estado avançado
      // Isso evita auto-complete indevido quando a ordem ainda está em pending/payment_received
      if (status == 'completed') {
        final existingOrder = getOrderById(orderId);
        final currentStatus = existingOrder?.status ?? '';
        final effectiveProviderId = providerId ?? existingOrder?.providerId;
        
        // Se a ordem está em estágios iniciais (pending, payment_received) E não tem provider,
        // é definitivamente um auto-complete indevido - BLOQUEAR
        const earlyStatuses = ['', 'draft', 'pending', 'payment_received'];
        if (earlyStatuses.contains(currentStatus) && (effectiveProviderId == null || effectiveProviderId.isEmpty)) {
          broLog('🚨 BLOQUEADO: completed para ${orderId.length > 8 ? orderId.substring(0, 8) : orderId} em status "$currentStatus" sem providerId!');
          _isLoading = false;
          _immediateNotify();
          return false;
        }
      }

      // IMPORTANTE: Publicar no Nostr PRIMEIRO e sÃÂ³ atualizar localmente se der certo
      final privateKey = _nostrService.privateKey;
      bool nostrSuccess = false;
      
      // v252: SEMPRE incluir providerId e userPubkey da ordem existente
      // Sem isso, status updates (ex: 'disputed') ficam sem #p tag e o provedor
      // nao consegue descobrir a ordem em disputa nos relays
      final existingForUpdate = getOrderById(orderId);
      final effectiveProviderIdForUpdate = providerId ?? existingForUpdate?.providerId;
      String? orderUserPubkeyForUpdate = existingForUpdate?.userPubkey;
      
      // v257: SAFEGUARD CRITICO - Se orderUserPubkey == currentUserPubkey
      // E currentUser NAO eh o criador da ordem (eh o provedor),
      // entao userPubkey esta errado e precisa ser corrigido.
      // Isso acontece quando o provedor publicou um update e o userPubkey
      // foi setado como o provedor em vez do criador original.
      if (orderUserPubkeyForUpdate != null &&
          orderUserPubkeyForUpdate == _currentUserPubkey &&
          effectiveProviderIdForUpdate == _currentUserPubkey) {
        broLog('\xe2\x9a\xa0\xef\xb8\x8f [updateOrderStatus] orderUserPubkey == currentUser == providerId! Buscando criador real do Nostr...');
        try {
          final originalOrderData = await _nostrOrderService.fetchOrderFromNostr(orderId).timeout(
            const Duration(seconds: 5),
            onTimeout: () => null,
          );
          if (originalOrderData != null) {
            final realUserPubkey = originalOrderData['userPubkey'] as String?;
            if (realUserPubkey != null && realUserPubkey.isNotEmpty && realUserPubkey != _currentUserPubkey) {
              orderUserPubkeyForUpdate = realUserPubkey;
              broLog('\xe2\x9c\x85 [updateOrderStatus] userPubkey corrigido para ');
              // Corrigir localmente tambem
              final fixIdx = _orders.indexWhere((o) => o.id == orderId);
              if (fixIdx != -1) {
                _orders[fixIdx] = _orders[fixIdx].copyWith(userPubkey: realUserPubkey);
              }
            }
          }
        } catch (e) {
          broLog('\xe2\x9a\xa0\xef\xb8\x8f [updateOrderStatus] Falha ao buscar criador real: ');
        }
      }
      
      if (privateKey != null && privateKey.isNotEmpty) {
        
        nostrSuccess = await _nostrOrderService.updateOrderStatus(
          privateKey: privateKey,
          orderId: orderId,
          newStatus: status,
          providerId: effectiveProviderIdForUpdate,
          orderUserPubkey: orderUserPubkeyForUpdate,
        );
        
        if (nostrSuccess) {
        } else {
          _error = 'Falha ao publicar no Nostr';
          _isLoading = false;
          _immediateNotify();
          return false; // CRÃÂTICO: Retornar false se Nostr falhar
        }
      } else {
        _error = 'Chave privada nÃÂ£o disponÃÂ­vel';
        _isLoading = false;
        _immediateNotify();
        return false;
      }
      
      // SÃÂ³ atualizar localmente APÃâS sucesso no Nostr
      final index = _orders.indexWhere((o) => o.id == orderId);
      if (index != -1) {
        // Preservar metadata existente se nÃÂ£o for passado novo
        final existingMetadata = _orders[index].metadata;
        
        // v233: Marcar como resolvida por mediação se transicionando de disputed
        Map<String, dynamic>? newMetadata;
        if (_orders[index].status == 'disputed' && (status == 'completed' || status == 'cancelled')) {
          newMetadata = {
            ...?existingMetadata,
            ...?metadata,
            'wasDisputed': true,
            'disputeResolvedAt': DateTime.now().toIso8601String(),
          };
        } else {
          newMetadata = metadata ?? existingMetadata;
        }
        
        // Usar copyWith para manter dados existentes
        _orders[index] = _orders[index].copyWith(
          status: status,
          providerId: providerId,
          metadata: newMetadata,
          acceptedAt: status == 'accepted' ? DateTime.now() : _orders[index].acceptedAt,
          completedAt: status == 'completed' ? DateTime.now() : _orders[index].completedAt,
        );
        
        // Salvar localmente Ã¢â¬â usar save filtrado para nÃÂ£o vazar ordens de outros
        _debouncedSave();
        
        // v261: Re-publicar o evento 30078 com status terminal para remover da marketplace
        _republishOrderEventWithTerminalStatus(_orders[index], status);
        
      } else {
      }
      
      _isLoading = false;
      _immediateNotify();
      return true;
    } catch (e) {
      _error = e.toString();
      _isLoading = false;
      _immediateNotify();
      return false;
    }
  }

  /// Provedor aceita uma ordem - publica aceitaÃÂ§ÃÂ£o no Nostr e atualiza localmente
  Future<bool> acceptOrderAsProvider(String orderId) async {
    broLog('Ã°Å¸âÂµ [acceptOrderAsProvider] INICIADO para $orderId');
    _isLoading = true;
    _error = null;
    _immediateNotify();

    try {
      // Buscar a ordem localmente primeiro (verificar AMBAS as listas)
      Order? order = getOrderById(orderId);
      broLog('Ã°Å¸âÂµ [acceptOrderAsProvider] getOrderById: ${order != null ? "encontrado (status=${order.status})" : "null"}');
      
      // TambÃÂ©m verificar em _availableOrdersForProvider
      if (order == null) {
        final availableOrder = _availableOrdersForProvider.cast<Order?>().firstWhere(
          (o) => o?.id == orderId,
          orElse: () => null,
        );
        if (availableOrder != null) {
          broLog('Ã°Å¸âÂµ [acceptOrderAsProvider] Encontrado em _availableOrdersForProvider (status=${availableOrder.status})');
          order = availableOrder;
          // Adicionar ÃÂ  lista _orders para referÃÂªncia futura
          _orders.add(order);
        }
      }
      
      // Se nÃÂ£o encontrou localmente, buscar do Nostr com timeout
      if (order == null) {
        broLog('Ã°Å¸âÂµ [acceptOrderAsProvider] Buscando do Nostr...');
        final orderData = await _nostrOrderService.fetchOrderFromNostr(orderId).timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            broLog('Ã¢ÂÂ±Ã¯Â¸Â [acceptOrderAsProvider] timeout ao buscar do Nostr');
            return null;
          },
        );
        if (orderData != null) {
          order = Order.fromJson(orderData);
          // Adicionar ÃÂ  lista local para referÃÂªncia futura
          _orders.add(order);
          broLog('Ã°Å¸âÂµ [acceptOrderAsProvider] Encontrado no Nostr (status=${order.status})');
        }
      }
      
      if (order == null) {
        _error = 'Ordem nÃÂ£o encontrada';
        broLog('Ã¢ÂÅ [acceptOrderAsProvider] Ordem nÃÂ£o encontrada em nenhum lugar');
        _isLoading = false;
        _immediateNotify();
        return false;
      }

      // Pegar chave privada do Nostr
      final privateKey = _nostrService.privateKey;
      if (privateKey == null) {
        _error = 'Chave privada nÃÂ£o disponÃÂ­vel';
        broLog('Ã¢ÂÅ [acceptOrderAsProvider] Chave privada null');
        _isLoading = false;
        _immediateNotify();
        return false;
      }

      final providerPubkey = _nostrService.publicKey;
      broLog('Ã°Å¸âÂµ [acceptOrderAsProvider] Publicando aceitaÃÂ§ÃÂ£o no Nostr (providerPubkey=${providerPubkey?.substring(0, 8)}...)');

      // Publicar aceitaÃÂ§ÃÂ£o no Nostr
      final success = await _nostrOrderService.acceptOrderOnNostr(
        order: order,
        providerPrivateKey: privateKey,
      );

      broLog('Ã°Å¸âÂµ [acceptOrderAsProvider] Resultado da publicaÃÂ§ÃÂ£o: $success');

      if (!success) {
        _error = 'Falha ao publicar aceitaÃÂ§ÃÂ£o no Nostr';
        _isLoading = false;
        _immediateNotify();
        return false;
      }

      // CORREÇÃO v1.0.129+223: Remover da lista de disponíveis IMEDIATAMENTE
      // Sem isso, a ordem ficava em _availableOrdersForProvider com status stale
      // e continuava aparecendo na aba "Disponíveis" mesmo após aceita/completada
      _availableOrdersForProvider.removeWhere((o) => o.id == orderId);
      broLog('🗑️ [acceptOrderAsProvider] Removido de _availableOrdersForProvider');
      
      // Atualizar localmente
      final index = _orders.indexWhere((o) => o.id == orderId);
      if (index != -1) {
        _orders[index] = _orders[index].copyWith(
          status: 'accepted',
          providerId: providerPubkey,
          acceptedAt: DateTime.now(),
        );
        
        // Salvar localmente (apenas ordens do usuÃÂ¡rio/provedor atual)
        await _saveOnlyUserOrders();
        broLog('Ã¢Åâ¦ [acceptOrderAsProvider] Ordem atualizada localmente: status=accepted, providerId=$providerPubkey');
      } else {
        broLog('Ã¢Å¡Â Ã¯Â¸Â [acceptOrderAsProvider] Ordem nÃÂ£o encontrada em _orders para atualizar (index=-1)');
      }

      return true;
    } catch (e) {
      _error = e.toString();
      broLog('Ã¢ÂÅ [acceptOrderAsProvider] ERRO: $e');
      return false;
    } finally {
      _isLoading = false;
      _immediateNotify();
      broLog('Ã°Å¸âÂµ [acceptOrderAsProvider] FINALIZADO');
    }
  }

  /// Provedor completa uma ordem - publica comprovante no Nostr e atualiza localmente
  Future<bool> completeOrderAsProvider(String orderId, String proof, {String? providerInvoice, String? e2eId}) async {
    _isLoading = true;
    _error = null;
    _immediateNotify();

    try {
      // Buscar a ordem localmente primeiro
      Order? order = getOrderById(orderId);
      
      // Se nÃÂ£o encontrou localmente, buscar do Nostr
      if (order == null) {
        
        final orderData = await _nostrOrderService.fetchOrderFromNostr(orderId).timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            broLog('[completeOrderAsProvider] timeout ao buscar ordem do Nostr');
            return null;
          },
        );
        if (orderData != null) {
          order = Order.fromJson(orderData);
          // Adicionar ÃÂ  lista local para referÃÂªncia futura
          _orders.add(order);
        }
      }
      
      if (order == null) {
        _error = 'Ordem nÃÂ£o encontrada';
        _isLoading = false;
        _immediateNotify();
        return false;
      }

      // Pegar chave privada do Nostr
      final privateKey = _nostrService.privateKey;
      if (privateKey == null) {
        _error = 'Chave privada nÃÂ£o disponÃÂ­vel';
        _isLoading = false;
        _immediateNotify();
        return false;
      }


      // Publicar conclusÃÂ£o no Nostr
      final success = await _nostrOrderService.completeOrderOnNostr(
        order: order,
        providerPrivateKey: privateKey,
        proofImageBase64: proof,
        providerInvoice: providerInvoice, // Invoice para receber pagamento
      );

      if (!success) {
        _error = 'Falha ao publicar comprovante no Nostr';
        _isLoading = false;
        _immediateNotify();
        return false;
      }

      // CORREÇÃO v1.0.129+223: Remover da lista de disponíveis (defesa em profundidade)
      _availableOrdersForProvider.removeWhere((o) => o.id == orderId);
      
      // Atualizar localmente
      final index = _orders.indexWhere((o) => o.id == orderId);
      if (index != -1) {
        _orders[index] = _orders[index].copyWith(
          status: 'awaiting_confirmation',
          metadata: {
            ...(_orders[index].metadata ?? {}),
            // CORRIGIDO: Salvar imagem completa em base64, nÃÂ£o truncar!
            'paymentProof': proof,
            'proofSentAt': DateTime.now().toIso8601String(),
            if (e2eId != null && e2eId.isNotEmpty) 'e2eId': e2eId,
            if (providerInvoice != null) 'providerInvoice': providerInvoice,
          },
        );
        
        // Salvar localmente usando _saveOrders() com filtro de seguranÃÂ§a
        await _saveOrders();
        
      }

      return true;
    } catch (e) {
      _error = e.toString();
      return false;
    } finally {
      _isLoading = false;
      _immediateNotify();
    }
  }


  /// v257: Corrigir ordens com userPubkey corrompido e republicar nos relays
  /// Quando o provedor publicou um update, o userPubkey no content/tag ficou errado
  /// (apontava para o provedor em vez do criador da ordem).
  /// Este metodo busca o criador real no Nostr e republica o evento corrigido.
  Future<void> _fixCorruptedUserPubkeys() async {
    if (_ordersNeedingUserPubkeyFix.isEmpty) return;
    if (_currentUserPubkey == null) return;
    
    final privateKey = _nostrService.privateKey;
    if (privateKey == null) return;
    
    broLog('v257-FIX:  ordens com userPubkey corrompido');
    
    int fixed = 0;
    final orderIdsToFix = List<String>.from(_ordersNeedingUserPubkeyFix);
    
    for (final orderId in orderIdsToFix) {
      try {
        // Buscar a ordem original no Nostr para obter o userPubkey correto
        final originalData = await _nostrOrderService.fetchOrderFromNostr(orderId).timeout(
          const Duration(seconds: 5),
          onTimeout: () => null,
        );
        
        if (originalData == null) {
          broLog('v257-FIX:  - nao encontrado no Nostr');
          continue;
        }
        
        final realUserPubkey = originalData['userPubkey'] as String?;
        if (realUserPubkey == null || realUserPubkey.isEmpty || realUserPubkey == _currentUserPubkey) {
          broLog('v257-FIX:  - userPubkey do Nostr tambem invalido');
          continue;
        }
        
        // Corrigir localmente
        final idx = _orders.indexWhere((o) => o.id == orderId);
        if (idx != -1) {
          final order = _orders[idx];
          _orders[idx] = order.copyWith(userPubkey: realUserPubkey);
          broLog('v257-FIX:  userPubkey corrigido para ');
          
          // Republicar evento com tags corretas
          final success = await _nostrOrderService.updateOrderStatus(
            privateKey: privateKey,
            orderId: orderId,
            newStatus: order.status,
            providerId: order.providerId,
            orderUserPubkey: realUserPubkey,
          );
          
          if (success) {
            fixed++;
            _ordersNeedingUserPubkeyFix.remove(orderId);
            broLog('v257-FIX:  republicado com sucesso');
          }
        }
        
        // Delay entre correcoes
        await Future.delayed(const Duration(milliseconds: 300));
      } catch (e) {
        broLog('v257-FIX:  erro: ');
      }
    }
    
    if (fixed > 0) {
      broLog('v257-FIX:  ordens corrigidas e republicadas');
      await _saveOrders();
    }
  }

  /// v253: AUTO-REPAIR: Republicar status de ordens perdidas nos relays
  /// Quando uma ordem existe localmente com status terminal (disputed, completed, etc)
  /// mas NAO foi encontrada em nenhuma busca dos relays, republicar o status update
  /// para que o outro lado (provedor ou usuario) possa descobri-la na proxima sync
  /// 
  /// v256: Roda APENAS UMA VEZ por sessao para evitar spam nos relays.
  /// SEGURANCA NIP-33: Cada d-tag e unica por usuario+ordem, entao o auto-repair
  /// apenas substitui o PROPRIO evento do usuario, sem afetar eventos do outro lado.
  Future<void> _autoRepairMissingOrderEvents({
    required List<Order> allPendingOrders,
    required List<Order> userOrders,
    required List<Order> providerOrders,
  }) async {
    if (_currentUserPubkey == null || _currentUserPubkey!.isEmpty) return;
    
    // v256: So reparar UMA VEZ por sessao para evitar spam nos relays
    if (_autoRepairDoneThisSession) {
      broLog('AUTO-REPAIR: ja executado nesta sessao, pulando');
      return;
    }
    
    final privateKey = _nostrService.privateKey;
    if (privateKey == null) return;
    
    // Coletar todos os IDs encontrados nos relays
    final relayOrderIds = <String>{};
    for (final o in allPendingOrders) relayOrderIds.add(o.id);
    for (final o in userOrders) relayOrderIds.add(o.id);
    for (final o in providerOrders) relayOrderIds.add(o.id);
    
    // Encontrar ordens locais com status NAO-draft que NAO foram encontradas nos relays
    // v255: disputed permite repair SEM providerId (ordens criadas antes do fix v252)
    const repairableStatuses = ['disputed', 'completed', 'liquidated', 'accepted', 'awaiting_confirmation', 'payment_received'];
    
    final ordersToRepair = _orders.where((o) {
      // So reparar ordens que pertencem a este usuario (como criador ou provedor)
      final isOwner = o.userPubkey == _currentUserPubkey;
      final isProvider = o.providerId == _currentUserPubkey;
      if (!isOwner && !isProvider) return false;
      
      // So reparar status reparaveis
      if (!repairableStatuses.contains(o.status)) return false;
      
      // So reparar se NAO foi encontrada nos relays
      if (relayOrderIds.contains(o.id)) return false;
      
      // v255: Para disputed, permitir repair MESMO sem providerId
      if (o.status == 'disputed') return true;
      
      // Para outros status, exigir providerId (houve interacao real)
      if (o.providerId == null || o.providerId!.isEmpty) return false;
      
      return true;
    }).toList();
    
    if (ordersToRepair.isEmpty) {
      _autoRepairDoneThisSession = true;
      return;
    }
    
    broLog('AUTO-REPAIR: ${ordersToRepair.length} ordens com eventos perdidos nos relays');
    
    // v259: Limitar batch size para nao travar sync com dezenas de publishes
    final batch = ordersToRepair.length > _maxRepairBatchSize 
        ? ordersToRepair.sublist(0, _maxRepairBatchSize)
        : ordersToRepair;
    if (ordersToRepair.length > _maxRepairBatchSize) {
      broLog('AUTO-REPAIR: limitado a $_maxRepairBatchSize de ${ordersToRepair.length} (v259 batch limit)');
    }
    
    int repaired = 0;
    for (final order in batch) {
      try {
        // v255: Tentar popular providerId de metadata se estiver null
        String? effectiveProviderId = order.providerId;
        if (effectiveProviderId == null || effectiveProviderId.isEmpty) {
          effectiveProviderId = order.metadata?['providerId'] as String?;
          effectiveProviderId ??= order.metadata?['provider_id'] as String?;
          if (effectiveProviderId != null && effectiveProviderId.isNotEmpty) {
            broLog('AUTO-REPAIR: providerId recuperado de metadata: ${effectiveProviderId.substring(0, 16)}');
            final idx = _orders.indexWhere((o) => o.id == order.id);
            if (idx != -1) {
              _orders[idx] = _orders[idx].copyWith(providerId: effectiveProviderId);
            }
          }
        }
        
        // v257: NUNCA publicar com providerId == userPubkey (self-reference invalida)
        // Se o usuario criou a ordem E o providerId aponta para ele mesmo, algo esta errado.
        // Neste caso, limpar providerId para evitar poluir relays com dados incorretos.
        if (effectiveProviderId != null && 
            effectiveProviderId == _currentUserPubkey && 
            order.userPubkey == _currentUserPubkey) {
          broLog('AUTO-REPAIR: SKIP self-reference! orderId=${order.id.substring(0, 8)} providerId igual ao userPubkey - dados corrompidos, nao republicar');
          continue;
        }
        
        broLog('Reparando: orderId=${order.id.substring(0, 8)} status=${order.status} providerId=${effectiveProviderId?.substring(0, 16) ?? "NULL"}');
        
        final success = await _nostrOrderService.updateOrderStatus(
          privateKey: privateKey,
          orderId: order.id,
          newStatus: order.status,
          providerId: effectiveProviderId,
          orderUserPubkey: order.userPubkey,
        );
        
        if (success) {
          repaired++;
          broLog('Reparada: orderId=${order.id.substring(0, 8)}');
        } else {
          broLog('Falha ao reparar: orderId=${order.id.substring(0, 8)}');
        }
        
        // Pequeno delay entre reparacoes para nao sobrecarregar relays
        await Future.delayed(const Duration(milliseconds: 500));
      } catch (e) {
        broLog('AUTO-REPAIR exception: $e');
      }
    }
    
    _autoRepairDoneThisSession = true;
    broLog('AUTO-REPAIR concluido: $repaired/${batch.length} reparadas (de ${ordersToRepair.length} total, flag sessao ativado)');
  }

  /// Verifica ordens em 'awaiting_confirmation' com prazo de 36h expirado
  /// e executa auto-liquidaÃÂ§ÃÂ£o em background durante o sync
  Future<void> _checkAutoLiquidation() async {
    if (_currentUserPubkey == null || _currentUserPubkey!.isEmpty) return;
    
    // Check if background task is already running auto-liquidation (lock with 2min TTL)
    final prefs = await SharedPreferences.getInstance();
    final lockTime = prefs.getInt('bg_auto_liq_lock');
    if (lockTime != null) {
      final elapsed = DateTime.now().millisecondsSinceEpoch - lockTime;
      if (elapsed < 120000) {
        broLog('[AutoLiquidation] Background task is running, skipping foreground check');
        return;
      }
    }
    
    final now = DateTime.now();
    const deadline = Duration(hours: 36);
    
    // Filtrar ordens do provedor atual em awaiting_confirmation
    final expiredOrders = _orders.where((order) {
      if (order.status != 'awaiting_confirmation') return false;
      // Verificar se a ordem ÃÂ© do provedor atual
      final providerId = order.providerId ?? order.metadata?['providerId'] ?? order.metadata?['provider_id'] ?? '';
      final isProvider = providerId.isNotEmpty && providerId == _currentUserPubkey;
      final isCreator = order.userPubkey == _currentUserPubkey;
      if (!isProvider && !isCreator) return false;
      // JÃÂ¡ foi auto-liquidada?
      if (order.metadata?['autoLiquidated'] == true) return false;
      
      // Determinar quando o comprovante foi enviado
      final proofTimestamp = order.metadata?['receipt_submitted_at'] 
          ?? order.metadata?['proofReceivedAt']
          ?? order.metadata?['proofSentAt']
          ?? order.metadata?['completedAt'];
      
      if (proofTimestamp == null) return false;
      
      try {
        final proofTime = DateTime.parse(proofTimestamp.toString());
        return now.difference(proofTime) > deadline;
      } catch (_) {
        return false;
      }
    }).toList();
    
    for (final order in expiredOrders) {
      broLog('[AutoLiquidation] Ordem ${order.id} expirou 36h - auto-liquidando...');
      final proof = order.metadata?['paymentProof'] ?? '';
      await autoLiquidateOrder(order.id, proof.toString());
    }
    
    if (expiredOrders.isNotEmpty) {
      broLog('[AutoLiquidation] ${expiredOrders.length} ordens auto-liquidadas em background');
    }
  }

  /// Auto-liquidaÃÂ§ÃÂ£o quando usuÃÂ¡rio nÃÂ£o confirma em 36h
  /// Marca a ordem como 'liquidated' e notifica o usuÃÂ¡rio
  Future<bool> autoLiquidateOrder(String orderId, String proof) async {
    _isLoading = true;
    _error = null;
    _immediateNotify();

    try {
      
      // Buscar a ordem localmente primeiro
      Order? order = getOrderById(orderId);
      
      if (order == null) {
        _error = 'Ordem nÃÂ£o encontrada';
        _isLoading = false;
        _immediateNotify();
        return false;
      }

      // Publicar no Nostr com status 'liquidated'
      final privateKey = _nostrService.privateKey;
      if (privateKey == null) {
        _error = 'Chave privada nÃÂ£o disponÃÂ­vel';
        _isLoading = false;
        _immediateNotify();
        return false;
      }

      // Usar a funÃÂ§ÃÂ£o existente de updateOrderStatus com status 'liquidated'
      final success = await _nostrOrderService.updateOrderStatus(
        privateKey: privateKey,
        orderId: orderId,
        newStatus: 'liquidated',
        providerId: _currentUserPubkey,
        orderUserPubkey: order.userPubkey,
      );

      if (!success) {
        _error = 'Falha ao publicar auto-liquidaÃÂ§ÃÂ£o no Nostr';
        _isLoading = false;
        _immediateNotify();
        return false;
      }

      // Atualizar localmente
      final index = _orders.indexWhere((o) => o.id == orderId);
      if (index != -1) {
        _orders[index] = _orders[index].copyWith(
          status: 'liquidated',
          metadata: {
            ...(_orders[index].metadata ?? {}),
            'autoLiquidated': true,
            'liquidatedAt': DateTime.now().toIso8601String(),
            'reason': 'UsuÃÂ¡rio nÃÂ£o confirmou em 36h',
          },
        );
        
        await _saveOrders();
      }

      return true;
    } catch (e) {
      _error = e.toString();
      return false;
    } finally {
      _isLoading = false;
      _immediateNotify();
    }
  }

  /// v132: Verifica ordens 'liquidated' do USUÁRIO que ainda não foram pagas
  /// e dispara auto-pagamento via callback (setado pelo main.dart)
  bool _isAutoPayingLiquidations = false;
  
  Future<void> _autoPayLiquidatedOrders() async {
    if (onAutoPayLiquidation == null) return;
    if (_isAutoPayingLiquidations) return;
    if (_currentUserPubkey == null || _currentUserPubkey!.isEmpty) return;
    
    _isAutoPayingLiquidations = true;
    
    try {
      // Encontrar ordens liquidadas onde EU sou o USUÁRIO (não o provedor)
      // e que ainda não tiveram auto-pagamento completado
      final unpaidLiquidated = _orders.where((order) {
        if (order.status != 'liquidated') return false;
        // Sou o criador da ordem (usuário que precisa pagar)
        if (order.userPubkey != _currentUserPubkey) return false;
        // Sou o provedor? Então não preciso pagar a mim mesmo
        final providerId = order.providerId ?? order.metadata?['providerId'] ?? order.metadata?['provider_id'] ?? '';
        if (providerId == _currentUserPubkey) return false;
        // Já paguei?
        if (order.metadata?['autoPaymentCompleted'] == true) return false;
        return true;
      }).toList();
      
      if (unpaidLiquidated.isEmpty) return;
      
      broLog('[AutoPay] ${unpaidLiquidated.length} ordens liquidadas pendentes de pagamento');
      
      for (final order in unpaidLiquidated) {
        try {
          broLog('[AutoPay] Pagando ordem ${order.id.substring(0, 8)}...');
          final success = await onAutoPayLiquidation!(order.id, order);
          
          if (success) {
            // Marcar como paga localmente
            final index = _orders.indexWhere((o) => o.id == order.id);
            if (index != -1) {
              _orders[index] = _orders[index].copyWith(
                metadata: {
                  ...(_orders[index].metadata ?? {}),
                  'autoPaymentCompleted': true,
                  'autoPaymentAt': DateTime.now().toIso8601String(),
                },
              );
            }
            broLog('[AutoPay] ✅ Ordem ${order.id.substring(0, 8)} paga com sucesso');
          } else {
            broLog('[AutoPay] ⚠️ Ordem ${order.id.substring(0, 8)} falhou no pagamento');
          }
        } catch (e) {
          broLog('[AutoPay] ❌ Erro ao pagar ${order.id.substring(0, 8)}: $e');
        }
      }
      
      await _saveOrders();
    } catch (e) {
      broLog('[AutoPay] Erro geral: $e');
    } finally {
      _isAutoPayingLiquidations = false;
    }
  }

  /// v133: Renova invoices para ordens liquidadas onde EU sou o PROVEDOR
  /// Gera nova invoice e publica no Nostr para o usuário poder pagar
  bool _isRenewingInvoices = false;

  Future<void> _renewInvoicesForLiquidatedAsProvider() async {
    if (onGenerateProviderInvoice == null) return;
    if (_isRenewingInvoices) return;
    if (_currentUserPubkey == null || _currentUserPubkey!.isEmpty) return;

    _isRenewingInvoices = true;

    try {
      final unpaidAsProvider = _orders.where((order) {
        if (order.status != 'liquidated') return false;
        final providerId = order.providerId ?? order.metadata?['providerId'] ?? order.metadata?['provider_id'] ?? '';
        if (providerId != _currentUserPubkey) return false;
        if (order.metadata?['invoiceRefreshed'] == true) return false;
        if (order.metadata?['providerPaymentReceived'] == true) return false;
        if (order.metadata?['autoPaymentCompleted'] == true) return false;
        return true;
      }).toList();

      if (unpaidAsProvider.isEmpty) return;

      broLog('[InvoiceRefresh] ${unpaidAsProvider.length} ordens liquidadas precisam de invoice refresh');

      final privateKey = _nostrService.privateKey;
      if (privateKey == null) return;

      for (final order in unpaidAsProvider) {
        try {
          final amountSats = (order.btcAmount * 100000000).round();
          if (amountSats <= 0) continue;

          broLog('[InvoiceRefresh] Gerando invoice de $amountSats sats para ${order.id.substring(0, 8)}...');
          final invoice = await onGenerateProviderInvoice!(amountSats, order.id);
          if (invoice == null || invoice.isEmpty) {
            broLog('[InvoiceRefresh] ⚠️ Falha ao gerar invoice para ${order.id.substring(0, 8)}');
            continue;
          }

          final success = await _nostrOrderService.publishInvoiceRefresh(
            orderId: order.id,
            providerPrivateKey: privateKey,
            providerInvoice: invoice,
            orderUserPubkey: order.userPubkey ?? '',
          );

          if (success) {
            final index = _orders.indexWhere((o) => o.id == order.id);
            if (index != -1) {
              _orders[index] = _orders[index].copyWith(
                metadata: {
                  ...(_orders[index].metadata ?? {}),
                  'providerInvoice': invoice,
                  'invoiceRefreshed': true,
                  'invoiceRefreshedAt': DateTime.now().toIso8601String(),
                },
              );
            }
            broLog('[InvoiceRefresh] ✅ Invoice refreshed para ${order.id.substring(0, 8)}');
          }
        } catch (e) {
          broLog('[InvoiceRefresh] ❌ Erro para ${order.id.substring(0, 8)}: $e');
        }
      }

      await _saveOrders();
    } catch (e) {
      broLog('[InvoiceRefresh] Erro geral: $e');
    } finally {
      _isRenewingInvoices = false;
    }
  }

  Future<Map<String, dynamic>?> validateBoleto(String code) async {
    _isLoading = true;
    _error = null;
    _immediateNotify();

    try {
      final result = await _apiService.validateBoleto(code);
      return result;
    } catch (e) {
      _error = e.toString();
      return null;
    } finally {
      _isLoading = false;
      _immediateNotify();
    }
  }

  // Decodificar PIX
  Future<Map<String, dynamic>?> decodePix(String code) async {
    _isLoading = true;
    _error = null;
    _immediateNotify();

    try {
      final result = await _apiService.decodePix(code);
      return result;
    } catch (e) {
      _error = e.toString();
      return null;
    } finally {
      _isLoading = false;
      _immediateNotify();
    }
  }

  // Converter preÃÂ§o
  Future<Map<String, dynamic>?> convertPrice(double amount) async {
    try {
      final result = await _apiService.convertPrice(amount: amount);
      return result;
    } catch (e) {
      _error = e.toString();
      return null;
    }
  }

  // Refresh
  Future<void> refresh() async {
    await fetchOrders();
  }

  // Get order by ID (retorna Order object)
  Order? getOrderById(String orderId) {
    try {
      return _orders.firstWhere(
        (o) => o.id == orderId,
        orElse: () => throw Exception('Ordem nÃÂ£o encontrada'),
      );
    } catch (e) {
      return null;
    }
  }

  // Get order (alias para fetchOrder)
  Future<Map<String, dynamic>?> getOrder(String orderId) async {
    try {
      
      // Primeiro, tentar encontrar na lista em memÃÂ³ria (mais rÃÂ¡pido)
      final localOrder = _orders.cast<Order?>().firstWhere(
        (o) => o?.id == orderId,
        orElse: () => null,
      );
      
      if (localOrder != null) {
        broLog('Ã°Å¸âÂ getOrder($orderId): encontrado em _orders (status=${localOrder.status})');
        return localOrder.toJson();
      }
      
      // TambÃÂ©m verificar nas ordens disponÃÂ­veis para provider
      final availableOrder = _availableOrdersForProvider.cast<Order?>().firstWhere(
        (o) => o?.id == orderId,
        orElse: () => null,
      );
      
      if (availableOrder != null) {
        broLog('Ã°Å¸âÂ getOrder($orderId): encontrado em _availableOrdersForProvider (status=${availableOrder.status})');
        return availableOrder.toJson();
      }
      
      // Tentar buscar do Nostr (mais confiÃÂ¡vel que backend)
      broLog('Ã°Å¸âÂ getOrder($orderId): nÃÂ£o encontrado localmente, buscando no Nostr...');
      try {
        final nostrOrder = await _nostrOrderService.fetchOrderFromNostr(orderId).timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            broLog('Ã¢ÂÂ±Ã¯Â¸Â getOrder: timeout ao buscar do Nostr');
            return null;
          },
        );
        if (nostrOrder != null) {
          broLog('Ã¢Åâ¦ getOrder($orderId): encontrado no Nostr');
          return nostrOrder;
        }
      } catch (e) {
        broLog('Ã¢Å¡Â Ã¯Â¸Â getOrder: erro ao buscar do Nostr: $e');
      }
      
      // NOTA: Backend API em http://10.0.2.2:3002 sÃÂ³ funciona no emulator
      // Em dispositivo real, nÃÂ£o tentar Ã¢â¬â causaria timeout desnecessÃÂ¡rio
      broLog('Ã¢Å¡Â Ã¯Â¸Â getOrder($orderId): nÃÂ£o encontrado em nenhum lugar');
      return null;
    } catch (e) {
      _error = e.toString();
      return null;
    }
  }

  // Update order (alias para updateOrderStatus)
  Future<bool> updateOrder(String orderId, {required String status, Map<String, dynamic>? metadata}) async {
    return await updateOrderStatus(
      orderId: orderId,
      status: status,
      metadata: metadata,
    );
  }

  // Set current order
  void setCurrentOrder(Order order) {
    _currentOrder = order;
    _throttledNotify();
  }

  // Clear current order
  void clearCurrentOrder() {
    _currentOrder = null;
    _throttledNotify();
  }

  // Clear error
  void clearError() {
    _error = null;
    _immediateNotify();
  }

  // Clear all orders (memory only)
  void clear() {
    _orders = [];
    _availableOrdersForProvider = [];  // Limpar tambÃÂ©m lista de disponÃÂ­veis
    _currentOrder = null;
    _error = null;
    _isInitialized = false;
    _immediateNotify();
  }

  // Clear orders from memory only (for logout - keeps data in storage)
  Future<void> clearAllOrders() async {
    _orders = [];
    _availableOrdersForProvider = [];  // Limpar tambÃÂ©m lista de disponÃÂ­veis
    _currentOrder = null;
    _error = null;
    _currentUserPubkey = null;
    _isInitialized = false;
    _immediateNotify();
  }

  // Permanently delete all orders (for testing/reset)
  Future<void> permanentlyDeleteAllOrders() async {
    _orders = [];
    _availableOrdersForProvider = [];  // Limpar tambÃÂ©m lista de disponÃÂ­veis
    _currentOrder = null;
    _error = null;
    _isInitialized = false;
    
    // Limpar do SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_ordersKey);
    } catch (e) {
    }
    
    _immediateNotify();
  }

  /// Reconciliar ordens pendentes com pagamentos jÃÂ¡ recebidos no Breez
  /// Esta funÃÂ§ÃÂ£o verifica os pagamentos recentes do Breez e atualiza ordens pendentes
  /// que possam ter perdido a atualizaÃÂ§ÃÂ£o de status (ex: app fechou antes do callback)
  /// 
  /// IMPORTANTE: Usa APENAS paymentHash para identificaÃÂ§ÃÂ£o PRECISA
  /// O fallback por valor foi DESATIVADO porque causava falsos positivos
  /// (mesmo pagamento usado para mÃÂºltiplas ordens diferentes)
  /// 
  /// @param breezPayments Lista de pagamentos do Breez SDK (obtida via listPayments)
  Future<int> reconcilePendingOrdersWithBreez(List<dynamic> breezPayments) async {
    
    // Buscar ordens pendentes
    final pendingOrders = _orders.where((o) => o.status == 'pending').toList();
    
    if (pendingOrders.isEmpty) {
      return 0;
    }
    
    
    int reconciled = 0;
    
    // Criar set de paymentHashes jÃÂ¡ usados (para evitar duplicaÃÂ§ÃÂ£o)
    final Set<String> usedHashes = {};
    
    // Primeiro, coletar hashes jÃÂ¡ usados por ordens que jÃÂ¡ foram pagas
    for (final order in _orders) {
      if (order.status != 'pending' && order.paymentHash != null) {
        usedHashes.add(order.paymentHash!);
      }
    }
    
    for (var order in pendingOrders) {
      
      // ÃÅ¡NICO MÃâ°TODO: Match por paymentHash (MAIS SEGURO)
      if (order.paymentHash != null && order.paymentHash!.isNotEmpty) {
        // Verificar se este hash nÃÂ£o foi usado por outra ordem
        if (usedHashes.contains(order.paymentHash)) {
          continue;
        }
        
        for (var payment in breezPayments) {
          final paymentHash = payment['paymentHash'] as String?;
          if (paymentHash == order.paymentHash) {
            final paymentAmount = (payment['amount'] is int) 
                ? payment['amount'] as int 
                : int.tryParse(payment['amount']?.toString() ?? '0') ?? 0;
            
            
            // Marcar hash como usado
            usedHashes.add(paymentHash!);
            
            await updateOrderStatus(
              orderId: order.id,
              status: 'payment_received',
              metadata: {
                'reconciledAt': DateTime.now().toIso8601String(),
                'reconciledFrom': 'breez_payments_hash_match',
                'paymentAmount': paymentAmount,
                'paymentHash': paymentHash,
              },
            );
            
            // Republicar no Nostr
            final updatedOrder = _orders.firstWhere((o) => o.id == order.id);
            await _publishOrderToNostr(updatedOrder);
            
            reconciled++;
            break;
          }
        }
      } else {
        // Ordem SEM paymentHash - NÃÆO fazer fallback por valor
        // Isso evita falsos positivos onde mÃÂºltiplas ordens sÃÂ£o marcadas com o mesmo pagamento
      }
    }
    
    return reconciled;
  }

  /// Reconciliar ordens na inicializaÃÂ§ÃÂ£o - DESATIVADO
  /// NOTA: Esta funÃÂ§ÃÂ£o foi desativada pois causava falsos positivos de "payment_received"
  /// quando o usuÃÂ¡rio tinha saldo de outras transaÃÂ§ÃÂµes na carteira.
  /// A reconciliaÃÂ§ÃÂ£o correta deve ser feita APENAS via evento do SDK Breez (PaymentSucceeded)
  /// que traz o paymentHash especÃÂ­fico da invoice.
  Future<void> reconcileOnStartup(int currentBalanceSats) async {
    // NÃÂ£o faz nada - reconciliaÃÂ§ÃÂ£o automÃÂ¡tica por saldo ÃÂ© muito propensa a erros
    return;
  }

  /// Callback chamado quando o Breez SDK detecta um pagamento recebido
  /// Este ÃÂ© o mÃÂ©todo SEGURO de atualizaÃÂ§ÃÂ£o - baseado no evento real do SDK
  /// IMPORTANTE: Usa APENAS paymentHash para identificaÃÂ§ÃÂ£o PRECISA
  /// O fallback por valor foi DESATIVADO para evitar falsos positivos
  Future<void> onPaymentReceived({
    required String paymentId,
    required int amountSats,
    String? paymentHash,
  }) async {
    
    // Buscar ordens pendentes
    final pendingOrders = _orders.where((o) => o.status == 'pending').toList();
    
    if (pendingOrders.isEmpty) {
      return;
    }
    
    
    // ÃÅ¡NICO MÃâ°TODO: Match EXATO por paymentHash (mais seguro)
    if (paymentHash != null && paymentHash.isNotEmpty) {
      for (final order in pendingOrders) {
        if (order.paymentHash == paymentHash) {
          
          await updateOrderStatus(
            orderId: order.id,
            status: 'payment_received',
            metadata: {
              'paymentId': paymentId,
              'paymentHash': paymentHash,
              'amountReceived': amountSats,
              'receivedAt': DateTime.now().toIso8601String(),
              'source': 'breez_sdk_event_hash_match',
            },
          );
          
          // Republicar no Nostr com novo status
          final updatedOrder = _orders.firstWhere((o) => o.id == order.id);
          await _publishOrderToNostr(updatedOrder);
          
          return;
        }
      }
    }
    
    // NÃÆO fazer fallback por valor - isso causa falsos positivos
    // Se o paymentHash nÃÂ£o corresponder, o pagamento nÃÂ£o ÃÂ© para nenhuma ordem nossa
  }

  /// Atualizar o paymentHash de uma ordem (chamado quando a invoice ÃÂ© gerada)
  Future<void> setOrderPaymentHash(String orderId, String paymentHash, String invoice) async {
    final index = _orders.indexWhere((o) => o.id == orderId);
    if (index == -1) {
      return;
    }
    
    _orders[index] = _orders[index].copyWith(
      paymentHash: paymentHash,
      invoice: invoice,
    );
    
    await _saveOrders();
    
    // Republicar no Nostr com paymentHash
    await _publishOrderToNostr(_orders[index]);
    
    _throttledNotify();
  }

  // ==================== NOSTR INTEGRATION ====================
  
  /// Publicar ordem no Nostr (background)
  Future<void> _publishOrderToNostr(Order order) async {
    try {
      final privateKey = _nostrService.privateKey;
      if (privateKey == null) {
        return;
      }
      
      final eventId = await _nostrOrderService.publishOrder(
        order: order,
        privateKey: privateKey,
      );
      
      if (eventId != null) {
        
        // Atualizar ordem com eventId
        final index = _orders.indexWhere((o) => o.id == order.id);
        if (index != -1) {
          _orders[index] = _orders[index].copyWith(eventId: eventId);
          await _saveOrders();
        }
      } else {
      }
    } catch (e) {
    }
  }

  /// Buscar ordens pendentes de todos os usuÃÂ¡rios (para providers verem)
  Future<List<Order>> fetchPendingOrdersFromNostr() async {
    try {
      final orders = await _nostrOrderService.fetchPendingOrders();
      return orders;
    } catch (e) {
      return [];
    }
  }

  /// Buscar histÃÂ³rico de ordens do usuÃÂ¡rio atual do Nostr
  /// PERFORMANCE: Throttled Ã¢â¬â ignora chamadas se sync jÃÂ¡ em andamento ou muito recente
  /// [force] = true bypassa cooldown (para aÃÂ§ÃÂµes explÃÂ­citas do usuÃÂ¡rio)
  Future<void> syncOrdersFromNostr({bool force = false}) async {
    // PERFORMANCE: NÃÂ£o sincronizar se jÃÂ¡ tem sync em andamento
    // v259: Detectar lock stale (sync travou e nunca liberou o lock)
    if (_isSyncingUser) {
      if (_syncUserStartedAt != null) {
        final elapsed = DateTime.now().difference(_syncUserStartedAt!).inSeconds;
        if (elapsed > _maxSyncDurationSeconds) {
          broLog('v259: syncUser LOCK STALE detectado (${elapsed}s) - resetando');
          _isSyncingUser = false;
          _syncUserStartedAt = null;
        } else {
          broLog('syncOrdersFromNostr: sync em andamento (${elapsed}s), ignorando');
          return;
        }
      } else {
        broLog('syncOrdersFromNostr: sync em andamento, ignorando');
        return;
      }
    }
    
    // PERFORMANCE: NÃÂ£o sincronizar se ÃÂºltimo sync foi hÃÂ¡ menos de N segundos
    // Ignorado quando force=true (aÃÂ§ÃÂ£o explÃÂ­cita do usuÃÂ¡rio)
    if (!force && _lastUserSyncTime != null) {
      final elapsed = DateTime.now().difference(_lastUserSyncTime!).inSeconds;
      if (elapsed < _minSyncIntervalSeconds) {
        broLog('Ã¢ÂÂ­Ã¯Â¸Â syncOrdersFromNostr: ÃÂºltimo sync hÃÂ¡ ${elapsed}s (mÃÂ­n: ${_minSyncIntervalSeconds}s), ignorando');
        return;
      }
    }
    
    // Tentar pegar a pubkey do NostrService se nÃÂ£o temos
    if (_currentUserPubkey == null || _currentUserPubkey!.isEmpty) {
      _currentUserPubkey = _nostrService.publicKey;
    }
    
    if (_currentUserPubkey == null || _currentUserPubkey!.isEmpty) {
      return;
    }
    
    _isSyncingUser = true;
    _syncUserStartedAt = DateTime.now(); // v259: track start time
    
    try {
      // PERFORMANCE v1.0.129+218: Se TODAS as ordens locais são terminais,
      // pular fetchUserOrders (que abre 9+ WebSocket connections).
      // Novas ordens do usuário aparecem via syncAllPendingOrdersFromNostr.
      // Só buscar do Nostr se: sem ordens locais (primeira vez) OU tem ordens ativas.
      const terminalOnly = ['completed', 'cancelled', 'liquidated'];
      final hasActiveOrders = _orders.isEmpty || _orders.any((o) => !terminalOnly.contains(o.status));
      
      List<Order> nostrOrders;
      if (hasActiveOrders) {
        nostrOrders = await _nostrOrderService.fetchUserOrders(_currentUserPubkey!);
      } else {
        broLog('⚡ syncOrdersFromNostr: todas ${_orders.length} ordens são terminais, pulando fetchUserOrders (9 WebSockets economizados)');
        nostrOrders = [];
      }
      
      // Mesclar ordens do Nostr com locais
      int added = 0;
      int updated = 0;
      int skipped = 0;
      for (var nostrOrder in nostrOrders) {
        // VALIDAÃâ¡ÃÆO: Ignorar ordens com amount=0 vindas do Nostr
        // (jÃÂ¡ sÃÂ£o filtradas em eventToOrder, mas double-check aqui)
        if (nostrOrder.amount <= 0) {
          skipped++;
          continue;
        }
        
        // SEGURANÃâ¡A CRÃÂTICA: Verificar se a ordem realmente pertence ao usuÃÂ¡rio atual
        // Ordem pertence se: userPubkey == atual OU providerId == atual (aceitou como Bro)
        final isMyOrder = nostrOrder.userPubkey == _currentUserPubkey;
        final isMyProviderOrder = nostrOrder.providerId == _currentUserPubkey;
        
        if (!isMyOrder && !isMyProviderOrder) {
          skipped++;
          continue;
        }
        
        final existingIndex = _orders.indexWhere((o) => o.id == nostrOrder.id);
        if (existingIndex == -1) {
          // Ordem nÃÂ£o existe localmente, adicionar
          // CORREÃâ¡ÃÆO: Adicionar TODAS as ordens do usuÃÂ¡rio incluindo completed para histÃÂ³rico!
          // SÃÂ³ ignoramos cancelled pois sÃÂ£o ordens canceladas pelo usuÃÂ¡rio
          if (nostrOrder.status != 'cancelled') {
            _orders.add(nostrOrder);
            added++;
          }
        } else {
          // Ordem jÃÂ¡ existe, mesclar dados preservando os locais que nÃÂ£o sÃÂ£o 0
          final existing = _orders[existingIndex];
          
          // CORREÃâ¡ÃÆO: Se Nostr diz 'cancelled', SEMPRE aceitar Ã¢â¬â cancelamento ÃÂ© aÃÂ§ÃÂ£o explÃÂ­cita
          // Isso corrige o bug onde auto-complete sobrescreveu cancelled com completed
          if (nostrOrder.status == 'cancelled' && existing.status != 'cancelled') {
            _orders[existingIndex] = existing.copyWith(status: 'cancelled');
            updated++;
            continue;
          }
          
          // REGRA CRÃÂTICA: Apenas status FINAIS nÃÂ£o podem reverter
          // accepted e awaiting_confirmation podem evoluir para completed
          final protectedStatuses = ['cancelled', 'completed', 'liquidated'];
          if (protectedStatuses.contains(existing.status)) {
            continue;
          }
          
          // Se Nostr tem status mais recente, atualizar apenas o status
          // MAS manter amount/btcAmount/billCode locais se Nostr tem 0
          if (_isStatusMoreRecent(nostrOrder.status, existing.status) || 
              existing.amount == 0 && nostrOrder.amount > 0) {
            
            // NOTA: O bloqueio de "completed" indevido ÃÂ© feito no NostrOrderService._applyStatusUpdate()
            // que verifica se o evento foi publicado pelo PROVEDOR ou pelo PRÃâPRIO USUÃÂRIO.
            // Aqui apenas aplicamos o status que jÃÂ¡ foi filtrado pelo NostrOrderService.
            String statusToUse = nostrOrder.status;
            
            // Mesclar metadata: preservar local e adicionar do Nostr (proofImage, etc)
            final mergedMetadata = <String, dynamic>{
              ...?existing.metadata,
              ...?nostrOrder.metadata, // Dados do Nostr (incluindo proofImage)
            };
            
            _orders[existingIndex] = existing.copyWith(
              status: _isStatusMoreRecent(statusToUse, existing.status) 
                  ? statusToUse 
                  : existing.status,
              // Preservar dados locais se Nostr tem 0
              amount: nostrOrder.amount > 0 ? nostrOrder.amount : existing.amount,
              btcAmount: nostrOrder.btcAmount > 0 ? nostrOrder.btcAmount : existing.btcAmount,
              btcPrice: nostrOrder.btcPrice > 0 ? nostrOrder.btcPrice : existing.btcPrice,
              total: nostrOrder.total > 0 ? nostrOrder.total : existing.total,
              billCode: nostrOrder.billCode.isNotEmpty ? nostrOrder.billCode : existing.billCode,
              providerId: nostrOrder.providerId ?? existing.providerId,
              eventId: nostrOrder.eventId ?? existing.eventId,
              metadata: mergedMetadata.isNotEmpty ? mergedMetadata : null,
            );
            updated++;
          }
        }
      }
      
      // NOVO: Buscar atualizaÃÂ§ÃÂµes de status (aceites e comprovantes de Bros)
      // CORREÃâ¡ÃÆO v1.0.128: fetchOrderUpdatesForUser agora tambÃÂ©m busca eventos do prÃÂ³prio usuÃÂ¡rio (kind 30080)
      // para recuperar status 'completed' apÃÂ³s reinstalaÃÂ§ÃÂ£o do app
      // PERFORMANCE v1.0.129+218: Buscar updates APENAS para ordens NAO-TERMINAIS
      // Ordens completed/cancelled/liquidated ja tem status final
      const terminalStatuses = ['completed', 'cancelled', 'liquidated'];
      final activeOrders = _orders.where((o) => !terminalStatuses.contains(o.status)).toList();
      final orderIds = activeOrders.map((o) => o.id).toList();
      broLog('syncOrdersFromNostr: ${orderIds.length} ordens ativas, ${_orders.length - orderIds.length} terminais ignoradas');
      final orderUpdates = await _nostrOrderService.fetchOrderUpdatesForUser(
        _currentUserPubkey!,
        orderIds: orderIds,
      );
      
      broLog('Ã°Å¸âÂ¡ syncOrdersFromNostr: ${orderUpdates.length} updates recebidos');
      int statusUpdated = 0;
      for (final entry in orderUpdates.entries) {
        final orderId = entry.key;
        final update = entry.value;
        
        final existingIndex = _orders.indexWhere((o) => o.id == orderId);
        if (existingIndex != -1) {
          final existing = _orders[existingIndex];
          final newStatus = update['status'] as String;
          final newProviderId = update['providerId'] as String?;
          
          // PROTEÃâ¡ÃÆO CRÃÂTICA: Status finais NUNCA podem regredir
          // Isso evita que 'completed' volte para 'awaiting_confirmation'
          const protectedStatuses = ['completed', 'cancelled', 'liquidated'];
          if (protectedStatuses.contains(existing.status) && !_isStatusMoreRecent(newStatus, existing.status)) {
            // Apenas atualizar providerId se necessÃÂ¡rio, sem mudar status
            if (newProviderId != null && newProviderId != existing.providerId) {
              _orders[existingIndex] = existing.copyWith(
                providerId: newProviderId,
              );
            }
            continue;
          }
          
          // SEMPRE atualizar providerId se vier do Nostr e for diferente
          bool needsUpdate = false;
          if (newProviderId != null && newProviderId != existing.providerId) {
            needsUpdate = true;
          }
          
          String statusToUse = newStatus;
          
          // GUARDA v1.0.129+232: Não aplicar 'completed' de sync se não há providerId
          // EXCEÇÃO v233: Se a ordem está 'disputed', permitir (resolução de disputa pelo admin)
          if (statusToUse == 'completed') {
            final effectiveProviderId = newProviderId ?? existing.providerId;
            if (effectiveProviderId == null || effectiveProviderId.isEmpty) {
              if (existing.status != 'disputed') {
                broLog('syncOrdersFromNostr: BLOQUEADO completed sem providerId');
                continue;
              } else {
                broLog('syncOrdersFromNostr: permitido completed de disputed (resolução de disputa)');
              }
            }
          }
          
          // Verificar se o novo status ÃÂ© mais avanÃÂ§ado
          if (_isStatusMoreRecent(statusToUse, existing.status)) {
            needsUpdate = true;
          }
          
          if (needsUpdate) {
            final isStatusAdvancing = _isStatusMoreRecent(statusToUse, existing.status);
            // TRACKING v233: Marcar ordem como 'wasDisputed' quando transiciona de disputed para completed/cancelled
            final wasDisputeResolution = existing.status == 'disputed' && 
                (statusToUse == 'completed' || statusToUse == 'cancelled') && isStatusAdvancing;
            
            Map<String, dynamic>? updatedMetadata;
            if (wasDisputeResolution) {
              updatedMetadata = {
                ...?existing.metadata,
                'wasDisputed': true,
                'disputeResolvedAt': DateTime.now().toIso8601String(),
                // v338: Marcar pagamento pendente se resolução foi a favor do provedor
                if (statusToUse == 'completed') 'disputePaymentPending': true,
              };
              broLog('⚖️ syncOrdersFromNostr: ordem ${existing.id.substring(0, 8)} resolvida de disputa → $statusToUse');
            } else if (update['proofImage'] != null || update['providerInvoice'] != null) {
              updatedMetadata = {
                ...?existing.metadata,
                if (update['proofImage'] != null) 'proofImage': update['proofImage'],
                if (update['providerInvoice'] != null) 'providerInvoice': update['providerInvoice'],
                'proofReceivedAt': DateTime.now().toIso8601String(),
              };
            } else {
              updatedMetadata = existing.metadata;
            }
            
            _orders[existingIndex] = existing.copyWith(
              status: isStatusAdvancing ? statusToUse : existing.status,
              providerId: newProviderId ?? existing.providerId,
              metadata: updatedMetadata,
            );
            statusUpdated++;
            
            // v261: Re-publicar o evento 30078 com status terminal para remover da marketplace
            // CRÍTICO para 'accepted': AWAIT o republish para garantir que billCode_nip44_provider
            // seja publicado antes de continuar. Sem await, o republish pode falhar silenciosamente.
            if (isStatusAdvancing) {
              if (statusToUse == 'accepted') {
                // AWAIT para accepted — billCode_nip44_provider é vital para o provedor
                await _republishOrderEventWithTerminalStatus(_orders[existingIndex], statusToUse);
              } else {
                // Fire-and-forget para outros status
                _republishOrderEventWithTerminalStatus(_orders[existingIndex], statusToUse);
              }
            }
          }
        }
      }
      
      if (statusUpdated > 0) {
        _immediateNotify(); // v269: notificar UI imediatamente quando status muda
      }
      
      // AUTO-LIQUIDAÇÃO v234: Também verificar no sync do usuário
      await _checkAutoLiquidation();
      
      // v132: Auto-pagamento de ordens liquidadas sem pagamento
      await _autoPayLiquidatedOrders();
      
      // v133: Renovar invoices para ordens liquidadas (provider side)
      await _renewInvoicesForLiquidatedAsProvider();
      
      // v253: AUTO-REPAIR: Tambem reparar no sync do usuario
      // v259: Timeout global no auto-repair para nao travar sync
      try {
        await _autoRepairMissingOrderEvents(
          allPendingOrders: <Order>[],
          userOrders: nostrOrders,
          providerOrders: <Order>[],
        ).timeout(const Duration(seconds: 30), onTimeout: () {
          broLog('v259: AUTO-REPAIR timeout (30s) no user sync - continuando');
        });
      } catch (e) {
        broLog('v259: AUTO-REPAIR exception no user sync: $e');
      }
      
      // v257/v259: Corrigir ordens com userPubkey corrompido (com timeout)
      try {
        await _fixCorruptedUserPubkeys().timeout(const Duration(seconds: 20), onTimeout: () {
          broLog('v259: _fixCorruptedUserPubkeys timeout (20s) no user sync');
        });
      } catch (e) {
        broLog('v259: _fixCorruptedUserPubkeys exception: $e');
      }
      
      // Ordenar por data (mais recente primeiro)
      _orders.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      
      // SEGURANÃâ¡A CRÃÂTICA: Salvar apenas ordens do usuÃÂ¡rio atual!
      // Isso evita que ordens de outros usuÃÂ¡rios sejam persistidas localmente
      _debouncedSave();
      _lastUserSyncTime = DateTime.now();
      _throttledNotify();
      
    } catch (e) {
    } finally {
      _isSyncingUser = false;
      _syncUserStartedAt = null; // v259: clear stale tracker
    }
  }

  /// Verificar se um status ÃÂ© mais recente que outro
  bool _isStatusMoreRecent(String newStatus, String currentStatus) {
    // CORREÃâ¡ÃÆO: Apenas status FINAIS nÃÂ£o podem regredir
    // accepted e awaiting_confirmation PODEM evoluir para completed/liquidated
    // CORREÃâ¡ÃÆO CRÃÂTICA: 'cancelled' ÃÂ© estado TERMINAL absoluto
    // Nada pode sobrescrever cancelled (exceto disputed)
    if (currentStatus == 'cancelled') {
      return newStatus == 'disputed';
    }
    // Se o novo status ÃÂ© 'cancelled', SEMPRE aceitar (cancelamento ÃÂ© aÃÂ§ÃÂ£o explÃÂ­cita do usuÃÂ¡rio)
    if (newStatus == 'cancelled') {
      return true;
    }
    // CORREÇÃO v349: disputed pode transicionar para completed/cancelled (resolução)
    if (currentStatus == 'disputed') {
      return newStatus == 'completed' || newStatus == 'cancelled';
    }
    // Status finais NÃO regridem  completed/liquidated é definitivo
    const finalStatuses = ['completed', 'liquidated'];
    if (finalStatuses.contains(currentStatus)) {
      return false;
    }
    // disputed vence sobre status NÃO-FINAIS
    if (newStatus == 'disputed') {
      return currentStatus != 'disputed';
    }
    
    // Ordem de progressÃÂ£o de status (SEM cancelled - tratado separadamente acima):
    // draft -> pending -> payment_received -> accepted -> processing -> awaiting_confirmation -> completed/liquidated
    const statusOrder = [
      'draft',
      'pending', 
      'payment_received', 
      'accepted', 
      'processing',
      'awaiting_confirmation',  // Bro enviou comprovante, aguardando validaÃÂ§ÃÂ£o do usuÃÂ¡rio
      'completed',
      'liquidated',  // Auto-liquidaÃÂ§ÃÂ£o apÃÂ³s 36h
    ];
    final newIndex = statusOrder.indexOf(newStatus);
    final currentIndex = statusOrder.indexOf(currentStatus);
    
    // Se algum status nÃÂ£o estÃÂ¡ na lista, considerar como nÃÂ£o sendo mais recente
    if (newIndex == -1 || currentIndex == -1) return false;
    
    return newIndex > currentIndex;
  }

  /// Republicar ordens locais que nÃÂ£o tÃÂªm eventId no Nostr
  /// ÃÅ¡til para migrar ordens criadas antes da integraÃÂ§ÃÂ£o Nostr
  /// SEGURANÃâ¡A: SÃÂ³ republica ordens que PERTENCEM ao usuÃÂ¡rio atual!
  Future<int> republishLocalOrdersToNostr() async {
    final privateKey = _nostrService.privateKey;
    if (privateKey == null) {
      return 0;
    }
    
    if (_currentUserPubkey == null || _currentUserPubkey!.isEmpty) {
      return 0;
    }
    
    int republished = 0;
    
    // PERFORMANCE: Coletar ordens a republicar e fazer em paralelo
    final ordersToRepublish = _orders.where((order) {
      if (order.userPubkey != _currentUserPubkey) return false;
      if (order.eventId == null || order.eventId!.isEmpty) return true;
      return false;
    }).toList();
    
    if (ordersToRepublish.isEmpty) return 0;
    
    final results = await Future.wait(
      ordersToRepublish.map((order) => _nostrOrderService.publishOrder(
        order: order,
        privateKey: privateKey,
      ).catchError((_) => null)),
    );
    
    for (int i = 0; i < results.length; i++) {
      final eventId = results[i];
      if (eventId != null) {
        final order = ordersToRepublish[i];
        final index = _orders.indexWhere((o) => o.id == order.id);
        if (index != -1) {
          _orders[index] = order.copyWith(
            eventId: eventId,
            userPubkey: _currentUserPubkey,
          );
          republished++;
        }
      }
    }
    
    if (republished > 0) {
      await _saveOrders();
      _throttledNotify();
    }
    
    return republished;
  }

  // ==================== AUTO RECONCILIATION ====================

  /// ReconciliaÃÂ§ÃÂ£o automÃÂ¡tica de ordens baseada em pagamentos do Breez SDK
  /// 
  /// Esta funÃÂ§ÃÂ£o analisa TODOS os pagamentos (recebidos e enviados) e atualiza
  /// os status das ordens automaticamente:
  /// 
  /// 1. Pagamentos RECEBIDOS Ã¢â â Atualiza ordens 'pending' para 'payment_received'
  ///    (usado quando o Bro paga via Lightning - menos comum no fluxo atual)
  /// 
  /// 2. Pagamentos ENVIADOS Ã¢â â Atualiza ordens 'awaiting_confirmation' para 'completed'
  ///    (quando o usuÃÂ¡rio liberou BTC para o Bro apÃÂ³s confirmar prova de pagamento)
  /// 
  /// A identificaÃÂ§ÃÂ£o ÃÂ© feita por:
  /// - paymentHash (se disponÃÂ­vel) - mais preciso
  /// - Valor aproximado + timestamp (fallback)
  Future<Map<String, int>> autoReconcileWithBreezPayments(List<Map<String, dynamic>> breezPayments) async {
    
    int pendingReconciled = 0;
    int completedReconciled = 0;
    
    // Separar pagamentos por direÃÂ§ÃÂ£o
    final receivedPayments = breezPayments.where((p) {
      final type = p['type']?.toString() ?? '';
      final direction = p['direction']?.toString() ?? '';
      return direction == 'RECEBIDO' || type.toLowerCase().contains('receive');
    }).toList();
    
    final sentPayments = breezPayments.where((p) {
      final type = p['type']?.toString() ?? '';
      final direction = p['direction']?.toString() ?? '';
      return direction == 'ENVIADO' || type.toLowerCase().contains('send');
    }).toList();
    
    
    // ========== RECONCILIAR PAGAMENTOS RECEBIDOS ==========
    // (ordens pending que receberam pagamento)
    final pendingOrders = _orders.where((o) => o.status == 'pending').toList();
    
    for (final order in pendingOrders) {
      final expectedSats = (order.btcAmount * 100000000).toInt();
      
      // Tentar match por paymentHash primeiro (mais seguro)
      if (order.paymentHash != null && order.paymentHash!.isNotEmpty) {
        for (final payment in receivedPayments) {
          final paymentHash = payment['paymentHash']?.toString();
          if (paymentHash == order.paymentHash) {
            await updateOrderStatus(
              orderId: order.id,
              status: 'payment_received',
              metadata: {
                'reconciledAt': DateTime.now().toIso8601String(),
                'reconciledFrom': 'auto_reconcile_received',
                'paymentHash': paymentHash,
              },
            );
            pendingReconciled++;
            break;
          }
        }
      }
    }
    
    // ========== RECONCILIAR PAGAMENTOS ENVIADOS ==========
    // DESATIVADO: Esta seÃÂ§ÃÂ£o auto-completava ordens sem confirmaÃÂ§ÃÂ£o do usuÃÂ¡rio.
    // Matchava por valor aproximado (5% tolerÃÂ¢ncia), o que causava falsos positivos.
    // A confirmaÃÂ§ÃÂ£o de pagamento DEVE ser feita MANUALMENTE pelo usuÃÂ¡rio.
    
    
    if (pendingReconciled > 0 || completedReconciled > 0) {
      await _saveOrders();
      _throttledNotify();
    }
    
    return {
      'pendingReconciled': pendingReconciled,
      'completedReconciled': completedReconciled,
    };
  }

  /// Callback chamado quando o Breez SDK detecta um pagamento ENVIADO
  /// DESATIVADO v1.0.129+232: Este callback causava auto-complete indevido!
  /// A ordem DEVE ser completada APENAS via _handleConfirmPayment (tela de ordem)
  /// O problema: qualquer pagamento enviado (inclusive para outros fins) podia
  /// ser matchado por valor e auto-completar uma ordem sem confirmação do usuário.
  Future<void> onPaymentSent({
    required String paymentId,
    required int amountSats,
    String? paymentHash,
  }) async {
    broLog('OrderProvider.onPaymentSent: $amountSats sats (hash: ${paymentHash ?? "N/A"})');
    broLog('onPaymentSent: Auto-complete DESATIVADO (v1.0.129+232)');
    broLog('   Ordens só podem ser completadas via confirmação manual do usuário');
    // NÃO fazer nada - a confirmação é feita via _handleConfirmPayment na tela de ordem
    // que já chama updateOrderStatus('completed') após o pagamento ao provedor ser confirmado
  }

  /// RECONCILIAÃâ¡ÃÆO FORÃâ¡ADA - Analisa TODAS as ordens e TODOS os pagamentos
  /// Use quando ordens antigas nÃÂ£o estÃÂ£o sendo atualizadas automaticamente
  /// 
  /// Esta funÃÂ§ÃÂ£o ÃÂ© mais agressiva que autoReconcileWithBreezPayments:
  /// - Verifica TODAS as ordens nÃÂ£o-completed (incluindo pending antigas)
  /// - Usa match por valor com tolerÃÂ¢ncia maior (10%)
  /// - Cria lista de pagamentos usados para evitar duplicaÃÂ§ÃÂ£o
  Future<Map<String, dynamic>> forceReconcileAllOrders(List<Map<String, dynamic>> breezPayments) async {
    
    int updated = 0;
    final usedPaymentIds = <String>{};
    final reconciliationLog = <Map<String, dynamic>>[];
    
    broLog('Ã°Å¸âÅ forceReconcileAllOrders: ${breezPayments.length} pagamentos');
    
    // Separar por tipo
    final receivedPayments = breezPayments.where((p) {
      final type = p['type']?.toString() ?? '';
      final direction = p['direction']?.toString() ?? '';
      final isReceived = direction == 'RECEBIDO' || 
                         type.toLowerCase().contains('receive') ||
                         type.toLowerCase().contains('received');
      return isReceived;
    }).toList();
    
    final sentPayments = breezPayments.where((p) {
      final type = p['type']?.toString() ?? '';
      final direction = p['direction']?.toString() ?? '';
      final isSent = direction == 'ENVIADO' || 
                     type.toLowerCase().contains('send') ||
                     type.toLowerCase().contains('sent');
      return isSent;
    }).toList();
    
    
    // CORREÃâ¡ÃÆO CRÃÂTICA: Para pagamentos ENVIADOS (que marcam como completed),
    // sÃÂ³ verificar ordens que EU CRIEI (sou o userPubkey)
    final currentUserPubkey = _nostrService.publicKey;
    
    // Buscar TODAS as ordens nÃÂ£o finalizadas
    final ordersToCheck = _orders.where((o) => 
      o.status != 'completed' && 
      o.status != 'cancelled'
    ).toList();
    
    for (final order in ordersToCheck) {
      final sats = (order.btcAmount * 100000000).toInt();
      final isMine = order.userPubkey == currentUserPubkey;
    }
    
    // ========== VERIFICAR CADA ORDEM ==========
    
    for (final order in ordersToCheck) {
      final expectedSats = (order.btcAmount * 100000000).toInt();
      final orderId = order.id.substring(0, 8);
      
      
      // Determinar qual lista de pagamentos verificar baseado no status
      List<Map<String, dynamic>> paymentsToCheck;
      String newStatus;
      
      if (order.status == 'pending' || order.status == 'payment_received') {
        // Para ordens pending - procurar em pagamentos RECEBIDOS
        // (no fluxo atual do Bro, isso ÃÂ© menos comum)
        paymentsToCheck = receivedPayments;
        newStatus = 'payment_received';
      } else {
        // DESATIVADO: NÃÂ£o auto-completar ordens accepted/awaiting_confirmation
        // UsuÃÂ¡rio deve confirmar recebimento MANUALMENTE
        continue;
      }
      
      // Procurar pagamento correspondente
      bool found = false;
      for (final payment in paymentsToCheck) {
        final paymentId = payment['id']?.toString() ?? '';
        
        // Pular se jÃÂ¡ foi usado
        if (usedPaymentIds.contains(paymentId)) continue;
        
        final paymentAmount = (payment['amount'] is int) 
            ? payment['amount'] as int 
            : int.tryParse(payment['amount']?.toString() ?? '0') ?? 0;
        
        final status = payment['status']?.toString() ?? '';
        
        // SÃÂ³ considerar pagamentos completados
        if (!status.toLowerCase().contains('completed') && 
            !status.toLowerCase().contains('complete') &&
            !status.toLowerCase().contains('succeeded')) {
          continue;
        }
        
        // TolerÃÂ¢ncia de 10% para match (mais agressivo)
        final tolerance = (expectedSats * 0.10).toInt().clamp(100, 10000);
        final diff = (paymentAmount - expectedSats).abs();
        
        
        if (diff <= tolerance) {
          
          // Marcar pagamento como usado
          usedPaymentIds.add(paymentId);
          
          // IMPORTANTE: Se vai marcar como 'completed', enviar taxa da plataforma primeiro
          bool feeSuccess = true;
          if (newStatus == 'completed') {
            feeSuccess = await PlatformFeeService.sendPlatformFee(
              orderId: order.id,
              totalSats: expectedSats,
            );
            if (!feeSuccess) {
            }
          }
          
          // Atualizar ordem
          await updateOrderStatus(
            orderId: order.id,
            status: newStatus,
            metadata: {
              ...?order.metadata,
              'reconciledAt': DateTime.now().toIso8601String(),
              'reconciledFrom': 'force_reconcile',
              'paymentAmount': paymentAmount,
              'paymentId': paymentId,
              'platformFeeSent': feeSuccess,
            },
          );
          
          reconciliationLog.add({
            'orderId': order.id,
            'oldStatus': order.status,
            'newStatus': newStatus,
            'paymentAmount': paymentAmount,
            'expectedAmount': expectedSats,
            'platformFeeSent': feeSuccess,
          });
          
          updated++;
          found = true;
          break;
        }
      }
      
      if (!found) {
      }
    }
    
    
    if (updated > 0) {
      await _saveOrders();
      _throttledNotify();
    }
    
    return {
      'updated': updated,
      'log': reconciliationLog,
    };
  }

  /// ForÃÂ§ar status de uma ordem especÃÂ­fica para 'completed'
  /// Use quando vocÃÂª tem certeza que a ordem foi paga mas o sistema nÃÂ£o detectou
  Future<bool> forceCompleteOrder(String orderId) async {
    final index = _orders.indexWhere((o) => o.id == orderId);
    if (index == -1) {
      return false;
    }
    
    final order = _orders[index];
    
    // IMPORTANTE: Enviar taxa da plataforma primeiro
    final expectedSats = (order.btcAmount * 100000000).toInt();
    final feeSuccess = await PlatformFeeService.sendPlatformFee(
      orderId: order.id,
      totalSats: expectedSats,
    );
    if (!feeSuccess) {
    }
    
    _orders[index] = order.copyWith(
      status: 'completed',
      completedAt: DateTime.now(),
      metadata: {
        ...?order.metadata,
        'forcedCompleteAt': DateTime.now().toIso8601String(),
        'forcedBy': 'user_manual',
        'platformFeeSent': feeSuccess,
      },
    );
    
    await _saveOrders();
    
    // Republicar no Nostr
    await _publishOrderToNostr(_orders[index]);
    
    _throttledNotify();
    return true;
  }
}
