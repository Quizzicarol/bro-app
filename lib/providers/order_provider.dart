?import 'package:flutter/material.dart';
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

  List<Order> _orders = [];  // APENAS ordens do usuário atual
  List<Order> _availableOrdersForProvider = [];  // Ordens disponíveis para Bros (NUNCA salvas)
  Order? _currentOrder;
  bool _isLoading = false;
  String? _error;
  bool _isInitialized = false;
  String? _currentUserPubkey;
  bool _isProviderMode = false;  // Modo provedor ativo (para UI, não para filtro de ordens)

  // Prefixo para salvar no SharedPreferences (será combinado com pubkey)
  static const String _ordersKeyPrefix = 'orders_';

  // SEGURAN�?A CRÍTICA: Filtrar ordens por usuário - NUNCA mostrar ordens de outros!
  // Esta lista é usada por TODOS os getters (orders, pendingOrders, etc)
  List<Order> get _filteredOrders {
    // SEGURAN�?A ABSOLUTA: Sem pubkey = sem ordens
    if (_currentUserPubkey == null || _currentUserPubkey!.isEmpty) {
      return [];
    }
    
    // SEMPRE filtrar por usuário - mesmo no modo provedor!
    // No modo provedor, mostramos ordens disponíveis em tela separada, não aqui
    final filtered = _orders.where((o) {
      // REGRA 1: Ordens SEM userPubkey são rejeitadas (dados corrompidos/antigos)
      if (o.userPubkey == null || o.userPubkey!.isEmpty) {
        return false;
      }
      
      // REGRA 2: Ordem criada por este usuário
      final isOwner = o.userPubkey == _currentUserPubkey;
      
      // REGRA 3: Ordem que este usuário aceitou como Bro (providerId)
      final isMyProviderOrder = o.providerId == _currentUserPubkey;
      
      if (!isOwner && !isMyProviderOrder) {
      }
      
      return isOwner || isMyProviderOrder;
    }).toList();
    
    // Log apenas quando há filtros aplicados
    if (_orders.length != filtered.length) {
    }
    return filtered;
  }

  // Getters - USAM _filteredOrders para SEGURAN�?A
  // NOTA: orders N�fO inclui draft (ordens não pagas não aparecem na lista do usuário)
  List<Order> get orders => _filteredOrders.where((o) => o.status != 'draft').toList();
  List<Order> get pendingOrders => _filteredOrders.where((o) => o.status == 'pending' || o.status == 'payment_received').toList();
  List<Order> get activeOrders => _filteredOrders.where((o) => ['payment_received', 'confirmed', 'accepted', 'processing'].contains(o.status)).toList();
  List<Order> get completedOrders => _filteredOrders.where((o) => o.status == 'completed').toList();
  bool get isProviderMode => _isProviderMode;
  Order? get currentOrder => _currentOrder;
  bool get isLoading => _isLoading;
  String? get error => _error;
  
  /// Getter público para a pubkey do usuário atual (usado para verificações externas)
  String? get currentUserPubkey => _currentUserPubkey;
  
  /// SEGURAN�?A: Getter para ordens que EU CRIEI (modo usuário)
  /// Retorna APENAS ordens onde userPubkey == currentUserPubkey
  /// Usado na tela "Minhas Trocas" do modo usuário
  List<Order> get myCreatedOrders {
    // Se não temos pubkey, tentar buscar do NostrService
    if (_currentUserPubkey == null || _currentUserPubkey!.isEmpty) {
      final fallbackPubkey = _nostrService.publicKey;
      if (fallbackPubkey != null && fallbackPubkey.isNotEmpty) {
        _currentUserPubkey = fallbackPubkey;
      } else {
        return [];
      }
    }
    
    final result = _orders.where((o) {
      // Apenas ordens que EU criei (não ordens aceitas como provedor)
      return o.userPubkey == _currentUserPubkey && o.status != 'draft';
    }).toList();
    
    return result;
  }
  
  /// SEGURAN�?A: Getter para ordens que EU ACEITEI como Bro (modo provedor)
  /// Retorna APENAS ordens onde providerId == currentUserPubkey
  /// Usado na tela "Minhas Ordens" do modo provedor
  List<Order> get myAcceptedOrders {
    // Se não temos pubkey, tentar buscar do NostrService
    if (_currentUserPubkey == null || _currentUserPubkey!.isEmpty) {
      final fallbackPubkey = _nostrService.publicKey;
      if (fallbackPubkey != null && fallbackPubkey.isNotEmpty) {
        _currentUserPubkey = fallbackPubkey;
      } else {
        return [];
      }
    }
    
    // DEBUG CRÍTICO: Listar todas as ordens e seus providerIds
    for (final o in _orders) {
    }
    
    final result = _orders.where((o) {
      // Apenas ordens que EU aceitei como provedor (não ordens que criei)
      return o.providerId == _currentUserPubkey;
    }).toList();
    
    return result;
  }

  /// CRÍTICO: Método para sair do modo provedor e limpar ordens de outros
  /// Deve ser chamado quando o usuário sai da tela de modo Bro
  void exitProviderMode() {
    _isProviderMode = false;
    
    // Limpar lista de ordens disponíveis para provedor (NUNCA eram salvas)
    _availableOrdersForProvider = [];
    
    // IMPORTANTE: N�fO remover ordens que este usuário aceitou como provedor!
    // Mesmo que userPubkey seja diferente, se providerId == _currentUserPubkey,
    // essa ordem deve ser mantida para aparecer em "Minhas Ordens" do provedor
    final before = _orders.length;
    _orders = _orders.where((o) {
      // Sempre manter ordens que este usuário criou
      final isOwner = o.userPubkey == _currentUserPubkey;
      // SEMPRE manter ordens que este usuário aceitou como provedor
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
  
  /// Getter para ordens disponíveis para Bros (usadas na tela de provedor)
  /// Esta lista NUNCA é salva localmente!
  /// IMPORTANTE: Retorna uma C�"PIA para evitar ConcurrentModificationException
  /// quando o timer de polling modifica a lista durante iteração na UI
  List<Order> get availableOrdersForProvider => List<Order>.from(_availableOrdersForProvider);

  /// Calcula o total de sats comprometidos com ordens pendentes/ativas (modo cliente)
  /// Este valor deve ser SUBTRAÍDO do saldo total para calcular saldo disponível para garantia
  /// 
  /// IMPORTANTE: Só conta ordens que ainda N�fO foram pagas via Lightning!
  /// - 'draft': Invoice ainda não pago - COMPROMETIDO
  /// - 'pending': Invoice pago, aguardando Bro aceitar - JÁ SAIU DA CARTEIRA
  /// - 'payment_received': Invoice pago, aguardando Bro - JÁ SAIU DA CARTEIRA
  /// - 'accepted', 'awaiting_confirmation', 'completed': JÁ PAGO
  /// 
  /// Na prática, APENAS ordens 'draft' deveriam ser contadas, mas removemos
  /// esse status ao refatorar o fluxo (invoice é pago antes de criar ordem)
  int get committedSats {
    // CORRIGIDO: Não contar nenhuma ordem como "comprometida" porque:
    // 1. 'draft' foi removido - invoice é pago ANTES de criar ordem
    // 2. Todas as outras já tiveram a invoice paga (sats não estão na carteira)
    //
    // Se o usuário tem uma ordem 'pending', os sats JÁ FORAM para o escrow
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
    
    // RETORNAR 0: Nenhum sat está "comprometido" na carteira
    // Os sats já saíram quando o usuário pagou a invoice Lightning
    return 0;
  }

  // Chave única para salvar ordens deste usuário
  String get _ordersKey => '${_ordersKeyPrefix}${_currentUserPubkey ?? 'anonymous'}';

  // Inicializar com a pubkey do usuário
  Future<void> initialize({String? userPubkey}) async {
    // Se passou uma pubkey, usar ela
    if (userPubkey != null && userPubkey.isNotEmpty) {
      _currentUserPubkey = userPubkey;
    } else {
      // Tentar pegar do NostrService
      _currentUserPubkey = _nostrService.publicKey;
    }
    
    
    // �Y�� SEGURAN�?A: Limpar storage 'orders_anonymous' que pode conter ordens vazadas
    await _cleanupAnonymousStorage();
    
    // Resetar estado - CRÍTICO: Limpar AMBAS as listas de ordens!
    _orders = [];
    _availableOrdersForProvider = [];
    _isInitialized = false;
    
    // SEMPRE carregar ordens locais primeiro (para preservar status atualizados)
    // Antes estava só em testMode, mas isso perdia status como payment_received
    // NOTA: Só carrega se temos pubkey válida (prevenção de vazamento)
    await _loadSavedOrders();
    
    // �Y�� LIMPEZA: Remover ordens DRAFT antigas (não pagas em 1 hora)
    await _cleanupOldDraftOrders();
    
    // CORRE�?�fO AUTOMÁTICA: Identificar ordens marcadas incorretamente como pagas
    // Se temos múltiplas ordens "payment_received" com valores pequenos e criadas quase ao mesmo tempo,
    // é provável que a reconciliação automática tenha marcado incorretamente.
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
  
  /// �Y�� SEGURAN�?A: Limpar storage 'orders_anonymous' que pode conter ordens de usuários anteriores
  /// Também limpa qualquer cache global que possa ter ordens vazadas
  Future<void> _cleanupAnonymousStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // 1. Remover ordens do usuário 'anonymous'
      if (prefs.containsKey('orders_anonymous')) {
        await prefs.remove('orders_anonymous');
      }
      
      // 2. Remover cache global de ordens (pode conter ordens de outros usuários)
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
  
  /// �Y�� Remove ordens draft que não foram pagas em 1 hora
  /// Isso evita acúmulo de ordens "fantasma" que o usuário abandonou
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

  // Recarregar ordens para novo usuário (após login)
  Future<void> loadOrdersForUser(String userPubkey) async {
    
    // �Y"� SEGURAN�?A CRÍTICA: Limpar TUDO antes de carregar novo usuário
    // Isso previne que ordens de usuário anterior vazem para o novo
    await _cleanupAnonymousStorage();
    
    // �s�️ N�fO limpar cache de collateral aqui!
    // O CollateralProvider gerencia isso próprio e verifica se usuário mudou
    // Limpar aqui causa problema de tier "caindo" durante a sessão
    
    _currentUserPubkey = userPubkey;
    _orders = [];
    _availableOrdersForProvider = [];  // Limpar também lista de disponíveis
    _isInitialized = false;
    _isProviderMode = false;  // Reset modo provedor ao trocar de usuário
    
    // Notificar IMEDIATAMENTE que ordens foram limpas
    // Isso garante que committedSats retorne 0 antes de carregar novas ordens
    notifyListeners();
    
    // Carregar ordens locais primeiro (SEMPRE, para preservar status atualizados)
    await _loadSavedOrders();
    
    // SEGURAN�?A: Filtrar ordens que não pertencem a este usuário
    // (podem ter vazado de sincronizações anteriores)
    // IMPORTANTE: Manter ordens que este usuário CRIOU ou ACEITOU como Bro!
    final originalCount = _orders.length;
    _orders = _orders.where((order) {
      // Manter ordens deste usuário (criador)
      if (order.userPubkey == userPubkey) return true;
      // Manter ordens que este usuário aceitou como Bro
      if (order.providerId == userPubkey) return true;
      // Manter ordens sem pubkey definido (legado, mas marcar como deste usuário)
      if (order.userPubkey == null || order.userPubkey!.isEmpty) {
        return false; // Remover ordens sem dono identificado
      }
      // Remover ordens de outros usuários
      return false;
    }).toList();
    
    if (_orders.length < originalCount) {
      await _saveOrders(); // Salvar lista limpa
    }
    
    
    _isInitialized = true;
    notifyListeners();
    
    // Sincronizar do Nostr IMEDIATAMENTE (não em background)
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
        // Primeiro republicar ordens locais antigas que não estão no Nostr
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

  // Limpar ordens ao fazer logout - SEGURAN�?A CRÍTICA
  void clearOrders() {
    _orders = [];
    _availableOrdersForProvider = [];  // Também limpar lista de disponíveis
    _currentOrder = null;
    _currentUserPubkey = null;
    _isProviderMode = false;  // Reset modo provedor
    _isInitialized = false;
    notifyListeners();
  }

  // Carregar ordens do SharedPreferences
  Future<void> _loadSavedOrders() async {
    // SEGURAN�?A CRÍTICA: Não carregar ordens de 'orders_anonymous'
    // Isso previne vazamento de ordens de outros usuários para contas novas
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
        
        
        // SEGURAN�?A CRÍTICA: Filtrar ordens de OUTROS usuários que vazaram para este storage
        // Isso pode acontecer se o modo provedor salvou ordens incorretamente
        final beforeFilter = _orders.length;
        _orders = _orders.where((o) {
          // REGRA ESTRITA: Ordem DEVE ter userPubkey igual ao usuário atual
          // Não aceitar mais ordens sem pubkey (eram causando vazamento)
          final isOwner = o.userPubkey == _currentUserPubkey;
          // Ordem que este usuário aceitou como provedor
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
        
        // CORRE�?�fO: Remover providerId falso (provider_test_001) de ordens
        // Este valor foi setado erroneamente por migração antiga
        // O providerId correto será recuperado do Nostr durante o sync
        bool needsMigration = false;
        for (int i = 0; i < _orders.length; i++) {
          final order = _orders[i];
          
          // Se ordem tem o providerId de teste antigo, REMOVER (será corrigido pelo Nostr)
          if (order.providerId == 'provider_test_001') {
            // Setar providerId como null para que seja recuperado do Nostr
            _orders[i] = order.copyWith(providerId: null);
            needsMigration = true;
          }
        }
        
        // Se houve migração, salvar
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
  /// pela reconciliação automática antiga (baseada apenas em saldo).
  /// 
  /// Corrigir ordens marcadas incorretamente como "payment_received"
  /// 
  /// REGRA SIMPLES: Se a ordem tem status "payment_received" mas N�fO tem paymentHash,
  /// é um falso positivo e deve voltar para "pending".
  /// 
  /// Ordens COM paymentHash foram verificadas pelo SDK Breez e são válidas.
  Future<void> _fixIncorrectlyPaidOrders() async {
    // Buscar ordens com payment_received
    final paidOrders = _orders.where((o) => o.status == 'payment_received').toList();
    
    if (paidOrders.isEmpty) {
      return;
    }
    
    
    bool needsCorrection = false;
    
    for (final order in paidOrders) {
      // Se N�fO tem paymentHash, é falso positivo!
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
  // Salvar ordens no SharedPreferences (SEMPRE salva, não só em testMode)
  // SEGURAN�?A: Agora só salva ordens do usuário atual (igual _saveOnlyUserOrders)
  Future<void> _saveOrders() async {
    // SEGURAN�?A CRÍTICA: Não salvar se não temos pubkey definida
    // Isso previne salvar ordens de outros usuários no storage 'orders_anonymous'
    if (_currentUserPubkey == null || _currentUserPubkey!.isEmpty) {
      return;
    }
    
    try {
      // SEGURAN�?A: Filtrar apenas ordens do usuário atual antes de salvar
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
  
  /// SEGURAN�?A: Salvar APENAS ordens do usuário atual no SharedPreferences
  /// Ordens de outros usuários (visualizadas no modo provedor) ficam apenas em memória
  Future<void> _saveOnlyUserOrders() async {
    // SEGURAN�?A CRÍTICA: Não salvar se não temos pubkey definida
    // Isso previne que ordens de outros usuários sejam salvas em 'orders_anonymous'
    if (_currentUserPubkey == null || _currentUserPubkey!.isEmpty) {
      return;
    }
    
    try {
      // Filtrar apenas ordens do usuário atual
      final userOrders = _orders.where((o) => 
        o.userPubkey == _currentUserPubkey || 
        o.providerId == _currentUserPubkey  // Ordens que este usuário aceitou como provedor
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
  /// SEGURAN�?A: Apenas o dono da ordem pode cancelá-la!
  Future<bool> cancelOrder(String orderId) async {
    final index = _orders.indexWhere((o) => o.id == orderId);
    if (index == -1) {
      return false;
    }
    
    final order = _orders[index];
    
    // VERIFICA�?�fO DE SEGURAN�?A: Apenas o dono pode cancelar
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

  /// Verificar se um pagamento específico corresponde a uma ordem pendente
  /// Usa match por valor quando paymentHash não está disponível (ordens antigas)
  /// IMPORTANTE: Este método deve ser chamado manualmente pelo usuário para evitar falsos positivos
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
    
    // Fallback: verificar por valor (menos seguro, mas útil para ordens antigas)
    // Tolerar diferença de até 5 sats (taxas de rede podem variar ligeiramente)
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

  // Criar ordem LOCAL (N�fO publica no Nostr!)
  // A ordem só será publicada no Nostr AP�"S pagamento confirmado
  // Isso evita que Bros vejam ordens sem depósito
  Future<Order?> createOrder({
    required String billType,
    required String billCode,
    required double amount,
    required double btcAmount,
    required double btcPrice,
  }) async {
    // VALIDA�?�fO CRÍTICA: Nunca criar ordem com amount = 0
    if (amount <= 0) {
      _error = 'Valor da ordem inválido';
      notifyListeners();
      return null;
    }
    
    if (btcAmount <= 0) {
      _error = 'Valor em BTC inválido';
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
      
      // �Y"� SIMPLIFICADO: Status 'pending' = Aguardando Bro
      // A ordem já está paga (invoice/endereço já foi criado)
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
        status: 'pending',  // �o. Direto para pending = Aguardando Bro
        createdAt: DateTime.now(),
      );
      
      // LOG DE VALIDA�?�fO
      
      _orders.insert(0, order);
      _currentOrder = order;
      
      // Salvar localmente - USAR _saveOrders() para garantir filtro de segurança!
      await _saveOrders();
      
      notifyListeners();
      
      // �Y"� PUBLICAR NO NOSTR IMEDIATAMENTE
      // A ordem já está com pagamento sendo processado
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
  
  /// CRÍTICO: Publicar ordem no Nostr SOMENTE AP�"S pagamento confirmado
  /// Este método transforma a ordem de 'draft' para 'pending' e publica no Nostr
  /// para que os Bros possam vê-la e aceitar
  Future<bool> publishOrderAfterPayment(String orderId) async {
    
    final index = _orders.indexWhere((o) => o.id == orderId);
    if (index == -1) {
      return false;
    }
    
    final order = _orders[index];
    
    // Validar que ordem está em draft (não foi publicada ainda)
    if (order.status != 'draft') {
      // Se já foi publicada, apenas retornar sucesso
      if (order.status == 'pending' || order.status == 'payment_received') {
        return true;
      }
      return false;
    }
    
    try {
      // Atualizar status para 'pending' (agora visível para Bros)
      _orders[index] = order.copyWith(status: 'pending');
      await _saveOrders();
      notifyListeners();
      
      // AGORA SIM publicar no Nostr
      await _publishOrderToNostr(_orders[index]);
      
      // Pequeno delay para propagação
      await Future.delayed(const Duration(milliseconds: 500));
      
      return true;
    } catch (e) {
      return false;
    }
  }

  // Listar ordens (para usuário normal ou provedor)
  Future<void> fetchOrders({String? status, bool forProvider = false}) async {
    _isLoading = true;
    
    // SEGURAN�?A: Definir modo provedor ANTES de sincronizar
    _isProviderMode = forProvider;
    
    // Se SAINDO do modo provedor (ou em modo usuário), limpar ordens de outros usuários
    if (!forProvider && _orders.isNotEmpty) {
      final before = _orders.length;
      _orders = _orders.where((o) {
        // REGRA ESTRITA: Apenas ordens deste usuário
        final isOwner = o.userPubkey == _currentUserPubkey;
        // Ou ordens que este usuário aceitou como provedor
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
        // MODO PROVEDOR: Buscar TODAS as ordens pendentes de TODOS os usuários
        // Timeout de 30s para sync provedor
        await syncAllPendingOrdersFromNostr().timeout(
          const Duration(seconds: 30),
          onTimeout: () {
          },
        );
      } else {
        // MODO USUÁRIO: Buscar apenas ordens do próprio usuário
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
  /// SEGURAN�?A: Ordens de outros usuários vão para _availableOrdersForProvider
  /// e NUNCA são adicionadas à lista principal _orders!
  Future<void> syncAllPendingOrdersFromNostr() async {
    try {
      
      // Helper para busca segura (captura exceções e retorna lista vazia)
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
      
      
      // SEGURAN�?A: Separar ordens em duas listas:
      // 1. Ordens do usuário atual -> _orders
      // 2. Ordens de outros (disponíveis para aceitar) -> _availableOrdersForProvider
      
      _availableOrdersForProvider = []; // Limpar lista anterior
      final seenAvailableIds = <String>{}; // Para evitar duplicatas
      int addedToAvailable = 0;
      int updated = 0;
      
      for (var pendingOrder in allPendingOrders) {
        // Ignorar ordens com amount=0
        if (pendingOrder.amount <= 0) continue;
        
        // DEDUPLICA�?�fO: Ignorar se já vimos esta ordem
        if (seenAvailableIds.contains(pendingOrder.id)) {
          continue;
        }
        seenAvailableIds.add(pendingOrder.id);
        
        // Verificar se é ordem do usuário atual OU ordem que ele aceitou como provedor
        final isMyOrder = pendingOrder.userPubkey == _currentUserPubkey;
        final isMyProviderOrder = pendingOrder.providerId == _currentUserPubkey;
        
        // Se N�fO é minha ordem e N�fO é ordem que aceitei, verificar status
        // Ordens de outros com status final não interessam
        if (!isMyOrder && !isMyProviderOrder) {
          if (pendingOrder.status == 'cancelled' || pendingOrder.status == 'completed') continue;
        }
        
        if (isMyOrder || isMyProviderOrder) {
          // Ordem do usuário OU ordem aceita como provedor: atualizar na lista _orders
          final existingIndex = _orders.indexWhere((o) => o.id == pendingOrder.id);
          if (existingIndex == -1) {
            // SEGURAN�?A CRÍTICA: Só adicionar se realmente é minha ordem ou aceitei como provedor
            // NUNCA adicionar ordem de outro usuário aqui!
            if (isMyOrder || (isMyProviderOrder && pendingOrder.providerId == _currentUserPubkey)) {
              _orders.add(pendingOrder);
            } else {
            }
          } else {
            final existing = _orders[existingIndex];
            // SEGURAN�?A: Verificar que ordem pertence ao usuário atual antes de atualizar
            final isOwnerExisting = existing.userPubkey == _currentUserPubkey;
            final isProviderExisting = existing.providerId == _currentUserPubkey;
            
            if (!isOwnerExisting && !isProviderExisting) {
              continue;
            }
            
            // CORRE�?�fO: Apenas status FINAIS devem ser protegidos
            // accepted e awaiting_confirmation podem evoluir para completed
            const protectedStatuses = ['cancelled', 'completed', 'liquidated', 'disputed'];
            if (protectedStatuses.contains(existing.status)) {
              continue;
            }
            
            // CORRE�?�fO: Sempre atualizar se status do Nostr é mais recente
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
          // Ordem de OUTRO usuário: adicionar apenas à lista de disponíveis
          // NUNCA adicionar à lista principal _orders!
          
          // CORRE�?�fO CRÍTICA: Verificar se essa ordem já existe em _orders com status avançado
          // (significa que EU já aceitei essa ordem, mas o evento Nostr ainda está como pending)
          final existingInOrders = _orders.cast<Order?>().firstWhere(
            (o) => o?.id == pendingOrder.id,
            orElse: () => null,
          );
          
          if (existingInOrders != null) {
            // Ordem já existe - N�fO adicionar à lista de disponíveis
            const protectedStatuses = ['accepted', 'awaiting_confirmation', 'completed', 'liquidated', 'cancelled', 'disputed'];
            if (protectedStatuses.contains(existingInOrders.status)) {
              continue;
            }
          }
          
          _availableOrdersForProvider.add(pendingOrder);
          addedToAvailable++;
        }
      }
      
      
      // Processar ordens do próprio usuário (já buscadas em paralelo)
      int addedFromUser = 0;
      int addedFromProviderHistory = 0;
      
      // 1. Processar ordens criadas pelo usuário
      for (var order in userOrders) {
        final existingIndex = _orders.indexWhere((o) => o.id == order.id);
        if (existingIndex == -1 && order.amount > 0) {
          _orders.add(order);
          addedFromUser++;
        }
      }
      
      // 2. CRÍTICO: Processar ordens onde este usuário é o PROVEDOR (histórico de ordens aceitas)
      // Estas ordens foram buscadas em paralelo acima
      
      for (var provOrder in providerOrders) {
        final existingIndex = _orders.indexWhere((o) => o.id == provOrder.id);
        if (existingIndex == -1 && provOrder.amount > 0) {
          // Nova ordem do histórico - adicionar
          // NOTA: O status agora já vem correto de fetchProviderOrders (que busca updates)
          // Só forçar "accepted" se vier como "pending" E não houver outro status mais avançado
          if (provOrder.status == 'pending') {
            // Se status ainda é pending, significa que não houve evento de update
            // Então esta é uma ordem aceita mas ainda não processada
            provOrder = provOrder.copyWith(status: 'accepted');
          }
          _orders.add(provOrder);
          addedFromProviderHistory++;
        } else if (existingIndex != -1) {
          // Ordem já existe - atualizar se status do Nostr é mais avançado
          final existing = _orders[existingIndex];
          
          // CORRE�?�fO: Status "accepted" N�fO deve ser protegido pois pode evoluir para completed
          // Apenas status finais devem ser protegidos
          const protectedStatuses = ['cancelled', 'completed', 'liquidated', 'disputed'];
          if (protectedStatuses.contains(existing.status)) {
            continue;
          }
          
          // Atualizar se o status do Nostr é mais avançado
          if (_isStatusMoreRecent(provOrder.status, existing.status)) {
            _orders[existingIndex] = existing.copyWith(
              status: provOrder.status,
              completedAt: provOrder.status == 'completed' ? DateTime.now() : existing.completedAt,
            );
          }
        }
      }
      
      
      // 3. CRÍTICO: Buscar updates de status para ordens que este provedor aceitou
      // Isso permite que o Bro veja quando o usuário confirmou (status=completed)
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
        
        // Também buscar ordens em awaiting_confirmation que podem ter sido atualizadas
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
            
            // Verificar se é completed e local é awaiting_confirmation
            if (newStatus == 'completed' && existing.status == 'awaiting_confirmation') {
              _orders[existingIndex] = existing.copyWith(
                status: 'completed',
                completedAt: DateTime.now(),
              );
              statusUpdated++;
            } else if (_isStatusMoreRecent(newStatus, existing.status)) {
              // Caso genérico
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
      
      // SEGURAN�?A: N�fO salvar ordens de outros usuários no storage local!
      // Apenas salvar as ordens que pertencem ao usuário atual
      // As ordens de outros ficam apenas em memória (para visualização do provedor)
      await _saveOnlyUserOrders();
      notifyListeners();
      
    } catch (e) {
    }
  }

  // Buscar ordem específica
  Future<Order?> fetchOrder(String orderId) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final orderData = await _apiService.getOrder(orderId);
      
      if (orderData != null) {
        final order = Order.fromJson(orderData);
        
        // SEGURAN�?A: Só inserir se for ordem do usuário atual ou modo provedor ativo
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
      
      // IMPORTANTE: Publicar atualização no Nostr para sincronização P2P
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
      // IMPORTANTE: Publicar no Nostr PRIMEIRO e só atualizar localmente se der certo
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
          return false; // CRÍTICO: Retornar false se Nostr falhar
        }
      } else {
        _error = 'Chave privada não disponível';
        _isLoading = false;
        notifyListeners();
        return false;
      }
      
      // Só atualizar localmente AP�"S sucesso no Nostr
      final index = _orders.indexWhere((o) => o.id == orderId);
      if (index != -1) {
        // Preservar metadata existente se não for passado novo
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

  /// Provedor aceita uma ordem - publica aceitação no Nostr e atualiza localmente
  Future<bool> acceptOrderAsProvider(String orderId) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      // Buscar a ordem localmente primeiro
      Order? order = getOrderById(orderId);
      
      // Se não encontrou localmente, buscar do Nostr
      if (order == null) {
        
        final orderData = await _nostrOrderService.fetchOrderFromNostr(orderId);
        if (orderData != null) {
          order = Order.fromJson(orderData);
          // Adicionar à lista local para referência futura
          _orders.add(order);
        }
      }
      
      if (order == null) {
        _error = 'Ordem não encontrada';
        _isLoading = false;
        notifyListeners();
        return false;
      }

      // Pegar chave privada do Nostr
      final privateKey = _nostrService.privateKey;
      if (privateKey == null) {
        _error = 'Chave privada não disponível';
        _isLoading = false;
        notifyListeners();
        return false;
      }

      final providerPubkey = _nostrService.publicKey;

      // Publicar aceitação no Nostr
      final success = await _nostrOrderService.acceptOrderOnNostr(
        order: order,
        providerPrivateKey: privateKey,
      );

      if (!success) {
        _error = 'Falha ao publicar aceitação no Nostr';
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
        
        // Salvar localmente (apenas ordens do usuário/provedor atual)
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
      
      // Se não encontrou localmente, buscar do Nostr
      if (order == null) {
        
        final orderData = await _nostrOrderService.fetchOrderFromNostr(orderId);
        if (orderData != null) {
          order = Order.fromJson(orderData);
          // Adicionar à lista local para referência futura
          _orders.add(order);
        }
      }
      
      if (order == null) {
        _error = 'Ordem não encontrada';
        _isLoading = false;
        notifyListeners();
        return false;
      }

      // Pegar chave privada do Nostr
      final privateKey = _nostrService.privateKey;
      if (privateKey == null) {
        _error = 'Chave privada não disponível';
        _isLoading = false;
        notifyListeners();
        return false;
      }


      // Publicar conclusão no Nostr
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
            // CORRIGIDO: Salvar imagem completa em base64, não truncar!
            'paymentProof': proof,
            'proofSentAt': DateTime.now().toIso8601String(),
            if (providerInvoice != null) 'providerInvoice': providerInvoice,
          },
        );
        
        // Salvar localmente usando _saveOrders() com filtro de segurança
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

  /// Auto-liquidação quando usuário não confirma em 24h
  /// Marca a ordem como 'liquidated' e notifica o usuário
  Future<bool> autoLiquidateOrder(String orderId, String proof) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      
      // Buscar a ordem localmente primeiro
      Order? order = getOrderById(orderId);
      
      if (order == null) {
        _error = 'Ordem não encontrada';
        _isLoading = false;
        notifyListeners();
        return false;
      }

      // Publicar no Nostr com status 'liquidated'
      final privateKey = _nostrService.privateKey;
      if (privateKey == null) {
        _error = 'Chave privada não disponível';
        _isLoading = false;
        notifyListeners();
        return false;
      }

      // Usar a função existente de updateOrderStatus com status 'liquidated'
      final success = await _nostrOrderService.updateOrderStatus(
        privateKey: privateKey,
        orderId: orderId,
        newStatus: 'liquidated',
        providerId: _currentUserPubkey,
      );

      if (!success) {
        _error = 'Falha ao publicar auto-liquidação no Nostr';
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
            'reason': 'Usuário não confirmou em 24h',
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

  // Converter preço
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
        orElse: () => throw Exception('Ordem não encontrada'),
      );
    } catch (e) {
      return null;
    }
  }

  // Get order (alias para fetchOrder)
  Future<Map<String, dynamic>?> getOrder(String orderId) async {
    try {
      
      // Primeiro, tentar encontrar na lista em memória (mais rápido)
      final localOrder = _orders.cast<Order?>().firstWhere(
        (o) => o?.id == orderId,
        orElse: () => null,
      );
      
      if (localOrder != null) {
        return localOrder.toJson();
      }
      
      // Também verificar nas ordens disponíveis para provider
      final availableOrder = _availableOrdersForProvider.cast<Order?>().firstWhere(
        (o) => o?.id == orderId,
        orElse: () => null,
      );
      
      if (availableOrder != null) {
        return availableOrder.toJson();
      }
      
      
      // Se não encontrou localmente, tentar buscar do backend
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
    _availableOrdersForProvider = [];  // Limpar também lista de disponíveis
    _currentOrder = null;
    _error = null;
    _isInitialized = false;
    notifyListeners();
  }

  // Clear orders from memory only (for logout - keeps data in storage)
  Future<void> clearAllOrders() async {
    _orders = [];
    _availableOrdersForProvider = [];  // Limpar também lista de disponíveis
    _currentOrder = null;
    _error = null;
    _currentUserPubkey = null;
    _isInitialized = false;
    notifyListeners();
  }

  // Permanently delete all orders (for testing/reset)
  Future<void> permanentlyDeleteAllOrders() async {
    _orders = [];
    _availableOrdersForProvider = [];  // Limpar também lista de disponíveis
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

  /// Reconciliar ordens pendentes com pagamentos já recebidos no Breez
  /// Esta função verifica os pagamentos recentes do Breez e atualiza ordens pendentes
  /// que possam ter perdido a atualização de status (ex: app fechou antes do callback)
  /// 
  /// IMPORTANTE: Usa APENAS paymentHash para identificação PRECISA
  /// O fallback por valor foi DESATIVADO porque causava falsos positivos
  /// (mesmo pagamento usado para múltiplas ordens diferentes)
  /// 
  /// @param breezPayments Lista de pagamentos do Breez SDK (obtida via listPayments)
  Future<int> reconcilePendingOrdersWithBreez(List<dynamic> breezPayments) async {
    
    // Buscar ordens pendentes
    final pendingOrders = _orders.where((o) => o.status == 'pending').toList();
    
    if (pendingOrders.isEmpty) {
      return 0;
    }
    
    
    int reconciled = 0;
    
    // Criar set de paymentHashes já usados (para evitar duplicação)
    final Set<String> usedHashes = {};
    
    // Primeiro, coletar hashes já usados por ordens que já foram pagas
    for (final order in _orders) {
      if (order.status != 'pending' && order.paymentHash != null) {
        usedHashes.add(order.paymentHash!);
      }
    }
    
    for (var order in pendingOrders) {
      
      // �sNICO M�?TODO: Match por paymentHash (MAIS SEGURO)
      if (order.paymentHash != null && order.paymentHash!.isNotEmpty) {
        // Verificar se este hash não foi usado por outra ordem
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
        // Ordem SEM paymentHash - N�fO fazer fallback por valor
        // Isso evita falsos positivos onde múltiplas ordens são marcadas com o mesmo pagamento
      }
    }
    
    return reconciled;
  }

  /// Reconciliar ordens na inicialização - DESATIVADO
  /// NOTA: Esta função foi desativada pois causava falsos positivos de "payment_received"
  /// quando o usuário tinha saldo de outras transações na carteira.
  /// A reconciliação correta deve ser feita APENAS via evento do SDK Breez (PaymentSucceeded)
  /// que traz o paymentHash específico da invoice.
  Future<void> reconcileOnStartup(int currentBalanceSats) async {
    // Não faz nada - reconciliação automática por saldo é muito propensa a erros
    return;
  }

  /// Callback chamado quando o Breez SDK detecta um pagamento recebido
  /// Este é o método SEGURO de atualização - baseado no evento real do SDK
  /// IMPORTANTE: Usa APENAS paymentHash para identificação PRECISA
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
    
    
    // �sNICO M�?TODO: Match EXATO por paymentHash (mais seguro)
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
    
    // N�fO fazer fallback por valor - isso causa falsos positivos
    // Se o paymentHash não corresponder, o pagamento não é para nenhuma ordem nossa
  }

  /// Atualizar o paymentHash de uma ordem (chamado quando a invoice é gerada)
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

  /// Buscar ordens pendentes de todos os usuários (para providers verem)
  Future<List<Order>> fetchPendingOrdersFromNostr() async {
    try {
      final orders = await _nostrOrderService.fetchPendingOrders();
      return orders;
    } catch (e) {
      return [];
    }
  }

  /// Buscar histórico de ordens do usuário atual do Nostr
  Future<void> syncOrdersFromNostr() async {
    // Tentar pegar a pubkey do NostrService se não temos
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
        // VALIDA�?�fO: Ignorar ordens com amount=0 vindas do Nostr
        // (já são filtradas em eventToOrder, mas double-check aqui)
        if (nostrOrder.amount <= 0) {
          skipped++;
          continue;
        }
        
        // SEGURAN�?A CRÍTICA: Verificar se a ordem realmente pertence ao usuário atual
        // Ordem pertence se: userPubkey == atual OU providerId == atual (aceitou como Bro)
        final isMyOrder = nostrOrder.userPubkey == _currentUserPubkey;
        final isMyProviderOrder = nostrOrder.providerId == _currentUserPubkey;
        
        if (!isMyOrder && !isMyProviderOrder) {
          skipped++;
          continue;
        }
        
        final existingIndex = _orders.indexWhere((o) => o.id == nostrOrder.id);
        if (existingIndex == -1) {
          // Ordem não existe localmente, adicionar
          // CORRE�?�fO: Adicionar TODAS as ordens do usuário incluindo completed para histórico!
          // Só ignoramos cancelled pois são ordens canceladas pelo usuário
          if (nostrOrder.status != 'cancelled') {
            _orders.add(nostrOrder);
            added++;
          }
        } else {
          // Ordem já existe, mesclar dados preservando os locais que não são 0
          final existing = _orders[existingIndex];
          
          // REGRA CRÍTICA: Apenas status FINAIS não podem reverter
          // accepted e awaiting_confirmation podem evoluir para completed
          final protectedStatuses = ['cancelled', 'completed', 'liquidated', 'disputed'];
          if (protectedStatuses.contains(existing.status)) {
            continue;
          }
          
          // Se Nostr tem status mais recente, atualizar apenas o status
          // MAS manter amount/btcAmount/billCode locais se Nostr tem 0
          if (_isStatusMoreRecent(nostrOrder.status, existing.status) || 
              existing.amount == 0 && nostrOrder.amount > 0) {
            
            // NOTA: O bloqueio de "completed" indevido é feito no NostrOrderService._applyStatusUpdate()
            // que verifica se o evento foi publicado pelo PROVEDOR ou pelo PR�"PRIO USUÁRIO.
            // Aqui apenas aplicamos o status que já foi filtrado pelo NostrOrderService.
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
      
      // NOVO: Buscar atualizações de status (aceites e comprovantes de Bros)
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
          
          // NOTA: O bloqueio de "completed" indevido é feito no NostrOrderService._applyStatusUpdate()
          // que verifica se o evento foi publicado pelo PROVEDOR ou pelo PR�"PRIO USUÁRIO.
          // Aqui apenas aplicamos o status que já foi processado.
          String statusToUse = newStatus;
          
          // Verificar se o novo status é mais avançado
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
      
      // SEGURAN�?A CRÍTICA: Salvar apenas ordens do usuário atual!
      // Isso evita que ordens de outros usuários sejam persistidas localmente
      await _saveOnlyUserOrders();
      notifyListeners();
      
    } catch (e) {
    }
  }

  /// Verificar se um status é mais recente que outro
  bool _isStatusMoreRecent(String newStatus, String currentStatus) {
    // CORRE�?�fO: Apenas status FINAIS não podem regredir
    // accepted e awaiting_confirmation PODEM evoluir para completed/liquidated
    const finalStatuses = ['cancelled', 'completed', 'liquidated', 'disputed'];
    if (finalStatuses.contains(currentStatus)) {
      // Status final - só pode virar disputed
      if (currentStatus != 'disputed' && newStatus == 'disputed') {
        return true;
      }
      return false;
    }
    
    // Ordem de progressão de status:
    // draft -> pending -> payment_received -> accepted -> processing -> awaiting_confirmation -> completed/liquidated
    const statusOrder = [
      'draft',
      'pending', 
      'payment_received', 
      'accepted', 
      'processing',
      'awaiting_confirmation',  // Bro enviou comprovante, aguardando validação do usuário
      'completed',
      'liquidated',  // Auto-liquidação após 24h
    ];
    final newIndex = statusOrder.indexOf(newStatus);
    final currentIndex = statusOrder.indexOf(currentStatus);
    
    // Se algum status não está na lista, considerar como não sendo mais recente
    if (newIndex == -1 || currentIndex == -1) return false;
    
    return newIndex > currentIndex;
  }

  /// Republicar ordens locais que não têm eventId no Nostr
  /// �stil para migrar ordens criadas antes da integração Nostr
  /// SEGURAN�?A: Só republica ordens que PERTENCEM ao usuário atual!
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
      // SEGURAN�?A CRÍTICA: Só republicar ordens que PERTENCEM ao usuário atual!
      // Nunca republicar ordens de outros usuários (isso causaria duplicação com pubkey errado)
      if (order.userPubkey != _currentUserPubkey) {
        continue;
      }
      
      // Só republicar ordens que não têm eventId
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

  /// Reconciliação automática de ordens baseada em pagamentos do Breez SDK
  /// 
  /// Esta função analisa TODOS os pagamentos (recebidos e enviados) e atualiza
  /// os status das ordens automaticamente:
  /// 
  /// 1. Pagamentos RECEBIDOS �?' Atualiza ordens 'pending' para 'payment_received'
  ///    (usado quando o Bro paga via Lightning - menos comum no fluxo atual)
  /// 
  /// 2. Pagamentos ENVIADOS �?' Atualiza ordens 'awaiting_confirmation' para 'completed'
  ///    (quando o usuário liberou BTC para o Bro após confirmar prova de pagamento)
  /// 
  /// A identificação é feita por:
  /// - paymentHash (se disponível) - mais preciso
  /// - Valor aproximado + timestamp (fallback)
  Future<Map<String, int>> autoReconcileWithBreezPayments(List<Map<String, dynamic>> breezPayments) async {
    
    int pendingReconciled = 0;
    int completedReconciled = 0;
    
    // Separar pagamentos por direção
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
    // DESATIVADO: Esta seção auto-completava ordens sem confirmação do usuário.
    // Matchava por valor aproximado (5% tolerância), o que causava falsos positivos.
    // A confirmação de pagamento DEVE ser feita MANUALMENTE pelo usuário.
    
    
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
  /// DESATIVADO: Não deve auto-completar ordens. Usuário deve confirmar manualmente.
  Future<void> onPaymentSent({
    required String paymentId,
    required int amountSats,
    String? paymentHash,
  }) async {
    return; // DESATIVADO - não auto-completar
    
    // CORRE�?�fO CRÍTICA: Só buscar ordens que EU CRIEI
    final currentUserPubkey = _nostrService.publicKey;
    final awaitingOrders = _orders.where((o) => 
      (o.status == 'awaiting_confirmation' || o.status == 'accepted') &&
      o.userPubkey == currentUserPubkey // IMPORTANTE: Só minhas ordens!
    ).toList();
    
    if (awaitingOrders.isEmpty) {
      return;
    }
    
    
    // Procurar ordem com valor correspondente
    for (final order in awaitingOrders) {
      final expectedSats = (order.btcAmount * 100000000).toInt();
      
      // Tolerância de 5% para taxas
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

  /// RECONCILIA�?�fO FOR�?ADA - Analisa TODAS as ordens e TODOS os pagamentos
  /// Use quando ordens antigas não estão sendo atualizadas automaticamente
  /// 
  /// Esta função é mais agressiva que autoReconcileWithBreezPayments:
  /// - Verifica TODAS as ordens não-completed (incluindo pending antigas)
  /// - Usa match por valor com tolerância maior (10%)
  /// - Cria lista de pagamentos usados para evitar duplicação
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
    
    
    // CORRE�?�fO CRÍTICA: Para pagamentos ENVIADOS (que marcam como completed),
    // só verificar ordens que EU CRIEI (sou o userPubkey)
    final currentUserPubkey = _nostrService.publicKey;
    
    // Buscar TODAS as ordens não finalizadas
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
        // (no fluxo atual do Bro, isso é menos comum)
        paymentsToCheck = receivedPayments;
        newStatus = 'payment_received';
      } else {
        // DESATIVADO: Não auto-completar ordens accepted/awaiting_confirmation
        // Usuário deve confirmar recebimento MANUALMENTE
        continue;
      }
      
      // Procurar pagamento correspondente
      bool found = false;
      for (final payment in paymentsToCheck) {
        final paymentId = payment['id']?.toString() ?? '';
        
        // Pular se já foi usado
        if (usedPaymentIds.contains(paymentId)) continue;
        
        final paymentAmount = (payment['amount'] is int) 
            ? payment['amount'] as int 
            : int.tryParse(payment['amount']?.toString() ?? '0') ?? 0;
        
        final status = payment['status']?.toString() ?? '';
        
        // Só considerar pagamentos completados
        if (!status.toLowerCase().contains('completed') && 
            !status.toLowerCase().contains('complete') &&
            !status.toLowerCase().contains('succeeded')) {
          continue;
        }
        
        // Tolerância de 10% para match (mais agressivo)
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

  /// Forçar status de uma ordem específica para 'completed'
  /// Use quando você tem certeza que a ordem foi paga mas o sistema não detectou
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
