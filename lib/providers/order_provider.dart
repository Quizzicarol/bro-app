import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
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

  List<Order> _orders = [];  // APENAS ordens do usuÃ¡rio atual
  List<Order> _availableOrdersForProvider = [];  // Ordens disponÃ­veis para Bros (NUNCA salvas)
  Order? _currentOrder;
  bool _isLoading = false;
  String? _error;
  bool _isInitialized = false;
  String? _currentUserPubkey;
  bool _isProviderMode = false;  // Modo provedor ativo (para UI, nÃ£o para filtro de ordens)

  // Prefixo para salvar no SharedPreferences (serÃ¡ combinado com pubkey)
  static const String _ordersKeyPrefix = 'orders_';

  // SEGURANÃ‡A CRÃTICA: Filtrar ordens por usuÃ¡rio - NUNCA mostrar ordens de outros!
  // Esta lista Ã© usada por TODOS os getters (orders, pendingOrders, etc)
  List<Order> get _filteredOrders {
    // SEGURANÃ‡A ABSOLUTA: Sem pubkey = sem ordens
    if (_currentUserPubkey == null || _currentUserPubkey!.isEmpty) {
      return [];
    }
    
    // SEMPRE filtrar por usuÃ¡rio - mesmo no modo provedor!
    // No modo provedor, mostramos ordens disponÃ­veis em tela separada, nÃ£o aqui
    final filtered = _orders.where((o) {
      // REGRA 1: Ordens SEM userPubkey sÃ£o rejeitadas (dados corrompidos/antigos)
      if (o.userPubkey == null || o.userPubkey!.isEmpty) {
        return false;
      }
      
      // REGRA 2: Ordem criada por este usuÃ¡rio
      final isOwner = o.userPubkey == _currentUserPubkey;
      
      // REGRA 3: Ordem que este usuÃ¡rio aceitou como Bro (providerId)
      final isMyProviderOrder = o.providerId == _currentUserPubkey;
      
      if (!isOwner && !isMyProviderOrder) {
      }
      
      return isOwner || isMyProviderOrder;
    }).toList();
    
    // Log apenas quando hÃ¡ filtros aplicados
    if (_orders.length != filtered.length) {
    }
    return filtered;
  }

  // Getters - USAM _filteredOrders para SEGURANÃ‡A
  // NOTA: orders NÃƒO inclui draft (ordens nÃ£o pagas nÃ£o aparecem na lista do usuÃ¡rio)
  List<Order> get orders => _filteredOrders.where((o) => o.status != 'draft').toList();
  List<Order> get pendingOrders => _filteredOrders.where((o) => o.status == 'pending' || o.status == 'payment_received').toList();
  List<Order> get activeOrders => _filteredOrders.where((o) => ['payment_received', 'confirmed', 'accepted', 'processing'].contains(o.status)).toList();
  List<Order> get completedOrders => _filteredOrders.where((o) => o.status == 'completed').toList();
  bool get isProviderMode => _isProviderMode;
  Order? get currentOrder => _currentOrder;
  bool get isLoading => _isLoading;
  String? get error => _error;
  
  /// Getter pÃºblico para a pubkey do usuÃ¡rio atual (usado para verificaÃ§Ãµes externas)
  String? get currentUserPubkey => _currentUserPubkey;
  
  /// SEGURANÃ‡A: Getter para ordens que EU CRIEI (modo usuÃ¡rio)
  /// Retorna APENAS ordens onde userPubkey == currentUserPubkey
  /// Usado na tela "Minhas Trocas" do modo usuÃ¡rio
  List<Order> get myCreatedOrders {
    // Se nÃ£o temos pubkey, tentar buscar do NostrService
    if (_currentUserPubkey == null || _currentUserPubkey!.isEmpty) {
      final fallbackPubkey = _nostrService.publicKey;
      if (fallbackPubkey != null && fallbackPubkey.isNotEmpty) {
        _currentUserPubkey = fallbackPubkey;
      } else {
        return [];
      }
    }
    
    final result = _orders.where((o) {
      // Apenas ordens que EU criei (nÃ£o ordens aceitas como provedor)
      return o.userPubkey == _currentUserPubkey && o.status != 'draft';
    }).toList();
    
    return result;
  }
  
  /// SEGURANÃ‡A: Getter para ordens que EU ACEITEI como Bro (modo provedor)
  /// Retorna APENAS ordens onde providerId == currentUserPubkey
  /// Usado na tela "Minhas Ordens" do modo provedor
  List<Order> get myAcceptedOrders {
    // Se nÃ£o temos pubkey, tentar buscar do NostrService
    if (_currentUserPubkey == null || _currentUserPubkey!.isEmpty) {
      final fallbackPubkey = _nostrService.publicKey;
      if (fallbackPubkey != null && fallbackPubkey.isNotEmpty) {
        _currentUserPubkey = fallbackPubkey;
      } else {
        return [];
      }
    }
    
    // DEBUG CRÃTICO: Listar todas as ordens e seus providerIds
    for (final o in _orders) {
    }
    
    final result = _orders.where((o) {
      // Apenas ordens que EU aceitei como provedor (nÃ£o ordens que criei)
      return o.providerId == _currentUserPubkey;
    }).toList();
    
    return result;
  }

  /// CRÃTICO: MÃ©todo para sair do modo provedor e limpar ordens de outros
  /// Deve ser chamado quando o usuÃ¡rio sai da tela de modo Bro
  void exitProviderMode() {
    _isProviderMode = false;
    
    // Limpar lista de ordens disponÃ­veis para provedor (NUNCA eram salvas)
    _availableOrdersForProvider = [];
    
    // IMPORTANTE: NÃƒO remover ordens que este usuÃ¡rio aceitou como provedor!
    // Mesmo que userPubkey seja diferente, se providerId == _currentUserPubkey,
    // essa ordem deve ser mantida para aparecer em "Minhas Ordens" do provedor
    final before = _orders.length;
    _orders = _orders.where((o) {
      // Sempre manter ordens que este usuÃ¡rio criou
      final isOwner = o.userPubkey == _currentUserPubkey;
      // SEMPRE manter ordens que este usuÃ¡rio aceitou como provedor
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
    
    notifyListeners();
  }
  
  /// Getter para ordens disponÃ­veis para Bros (usadas na tela de provedor)
  /// Esta lista NUNCA Ã© salva localmente!
  /// IMPORTANTE: Retorna uma CÃ“PIA para evitar ConcurrentModificationException
  /// quando o timer de polling modifica a lista durante iteraÃ§Ã£o na UI
  List<Order> get availableOrdersForProvider => List<Order>.from(_availableOrdersForProvider);

  /// Calcula o total de sats comprometidos com ordens pendentes/ativas (modo cliente)
  /// Este valor deve ser SUBTRAÃDO do saldo total para calcular saldo disponÃ­vel para garantia
  /// 
  /// IMPORTANTE: SÃ³ conta ordens que ainda NÃƒO foram pagas via Lightning!
  /// - 'draft': Invoice ainda nÃ£o pago - COMPROMETIDO
  /// - 'pending': Invoice pago, aguardando Bro aceitar - JÃ SAIU DA CARTEIRA
  /// - 'payment_received': Invoice pago, aguardando Bro - JÃ SAIU DA CARTEIRA
  /// - 'accepted', 'awaiting_confirmation', 'completed': JÃ PAGO
  /// 
  /// Na prÃ¡tica, APENAS ordens 'draft' deveriam ser contadas, mas removemos
  /// esse status ao refatorar o fluxo (invoice Ã© pago antes de criar ordem)
  int get committedSats {
    // CORRIGIDO: NÃ£o contar nenhuma ordem como "comprometida" porque:
    // 1. 'draft' foi removido - invoice Ã© pago ANTES de criar ordem
    // 2. Todas as outras jÃ¡ tiveram a invoice paga (sats nÃ£o estÃ£o na carteira)
    //
    // Se o usuÃ¡rio tem uma ordem 'pending', os sats JÃ FORAM para o escrow
    // quando ele pagou a invoice Lightning na tela de pagamento
    
    // Manter o log para debug, mas retornar 0
    final filteredForDebug = _filteredOrders.where((o) => 
      o.status == 'pending' || 
      o.status == 'payment_received' || 
      o.status == 'confirmed'
    ).toList();
    
    if (filteredForDebug.isNotEmpty) {
      for (final o in filteredForDebug) {
      }
    }
    
    // RETORNAR 0: Nenhum sat estÃ¡ "comprometido" na carteira
    // Os sats jÃ¡ saÃ­ram quando o usuÃ¡rio pagou a invoice Lightning
    return 0;
  }

  // Chave Ãºnica para salvar ordens deste usuÃ¡rio
  String get _ordersKey => '${_ordersKeyPrefix}${_currentUserPubkey ?? 'anonymous'}';

  // Inicializar com a pubkey do usuÃ¡rio
  Future<void> initialize({String? userPubkey}) async {
    // Se passou uma pubkey, usar ela
    if (userPubkey != null && userPubkey.isNotEmpty) {
      _currentUserPubkey = userPubkey;
    } else {
      // Tentar pegar do NostrService
      _currentUserPubkey = _nostrService.publicKey;
    }
    
    
    // ðŸ§¹ SEGURANÃ‡A: Limpar storage 'orders_anonymous' que pode conter ordens vazadas
    await _cleanupAnonymousStorage();
    
    // Resetar estado - CRÃTICO: Limpar AMBAS as listas de ordens!
    _orders = [];
    _availableOrdersForProvider = [];
    _isInitialized = false;
    
    // SEMPRE carregar ordens locais primeiro (para preservar status atualizados)
    // Antes estava sÃ³ em testMode, mas isso perdia status como payment_received
    // NOTA: SÃ³ carrega se temos pubkey vÃ¡lida (prevenÃ§Ã£o de vazamento)
    await _loadSavedOrders();
    
    // ðŸ§¹ LIMPEZA: Remover ordens DRAFT antigas (nÃ£o pagas em 1 hora)
    await _cleanupOldDraftOrders();
    
    // CORREÃ‡ÃƒO AUTOMÃTICA: Identificar ordens marcadas incorretamente como pagas
    // Se temos mÃºltiplas ordens "payment_received" com valores pequenos e criadas quase ao mesmo tempo,
    // Ã© provÃ¡vel que a reconciliaÃ§Ã£o automÃ¡tica tenha marcado incorretamente.
    // A ordem 4c805ae7 foi marcada incorretamente - ela foi criada DEPOIS da primeira ordem
    // e nunca recebeu pagamento real.
    await _fixIncorrectlyPaidOrders();
    
    // Depois sincronizar do Nostr (em background)
    if (_currentUserPubkey != null) {
      _syncFromNostrBackground();
    }
    
    _isInitialized = true;
    notifyListeners();
  }
  
  /// ðŸ§¹ SEGURANÃ‡A: Limpar storage 'orders_anonymous' que pode conter ordens de usuÃ¡rios anteriores
  /// TambÃ©m limpa qualquer cache global que possa ter ordens vazadas
  Future<void> _cleanupAnonymousStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // 1. Remover ordens do usuÃ¡rio 'anonymous'
      if (prefs.containsKey('orders_anonymous')) {
        await prefs.remove('orders_anonymous');
      }
      
      // 2. Remover cache global de ordens (pode conter ordens de outros usuÃ¡rios)
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
  
  /// ðŸ§¹ Remove ordens draft que nÃ£o foram pagas em 1 hora
  /// Isso evita acÃºmulo de ordens "fantasma" que o usuÃ¡rio abandonou
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

  // Recarregar ordens para novo usuÃ¡rio (apÃ³s login)
  Future<void> loadOrdersForUser(String userPubkey) async {
    
    // ðŸ” SEGURANÃ‡A CRÃTICA: Limpar TUDO antes de carregar novo usuÃ¡rio
    // Isso previne que ordens de usuÃ¡rio anterior vazem para o novo
    await _cleanupAnonymousStorage();
    
    // âš ï¸ NÃƒO limpar cache de collateral aqui!
    // O CollateralProvider gerencia isso prÃ³prio e verifica se usuÃ¡rio mudou
    // Limpar aqui causa problema de tier "caindo" durante a sessÃ£o
    
    _currentUserPubkey = userPubkey;
    _orders = [];
    _availableOrdersForProvider = [];  // Limpar tambÃ©m lista de disponÃ­veis
    _isInitialized = false;
    _isProviderMode = false;  // Reset modo provedor ao trocar de usuÃ¡rio
    
    // Notificar IMEDIATAMENTE que ordens foram limpas
    // Isso garante que committedSats retorne 0 antes de carregar novas ordens
    notifyListeners();
    
    // Carregar ordens locais primeiro (SEMPRE, para preservar status atualizados)
    await _loadSavedOrders();
    
    // SEGURANÃ‡A: Filtrar ordens que nÃ£o pertencem a este usuÃ¡rio
    // (podem ter vazado de sincronizaÃ§Ãµes anteriores)
    // IMPORTANTE: Manter ordens que este usuÃ¡rio CRIOU ou ACEITOU como Bro!
    final originalCount = _orders.length;
    _orders = _orders.where((order) {
      // Manter ordens deste usuÃ¡rio (criador)
      if (order.userPubkey == userPubkey) return true;
      // Manter ordens que este usuÃ¡rio aceitou como Bro
      if (order.providerId == userPubkey) return true;
      // Manter ordens sem pubkey definido (legado, mas marcar como deste usuÃ¡rio)
      if (order.userPubkey == null || order.userPubkey!.isEmpty) {
        return false; // Remover ordens sem dono identificado
      }
      // Remover ordens de outros usuÃ¡rios
      return false;
    }).toList();
    
    if (_orders.length < originalCount) {
      await _saveOrders(); // Salvar lista limpa
    }
    
    
    _isInitialized = true;
    notifyListeners();
    
    // Sincronizar do Nostr IMEDIATAMENTE (nÃ£o em background)
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
        // Primeiro republicar ordens locais antigas que nÃ£o estÃ£o no Nostr
        final privateKey = _nostrService.privateKey;
        if (privateKey != null) {
          await republishLocalOrdersToNostr();
        }
        
        // Depois sincronizar do Nostr
        await syncOrdersFromNostr();
      } catch (e) {
      }
    });
  }

  // Limpar ordens ao fazer logout - SEGURANÃ‡A CRÃTICA
  void clearOrders() {
    _orders = [];
    _availableOrdersForProvider = [];  // TambÃ©m limpar lista de disponÃ­veis
    _currentOrder = null;
    _currentUserPubkey = null;
    _isProviderMode = false;  // Reset modo provedor
    _isInitialized = false;
    notifyListeners();
  }

  // Carregar ordens do SharedPreferences
  Future<void> _loadSavedOrders() async {
    // SEGURANÃ‡A CRÃTICA: NÃ£o carregar ordens de 'orders_anonymous'
    // Isso previne vazamento de ordens de outros usuÃ¡rios para contas novas
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
        
        
        // SEGURANÃ‡A CRÃTICA: Filtrar ordens de OUTROS usuÃ¡rios que vazaram para este storage
        // Isso pode acontecer se o modo provedor salvou ordens incorretamente
        final beforeFilter = _orders.length;
        _orders = _orders.where((o) {
          // REGRA ESTRITA: Ordem DEVE ter userPubkey igual ao usuÃ¡rio atual
          // NÃ£o aceitar mais ordens sem pubkey (eram causando vazamento)
          final isOwner = o.userPubkey == _currentUserPubkey;
          // Ordem que este usuÃ¡rio aceitou como provedor
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
        
        // CORREÃ‡ÃƒO: Remover providerId falso (provider_test_001) de ordens
        // Este valor foi setado erroneamente por migraÃ§Ã£o antiga
        // O providerId correto serÃ¡ recuperado do Nostr durante o sync
        bool needsMigration = false;
        for (int i = 0; i < _orders.length; i++) {
          final order = _orders[i];
          
          // Se ordem tem o providerId de teste antigo, REMOVER (serÃ¡ corrigido pelo Nostr)
          if (order.providerId == 'provider_test_001') {
            // Setar providerId como null para que seja recuperado do Nostr
            _orders[i] = order.copyWith(providerId: null);
            needsMigration = true;
          }
        }
        
        // Se houve migraÃ§Ã£o, salvar
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
  /// pela reconciliaÃ§Ã£o automÃ¡tica antiga (baseada apenas em saldo).
  /// 
  /// Corrigir ordens marcadas incorretamente como "payment_received"
  /// 
  /// REGRA SIMPLES: Se a ordem tem status "payment_received" mas NÃƒO tem paymentHash,
  /// Ã© um falso positivo e deve voltar para "pending".
  /// 
  /// Ordens COM paymentHash foram verificadas pelo SDK Breez e sÃ£o vÃ¡lidas.
  Future<void> _fixIncorrectlyPaidOrders() async {
    // Buscar ordens com payment_received
    final paidOrders = _orders.where((o) => o.status == 'payment_received').toList();
    
    if (paidOrders.isEmpty) {
      return;
    }
    
    
    bool needsCorrection = false;
    
    for (final order in paidOrders) {
      // Se NÃƒO tem paymentHash, Ã© falso positivo!
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
  // Salvar ordens no SharedPreferences (SEMPRE salva, nÃ£o sÃ³ em testMode)
  // SEGURANÃ‡A: Agora sÃ³ salva ordens do usuÃ¡rio atual (igual _saveOnlyUserOrders)
  Future<void> _saveOrders() async {
    // SEGURANÃ‡A CRÃTICA: NÃ£o salvar se nÃ£o temos pubkey definida
    // Isso previne salvar ordens de outros usuÃ¡rios no storage 'orders_anonymous'
    if (_currentUserPubkey == null || _currentUserPubkey!.isEmpty) {
      return;
    }
    
    try {
      // SEGURANÃ‡A: Filtrar apenas ordens do usuÃ¡rio atual antes de salvar
      final userOrders = _orders.where((o) => 
        o.userPubkey == _currentUserPubkey || 
        o.providerId == _currentUserPubkey
      ).toList();
      
      final prefs = await SharedPreferences.getInstance();
      final ordersJson = json.encode(userOrders.map((o) => o.toJson()).toList());
      await prefs.setString(_ordersKey, ordersJson);
      
      // Log de cada ordem salva
      for (var order in userOrders) {
      }
    } catch (e) {
    }
  }
  
  /// SEGURANÃ‡A: Salvar APENAS ordens do usuÃ¡rio atual no SharedPreferences
  /// Ordens de outros usuÃ¡rios (visualizadas no modo provedor) ficam apenas em memÃ³ria
  Future<void> _saveOnlyUserOrders() async {
    // SEGURANÃ‡A CRÃTICA: NÃ£o salvar se nÃ£o temos pubkey definida
    // Isso previne que ordens de outros usuÃ¡rios sejam salvas em 'orders_anonymous'
    if (_currentUserPubkey == null || _currentUserPubkey!.isEmpty) {
      return;
    }
    
    try {
      // Filtrar apenas ordens do usuÃ¡rio atual
      final userOrders = _orders.where((o) => 
        o.userPubkey == _currentUserPubkey || 
        o.providerId == _currentUserPubkey  // Ordens que este usuÃ¡rio aceitou como provedor
      ).toList();
      
      final prefs = await SharedPreferences.getInstance();
      final ordersJson = json.encode(userOrders.map((o) => o.toJson()).toList());
      await prefs.setString(_ordersKey, ordersJson);
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
    notifyListeners();
    return true;
  }

  /// Cancelar uma ordem pendente
  /// Apenas ordens com status 'pending' podem ser canceladas
  /// SEGURANÃ‡A: Apenas o dono da ordem pode cancelÃ¡-la!
  Future<bool> cancelOrder(String orderId) async {
    final index = _orders.indexWhere((o) => o.id == orderId);
    if (index == -1) {
      return false;
    }
    
    final order = _orders[index];
    
    // VERIFICAÃ‡ÃƒO DE SEGURANÃ‡A: Apenas o dono pode cancelar
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
    try {
      final privateKey = _nostrService.privateKey;
      if (privateKey != null) {
        await _nostrOrderService.updateOrderStatus(
          privateKey: privateKey,
          orderId: orderId,
          newStatus: 'cancelled',
        );
      }
    } catch (e) {
    }
    
    notifyListeners();
    return true;
  }

  /// Verificar se um pagamento especÃ­fico corresponde a uma ordem pendente
  /// Usa match por valor quando paymentHash nÃ£o estÃ¡ disponÃ­vel (ordens antigas)
  /// IMPORTANTE: Este mÃ©todo deve ser chamado manualmente pelo usuÃ¡rio para evitar falsos positivos
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
          notifyListeners();
          return true;
        }
      }
    }
    
    // Fallback: verificar por valor (menos seguro, mas Ãºtil para ordens antigas)
    // Tolerar diferenÃ§a de atÃ© 5 sats (taxas de rede podem variar ligeiramente)
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
        notifyListeners();
        return true;
      }
    }
    
    return false;
  }

  // Criar ordem LOCAL (NÃƒO publica no Nostr!)
  // A ordem sÃ³ serÃ¡ publicada no Nostr APÃ“S pagamento confirmado
  // Isso evita que Bros vejam ordens sem depÃ³sito
  Future<Order?> createOrder({
    required String billType,
    required String billCode,
    required double amount,
    required double btcAmount,
    required double btcPrice,
  }) async {
    // VALIDAÃ‡ÃƒO CRÃTICA: Nunca criar ordem com amount = 0
    if (amount <= 0) {
      _error = 'Valor da ordem invÃ¡lido';
      notifyListeners();
      return null;
    }
    
    if (btcAmount <= 0) {
      _error = 'Valor em BTC invÃ¡lido';
      notifyListeners();
      return null;
    }
    
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      
      // Calcular taxas (1% provider + 2% platform)
      final providerFee = amount * 0.01;
      final platformFee = amount * 0.02;
      final total = amount + providerFee + platformFee;
      
      // ðŸ”¥ SIMPLIFICADO: Status 'pending' = Aguardando Bro
      // A ordem jÃ¡ estÃ¡ paga (invoice/endereÃ§o jÃ¡ foi criado)
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
        status: 'pending',  // âœ… Direto para pending = Aguardando Bro
        createdAt: DateTime.now(),
      );
      
      // LOG DE VALIDAÃ‡ÃƒO
      
      _orders.insert(0, order);
      _currentOrder = order;
      
      // Salvar localmente - USAR _saveOrders() para garantir filtro de seguranÃ§a!
      await _saveOrders();
      
      notifyListeners();
      
      // ðŸ”¥ PUBLICAR NO NOSTR IMEDIATAMENTE
      // A ordem jÃ¡ estÃ¡ com pagamento sendo processado
      _publishOrderToNostr(order);
      
      return order;
    } catch (e) {
      _error = e.toString();
      return null;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
  
  /// CRÃTICO: Publicar ordem no Nostr SOMENTE APÃ“S pagamento confirmado
  /// Este mÃ©todo transforma a ordem de 'draft' para 'pending' e publica no Nostr
  /// para que os Bros possam vÃª-la e aceitar
  Future<bool> publishOrderAfterPayment(String orderId) async {
    
    final index = _orders.indexWhere((o) => o.id == orderId);
    if (index == -1) {
      return false;
    }
    
    final order = _orders[index];
    
    // Validar que ordem estÃ¡ em draft (nÃ£o foi publicada ainda)
    if (order.status != 'draft') {
      // Se jÃ¡ foi publicada, apenas retornar sucesso
      if (order.status == 'pending' || order.status == 'payment_received') {
        return true;
      }
      return false;
    }
    
    try {
      // Atualizar status para 'pending' (agora visÃ­vel para Bros)
      _orders[index] = order.copyWith(status: 'pending');
      await _saveOrders();
      notifyListeners();
      
      // AGORA SIM publicar no Nostr
      await _publishOrderToNostr(_orders[index]);
      
      // Pequeno delay para propagaÃ§Ã£o
      await Future.delayed(const Duration(milliseconds: 500));
      
      return true;
    } catch (e) {
      return false;
    }
  }

  // Listar ordens (para usuÃ¡rio normal ou provedor)
  Future<void> fetchOrders({String? status, bool forProvider = false}) async {
    _isLoading = true;
    
    // SEGURANÃ‡A: Definir modo provedor ANTES de sincronizar
    _isProviderMode = forProvider;
    
    // Se SAINDO do modo provedor (ou em modo usuÃ¡rio), limpar ordens de outros usuÃ¡rios
    if (!forProvider && _orders.isNotEmpty) {
      final before = _orders.length;
      _orders = _orders.where((o) {
        // REGRA ESTRITA: Apenas ordens deste usuÃ¡rio
        final isOwner = o.userPubkey == _currentUserPubkey;
        // Ou ordens que este usuÃ¡rio aceitou como provedor
        final isProvider = o.providerId == _currentUserPubkey;
        return isOwner || isProvider;
      }).toList();
      final removed = before - _orders.length;
      if (removed > 0) {
        // Salvar storage limpo
        await _saveOnlyUserOrders();
      }
    }
    
    notifyListeners();
    
    try {
      if (forProvider) {
        // MODO PROVEDOR: Buscar TODAS as ordens pendentes de TODOS os usuÃ¡rios
        // Timeout de 30s para sync provedor
        await syncAllPendingOrdersFromNostr().timeout(
          const Duration(seconds: 30),
          onTimeout: () {
          },
        );
      } else {
        // MODO USUÃRIO: Buscar apenas ordens do prÃ³prio usuÃ¡rio
        await syncOrdersFromNostr().timeout(
          const Duration(seconds: 15),
          onTimeout: () {
          },
        );
      }
    } catch (e) {
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
  
  /// Buscar TODAS as ordens pendentes do Nostr (para modo Provedor/Bro)
  /// SEGURANÃ‡A: Ordens de outros usuÃ¡rios vÃ£o para _availableOrdersForProvider
  /// e NUNCA sÃ£o adicionadas Ã  lista principal _orders!
  Future<void> syncAllPendingOrdersFromNostr() async {
    try {
      
      // Helper para busca segura (captura exceÃ§Ãµes e retorna lista vazia)
      // Timeout de 25s por fonte individual
      Future<List<Order>> safeFetch(Future<List<Order>> Function() fetcher, String name) async {
        try {
          return await fetcher().timeout(const Duration(seconds: 25), onTimeout: () {
            return <Order>[];
          });
        } catch (e) {
          return <Order>[];
        }
      }
      
      // Executar buscas EM PARALELO com tratamento de erro individual
      final results = await Future.wait([
        safeFetch(() => _nostrOrderService.fetchPendingOrders(), 'fetchPendingOrders'),
        safeFetch(() => _currentUserPubkey != null 
            ? _nostrOrderService.fetchUserOrders(_currentUserPubkey!)
            : Future.value(<Order>[]), 'fetchUserOrders'),
        safeFetch(() => _currentUserPubkey != null
            ? _nostrOrderService.fetchProviderOrders(_currentUserPubkey!)
            : Future.value(<Order>[]), 'fetchProviderOrders'),
      ]);
      
      final allPendingOrders = results[0];
      final userOrders = results[1];
      final providerOrders = results[2];
      
      
      // SEGURANÃ‡A: Separar ordens em duas listas:
      // 1. Ordens do usuÃ¡rio atual -> _orders
      // 2. Ordens de outros (disponÃ­veis para aceitar) -> _availableOrdersForProvider
      
      _availableOrdersForProvider = []; // Limpar lista anterior
      final seenAvailableIds = <String>{}; // Para evitar duplicatas
      int addedToAvailable = 0;
      int updated = 0;
      
      for (var pendingOrder in allPendingOrders) {
        // Ignorar ordens com amount=0
        if (pendingOrder.amount <= 0) continue;
        
        // DEDUPLICAÃ‡ÃƒO: Ignorar se jÃ¡ vimos esta ordem
        if (seenAvailableIds.contains(pendingOrder.id)) {
          continue;
        }
        seenAvailableIds.add(pendingOrder.id);
        
        // Verificar se Ã© ordem do usuÃ¡rio atual OU ordem que ele aceitou como provedor
        final isMyOrder = pendingOrder.userPubkey == _currentUserPubkey;
        final isMyProviderOrder = pendingOrder.providerId == _currentUserPubkey;
        
        // Se NÃƒO Ã© minha ordem e NÃƒO Ã© ordem que aceitei, verificar status
        // Ordens de outros com status final nÃ£o interessam
        if (!isMyOrder && !isMyProviderOrder) {
          if (pendingOrder.status == 'cancelled' || pendingOrder.status == 'completed') continue;
        }
        
        if (isMyOrder || isMyProviderOrder) {
          // Ordem do usuÃ¡rio OU ordem aceita como provedor: atualizar na lista _orders
          final existingIndex = _orders.indexWhere((o) => o.id == pendingOrder.id);
          if (existingIndex == -1) {
            // SEGURANÃ‡A CRÃTICA: SÃ³ adicionar se realmente Ã© minha ordem ou aceitei como provedor
            // NUNCA adicionar ordem de outro usuÃ¡rio aqui!
            if (isMyOrder || (isMyProviderOrder && pendingOrder.providerId == _currentUserPubkey)) {
              _orders.add(pendingOrder);
            } else {
            }
          } else {
            final existing = _orders[existingIndex];
            // SEGURANÃ‡A: Verificar que ordem pertence ao usuÃ¡rio atual antes de atualizar
            final isOwnerExisting = existing.userPubkey == _currentUserPubkey;
            final isProviderExisting = existing.providerId == _currentUserPubkey;
            
            if (!isOwnerExisting && !isProviderExisting) {
              continue;
            }
            
            // CORREÃ‡ÃƒO: Apenas status FINAIS devem ser protegidos
            // accepted e awaiting_confirmation podem evoluir para completed
            const protectedStatuses = ['cancelled', 'completed', 'liquidated', 'disputed'];
            if (protectedStatuses.contains(existing.status)) {
              continue;
            }
            
            // CORREÃ‡ÃƒO: Sempre atualizar se status do Nostr Ã© mais recente
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
          // Ordem de OUTRO usuÃ¡rio: adicionar apenas Ã  lista de disponÃ­veis
          // NUNCA adicionar Ã  lista principal _orders!
          
          // CORREÃ‡ÃƒO CRÃTICA: Verificar se essa ordem jÃ¡ existe em _orders com status avanÃ§ado
          // (significa que EU jÃ¡ aceitei essa ordem, mas o evento Nostr ainda estÃ¡ como pending)
          final existingInOrders = _orders.cast<Order?>().firstWhere(
            (o) => o?.id == pendingOrder.id,
            orElse: () => null,
          );
          
          if (existingInOrders != null) {
            // Ordem jÃ¡ existe - NÃƒO adicionar Ã  lista de disponÃ­veis
            const protectedStatuses = ['accepted', 'awaiting_confirmation', 'completed', 'liquidated', 'cancelled', 'disputed'];
            if (protectedStatuses.contains(existingInOrders.status)) {
              continue;
            }
          }
          
          _availableOrdersForProvider.add(pendingOrder);
          addedToAvailable++;
        }
      }
      
      
      // Processar ordens do prÃ³prio usuÃ¡rio (jÃ¡ buscadas em paralelo)
      int addedFromUser = 0;
      int addedFromProviderHistory = 0;
      
      // 1. Processar ordens criadas pelo usuÃ¡rio
      for (var order in userOrders) {
        final existingIndex = _orders.indexWhere((o) => o.id == order.id);
        if (existingIndex == -1 && order.amount > 0) {
          _orders.add(order);
          addedFromUser++;
        }
      }
      
      // 2. CRÃTICO: Processar ordens onde este usuÃ¡rio Ã© o PROVEDOR (histÃ³rico de ordens aceitas)
      // Estas ordens foram buscadas em paralelo acima
      
      for (var provOrder in providerOrders) {
        final existingIndex = _orders.indexWhere((o) => o.id == provOrder.id);
        if (existingIndex == -1 && provOrder.amount > 0) {
          // Nova ordem do histÃ³rico - adicionar
          // NOTA: O status agora jÃ¡ vem correto de fetchProviderOrders (que busca updates)
          // SÃ³ forÃ§ar "accepted" se vier como "pending" E nÃ£o houver outro status mais avanÃ§ado
          if (provOrder.status == 'pending') {
            // Se status ainda Ã© pending, significa que nÃ£o houve evento de update
            // EntÃ£o esta Ã© uma ordem aceita mas ainda nÃ£o processada
            provOrder = provOrder.copyWith(status: 'accepted');
          }
          _orders.add(provOrder);
          addedFromProviderHistory++;
        } else if (existingIndex != -1) {
          // Ordem jÃ¡ existe - atualizar se status do Nostr Ã© mais avanÃ§ado
          final existing = _orders[existingIndex];
          
          // CORREÃ‡ÃƒO: Status "accepted" NÃƒO deve ser protegido pois pode evoluir para completed
          // Apenas status finais devem ser protegidos
          const protectedStatuses = ['cancelled', 'completed', 'liquidated', 'disputed'];
          if (protectedStatuses.contains(existing.status)) {
            continue;
          }
          
          // Atualizar se o status do Nostr Ã© mais avanÃ§ado
          if (_isStatusMoreRecent(provOrder.status, existing.status)) {
            _orders[existingIndex] = existing.copyWith(
              status: provOrder.status,
              completedAt: provOrder.status == 'completed' ? DateTime.now() : existing.completedAt,
            );
          }
        }
      }
      
      
      // 3. CRÃTICO: Buscar updates de status para ordens que este provedor aceitou
      // Isso permite que o Bro veja quando o usuÃ¡rio confirmou (status=completed)
      if (_currentUserPubkey != null && _currentUserPubkey!.isNotEmpty) {
        
        // Log de todas as ordens e seus providerIds
        for (final o in _orders) {
          final provId = o.providerId;
          final match = provId == _currentUserPubkey;
        }
        
        final myOrderIds = _orders
            .where((o) => o.providerId == _currentUserPubkey)
            .map((o) => o.id)
            .toList();
        
        // TambÃ©m buscar ordens em awaiting_confirmation que podem ter sido atualizadas
        final awaitingOrderIds = _orders
            .where((o) => o.providerId == _currentUserPubkey && o.status == 'awaiting_confirmation')
            .map((o) => o.id)
            .toList();
        
        if (awaitingOrderIds.isNotEmpty) {
        }
        
        if (myOrderIds.isNotEmpty) {
          final providerUpdates = await _nostrOrderService.fetchOrderUpdatesForProvider(
            _currentUserPubkey!,
            orderIds: myOrderIds,
          );
          
          for (final entry in providerUpdates.entries) {
          }
          
          int statusUpdated = 0;
          for (final entry in providerUpdates.entries) {
            final orderId = entry.key;
            final update = entry.value;
            final newStatus = update['status'] as String?;
            
            if (newStatus == null) {
              continue;
            }
            
            final existingIndex = _orders.indexWhere((o) => o.id == orderId);
            if (existingIndex == -1) {
              continue;
            }
            
            final existing = _orders[existingIndex];
            
            // Verificar se Ã© completed e local Ã© awaiting_confirmation
            if (newStatus == 'completed' && existing.status == 'awaiting_confirmation') {
              _orders[existingIndex] = existing.copyWith(
                status: 'completed',
                completedAt: DateTime.now(),
              );
              statusUpdated++;
            } else if (_isStatusMoreRecent(newStatus, existing.status)) {
              // Caso genÃ©rico
              _orders[existingIndex] = existing.copyWith(
                status: newStatus,
                completedAt: newStatus == 'completed' ? DateTime.now() : existing.completedAt,
              );
              statusUpdated++;
            } else {
            }
          }
          
          if (statusUpdated > 0) {
          } else {
          }
        }
      }
      
      // Ordenar por data (mais recente primeiro)
      _orders.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      
      // SEGURANÃ‡A: NÃƒO salvar ordens de outros usuÃ¡rios no storage local!
      // Apenas salvar as ordens que pertencem ao usuÃ¡rio atual
      // As ordens de outros ficam apenas em memÃ³ria (para visualizaÃ§Ã£o do provedor)
      await _saveOnlyUserOrders();
      notifyListeners();
      
    } catch (e) {
    }
  }

  // Buscar ordem especÃ­fica
  Future<Order?> fetchOrder(String orderId) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final orderData = await _apiService.getOrder(orderId);
      
      if (orderData != null) {
        final order = Order.fromJson(orderData);
        
        // SEGURANÃ‡A: SÃ³ inserir se for ordem do usuÃ¡rio atual ou modo provedor ativo
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
        notifyListeners();
        return order;
      }

      return null;
    } catch (e) {
      _error = e.toString();
      return null;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // Aceitar ordem (provider)
  Future<bool> acceptOrder(String orderId, String providerId) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

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
      notifyListeners();
    }
  }

  // Atualizar status local E publicar no Nostr
  Future<void> updateOrderStatusLocal(String orderId, String status) async {
    final index = _orders.indexWhere((o) => o.id == orderId);
    if (index != -1) {
      _orders[index] = _orders[index].copyWith(status: status);
      await _saveOrders();
      notifyListeners();
      
      // IMPORTANTE: Publicar atualizaÃ§Ã£o no Nostr para sincronizaÃ§Ã£o P2P
      final privateKey = _nostrService.privateKey;
      if (privateKey != null) {
        try {
          final success = await _nostrOrderService.updateOrderStatus(
            privateKey: privateKey,
            orderId: orderId,
            newStatus: status,
          );
          if (success) {
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
    notifyListeners();

    try {
      // IMPORTANTE: Publicar no Nostr PRIMEIRO e sÃ³ atualizar localmente se der certo
      final privateKey = _nostrService.privateKey;
      bool nostrSuccess = false;
      
      
      if (privateKey != null && privateKey.isNotEmpty) {
        
        nostrSuccess = await _nostrOrderService.updateOrderStatus(
          privateKey: privateKey,
          orderId: orderId,
          newStatus: status,
          providerId: providerId,
        );
        
        if (nostrSuccess) {
        } else {
          _error = 'Falha ao publicar no Nostr';
          _isLoading = false;
          notifyListeners();
          return false; // CRÃTICO: Retornar false se Nostr falhar
        }
      } else {
        _error = 'Chave privada nÃ£o disponÃ­vel';
        _isLoading = false;
        notifyListeners();
        return false;
      }
      
      // SÃ³ atualizar localmente APÃ“S sucesso no Nostr
      final index = _orders.indexWhere((o) => o.id == orderId);
      if (index != -1) {
        // Preservar metadata existente se nÃ£o for passado novo
        final existingMetadata = _orders[index].metadata;
        final newMetadata = metadata ?? existingMetadata;
        
        // Usar copyWith para manter dados existentes
        _orders[index] = _orders[index].copyWith(
          status: status,
          providerId: providerId,
          metadata: newMetadata,
          acceptedAt: status == 'accepted' ? DateTime.now() : _orders[index].acceptedAt,
          completedAt: status == 'completed' ? DateTime.now() : _orders[index].completedAt,
        );
        
        // Salvar localmente
        final prefs = await SharedPreferences.getInstance();
        final ordersJson = json.encode(_orders.map((o) => o.toJson()).toList());
        await prefs.setString(_ordersKey, ordersJson);
        
      } else {
      }
      
      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// Provedor aceita uma ordem - publica aceitaÃ§Ã£o no Nostr e atualiza localmente
  Future<bool> acceptOrderAsProvider(String orderId) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      // Buscar a ordem localmente primeiro
      Order? order = getOrderById(orderId);
      
      // Se nÃ£o encontrou localmente, buscar do Nostr
      if (order == null) {
        
        final orderData = await _nostrOrderService.fetchOrderFromNostr(orderId);
        if (orderData != null) {
          order = Order.fromJson(orderData);
          // Adicionar Ã  lista local para referÃªncia futura
          _orders.add(order);
        }
      }
      
      if (order == null) {
        _error = 'Ordem nÃ£o encontrada';
        _isLoading = false;
        notifyListeners();
        return false;
      }

      // Pegar chave privada do Nostr
      final privateKey = _nostrService.privateKey;
      if (privateKey == null) {
        _error = 'Chave privada nÃ£o disponÃ­vel';
        _isLoading = false;
        notifyListeners();
        return false;
      }

      final providerPubkey = _nostrService.publicKey;

      // Publicar aceitaÃ§Ã£o no Nostr
      final success = await _nostrOrderService.acceptOrderOnNostr(
        order: order,
        providerPrivateKey: privateKey,
      );

      if (!success) {
        _error = 'Falha ao publicar aceitaÃ§Ã£o no Nostr';
        _isLoading = false;
        notifyListeners();
        return false;
      }

      // Atualizar localmente
      final index = _orders.indexWhere((o) => o.id == orderId);
      if (index != -1) {
        _orders[index] = _orders[index].copyWith(
          status: 'accepted',
          providerId: providerPubkey,
          acceptedAt: DateTime.now(),
        );
        
        // Salvar localmente (apenas ordens do usuÃ¡rio/provedor atual)
        await _saveOnlyUserOrders();
        
      }

      return true;
    } catch (e) {
      _error = e.toString();
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Provedor completa uma ordem - publica comprovante no Nostr e atualiza localmente
  Future<bool> completeOrderAsProvider(String orderId, String proof, {String? providerInvoice}) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      // Buscar a ordem localmente primeiro
      Order? order = getOrderById(orderId);
      
      // Se nÃ£o encontrou localmente, buscar do Nostr
      if (order == null) {
        
        final orderData = await _nostrOrderService.fetchOrderFromNostr(orderId);
        if (orderData != null) {
          order = Order.fromJson(orderData);
          // Adicionar Ã  lista local para referÃªncia futura
          _orders.add(order);
        }
      }
      
      if (order == null) {
        _error = 'Ordem nÃ£o encontrada';
        _isLoading = false;
        notifyListeners();
        return false;
      }

      // Pegar chave privada do Nostr
      final privateKey = _nostrService.privateKey;
      if (privateKey == null) {
        _error = 'Chave privada nÃ£o disponÃ­vel';
        _isLoading = false;
        notifyListeners();
        return false;
      }


      // Publicar conclusÃ£o no Nostr
      final success = await _nostrOrderService.completeOrderOnNostr(
        order: order,
        providerPrivateKey: privateKey,
        proofImageBase64: proof,
        providerInvoice: providerInvoice, // Invoice para receber pagamento
      );

      if (!success) {
        _error = 'Falha ao publicar comprovante no Nostr';
        _isLoading = false;
        notifyListeners();
        return false;
      }

      // Atualizar localmente
      final index = _orders.indexWhere((o) => o.id == orderId);
      if (index != -1) {
        _orders[index] = _orders[index].copyWith(
          status: 'awaiting_confirmation',
          metadata: {
            ...(_orders[index].metadata ?? {}),
            // CORRIGIDO: Salvar imagem completa em base64, nÃ£o truncar!
            'paymentProof': proof,
            'proofSentAt': DateTime.now().toIso8601String(),
            if (providerInvoice != null) 'providerInvoice': providerInvoice,
          },
        );
        
        // Salvar localmente usando _saveOrders() com filtro de seguranÃ§a
        await _saveOrders();
        
      }

      return true;
    } catch (e) {
      _error = e.toString();
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Auto-liquidaÃ§Ã£o quando usuÃ¡rio nÃ£o confirma em 24h
  /// Marca a ordem como 'liquidated' e notifica o usuÃ¡rio
  Future<bool> autoLiquidateOrder(String orderId, String proof) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      
      // Buscar a ordem localmente primeiro
      Order? order = getOrderById(orderId);
      
      if (order == null) {
        _error = 'Ordem nÃ£o encontrada';
        _isLoading = false;
        notifyListeners();
        return false;
      }

      // Publicar no Nostr com status 'liquidated'
      final privateKey = _nostrService.privateKey;
      if (privateKey == null) {
        _error = 'Chave privada nÃ£o disponÃ­vel';
        _isLoading = false;
        notifyListeners();
        return false;
      }

      // Usar a funÃ§Ã£o existente de updateOrderStatus com status 'liquidated'
      final success = await _nostrOrderService.updateOrderStatus(
        privateKey: privateKey,
        orderId: orderId,
        newStatus: 'liquidated',
        providerId: _currentUserPubkey,
      );

      if (!success) {
        _error = 'Falha ao publicar auto-liquidaÃ§Ã£o no Nostr';
        _isLoading = false;
        notifyListeners();
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
            'reason': 'UsuÃ¡rio nÃ£o confirmou em 24h',
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
      notifyListeners();
    }
  }

  // Validar boleto
  Future<Map<String, dynamic>?> validateBoleto(String code) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final result = await _apiService.validateBoleto(code);
      return result;
    } catch (e) {
      _error = e.toString();
      return null;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // Decodificar PIX
  Future<Map<String, dynamic>?> decodePix(String code) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final result = await _apiService.decodePix(code);
      return result;
    } catch (e) {
      _error = e.toString();
      return null;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // Converter preÃ§o
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
        orElse: () => throw Exception('Ordem nÃ£o encontrada'),
      );
    } catch (e) {
      return null;
    }
  }

  // Get order (alias para fetchOrder)
  Future<Map<String, dynamic>?> getOrder(String orderId) async {
    try {
      
      // Primeiro, tentar encontrar na lista em memÃ³ria (mais rÃ¡pido)
      final localOrder = _orders.cast<Order?>().firstWhere(
        (o) => o?.id == orderId,
        orElse: () => null,
      );
      
      if (localOrder != null) {
        return localOrder.toJson();
      }
      
      // TambÃ©m verificar nas ordens disponÃ­veis para provider
      final availableOrder = _availableOrdersForProvider.cast<Order?>().firstWhere(
        (o) => o?.id == orderId,
        orElse: () => null,
      );
      
      if (availableOrder != null) {
        return availableOrder.toJson();
      }
      
      
      // Se nÃ£o encontrou localmente, tentar buscar do backend
      final orderData = await _apiService.getOrder(orderId);
      if (orderData != null) {
        return orderData;
      }
      
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
    notifyListeners();
  }

  // Clear current order
  void clearCurrentOrder() {
    _currentOrder = null;
    notifyListeners();
  }

  // Clear error
  void clearError() {
    _error = null;
    notifyListeners();
  }

  // Clear all orders (memory only)
  void clear() {
    _orders = [];
    _availableOrdersForProvider = [];  // Limpar tambÃ©m lista de disponÃ­veis
    _currentOrder = null;
    _error = null;
    _isInitialized = false;
    notifyListeners();
  }

  // Clear orders from memory only (for logout - keeps data in storage)
  Future<void> clearAllOrders() async {
    _orders = [];
    _availableOrdersForProvider = [];  // Limpar tambÃ©m lista de disponÃ­veis
    _currentOrder = null;
    _error = null;
    _currentUserPubkey = null;
    _isInitialized = false;
    notifyListeners();
  }

  // Permanently delete all orders (for testing/reset)
  Future<void> permanentlyDeleteAllOrders() async {
    _orders = [];
    _availableOrdersForProvider = [];  // Limpar tambÃ©m lista de disponÃ­veis
    _currentOrder = null;
    _error = null;
    _isInitialized = false;
    
    // Limpar do SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_ordersKey);
    } catch (e) {
    }
    
    notifyListeners();
  }

  /// Reconciliar ordens pendentes com pagamentos jÃ¡ recebidos no Breez
  /// Esta funÃ§Ã£o verifica os pagamentos recentes do Breez e atualiza ordens pendentes
  /// que possam ter perdido a atualizaÃ§Ã£o de status (ex: app fechou antes do callback)
  /// 
  /// IMPORTANTE: Usa APENAS paymentHash para identificaÃ§Ã£o PRECISA
  /// O fallback por valor foi DESATIVADO porque causava falsos positivos
  /// (mesmo pagamento usado para mÃºltiplas ordens diferentes)
  /// 
  /// @param breezPayments Lista de pagamentos do Breez SDK (obtida via listPayments)
  Future<int> reconcilePendingOrdersWithBreez(List<dynamic> breezPayments) async {
    
    // Buscar ordens pendentes
    final pendingOrders = _orders.where((o) => o.status == 'pending').toList();
    
    if (pendingOrders.isEmpty) {
      return 0;
    }
    
    
    int reconciled = 0;
    
    // Criar set de paymentHashes jÃ¡ usados (para evitar duplicaÃ§Ã£o)
    final Set<String> usedHashes = {};
    
    // Primeiro, coletar hashes jÃ¡ usados por ordens que jÃ¡ foram pagas
    for (final order in _orders) {
      if (order.status != 'pending' && order.paymentHash != null) {
        usedHashes.add(order.paymentHash!);
      }
    }
    
    for (var order in pendingOrders) {
      
      // ÃšNICO MÃ‰TODO: Match por paymentHash (MAIS SEGURO)
      if (order.paymentHash != null && order.paymentHash!.isNotEmpty) {
        // Verificar se este hash nÃ£o foi usado por outra ordem
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
        // Ordem SEM paymentHash - NÃƒO fazer fallback por valor
        // Isso evita falsos positivos onde mÃºltiplas ordens sÃ£o marcadas com o mesmo pagamento
      }
    }
    
    return reconciled;
  }

  /// Reconciliar ordens na inicializaÃ§Ã£o - DESATIVADO
  /// NOTA: Esta funÃ§Ã£o foi desativada pois causava falsos positivos de "payment_received"
  /// quando o usuÃ¡rio tinha saldo de outras transaÃ§Ãµes na carteira.
  /// A reconciliaÃ§Ã£o correta deve ser feita APENAS via evento do SDK Breez (PaymentSucceeded)
  /// que traz o paymentHash especÃ­fico da invoice.
  Future<void> reconcileOnStartup(int currentBalanceSats) async {
    // NÃ£o faz nada - reconciliaÃ§Ã£o automÃ¡tica por saldo Ã© muito propensa a erros
    return;
  }

  /// Callback chamado quando o Breez SDK detecta um pagamento recebido
  /// Este Ã© o mÃ©todo SEGURO de atualizaÃ§Ã£o - baseado no evento real do SDK
  /// IMPORTANTE: Usa APENAS paymentHash para identificaÃ§Ã£o PRECISA
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
    
    
    // ÃšNICO MÃ‰TODO: Match EXATO por paymentHash (mais seguro)
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
    
    // NÃƒO fazer fallback por valor - isso causa falsos positivos
    // Se o paymentHash nÃ£o corresponder, o pagamento nÃ£o Ã© para nenhuma ordem nossa
  }

  /// Atualizar o paymentHash de uma ordem (chamado quando a invoice Ã© gerada)
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
    
    notifyListeners();
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

  /// Buscar ordens pendentes de todos os usuÃ¡rios (para providers verem)
  Future<List<Order>> fetchPendingOrdersFromNostr() async {
    try {
      final orders = await _nostrOrderService.fetchPendingOrders();
      return orders;
    } catch (e) {
      return [];
    }
  }

  /// Buscar histÃ³rico de ordens do usuÃ¡rio atual do Nostr
  Future<void> syncOrdersFromNostr() async {
    // Tentar pegar a pubkey do NostrService se nÃ£o temos
    if (_currentUserPubkey == null || _currentUserPubkey!.isEmpty) {
      _currentUserPubkey = _nostrService.publicKey;
    }
    
    if (_currentUserPubkey == null || _currentUserPubkey!.isEmpty) {
      return;
    }
    
    try {
      final nostrOrders = await _nostrOrderService.fetchUserOrders(_currentUserPubkey!);
      
      // Mesclar ordens do Nostr com locais
      int added = 0;
      int updated = 0;
      int skipped = 0;
      for (var nostrOrder in nostrOrders) {
        // VALIDAÃ‡ÃƒO: Ignorar ordens com amount=0 vindas do Nostr
        // (jÃ¡ sÃ£o filtradas em eventToOrder, mas double-check aqui)
        if (nostrOrder.amount <= 0) {
          skipped++;
          continue;
        }
        
        // SEGURANÃ‡A CRÃTICA: Verificar se a ordem realmente pertence ao usuÃ¡rio atual
        // Ordem pertence se: userPubkey == atual OU providerId == atual (aceitou como Bro)
        final isMyOrder = nostrOrder.userPubkey == _currentUserPubkey;
        final isMyProviderOrder = nostrOrder.providerId == _currentUserPubkey;
        
        if (!isMyOrder && !isMyProviderOrder) {
          skipped++;
          continue;
        }
        
        final existingIndex = _orders.indexWhere((o) => o.id == nostrOrder.id);
        if (existingIndex == -1) {
          // Ordem nÃ£o existe localmente, adicionar
          // CORREÃ‡ÃƒO: Adicionar TODAS as ordens do usuÃ¡rio incluindo completed para histÃ³rico!
          // SÃ³ ignoramos cancelled pois sÃ£o ordens canceladas pelo usuÃ¡rio
          if (nostrOrder.status != 'cancelled') {
            _orders.add(nostrOrder);
            added++;
          }
        } else {
          // Ordem jÃ¡ existe, mesclar dados preservando os locais que nÃ£o sÃ£o 0
          final existing = _orders[existingIndex];
          
          // REGRA CRÃTICA: Apenas status FINAIS nÃ£o podem reverter
          // accepted e awaiting_confirmation podem evoluir para completed
          final protectedStatuses = ['cancelled', 'completed', 'liquidated', 'disputed'];
          if (protectedStatuses.contains(existing.status)) {
            continue;
          }
          
          // Se Nostr tem status mais recente, atualizar apenas o status
          // MAS manter amount/btcAmount/billCode locais se Nostr tem 0
          if (_isStatusMoreRecent(nostrOrder.status, existing.status) || 
              existing.amount == 0 && nostrOrder.amount > 0) {
            
            // NOTA: O bloqueio de "completed" indevido Ã© feito no NostrOrderService._applyStatusUpdate()
            // que verifica se o evento foi publicado pelo PROVEDOR ou pelo PRÃ“PRIO USUÃRIO.
            // Aqui apenas aplicamos o status que jÃ¡ foi filtrado pelo NostrOrderService.
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
      
      // NOVO: Buscar atualizaÃ§Ãµes de status (aceites e comprovantes de Bros)
      final orderIds = _orders.map((o) => o.id).toList();
      final orderUpdates = await _nostrOrderService.fetchOrderUpdatesForUser(
        _currentUserPubkey!,
        orderIds: orderIds,
      );
      
      int statusUpdated = 0;
      for (final entry in orderUpdates.entries) {
        final orderId = entry.key;
        final update = entry.value;
        
        final existingIndex = _orders.indexWhere((o) => o.id == orderId);
        if (existingIndex != -1) {
          final existing = _orders[existingIndex];
          final newStatus = update['status'] as String;
          final newProviderId = update['providerId'] as String?;
          
          // SEMPRE atualizar providerId se vier do Nostr e for diferente
          // Isso corrige ordens com providerId errado ou null
          bool needsUpdate = false;
          if (newProviderId != null && newProviderId != existing.providerId) {
            needsUpdate = true;
          }
          
          // NOTA: O bloqueio de "completed" indevido Ã© feito no NostrOrderService._applyStatusUpdate()
          // que verifica se o evento foi publicado pelo PROVEDOR ou pelo PRÃ“PRIO USUÃRIO.
          // Aqui apenas aplicamos o status que jÃ¡ foi processado.
          String statusToUse = newStatus;
          
          // Verificar se o novo status Ã© mais avanÃ§ado
          if (_isStatusMoreRecent(statusToUse, existing.status)) {
            needsUpdate = true;
          }
          
          if (needsUpdate) {
            _orders[existingIndex] = existing.copyWith(
              status: _isStatusMoreRecent(statusToUse, existing.status) ? statusToUse : existing.status,
              providerId: newProviderId ?? existing.providerId,
              // Se for comprovante, salvar no metadata (incluindo providerInvoice)
              metadata: (update['proofImage'] != null || update['providerInvoice'] != null) ? {
                ...?existing.metadata,
                if (update['proofImage'] != null) 'proofImage': update['proofImage'],
                if (update['providerInvoice'] != null) 'providerInvoice': update['providerInvoice'],
                'proofReceivedAt': DateTime.now().toIso8601String(),
              } : existing.metadata,
            );
            statusUpdated++;
          }
        }
      }
      
      if (statusUpdated > 0) {
      }
      
      // Ordenar por data (mais recente primeiro)
      _orders.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      
      // SEGURANÃ‡A CRÃTICA: Salvar apenas ordens do usuÃ¡rio atual!
      // Isso evita que ordens de outros usuÃ¡rios sejam persistidas localmente
      await _saveOnlyUserOrders();
      notifyListeners();
      
    } catch (e) {
    }
  }

  /// Verificar se um status Ã© mais recente que outro
  bool _isStatusMoreRecent(String newStatus, String currentStatus) {
    // CORREÃ‡ÃƒO: Apenas status FINAIS nÃ£o podem regredir
    // accepted e awaiting_confirmation PODEM evoluir para completed/liquidated
    const finalStatuses = ['cancelled', 'completed', 'liquidated', 'disputed'];
    if (finalStatuses.contains(currentStatus)) {
      // Status final - sÃ³ pode virar disputed
      if (currentStatus != 'disputed' && newStatus == 'disputed') {
        return true;
      }
      return false;
    }
    
    // Ordem de progressÃ£o de status:
    // draft -> pending -> payment_received -> accepted -> processing -> awaiting_confirmation -> completed/liquidated
    const statusOrder = [
      'draft',
      'pending', 
      'payment_received', 
      'accepted', 
      'processing',
      'awaiting_confirmation',  // Bro enviou comprovante, aguardando validaÃ§Ã£o do usuÃ¡rio
      'completed',
      'liquidated',  // Auto-liquidaÃ§Ã£o apÃ³s 24h
    ];
    final newIndex = statusOrder.indexOf(newStatus);
    final currentIndex = statusOrder.indexOf(currentStatus);
    
    // Se algum status nÃ£o estÃ¡ na lista, considerar como nÃ£o sendo mais recente
    if (newIndex == -1 || currentIndex == -1) return false;
    
    return newIndex > currentIndex;
  }

  /// Republicar ordens locais que nÃ£o tÃªm eventId no Nostr
  /// Ãštil para migrar ordens criadas antes da integraÃ§Ã£o Nostr
  /// SEGURANÃ‡A: SÃ³ republica ordens que PERTENCEM ao usuÃ¡rio atual!
  Future<int> republishLocalOrdersToNostr() async {
    final privateKey = _nostrService.privateKey;
    if (privateKey == null) {
      return 0;
    }
    
    if (_currentUserPubkey == null || _currentUserPubkey!.isEmpty) {
      return 0;
    }
    
    int republished = 0;
    
    for (var order in _orders) {
      // SEGURANÃ‡A CRÃTICA: SÃ³ republicar ordens que PERTENCEM ao usuÃ¡rio atual!
      // Nunca republicar ordens de outros usuÃ¡rios (isso causaria duplicaÃ§Ã£o com pubkey errado)
      if (order.userPubkey != _currentUserPubkey) {
        continue;
      }
      
      // SÃ³ republicar ordens que nÃ£o tÃªm eventId
      if (order.eventId == null || order.eventId!.isEmpty) {
        try {
          final eventId = await _nostrOrderService.publishOrder(
            order: order,
            privateKey: privateKey,
          );
          
          if (eventId != null) {
            // Atualizar ordem com eventId
            final index = _orders.indexWhere((o) => o.id == order.id);
            if (index != -1) {
              _orders[index] = order.copyWith(
                eventId: eventId,
                userPubkey: _currentUserPubkey,
              );
              republished++;
            }
          }
        } catch (e) {
        }
      }
    }
    
    if (republished > 0) {
      await _saveOrders();
      notifyListeners();
    }
    
    return republished;
  }

  // ==================== AUTO RECONCILIATION ====================

  /// ReconciliaÃ§Ã£o automÃ¡tica de ordens baseada em pagamentos do Breez SDK
  /// 
  /// Esta funÃ§Ã£o analisa TODOS os pagamentos (recebidos e enviados) e atualiza
  /// os status das ordens automaticamente:
  /// 
  /// 1. Pagamentos RECEBIDOS â†’ Atualiza ordens 'pending' para 'payment_received'
  ///    (usado quando o Bro paga via Lightning - menos comum no fluxo atual)
  /// 
  /// 2. Pagamentos ENVIADOS â†’ Atualiza ordens 'awaiting_confirmation' para 'completed'
  ///    (quando o usuÃ¡rio liberou BTC para o Bro apÃ³s confirmar prova de pagamento)
  /// 
  /// A identificaÃ§Ã£o Ã© feita por:
  /// - paymentHash (se disponÃ­vel) - mais preciso
  /// - Valor aproximado + timestamp (fallback)
  Future<Map<String, int>> autoReconcileWithBreezPayments(List<Map<String, dynamic>> breezPayments) async {
    
    int pendingReconciled = 0;
    int completedReconciled = 0;
    
    // Separar pagamentos por direÃ§Ã£o
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
    // DESATIVADO: Esta seÃ§Ã£o auto-completava ordens sem confirmaÃ§Ã£o do usuÃ¡rio.
    // Matchava por valor aproximado (5% tolerÃ¢ncia), o que causava falsos positivos.
    // A confirmaÃ§Ã£o de pagamento DEVE ser feita MANUALMENTE pelo usuÃ¡rio.
    
    
    if (pendingReconciled > 0 || completedReconciled > 0) {
      await _saveOrders();
      notifyListeners();
    }
    
    return {
      'pendingReconciled': pendingReconciled,
      'completedReconciled': completedReconciled,
    };
  }

  /// Callback chamado quando o Breez SDK detecta um pagamento ENVIADO
  /// DESATIVADO: NÃ£o deve auto-completar ordens. UsuÃ¡rio deve confirmar manualmente.
  Future<void> onPaymentSent({
    required String paymentId,
    required int amountSats,
    String? paymentHash,
  }) async {
    return; // DESATIVADO - nÃ£o auto-completar
    
    // CORREÃ‡ÃƒO CRÃTICA: SÃ³ buscar ordens que EU CRIEI
    final currentUserPubkey = _nostrService.publicKey;
    final awaitingOrders = _orders.where((o) => 
      (o.status == 'awaiting_confirmation' || o.status == 'accepted') &&
      o.userPubkey == currentUserPubkey // IMPORTANTE: SÃ³ minhas ordens!
    ).toList();
    
    if (awaitingOrders.isEmpty) {
      return;
    }
    
    
    // Procurar ordem com valor correspondente
    for (final order in awaitingOrders) {
      final expectedSats = (order.btcAmount * 100000000).toInt();
      
      // TolerÃ¢ncia de 5% para taxas
      final tolerance = (expectedSats * 0.05).toInt();
      final diff = (amountSats - expectedSats).abs();
      
      if (diff <= tolerance) {
        
        // IMPORTANTE: Enviar taxa da plataforma (2%) ANTES de marcar como completed
        final feeSuccess = await PlatformFeeService.sendPlatformFee(
          orderId: order.id,
          totalSats: expectedSats,
        );
        if (!feeSuccess) {
        }
        
        await updateOrderStatus(
          orderId: order.id,
          status: 'completed',
          metadata: {
            ...?order.metadata,
            'completedAt': DateTime.now().toIso8601String(),
            'completedFrom': 'breez_sdk_payment_sent',
            'paymentAmount': amountSats,
            'paymentId': paymentId,
            'paymentHash': paymentHash,
            'platformFeeSent': feeSuccess,
          },
        );
        
        // Republicar no Nostr com status completed
        final updatedOrder = _orders.firstWhere((o) => o.id == order.id);
        await _publishOrderToNostr(updatedOrder);
        
        return;
      }
    }
    
  }

  /// RECONCILIAÃ‡ÃƒO FORÃ‡ADA - Analisa TODAS as ordens e TODOS os pagamentos
  /// Use quando ordens antigas nÃ£o estÃ£o sendo atualizadas automaticamente
  /// 
  /// Esta funÃ§Ã£o Ã© mais agressiva que autoReconcileWithBreezPayments:
  /// - Verifica TODAS as ordens nÃ£o-completed (incluindo pending antigas)
  /// - Usa match por valor com tolerÃ¢ncia maior (10%)
  /// - Cria lista de pagamentos usados para evitar duplicaÃ§Ã£o
  Future<Map<String, dynamic>> forceReconcileAllOrders(List<Map<String, dynamic>> breezPayments) async {
    
    int updated = 0;
    final usedPaymentIds = <String>{};
    final reconciliationLog = <Map<String, dynamic>>[];
    
    // Listar todos os pagamentos
    for (final p in breezPayments) {
      final amount = p['amount'];
      final status = p['status']?.toString() ?? '';
      final type = p['type']?.toString() ?? '';
      final id = p['id']?.toString() ?? '';
      final direction = p['direction']?.toString() ?? type;
    }
    
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
    
    
    // CORREÃ‡ÃƒO CRÃTICA: Para pagamentos ENVIADOS (que marcam como completed),
    // sÃ³ verificar ordens que EU CRIEI (sou o userPubkey)
    final currentUserPubkey = _nostrService.publicKey;
    
    // Buscar TODAS as ordens nÃ£o finalizadas
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
        // (no fluxo atual do Bro, isso Ã© menos comum)
        paymentsToCheck = receivedPayments;
        newStatus = 'payment_received';
      } else {
        // DESATIVADO: NÃ£o auto-completar ordens accepted/awaiting_confirmation
        // UsuÃ¡rio deve confirmar recebimento MANUALMENTE
        continue;
      }
      
      // Procurar pagamento correspondente
      bool found = false;
      for (final payment in paymentsToCheck) {
        final paymentId = payment['id']?.toString() ?? '';
        
        // Pular se jÃ¡ foi usado
        if (usedPaymentIds.contains(paymentId)) continue;
        
        final paymentAmount = (payment['amount'] is int) 
            ? payment['amount'] as int 
            : int.tryParse(payment['amount']?.toString() ?? '0') ?? 0;
        
        final status = payment['status']?.toString() ?? '';
        
        // SÃ³ considerar pagamentos completados
        if (!status.toLowerCase().contains('completed') && 
            !status.toLowerCase().contains('complete') &&
            !status.toLowerCase().contains('succeeded')) {
          continue;
        }
        
        // TolerÃ¢ncia de 10% para match (mais agressivo)
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
      notifyListeners();
    }
    
    return {
      'updated': updated,
      'log': reconciliationLog,
    };
  }

  /// ForÃ§ar status de uma ordem especÃ­fica para 'completed'
  /// Use quando vocÃª tem certeza que a ordem foi paga mas o sistema nÃ£o detectou
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
    
    notifyListeners();
    return true;
  }
}
