import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../services/api_service.dart';
import '../services/nostr_service.dart';
import '../services/nostr_order_service.dart';
import '../models/order.dart';
import '../config.dart';

class OrderProvider with ChangeNotifier {
  final ApiService _apiService = ApiService();
  final NostrService _nostrService = NostrService();
  final NostrOrderService _nostrOrderService = NostrOrderService();

  List<Order> _orders = [];
  Order? _currentOrder;
  bool _isLoading = false;
  String? _error;
  bool _isInitialized = false;
  String? _currentUserPubkey;

  // Prefixo para salvar no SharedPreferences (será combinado com pubkey)
  static const String _ordersKeyPrefix = 'orders_';

  // Getters
  List<Order> get orders => _orders;
  List<Order> get pendingOrders => _orders.where((o) => o.status == 'pending' || o.status == 'payment_received').toList();
  List<Order> get activeOrders => _orders.where((o) => ['payment_received', 'confirmed', 'accepted', 'processing'].contains(o.status)).toList();
  List<Order> get completedOrders => _orders.where((o) => o.status == 'completed').toList();
  Order? get currentOrder => _currentOrder;
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// Calcula o total de sats comprometidos com ordens pendentes/ativas (modo cliente)
  /// Este valor deve ser SUBTRAÍDO do saldo total para calcular saldo disponível para garantia
  /// INCLUI ordens draft (aguardando pagamento) pois o saldo já está reservado
  int get committedSats {
    // Somar btcAmount de todas as ordens pendentes e ativas (que ainda não foram completadas/canceladas)
    // btcAmount está em BTC, precisa converter para sats (x 100_000_000)
    final committedOrders = _orders.where((o) => 
      o.status == 'draft' ||  // ⚠️ Incluir draft - saldo reservado mesmo antes de pagar
      o.status == 'pending' || 
      o.status == 'payment_received' || 
      o.status == 'confirmed' || 
      o.status == 'accepted' ||
      o.status == 'awaiting_confirmation' ||
      o.status == 'processing'
    );
    
    int total = 0;
    for (final order in committedOrders) {
      total += (order.btcAmount * 100000000).toInt();
    }
    
    debugPrint('💰 Sats comprometidos com ordens: $total sats (${committedOrders.length} ordens)');
    return total;
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
    
    debugPrint('📦 OrderProvider inicializando para usuário: ${_currentUserPubkey?.substring(0, 8) ?? 'anonymous'}...');
    
    // Resetar estado
    _orders = [];
    _isInitialized = false;
    
    // SEMPRE carregar ordens locais primeiro (para preservar status atualizados)
    // Antes estava só em testMode, mas isso perdia status como payment_received
    await _loadSavedOrders();
    debugPrint('📦 ${_orders.length} ordens locais carregadas (para preservar status)');
    
    // CORREÇÃO AUTOMÁTICA: Identificar ordens marcadas incorretamente como pagas
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

  // Recarregar ordens para novo usuário (após login)
  Future<void> loadOrdersForUser(String userPubkey) async {
    debugPrint('🔄 Carregando ordens para usuário: ${userPubkey.substring(0, 8)}...');
    _currentUserPubkey = userPubkey;
    _orders = [];
    _isInitialized = false;
    
    // Carregar ordens locais primeiro (SEMPRE, para preservar status atualizados)
    await _loadSavedOrders();
    
    // SEGURANÇA: Filtrar ordens que não pertencem a este usuário
    // (podem ter vazado de sincronizações anteriores)
    final originalCount = _orders.length;
    _orders = _orders.where((order) {
      // Manter ordens deste usuário
      if (order.userPubkey == userPubkey) return true;
      // Manter ordens sem pubkey definido (legado, mas marcar como deste usuário)
      if (order.userPubkey == null || order.userPubkey!.isEmpty) {
        debugPrint('⚠️ Ordem ${order.id.substring(0, 8)} sem userPubkey - removendo por segurança');
        return false; // Remover ordens sem dono identificado
      }
      // Remover ordens de outros usuários
      debugPrint('🚫 Removendo ordem ${order.id.substring(0, 8)} de outro usuário');
      return false;
    }).toList();
    
    if (_orders.length < originalCount) {
      debugPrint('🔐 Removidas ${originalCount - _orders.length} ordens de outros usuários');
      await _saveOrders(); // Salvar lista limpa
    }
    
    debugPrint('📦 ${_orders.length} ordens locais carregadas (para preservar status)');
    
    _isInitialized = true;
    notifyListeners();
    
    // Sincronizar do Nostr IMEDIATAMENTE (não em background)
    debugPrint('🔄 Iniciando sincronização do Nostr...');
    try {
      await syncOrdersFromNostr();
      debugPrint('✅ Sincronização do Nostr concluída');
    } catch (e) {
      debugPrint('⚠️ Erro ao sincronizar do Nostr: $e');
    }
  }
  
  // Sincronizar ordens do Nostr em background
  void _syncFromNostrBackground() {
    if (_currentUserPubkey == null) return;
    
    debugPrint('🔄 Iniciando sincronização do Nostr em background...');
    
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
        debugPrint('⚠️ Erro ao sincronizar do Nostr: $e');
      }
    });
  }

  // Limpar ordens ao fazer logout
  void clearOrders() {
    debugPrint('🗑️ Limpando ordens da memória (logout)');
    _orders = [];
    _currentOrder = null;
    _currentUserPubkey = null;
    _isInitialized = false;
    notifyListeners();
  }

  // Carregar ordens do SharedPreferences
  Future<void> _loadSavedOrders() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ordersJson = prefs.getString(_ordersKey);
      
      if (ordersJson != null) {
        final List<dynamic> ordersList = json.decode(ordersJson);
        _orders = ordersList.map((data) {
          try {
            return Order.fromJson(data);
          } catch (e) {
            debugPrint('⚠️ Erro ao carregar ordem individual: $e');
            return null;
          }
        }).whereType<Order>().toList(); // Remove nulls
        
        debugPrint('📦 Carregadas ${_orders.length} ordens salvas');
        
        // Migrar ordens antigas: corrigir providerId se ordem está aceita mas sem providerId correto
        bool needsMigration = false;
        for (int i = 0; i < _orders.length; i++) {
          final order = _orders[i];
          debugPrint('   - ${order.id.substring(0, 8)}: R\$ ${order.amount.toStringAsFixed(2)} (${order.status}, providerId=${order.providerId ?? "null"})');
          
          // Se ordem está aceita/awaiting/completed mas sem providerId fixo, migrar
          if ((order.status == 'accepted' || 
               order.status == 'awaiting_confirmation' || 
               order.status == 'completed') && 
              order.providerId != 'provider_test_001') {
            debugPrint('   ⚠️ Migrando ordem ${order.id.substring(0, 8)} para provider_test_001');
            _orders[i] = order.copyWith(providerId: 'provider_test_001');
            needsMigration = true;
          }
        }
        
        // Se houve migração, salvar
        if (needsMigration) {
          debugPrint('🔄 Salvando ordens migradas...');
          await _saveOrders();
        }
      } else {
        debugPrint('📦 Nenhuma ordem salva encontrada');
      }
    } catch (e) {
      debugPrint('❌ Erro ao carregar ordens: $e');
      // Em caso de erro, limpar dados corrompidos
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_ordersKey);
        debugPrint('🗑️ Dados corrompidos removidos');
      } catch (e2) {
        debugPrint('❌ Erro ao limpar dados: $e2');
      }
    }
  }

  /// Corrigir ordens que foram marcadas incorretamente como "payment_received"
  /// pela reconciliação automática antiga (baseada apenas em saldo).
  /// 
  /// Corrigir ordens marcadas incorretamente como "payment_received"
  /// 
  /// REGRA SIMPLES: Se a ordem tem status "payment_received" mas NÃO tem paymentHash,
  /// é um falso positivo e deve voltar para "pending".
  /// 
  /// Ordens COM paymentHash foram verificadas pelo SDK Breez e são válidas.
  Future<void> _fixIncorrectlyPaidOrders() async {
    // Buscar ordens com payment_received
    final paidOrders = _orders.where((o) => o.status == 'payment_received').toList();
    
    if (paidOrders.isEmpty) {
      return;
    }
    
    debugPrint('🔧 Verificando ${paidOrders.length} ordens com payment_received...');
    
    bool needsCorrection = false;
    
    for (final order in paidOrders) {
      // Se NÃO tem paymentHash, é falso positivo!
      if (order.paymentHash == null || order.paymentHash!.isEmpty) {
        debugPrint('🔧 FALSO POSITIVO: Ordem ${order.id.substring(0, 8)} sem paymentHash -> voltando para pending');
        
        final index = _orders.indexWhere((o) => o.id == order.id);
        if (index != -1) {
          _orders[index] = _orders[index].copyWith(status: 'pending');
          needsCorrection = true;
        }
      } else {
        debugPrint('✅ Ordem ${order.id.substring(0, 8)} tem paymentHash - status válido');
      }
    }
    
    if (needsCorrection) {
      await _saveOrders();
      debugPrint('✅ Status de ordens corrigido e salvo');
      
      // Republicar no Nostr com status correto
      for (final order in _orders.where((o) => o.status == 'pending')) {
        try {
          await _publishOrderToNostr(order);
        } catch (e) {
          debugPrint('⚠️ Erro ao republicar ordem ${order.id.substring(0, 8)}: $e');
        }
      }
    }
  }

  /// Expirar ordens pendentes antigas (> 2 horas sem aceite)
  /// Ordens que ficam muito tempo pendentes provavelmente foram abandonadas
  // Salvar ordens no SharedPreferences (SEMPRE salva, não só em testMode)
  Future<void> _saveOrders() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ordersJson = json.encode(_orders.map((o) => o.toJson()).toList());
      await prefs.setString(_ordersKey, ordersJson);
      debugPrint('💾 ${_orders.length} ordens salvas no SharedPreferences');
      
      // Log de cada ordem salva
      for (var order in _orders) {
        debugPrint('   - ${order.id.substring(0, 8)}: status="${order.status}", providerId=${order.providerId ?? "null"}, R\$ ${order.amount}');
      }
    } catch (e) {
      debugPrint('❌ Erro ao salvar ordens: $e');
    }
  }
  
  /// SEGURANÇA: Salvar APENAS ordens do usuário atual no SharedPreferences
  /// Ordens de outros usuários (visualizadas no modo provedor) ficam apenas em memória
  Future<void> _saveOnlyUserOrders() async {
    try {
      // Filtrar apenas ordens do usuário atual
      final userOrders = _orders.where((o) => 
        o.userPubkey == _currentUserPubkey || 
        o.providerId == _currentUserPubkey  // Ordens que este usuário aceitou como provedor
      ).toList();
      
      final prefs = await SharedPreferences.getInstance();
      final ordersJson = json.encode(userOrders.map((o) => o.toJson()).toList());
      await prefs.setString(_ordersKey, ordersJson);
      debugPrint('💾 SEGURO: ${userOrders.length}/${_orders.length} ordens salvas (apenas do usuário atual)');
    } catch (e) {
      debugPrint('❌ Erro ao salvar ordens: $e');
    }
  }

  /// Corrigir status de uma ordem manualmente
  /// Usado para corrigir ordens que foram marcadas incorretamente
  Future<bool> fixOrderStatus(String orderId, String newStatus) async {
    final index = _orders.indexWhere((o) => o.id == orderId);
    if (index == -1) {
      debugPrint('❌ Ordem não encontrada para corrigir: $orderId');
      return false;
    }
    
    final oldStatus = _orders[index].status;
    _orders[index] = _orders[index].copyWith(status: newStatus);
    debugPrint('🔧 Status da ordem ${orderId.substring(0, 8)} corrigido: $oldStatus -> $newStatus');
    
    await _saveOrders();
    notifyListeners();
    return true;
  }

  /// Cancelar uma ordem pendente
  /// Apenas ordens com status 'pending' podem ser canceladas
  /// SEGURANÇA: Apenas o dono da ordem pode cancelá-la!
  Future<bool> cancelOrder(String orderId) async {
    final index = _orders.indexWhere((o) => o.id == orderId);
    if (index == -1) {
      debugPrint('❌ Ordem não encontrada para cancelar: $orderId');
      return false;
    }
    
    final order = _orders[index];
    
    // VERIFICAÇÃO DE SEGURANÇA: Apenas o dono pode cancelar
    if (order.userPubkey != null && 
        _currentUserPubkey != null && 
        order.userPubkey != _currentUserPubkey) {
      debugPrint('❌ SEGURANÇA: Tentativa de cancelar ordem de outro usuário!');
      debugPrint('   Ordem pertence a: ${order.userPubkey?.substring(0, 8)}');
      debugPrint('   Usuário atual: ${_currentUserPubkey?.substring(0, 8)}');
      return false;
    }
    
    if (order.status != 'pending') {
      debugPrint('❌ Apenas ordens pendentes podem ser canceladas. Status atual: ${order.status}');
      return false;
    }
    
    _orders[index] = order.copyWith(status: 'cancelled');
    debugPrint('🗑️ Ordem ${orderId.substring(0, 8)} cancelada');
    
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
        debugPrint('✅ Cancelamento publicado no Nostr');
      }
    } catch (e) {
      debugPrint('⚠️ Erro ao publicar cancelamento no Nostr: $e');
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
      debugPrint('❌ Ordem não encontrada: $orderId');
      return false;
    }
    
    final order = _orders[index];
    if (order.status != 'pending') {
      debugPrint('ℹ️ Ordem ${orderId.substring(0, 8)} não está pendente: ${order.status}');
      return false;
    }
    
    final expectedSats = (order.btcAmount * 100000000).toInt();
    debugPrint('🔍 Verificando ordem ${orderId.substring(0, 8)}: esperado=$expectedSats sats');
    
    // Primeiro tentar por paymentHash (mais seguro)
    if (order.paymentHash != null && order.paymentHash!.isNotEmpty) {
      for (var payment in breezPayments) {
        final paymentHash = payment['paymentHash'] as String?;
        if (paymentHash == order.paymentHash) {
          debugPrint('✅ MATCH por paymentHash! Atualizando ordem...');
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
        debugPrint('✅ MATCH por valor! Pagamento de $paymentAmount sats corresponde a ordem de $expectedSats sats');
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
    
    debugPrint('❌ Nenhum pagamento correspondente encontrado para ordem ${orderId.substring(0, 8)}');
    return false;
  }

  // Criar ordem LOCAL (NÃO publica no Nostr!)
  // A ordem só será publicada no Nostr APÓS pagamento confirmado
  // Isso evita que Bros vejam ordens sem depósito
  Future<Order?> createOrder({
    required String billType,
    required String billCode,
    required double amount,
    required double btcAmount,
    required double btcPrice,
  }) async {
    // VALIDAÇÃO CRÍTICA: Nunca criar ordem com amount = 0
    if (amount <= 0) {
      debugPrint('❌ ERRO CRÍTICO: Tentativa de criar ordem com amount=$amount');
      _error = 'Valor da ordem inválido';
      notifyListeners();
      return null;
    }
    
    if (btcAmount <= 0) {
      debugPrint('❌ ERRO CRÍTICO: Tentativa de criar ordem com btcAmount=$btcAmount');
      _error = 'Valor em BTC inválido';
      notifyListeners();
      return null;
    }
    
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      debugPrint('📦 Criando ordem LOCAL: amount=$amount, btcAmount=$btcAmount, btcPrice=$btcPrice');
      
      // Calcular taxas (1% provider + 2% platform)
      final providerFee = amount * 0.01;
      final platformFee = amount * 0.02;
      final total = amount + providerFee + platformFee;
      
      // CRÍTICO: Status 'draft' = aguardando pagamento, não visível para Bros
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
        status: 'draft',  // ⚠️ DRAFT = não publicado no Nostr ainda
        createdAt: DateTime.now(),
      );
      
      // LOG DE VALIDAÇÃO
      debugPrint('✅ Ordem DRAFT criada: amount=${order.amount}, btcAmount=${order.btcAmount}, total=${order.total}');
      debugPrint('⚠️ IMPORTANTE: Ordem NÃO publicada no Nostr - aguardando pagamento!');
      
      _orders.insert(0, order);
      _currentOrder = order;
      
      // Salvar localmente (NÃO publica no Nostr!)
      final prefs = await SharedPreferences.getInstance();
      final ordersJson = json.encode(_orders.map((o) => o.toJson()).toList());
      await prefs.setString(_ordersKey, ordersJson);
      
      notifyListeners();
      
      // ⛔ NÃO PUBLICAR NO NOSTR AQUI!
      // A publicação ocorre em publishOrderAfterPayment() após pagamento confirmado
      
      debugPrint('✅ Ordem DRAFT criada localmente: ${order.id}');
      debugPrint('⏳ Aguardando pagamento Lightning para publicar no Nostr...');
      return order;
    } catch (e) {
      _error = e.toString();
      debugPrint('❌ Erro ao criar ordem: $e');
      return null;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
  
  /// CRÍTICO: Publicar ordem no Nostr SOMENTE APÓS pagamento confirmado
  /// Este método transforma a ordem de 'draft' para 'pending' e publica no Nostr
  /// para que os Bros possam vê-la e aceitar
  Future<bool> publishOrderAfterPayment(String orderId) async {
    debugPrint('🚀 publishOrderAfterPayment chamado para ordem: $orderId');
    
    final index = _orders.indexWhere((o) => o.id == orderId);
    if (index == -1) {
      debugPrint('❌ Ordem não encontrada: $orderId');
      return false;
    }
    
    final order = _orders[index];
    
    // Validar que ordem está em draft (não foi publicada ainda)
    if (order.status != 'draft') {
      debugPrint('⚠️ Ordem ${orderId.substring(0, 8)} não está em draft: ${order.status}');
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
      debugPrint('📤 Publicando ordem no Nostr APÓS pagamento confirmado...');
      await _publishOrderToNostr(_orders[index]);
      
      // Pequeno delay para propagação
      await Future.delayed(const Duration(milliseconds: 500));
      
      debugPrint('✅ Ordem ${orderId.substring(0, 8)} publicada no Nostr com sucesso!');
      debugPrint('👀 Agora os Bros podem ver e aceitar esta ordem');
      return true;
    } catch (e) {
      debugPrint('❌ Erro ao publicar ordem no Nostr: $e');
      return false;
    }
  }

  // Listar ordens (para usuário normal ou provedor)
  Future<void> fetchOrders({String? status, bool forProvider = false}) async {
    debugPrint('📦 Sincronizando ordens com Nostr... (forProvider: $forProvider)');
    _isLoading = true;
    notifyListeners();
    
    try {
      if (forProvider) {
        // MODO PROVEDOR: Buscar TODAS as ordens pendentes de TODOS os usuários
        await syncAllPendingOrdersFromNostr().timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            debugPrint('⏰ Timeout na sincronização Nostr (modo provedor), usando ordens locais');
          },
        );
      } else {
        // MODO USUÁRIO: Buscar apenas ordens do próprio usuário
        await syncOrdersFromNostr().timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            debugPrint('⏰ Timeout na sincronização Nostr, usando ordens locais');
          },
        );
      }
      debugPrint('✅ Sincronização com Nostr concluída (${_orders.length} ordens)');
    } catch (e) {
      debugPrint('❌ Erro ao sincronizar com Nostr: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
  
  /// Buscar TODAS as ordens pendentes do Nostr (para modo Provedor/Bro)
  /// Isso permite que o Bro veja ordens de outros usuários
  Future<void> syncAllPendingOrdersFromNostr() async {
    try {
      debugPrint('🔄 [PROVEDOR] Buscando TODAS as ordens pendentes do Nostr...');
      
      // Buscar todas as ordens pendentes (de qualquer usuário)
      final allPendingOrders = await _nostrOrderService.fetchPendingOrders();
      debugPrint('📦 Recebidas ${allPendingOrders.length} ordens pendentes do Nostr');
      
      // Log das ordens recebidas
      for (var order in allPendingOrders) {
        debugPrint('   📋 Ordem ${order.id.substring(0, 8)}: R\$ ${order.amount.toStringAsFixed(2)}, pubkey=${order.userPubkey?.substring(0, 8) ?? "?"}, status=${order.status}');
      }
      
      // Mesclar com ordens locais (sem duplicar)
      int added = 0;
      int updated = 0;
      for (var pendingOrder in allPendingOrders) {
        // Ignorar ordens com amount=0
        if (pendingOrder.amount <= 0) {
          debugPrint('⚠️ IGNORANDO ordem ${pendingOrder.id.substring(0, 8)} com amount=0');
          continue;
        }
        
        final existingIndex = _orders.indexWhere((o) => o.id == pendingOrder.id);
        if (existingIndex == -1) {
          // Ordem não existe localmente, adicionar
          _orders.add(pendingOrder);
          added++;
        } else {
          // Ordem já existe - PRESERVAR dados locais que são mais recentes
          final existing = _orders[existingIndex];
          
          // Só atualizar se Nostr tem dados mais completos E local não tem providerId
          // Isso garante que ordens aceitas localmente não perdem o providerId
          if (pendingOrder.amount > 0 && existing.amount == 0) {
            _orders[existingIndex] = existing.copyWith(
              amount: pendingOrder.amount,
              btcAmount: pendingOrder.btcAmount,
              btcPrice: pendingOrder.btcPrice,
              total: pendingOrder.total,
              billCode: pendingOrder.billCode,
              // IMPORTANTE: Preservar providerId local se existir!
              providerId: existing.providerId ?? pendingOrder.providerId,
              status: existing.providerId != null ? existing.status : pendingOrder.status,
            );
            updated++;
          } else if (existing.providerId == null && pendingOrder.providerId != null) {
            // Se Nostr tem providerId e local não, atualizar
            _orders[existingIndex] = existing.copyWith(
              providerId: pendingOrder.providerId,
              status: pendingOrder.status,
            );
            updated++;
          }
        }
      }
      
      // Também buscar ordens do próprio usuário
      if (_currentUserPubkey != null && _currentUserPubkey!.isNotEmpty) {
        final userOrders = await _nostrOrderService.fetchUserOrders(_currentUserPubkey!);
        for (var order in userOrders) {
          final existingIndex = _orders.indexWhere((o) => o.id == order.id);
          if (existingIndex == -1 && order.amount > 0) {
            _orders.add(order);
            added++;
          }
        }
      }
      
      // Ordenar por data (mais recente primeiro)
      _orders.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      
      // SEGURANÇA: NÃO salvar ordens de outros usuários no storage local!
      // Apenas salvar as ordens que pertencem ao usuário atual
      // As ordens de outros ficam apenas em memória (para visualização do provedor)
      await _saveOnlyUserOrders();
      notifyListeners();
      
      debugPrint('✅ [PROVEDOR] Sincronização concluída: ${_orders.length} ordens totais (added: $added, updated: $updated)');
    } catch (e) {
      debugPrint('❌ [PROVEDOR] Erro ao sincronizar ordens: $e');
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
      debugPrint('💾 Ordem $orderId atualizada para status: $status');
      
      // IMPORTANTE: Publicar atualização no Nostr para sincronização P2P
      final privateKey = _nostrService.privateKey;
      if (privateKey != null) {
        debugPrint('📤 Publicando atualização de status no Nostr (local)...');
        try {
          final success = await _nostrOrderService.updateOrderStatus(
            privateKey: privateKey,
            orderId: orderId,
            newStatus: status,
          );
          if (success) {
            debugPrint('✅ Status publicado no Nostr');
          } else {
            debugPrint('⚠️ Falha ao publicar status no Nostr');
          }
        } catch (e) {
          debugPrint('❌ Erro ao publicar no Nostr: $e');
        }
      } else {
        debugPrint('⚠️ Sem privateKey Nostr para publicar status');
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
      // SEMPRE atualizar localmente (modo P2P via Nostr)
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
        
        debugPrint('💾 Ordem $orderId atualizada: status=$status, providerId=$providerId');
        
        // IMPORTANTE: Publicar atualização no Nostr para sincronização P2P
        final privateKey = _nostrService.privateKey;
        if (privateKey != null) {
          debugPrint('📤 Publicando atualização de status no Nostr...');
          final success = await _nostrOrderService.updateOrderStatus(
            privateKey: privateKey,
            orderId: orderId,
            newStatus: status,
            providerId: providerId,
          );
          if (success) {
            debugPrint('✅ Status publicado no Nostr');
          } else {
            debugPrint('⚠️ Falha ao publicar status no Nostr (ordem salva localmente)');
          }
        }
      } else {
        debugPrint('⚠️ Ordem $orderId não encontrada para atualizar');
      }
      
      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
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
        debugPrint('⚠️ Ordem $orderId não encontrada localmente, buscando no Nostr...');
        
        final orderData = await _nostrOrderService.fetchOrderFromNostr(orderId);
        if (orderData != null) {
          order = Order.fromJson(orderData);
          // Adicionar à lista local para referência futura
          _orders.add(order);
          debugPrint('✅ Ordem encontrada no Nostr e adicionada localmente');
        }
      }
      
      if (order == null) {
        debugPrint('❌ Ordem $orderId não encontrada em nenhum lugar');
        _error = 'Ordem não encontrada';
        _isLoading = false;
        notifyListeners();
        return false;
      }

      // Pegar chave privada do Nostr
      final privateKey = _nostrService.privateKey;
      if (privateKey == null) {
        debugPrint('❌ Chave privada Nostr não disponível');
        _error = 'Chave privada não disponível';
        _isLoading = false;
        notifyListeners();
        return false;
      }

      final providerPubkey = _nostrService.publicKey;
      debugPrint('🔄 Provedor $providerPubkey aceitando ordem $orderId...');

      // Publicar aceitação no Nostr
      final success = await _nostrOrderService.acceptOrderOnNostr(
        order: order,
        providerPrivateKey: privateKey,
      );

      if (!success) {
        debugPrint('⚠️ Falha ao publicar aceitação no Nostr');
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
        
        debugPrint('✅ Ordem $orderId aceita com sucesso');
        debugPrint('   providerId: $providerPubkey');
        debugPrint('   status: accepted');
      }

      return true;
    } catch (e) {
      _error = e.toString();
      debugPrint('❌ Erro ao aceitar ordem: $e');
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Provedor completa uma ordem - publica comprovante no Nostr e atualiza localmente
  Future<bool> completeOrderAsProvider(String orderId, String proof) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      // Buscar a ordem localmente primeiro
      Order? order = getOrderById(orderId);
      
      // Se não encontrou localmente, buscar do Nostr
      if (order == null) {
        debugPrint('⚠️ Ordem $orderId não encontrada localmente, buscando no Nostr...');
        
        final orderData = await _nostrOrderService.fetchOrderFromNostr(orderId);
        if (orderData != null) {
          order = Order.fromJson(orderData);
          // Adicionar à lista local para referência futura
          _orders.add(order);
          debugPrint('✅ Ordem encontrada no Nostr e adicionada localmente');
        }
      }
      
      if (order == null) {
        debugPrint('❌ Ordem $orderId não encontrada em nenhum lugar');
        _error = 'Ordem não encontrada';
        _isLoading = false;
        notifyListeners();
        return false;
      }

      // Pegar chave privada do Nostr
      final privateKey = _nostrService.privateKey;
      if (privateKey == null) {
        debugPrint('❌ Chave privada Nostr não disponível');
        _error = 'Chave privada não disponível';
        _isLoading = false;
        notifyListeners();
        return false;
      }

      debugPrint('🔄 Completando ordem $orderId com comprovante...');

      // Publicar conclusão no Nostr
      final success = await _nostrOrderService.completeOrderOnNostr(
        order: order,
        providerPrivateKey: privateKey,
        proofImageBase64: proof,
      );

      if (!success) {
        debugPrint('⚠️ Falha ao publicar comprovante no Nostr');
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
            'paymentProof': proof.length > 100 ? 'image_base64_stored' : proof,
          },
        );
        
        // Salvar localmente
        final prefs = await SharedPreferences.getInstance();
        final ordersJson = json.encode(_orders.map((o) => o.toJson()).toList());
        await prefs.setString(_ordersKey, ordersJson);
        
        debugPrint('✅ Ordem $orderId completada, aguardando confirmação');
      }

      return true;
    } catch (e) {
      _error = e.toString();
      debugPrint('❌ Erro ao completar ordem: $e');
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
      debugPrint('❌ Ordem $orderId não encontrada: $e');
      return null;
    }
  }

  // Get order (alias para fetchOrder)
  Future<Map<String, dynamic>?> getOrder(String orderId) async {
    try {
      debugPrint('🔍 getOrder: Buscando ordem $orderId');
      debugPrint('🔍 getOrder: Total de ordens em memória: ${_orders.length}');
      
      // Primeiro, tentar encontrar na lista em memória (mais rápido)
      final localOrder = _orders.cast<Order?>().firstWhere(
        (o) => o?.id == orderId,
        orElse: () => null,
      );
      
      if (localOrder != null) {
        debugPrint('✅ getOrder: Ordem encontrada em memória');
        return localOrder.toJson();
      }
      
      debugPrint('⚠️ getOrder: Ordem não encontrada em memória, tentando backend...');
      
      // Se não encontrou localmente, tentar buscar do backend
      final orderData = await _apiService.getOrder(orderId);
      if (orderData != null) {
        debugPrint('✅ getOrder: Ordem encontrada no backend');
        return orderData;
      }
      
      debugPrint('❌ getOrder: Ordem não encontrada em nenhum lugar');
      return null;
    } catch (e) {
      _error = e.toString();
      debugPrint('❌ Erro ao buscar ordem $orderId: $e');
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
    _currentOrder = null;
    _error = null;
    _isInitialized = false;
    notifyListeners();
  }

  // Clear orders from memory only (for logout - keeps data in storage)
  Future<void> clearAllOrders() async {
    debugPrint('🔄 Limpando ordens da memória (logout) - dados mantidos no storage');
    _orders = [];
    _currentOrder = null;
    _error = null;
    _currentUserPubkey = null;
    _isInitialized = false;
    notifyListeners();
  }

  // Permanently delete all orders (for testing/reset)
  Future<void> permanentlyDeleteAllOrders() async {
    _orders = [];
    _currentOrder = null;
    _error = null;
    _isInitialized = false;
    
    // Limpar do SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_ordersKey);
      debugPrint('🗑️ Todas as ordens foram PERMANENTEMENTE removidas');
    } catch (e) {
      debugPrint('❌ Erro ao limpar ordens: $e');
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
    debugPrint('🔄 Reconciliando ordens pendentes com pagamentos do Breez...');
    
    // Buscar ordens pendentes
    final pendingOrders = _orders.where((o) => o.status == 'pending').toList();
    
    if (pendingOrders.isEmpty) {
      debugPrint('✅ Nenhuma ordem pendente para reconciliar');
      return 0;
    }
    
    debugPrint('📋 ${pendingOrders.length} ordens pendentes encontradas');
    debugPrint('💰 ${breezPayments.length} pagamentos do Breez para verificar');
    
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
      debugPrint('   🔍 Ordem ${order.id.substring(0, 8)}: paymentHash=${order.paymentHash ?? 'NULL'}');
      
      // ÚNICO MÉTODO: Match por paymentHash (MAIS SEGURO)
      if (order.paymentHash != null && order.paymentHash!.isNotEmpty) {
        // Verificar se este hash não foi usado por outra ordem
        if (usedHashes.contains(order.paymentHash)) {
          debugPrint('   ⚠️ Hash ${order.paymentHash!.substring(0, 16)}... já usado por outra ordem');
          continue;
        }
        
        for (var payment in breezPayments) {
          final paymentHash = payment['paymentHash'] as String?;
          if (paymentHash == order.paymentHash) {
            final paymentAmount = (payment['amount'] is int) 
                ? payment['amount'] as int 
                : int.tryParse(payment['amount']?.toString() ?? '0') ?? 0;
            
            debugPrint('   ✅ MATCH EXATO por paymentHash!');
            
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
        // Ordem SEM paymentHash - NÃO fazer fallback por valor
        // Isso evita falsos positivos onde múltiplas ordens são marcadas com o mesmo pagamento
        debugPrint('   ⚠️ Ordem ${order.id.substring(0, 8)} sem paymentHash - ignorando');
        debugPrint('      (ordens antigas sem paymentHash precisam ser canceladas manualmente)');
      }
    }
    
    debugPrint('📊 Total reconciliado: $reconciled ordens');
    return reconciled;
  }

  /// Reconciliar ordens na inicialização - DESATIVADO
  /// NOTA: Esta função foi desativada pois causava falsos positivos de "payment_received"
  /// quando o usuário tinha saldo de outras transações na carteira.
  /// A reconciliação correta deve ser feita APENAS via evento do SDK Breez (PaymentSucceeded)
  /// que traz o paymentHash específico da invoice.
  Future<void> reconcileOnStartup(int currentBalanceSats) async {
    debugPrint('🔄 reconcileOnStartup DESATIVADO - reconciliação feita apenas via eventos do SDK');
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
    debugPrint('💰 OrderProvider.onPaymentReceived: $amountSats sats (hash: $paymentHash)');
    
    // Buscar ordens pendentes
    final pendingOrders = _orders.where((o) => o.status == 'pending').toList();
    
    if (pendingOrders.isEmpty) {
      debugPrint('📭 Nenhuma ordem pendente para atualizar');
      return;
    }
    
    debugPrint('🔍 Verificando ${pendingOrders.length} ordens pendentes...');
    
    // ÚNICO MÉTODO: Match EXATO por paymentHash (mais seguro)
    if (paymentHash != null && paymentHash.isNotEmpty) {
      for (final order in pendingOrders) {
        if (order.paymentHash == paymentHash) {
          debugPrint('   ✅ MATCH EXATO por paymentHash! Ordem ${order.id.substring(0, 8)}');
          
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
          
          debugPrint('✅ Ordem ${order.id.substring(0, 8)} atualizada e republicada no Nostr!');
          return;
        }
      }
      debugPrint('   ⚠️ PaymentHash $paymentHash não corresponde a nenhuma ordem pendente');
    }
    
    // NÃO fazer fallback por valor - isso causa falsos positivos
    // Se o paymentHash não corresponder, o pagamento não é para nenhuma ordem nossa
    debugPrint('❌ Pagamento de $amountSats sats (hash: $paymentHash) NÃO correspondeu a nenhuma ordem pendente');
    debugPrint('   (Isso pode ser um depósito manual ou pagamento não relacionado a ordens)');
  }

  /// Atualizar o paymentHash de uma ordem (chamado quando a invoice é gerada)
  Future<void> setOrderPaymentHash(String orderId, String paymentHash, String invoice) async {
    final index = _orders.indexWhere((o) => o.id == orderId);
    if (index == -1) {
      debugPrint('❌ Ordem $orderId não encontrada para definir paymentHash');
      return;
    }
    
    _orders[index] = _orders[index].copyWith(
      paymentHash: paymentHash,
      invoice: invoice,
    );
    
    await _saveOrders();
    
    // Republicar no Nostr com paymentHash
    await _publishOrderToNostr(_orders[index]);
    
    debugPrint('✅ PaymentHash definido para ordem $orderId: $paymentHash');
    notifyListeners();
  }

  // ==================== NOSTR INTEGRATION ====================
  
  /// Publicar ordem no Nostr (background)
  Future<void> _publishOrderToNostr(Order order) async {
    debugPrint('📤 Tentando publicar ordem no Nostr: ${order.id}');
    try {
      final privateKey = _nostrService.privateKey;
      if (privateKey == null) {
        debugPrint('⚠️ Sem chave privada Nostr, não publicando');
        return;
      }
      
      debugPrint('🔑 Chave privada encontrada, publicando...');
      final eventId = await _nostrOrderService.publishOrder(
        order: order,
        privateKey: privateKey,
      );
      
      if (eventId != null) {
        debugPrint('✅ Ordem publicada no Nostr com eventId: $eventId');
        
        // Atualizar ordem com eventId
        final index = _orders.indexWhere((o) => o.id == order.id);
        if (index != -1) {
          _orders[index] = _orders[index].copyWith(eventId: eventId);
          await _saveOrders();
        }
      } else {
        debugPrint('❌ Falha ao publicar ordem no Nostr (eventId null)');
      }
    } catch (e) {
      debugPrint('❌ Erro ao publicar ordem no Nostr: $e');
    }
  }

  /// Buscar ordens pendentes de todos os usuários (para providers verem)
  Future<List<Order>> fetchPendingOrdersFromNostr() async {
    try {
      debugPrint('🔍 Buscando ordens pendentes do Nostr...');
      final orders = await _nostrOrderService.fetchPendingOrders();
      debugPrint('📦 ${orders.length} ordens pendentes encontradas no Nostr');
      return orders;
    } catch (e) {
      debugPrint('❌ Erro ao buscar ordens do Nostr: $e');
      return [];
    }
  }

  /// Buscar histórico de ordens do usuário atual do Nostr
  Future<void> syncOrdersFromNostr() async {
    // Tentar pegar a pubkey do NostrService se não temos
    if (_currentUserPubkey == null || _currentUserPubkey!.isEmpty) {
      _currentUserPubkey = _nostrService.publicKey;
      debugPrint('🔑 Pubkey obtida do NostrService: ${_currentUserPubkey?.substring(0, 16) ?? 'null'}');
    }
    
    if (_currentUserPubkey == null || _currentUserPubkey!.isEmpty) {
      debugPrint('⚠️ Sem pubkey, não sincronizando do Nostr');
      return;
    }
    
    try {
      debugPrint('🔄 Sincronizando ordens do Nostr para pubkey: ${_currentUserPubkey!.substring(0, 16)}...');
      final nostrOrders = await _nostrOrderService.fetchUserOrders(_currentUserPubkey!);
      debugPrint('📦 Recebidas ${nostrOrders.length} ordens válidas do Nostr');
      
      // Mesclar ordens do Nostr com locais
      int added = 0;
      int updated = 0;
      int skipped = 0;
      for (var nostrOrder in nostrOrders) {
        // VALIDAÇÃO: Ignorar ordens com amount=0 vindas do Nostr
        // (já são filtradas em eventToOrder, mas double-check aqui)
        if (nostrOrder.amount <= 0) {
          debugPrint('⚠️ IGNORANDO ordem ${nostrOrder.id.substring(0, 8)} com amount=0');
          skipped++;
          continue;
        }
        
        // SEGURANÇA: Verificar se a ordem realmente pertence ao usuário atual
        if (nostrOrder.userPubkey != null && 
            nostrOrder.userPubkey!.isNotEmpty &&
            nostrOrder.userPubkey != _currentUserPubkey) {
          debugPrint('🚫 SEGURANÇA: Ordem ${nostrOrder.id.substring(0, 8)} é de outro usuário - ignorando');
          skipped++;
          continue;
        }
        
        final existingIndex = _orders.indexWhere((o) => o.id == nostrOrder.id);
        if (existingIndex == -1) {
          // Ordem não existe localmente, adicionar
          _orders.add(nostrOrder);
          added++;
          debugPrint('➕ Ordem ${nostrOrder.id.substring(0, 8)} recuperada do Nostr (R\$ ${nostrOrder.amount.toStringAsFixed(2)})');
        } else {
          // Ordem já existe, mesclar dados preservando os locais que não são 0
          final existing = _orders[existingIndex];
          
          // Se Nostr tem status mais recente, atualizar apenas o status
          // MAS manter amount/btcAmount/billCode locais se Nostr tem 0
          if (_isStatusMoreRecent(nostrOrder.status, existing.status) || 
              existing.amount == 0 && nostrOrder.amount > 0) {
            _orders[existingIndex] = existing.copyWith(
              status: _isStatusMoreRecent(nostrOrder.status, existing.status) 
                  ? nostrOrder.status 
                  : existing.status,
              // Preservar dados locais se Nostr tem 0
              amount: nostrOrder.amount > 0 ? nostrOrder.amount : existing.amount,
              btcAmount: nostrOrder.btcAmount > 0 ? nostrOrder.btcAmount : existing.btcAmount,
              btcPrice: nostrOrder.btcPrice > 0 ? nostrOrder.btcPrice : existing.btcPrice,
              total: nostrOrder.total > 0 ? nostrOrder.total : existing.total,
              billCode: nostrOrder.billCode.isNotEmpty ? nostrOrder.billCode : existing.billCode,
              providerId: nostrOrder.providerId ?? existing.providerId,
              eventId: nostrOrder.eventId ?? existing.eventId,
            );
            updated++;
            debugPrint('🔄 Ordem ${nostrOrder.id.substring(0, 8)} mesclada (preservando dados locais)');
          }
        }
      }
      
      // NOVO: Buscar atualizações de status (aceites e comprovantes de Bros)
      debugPrint('🔍 Buscando atualizações de status (aceites/comprovantes)...');
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
          
          // Verificar se o novo status é mais avançado
          if (_isStatusMoreRecent(newStatus, existing.status)) {
            _orders[existingIndex] = existing.copyWith(
              status: newStatus,
              providerId: update['providerId'] as String?,
              // Se for comprovante, salvar no metadata
              metadata: update['proofImage'] != null ? {
                ...?existing.metadata,
                'proofImage': update['proofImage'],
                'proofReceivedAt': DateTime.now().toIso8601String(),
              } : existing.metadata,
            );
            statusUpdated++;
            debugPrint('📥 Status atualizado: ${orderId.substring(0, 8)} -> $newStatus');
          }
        }
      }
      
      if (statusUpdated > 0) {
        debugPrint('✅ $statusUpdated ordens tiveram status atualizado');
      }
      
      // Ordenar por data (mais recente primeiro)
      _orders.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      
      await _saveOrders();
      notifyListeners();
      
      debugPrint('✅ Sincronização concluída: ${_orders.length} ordens totais');
      debugPrint('   Adicionadas: $added, Atualizadas: $updated, Status: $statusUpdated, Ignoradas(amount=0): $skipped');
    } catch (e) {
      debugPrint('❌ Erro ao sincronizar ordens do Nostr: $e');
    }
  }

  /// Verificar se um status é mais recente que outro
  bool _isStatusMoreRecent(String newStatus, String currentStatus) {
    // Ordem de progressão de status:
    // pending -> payment_received -> accepted -> awaiting_confirmation -> completed
    // (cancelled pode acontecer a qualquer momento)
    const statusOrder = [
      'pending', 
      'payment_received', 
      'accepted', 
      'processing',
      'awaiting_confirmation',  // Bro enviou comprovante, aguardando validação do usuário
      'completed', 
      'cancelled'
    ];
    final newIndex = statusOrder.indexOf(newStatus);
    final currentIndex = statusOrder.indexOf(currentStatus);
    
    // Se algum status não está na lista, considerar como não sendo mais recente
    if (newIndex == -1 || currentIndex == -1) return false;
    
    return newIndex > currentIndex;
  }

  /// Republicar ordens locais que não têm eventId no Nostr
  /// Útil para migrar ordens criadas antes da integração Nostr
  Future<int> republishLocalOrdersToNostr() async {
    final privateKey = _nostrService.privateKey;
    if (privateKey == null) {
      debugPrint('⚠️ Sem chave privada para republicar ordens');
      return 0;
    }
    
    int republished = 0;
    
    for (var order in _orders) {
      // Só republicar ordens que não têm eventId
      if (order.eventId == null || order.eventId!.isEmpty) {
        try {
          debugPrint('📤 Republicando ordem ${order.id.substring(0, 8)}...');
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
              debugPrint('✅ Ordem ${order.id.substring(0, 8)} republicada: $eventId');
            }
          }
        } catch (e) {
          debugPrint('⚠️ Erro ao republicar ordem ${order.id}: $e');
        }
      }
    }
    
    if (republished > 0) {
      await _saveOrders();
      notifyListeners();
    }
    
    debugPrint('📦 Total republicado: $republished ordens');
    return republished;
  }

  // ==================== AUTO RECONCILIATION ====================

  /// Reconciliação automática de ordens baseada em pagamentos do Breez SDK
  /// 
  /// Esta função analisa TODOS os pagamentos (recebidos e enviados) e atualiza
  /// os status das ordens automaticamente:
  /// 
  /// 1. Pagamentos RECEBIDOS → Atualiza ordens 'pending' para 'payment_received'
  ///    (usado quando o Bro paga via Lightning - menos comum no fluxo atual)
  /// 
  /// 2. Pagamentos ENVIADOS → Atualiza ordens 'awaiting_confirmation' para 'completed'
  ///    (quando o usuário liberou BTC para o Bro após confirmar prova de pagamento)
  /// 
  /// A identificação é feita por:
  /// - paymentHash (se disponível) - mais preciso
  /// - Valor aproximado + timestamp (fallback)
  Future<Map<String, int>> autoReconcileWithBreezPayments(List<Map<String, dynamic>> breezPayments) async {
    debugPrint('');
    debugPrint('═══════════════════════════════════════════════════════════════');
    debugPrint('🔄 RECONCILIAÇÃO AUTOMÁTICA DE ORDENS');
    debugPrint('═══════════════════════════════════════════════════════════════');
    
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
    
    debugPrint('📥 ${receivedPayments.length} pagamentos RECEBIDOS encontrados');
    debugPrint('📤 ${sentPayments.length} pagamentos ENVIADOS encontrados');
    debugPrint('📋 ${_orders.length} ordens no total');
    
    // ========== RECONCILIAR PAGAMENTOS RECEBIDOS ==========
    // (ordens pending que receberam pagamento)
    final pendingOrders = _orders.where((o) => o.status == 'pending').toList();
    debugPrint('\n🔍 Verificando ${pendingOrders.length} ordens PENDENTES...');
    
    for (final order in pendingOrders) {
      final expectedSats = (order.btcAmount * 100000000).toInt();
      debugPrint('   📋 Ordem ${order.id.substring(0, 8)}: esperado=$expectedSats sats, hash=${order.paymentHash ?? "null"}');
      
      // Tentar match por paymentHash primeiro (mais seguro)
      if (order.paymentHash != null && order.paymentHash!.isNotEmpty) {
        for (final payment in receivedPayments) {
          final paymentHash = payment['paymentHash']?.toString();
          if (paymentHash == order.paymentHash) {
            debugPrint('   ✅ MATCH por paymentHash! Atualizando para payment_received');
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
    // (ordens awaiting_confirmation onde o usuário já pagou o Bro)
    final awaitingOrders = _orders.where((o) => 
      o.status == 'awaiting_confirmation' || 
      o.status == 'accepted'
    ).toList();
    debugPrint('\n🔍 Verificando ${awaitingOrders.length} ordens AGUARDANDO CONFIRMAÇÃO/ACEITAS...');
    
    for (final order in awaitingOrders) {
      final expectedSats = (order.btcAmount * 100000000).toInt();
      debugPrint('   📋 Ordem ${order.id.substring(0, 8)}: status=${order.status}, esperado=$expectedSats sats');
      
      // Verificar se há um pagamento enviado com valor aproximado
      // Tolerância de 5% para taxas de rede
      for (final payment in sentPayments) {
        final paymentAmount = (payment['amount'] is int) 
            ? payment['amount'] as int 
            : int.tryParse(payment['amount']?.toString() ?? '0') ?? 0;
        
        final status = payment['status']?.toString() ?? '';
        
        // Só considerar pagamentos completados
        if (!status.toLowerCase().contains('completed') && 
            !status.toLowerCase().contains('complete')) {
          continue;
        }
        
        // Verificar se o valor está dentro da tolerância (5%)
        final tolerance = (expectedSats * 0.05).toInt();
        final diff = (paymentAmount - expectedSats).abs();
        
        if (diff <= tolerance) {
          debugPrint('   ✅ MATCH por valor! $paymentAmount sats ≈ $expectedSats sats (diff=$diff)');
          debugPrint('      Status da ordem: ${order.status} → completed');
          
          await updateOrderStatus(
            orderId: order.id,
            status: 'completed',
            metadata: {
              ...?order.metadata,
              'completedAt': DateTime.now().toIso8601String(),
              'reconciledFrom': 'auto_reconcile_sent',
              'paymentAmount': paymentAmount,
              'paymentId': payment['id'],
            },
          );
          completedReconciled++;
          break;
        }
      }
    }
    
    debugPrint('');
    debugPrint('═══════════════════════════════════════════════════════════════');
    debugPrint('📊 RESULTADO DA RECONCILIAÇÃO:');
    debugPrint('   - Ordens pending → payment_received: $pendingReconciled');
    debugPrint('   - Ordens awaiting → completed: $completedReconciled');
    debugPrint('═══════════════════════════════════════════════════════════════');
    debugPrint('');
    
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
  /// Usado para marcar ordens como completed automaticamente
  Future<void> onPaymentSent({
    required String paymentId,
    required int amountSats,
    String? paymentHash,
  }) async {
    debugPrint('💸 OrderProvider.onPaymentSent: $amountSats sats (hash: ${paymentHash ?? "N/A"})');
    
    // Buscar ordens aguardando confirmação que podem ter sido pagas
    final awaitingOrders = _orders.where((o) => 
      o.status == 'awaiting_confirmation' || 
      o.status == 'accepted'
    ).toList();
    
    if (awaitingOrders.isEmpty) {
      debugPrint('📭 Nenhuma ordem aguardando liberação de BTC');
      return;
    }
    
    debugPrint('🔍 Verificando ${awaitingOrders.length} ordens...');
    
    // Procurar ordem com valor correspondente
    for (final order in awaitingOrders) {
      final expectedSats = (order.btcAmount * 100000000).toInt();
      
      // Tolerância de 5% para taxas
      final tolerance = (expectedSats * 0.05).toInt();
      final diff = (amountSats - expectedSats).abs();
      
      if (diff <= tolerance) {
        debugPrint('✅ Ordem ${order.id.substring(0, 8)} corresponde ao pagamento!');
        debugPrint('   Valor esperado: $expectedSats sats, Valor enviado: $amountSats sats');
        
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
          },
        );
        
        // Republicar no Nostr com status completed
        final updatedOrder = _orders.firstWhere((o) => o.id == order.id);
        await _publishOrderToNostr(updatedOrder);
        
        debugPrint('✅ Ordem ${order.id.substring(0, 8)} marcada como COMPLETED!');
        return;
      }
    }
    
    debugPrint('❌ Pagamento de $amountSats sats não correspondeu a nenhuma ordem');
  }

  /// RECONCILIAÇÃO FORÇADA - Analisa TODAS as ordens e TODOS os pagamentos
  /// Use quando ordens antigas não estão sendo atualizadas automaticamente
  /// 
  /// Esta função é mais agressiva que autoReconcileWithBreezPayments:
  /// - Verifica TODAS as ordens não-completed (incluindo pending antigas)
  /// - Usa match por valor com tolerância maior (10%)
  /// - Cria lista de pagamentos usados para evitar duplicação
  Future<Map<String, dynamic>> forceReconcileAllOrders(List<Map<String, dynamic>> breezPayments) async {
    debugPrint('');
    debugPrint('╔═══════════════════════════════════════════════════════════════╗');
    debugPrint('║         🔥 RECONCILIAÇÃO FORÇADA DE TODAS AS ORDENS 🔥        ║');
    debugPrint('╚═══════════════════════════════════════════════════════════════╝');
    
    int updated = 0;
    final usedPaymentIds = <String>{};
    final reconciliationLog = <Map<String, dynamic>>[];
    
    // Listar todos os pagamentos
    debugPrint('\n📋 PAGAMENTOS NO BREEZ SDK:');
    for (final p in breezPayments) {
      final amount = p['amount'];
      final status = p['status']?.toString() ?? '';
      final type = p['type']?.toString() ?? '';
      final id = p['id']?.toString() ?? '';
      final direction = p['direction']?.toString() ?? type;
      debugPrint('   💳 $direction: $amount sats - $status - ID: ${id.substring(0, 16)}...');
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
    
    debugPrint('\n📊 RESUMO:');
    debugPrint('   📥 ${receivedPayments.length} pagamentos RECEBIDOS');
    debugPrint('   📤 ${sentPayments.length} pagamentos ENVIADOS');
    
    // Buscar TODAS as ordens não finalizadas
    final ordersToCheck = _orders.where((o) => 
      o.status != 'completed' && 
      o.status != 'cancelled'
    ).toList();
    
    debugPrint('\n📋 ORDENS PARA RECONCILIAR (${ordersToCheck.length}):');
    for (final order in ordersToCheck) {
      final sats = (order.btcAmount * 100000000).toInt();
      debugPrint('   📦 ${order.id.substring(0, 8)}: ${order.status} - R\$ ${order.amount.toStringAsFixed(2)} ($sats sats)');
    }
    
    // ========== VERIFICAR CADA ORDEM ==========
    debugPrint('\n🔍 INICIANDO RECONCILIAÇÃO...\n');
    
    for (final order in ordersToCheck) {
      final expectedSats = (order.btcAmount * 100000000).toInt();
      final orderId = order.id.substring(0, 8);
      
      debugPrint('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      debugPrint('📦 Ordem $orderId: ${order.status}');
      debugPrint('   Valor: R\$ ${order.amount.toStringAsFixed(2)} = $expectedSats sats');
      
      // Determinar qual lista de pagamentos verificar baseado no status
      List<Map<String, dynamic>> paymentsToCheck;
      String newStatus;
      
      if (order.status == 'pending' || order.status == 'payment_received') {
        // Para ordens pending - procurar em pagamentos RECEBIDOS
        // (no fluxo atual do Bro, isso é menos comum)
        paymentsToCheck = receivedPayments;
        newStatus = 'payment_received';
        debugPrint('   🔍 Buscando em ${paymentsToCheck.length} pagamentos RECEBIDOS...');
      } else {
        // Para ordens accepted/awaiting - procurar em pagamentos ENVIADOS
        paymentsToCheck = sentPayments;
        newStatus = 'completed';
        debugPrint('   🔍 Buscando em ${paymentsToCheck.length} pagamentos ENVIADOS...');
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
        
        debugPrint('   📊 Comparando: ordem=$expectedSats sats vs pagamento=$paymentAmount sats (diff=$diff, tol=$tolerance)');
        
        if (diff <= tolerance) {
          debugPrint('   ✅ MATCH ENCONTRADO!');
          
          // Marcar pagamento como usado
          usedPaymentIds.add(paymentId);
          
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
            },
          );
          
          reconciliationLog.add({
            'orderId': order.id,
            'oldStatus': order.status,
            'newStatus': newStatus,
            'paymentAmount': paymentAmount,
            'expectedAmount': expectedSats,
          });
          
          updated++;
          found = true;
          break;
        }
      }
      
      if (!found) {
        debugPrint('   ❌ Nenhum pagamento correspondente encontrado');
      }
    }
    
    debugPrint('');
    debugPrint('╔═══════════════════════════════════════════════════════════════╗');
    debugPrint('║                    📊 RESULTADO FINAL                         ║');
    debugPrint('╠═══════════════════════════════════════════════════════════════╣');
    debugPrint('║   Ordens atualizadas: $updated                                 ');
    debugPrint('╚═══════════════════════════════════════════════════════════════╝');
    
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
      debugPrint('❌ Ordem não encontrada: $orderId');
      return false;
    }
    
    final order = _orders[index];
    debugPrint('🔧 Forçando conclusão da ordem ${order.id.substring(0, 8)}');
    debugPrint('   Status atual: ${order.status}');
    
    _orders[index] = order.copyWith(
      status: 'completed',
      completedAt: DateTime.now(),
      metadata: {
        ...?order.metadata,
        'forcedCompleteAt': DateTime.now().toIso8601String(),
        'forcedBy': 'user_manual',
      },
    );
    
    await _saveOrders();
    
    // Republicar no Nostr
    await _publishOrderToNostr(_orders[index]);
    
    notifyListeners();
    debugPrint('✅ Ordem marcada como COMPLETED');
    return true;
  }
}
