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
    
    // Carregar ordens locais primeiro
    if (AppConfig.testMode) {
      await _loadSavedOrders();
    }
    
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
    
    // Carregar ordens locais primeiro
    if (AppConfig.testMode) {
      await _loadSavedOrders();
      debugPrint('📦 ${_orders.length} ordens locais carregadas');
    }
    
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

  // Salvar ordens no SharedPreferences
  Future<void> _saveOrders() async {
    if (!AppConfig.testMode) return;
    
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

  // Criar ordem
  Future<Order?> createOrder({
    required String billType,
    required String billCode,
    required double amount,
    required double btcAmount,
    required double btcPrice,
  }) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      // Test mode: criar ordem local e publicar no Nostr
      if (AppConfig.testMode) {
        debugPrint('🧪 TEST MODE: Criando ordem local');
        
        // Calcular taxas (5% provider + 2% platform)
        final providerFee = amount * 0.05;
        final platformFee = amount * 0.02;
        final total = amount + providerFee + platformFee;
        
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
          status: 'pending',
          createdAt: DateTime.now(),
        );
        
        _orders.insert(0, order);
        _currentOrder = order;
        await _saveOrders(); // Salvar após criar
        notifyListeners();
        
        // Publicar no Nostr (em background)
        _publishOrderToNostr(order);
        
        debugPrint('✅ Ordem local criada: ${order.id}');
        return order;
      }
      
      // Produção: usar API
      final response = await _apiService.createOrder(
        billType: billType,
        billCode: billCode,
        amount: amount,
        btcAmount: btcAmount,
        btcPrice: btcPrice,
      );

      if (response != null && response['success'] == true) {
        final order = Order.fromJson(response['order']);
        _orders.insert(0, order);
        _currentOrder = order;
        notifyListeners();
        return order;
      }

      return null;
    } catch (e) {
      _error = e.toString();
      debugPrint('❌ Erro ao criar ordem: $e');
      return null;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // Listar ordens
  Future<void> fetchOrders({String? status}) async {
    // Em modo teste, sincronizar com Nostr ao invés do backend
    if (AppConfig.testMode) {
      debugPrint('📦 Modo teste: sincronizando ordens com Nostr...');
      _isLoading = true;
      notifyListeners();
      
      try {
        await syncOrdersFromNostr();
        debugPrint('✅ Sincronização com Nostr concluída');
      } catch (e) {
        debugPrint('❌ Erro ao sincronizar com Nostr: $e');
      } finally {
        _isLoading = false;
        notifyListeners();
      }
      return;
    }
    
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final ordersData = await _apiService.listOrders(status: status);
      _orders = ordersData.map((data) => Order.fromJson(data)).toList();
    } catch (e) {
      debugPrint('❌ Erro ao buscar ordens: $e');
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
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

  // Atualizar status local (modo teste)
  Future<void> updateOrderStatusLocal(String orderId, String status) async {
    final index = _orders.indexWhere((o) => o.id == orderId);
    if (index != -1) {
      _orders[index] = _orders[index].copyWith(status: status);
      await _saveOrders();
      notifyListeners();
      debugPrint('💾 Ordem $orderId atualizada para status: $status');
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
      // Em modo teste, atualizar localmente
      if (AppConfig.testMode) {
        final index = _orders.indexWhere((o) => o.id == orderId);
        if (index != -1) {
          // Usar copyWith para manter dados existentes
          _orders[index] = _orders[index].copyWith(
            status: status,
            providerId: providerId,
            metadata: metadata,
            acceptedAt: status == 'accepted' ? DateTime.now() : _orders[index].acceptedAt,
            completedAt: status == 'completed' ? DateTime.now() : _orders[index].completedAt,
          );
          await _saveOrders();
          debugPrint('💾 Ordem $orderId atualizada: status=$status, providerId=$providerId');
        } else {
          debugPrint('⚠️ Ordem $orderId não encontrada para atualizar');
        }
        
        _isLoading = false;
        notifyListeners();
        return true;
      }
      
      // Produção: usar API
      final success = await _apiService.updateOrderStatus(
        orderId: orderId,
        status: status,
        providerId: providerId,
        metadata: metadata,
      );

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
      // Em modo teste, buscar localmente
      if (AppConfig.testMode) {
        final order = _orders.firstWhere(
          (o) => o.id == orderId,
          orElse: () => throw Exception('Ordem não encontrada'),
        );
        return order.toJson();
      }
      
      // Produção: buscar do backend
      final orderData = await _apiService.getOrder(orderId);
      return orderData;
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

  /// Reconciliar pagamentos automaticamente
  /// Quando um pagamento é recebido, atualiza a ordem pendente correspondente
  Future<void> onPaymentReceived({
    required String paymentId,
    required int amountSats,
  }) async {
    debugPrint('🔄 RECONCILIAÇÃO AUTOMÁTICA: Pagamento recebido!');
    debugPrint('   PaymentId: $paymentId');
    debugPrint('   Valor: $amountSats sats');
    
    // Buscar ordens pendentes que correspondem ao valor
    final pendingOrders = _orders.where((o) => o.status == 'pending').toList();
    
    if (pendingOrders.isEmpty) {
      debugPrint('⚠️ Nenhuma ordem pendente para reconciliar');
      return;
    }
    
    debugPrint('📋 ${pendingOrders.length} ordens pendentes encontradas');
    
    // Encontrar a ordem mais recente que corresponde ao valor (com tolerância)
    for (var order in pendingOrders) {
      // Calcular sats esperado para esta ordem (usando btcAmount que já está em sats)
      final expectedSats = (order.btcAmount * 100000000).toInt(); // btcAmount em BTC -> sats
      final tolerance = (expectedSats * 0.05).toInt(); // 5% tolerância
      
      debugPrint('   Ordem ${order.id.substring(0, 8)}: espera ~$expectedSats sats (btcAmount=${order.btcAmount})');
      
      // Verificar se o valor corresponde (com tolerância)
      if ((amountSats >= expectedSats - tolerance) && (amountSats <= expectedSats + tolerance)) {
        debugPrint('✅ MATCH! Atualizando ordem ${order.id} para payment_received');
        
        await updateOrderStatus(
          orderId: order.id,
          status: 'payment_received',
          metadata: {
            'paymentId': paymentId,
            'amountSats': amountSats,
            'reconciledAt': DateTime.now().toIso8601String(),
          },
        );
        return; // Reconciliou uma ordem, sair
      }
    }
    
    // Se não encontrou correspondência exata, atualizar a ordem pendente mais recente
    if (pendingOrders.isNotEmpty) {
      final latestOrder = pendingOrders.first; // Já ordenado do mais recente para o mais antigo
      debugPrint('⚠️ Nenhuma correspondência exata. Atualizando ordem mais recente: ${latestOrder.id}');
      
      await updateOrderStatus(
        orderId: latestOrder.id,
        status: 'payment_received',
        metadata: {
          'paymentId': paymentId,
          'amountSats': amountSats,
          'reconciledAt': DateTime.now().toIso8601String(),
          'note': 'Reconciliação por proximidade temporal',
        },
      );
    }
  }

  /// Reconciliar ordens na inicialização (verificar se há saldo que deveria ter atualizado uma ordem)
  Future<void> reconcileOnStartup(int currentBalanceSats) async {
    debugPrint('🔄 Verificando ordens pendentes na inicialização...');
    debugPrint('   Saldo atual: $currentBalanceSats sats');
    
    if (currentBalanceSats <= 0) {
      debugPrint('   Saldo zero, nada para reconciliar');
      return;
    }
    
    final pendingOrders = _orders.where((o) => o.status == 'pending').toList();
    
    if (pendingOrders.isEmpty) {
      debugPrint('   Nenhuma ordem pendente');
      return;
    }
    
    debugPrint('📋 ${pendingOrders.length} ordens pendentes encontradas');
    
    // Verificar cada ordem pendente
    for (var order in pendingOrders) {
      final expectedSats = (order.btcAmount * 100000000).toInt();
      
      debugPrint('   Ordem ${order.id.substring(0, 8)}: espera $expectedSats sats');
      
      // Se o saldo atual é >= ao esperado pela ordem, provavelmente o pagamento foi recebido
      if (currentBalanceSats >= expectedSats) {
        debugPrint('✅ Saldo suficiente! Reconciliando ordem ${order.id}');
        
        await updateOrderStatus(
          orderId: order.id,
          status: 'payment_received',
          metadata: {
            'reconciledOnStartup': true,
            'reconciledAt': DateTime.now().toIso8601String(),
            'balanceAtReconciliation': currentBalanceSats,
          },
        );
        
        // Subtrair o valor reconciliado para verificar outras ordens
        currentBalanceSats -= expectedSats;
        
        if (currentBalanceSats <= 0) break;
      }
    }
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
      debugPrint('📦 Recebidas ${nostrOrders.length} ordens do Nostr');
      
      // Mesclar ordens do Nostr com locais
      int added = 0;
      int updated = 0;
      for (var nostrOrder in nostrOrders) {
        final existingIndex = _orders.indexWhere((o) => o.id == nostrOrder.id);
        if (existingIndex == -1) {
          // Ordem não existe localmente, adicionar
          _orders.add(nostrOrder);
          added++;
          debugPrint('➕ Ordem ${nostrOrder.id.substring(0, 8)} recuperada do Nostr');
        } else {
          // Ordem já existe, verificar se Nostr tem status mais recente
          final existing = _orders[existingIndex];
          if (_isStatusMoreRecent(nostrOrder.status, existing.status)) {
            _orders[existingIndex] = nostrOrder;
            updated++;
            debugPrint('🔄 Ordem ${nostrOrder.id.substring(0, 8)} atualizada do Nostr');
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
      
      debugPrint('✅ Sincronização concluída: ${_orders.length} ordens totais (adicionadas: $added, atualizadas: $updated, status: $statusUpdated)');
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

  /// Aceitar ordem como provider (publica evento de aceitação no Nostr)
  Future<bool> acceptOrderAsProvider(String orderId) async {
    final privateKey = _nostrService.privateKey;
    if (privateKey == null) {
      debugPrint('⚠️ Sem chave privada para aceitar ordem');
      return false;
    }
    
    try {
      // Buscar ordem
      final order = getOrderById(orderId);
      if (order == null) {
        debugPrint('⚠️ Ordem não encontrada: $orderId');
        return false;
      }
      
      // Publicar aceitação no Nostr
      final success = await _nostrOrderService.acceptOrderOnNostr(
        order: order,
        providerPrivateKey: privateKey,
      );
      
      if (success) {
        // Atualizar localmente
        await updateOrderStatus(
          orderId: orderId,
          status: 'accepted',
          providerId: _currentUserPubkey,
        );
        debugPrint('✅ Ordem aceita: $orderId');
        return true;
      }
      
      return false;
    } catch (e) {
      debugPrint('❌ Erro ao aceitar ordem: $e');
      return false;
    }
  }

  /// Completar ordem como provider (publica prova no Nostr)
  Future<bool> completeOrderAsProvider(String orderId, String proofImageBase64) async {
    final privateKey = _nostrService.privateKey;
    if (privateKey == null) {
      debugPrint('⚠️ Sem chave privada para completar ordem');
      return false;
    }
    
    try {
      // Buscar ordem
      final order = getOrderById(orderId);
      if (order == null) {
        debugPrint('⚠️ Ordem não encontrada: $orderId');
        return false;
      }
      
      // Publicar prova no Nostr
      final success = await _nostrOrderService.completeOrderOnNostr(
        order: order,
        providerPrivateKey: privateKey,
        proofImageBase64: proofImageBase64,
      );
      
      if (success) {
        // Atualizar localmente - status vai para 'awaiting_confirmation'
        // O status 'completed' só deve ser usado quando o USUÁRIO confirmar o pagamento
        await updateOrderStatus(
          orderId: orderId,
          status: 'awaiting_confirmation',
          metadata: {
            'proofSentAt': DateTime.now().toIso8601String(),
            'proofSentBy': _currentUserPubkey,
          },
        );
        debugPrint('✅ Comprovante enviado, aguardando confirmação do usuário: $orderId');
        return true;
      }
      
      return false;
    } catch (e) {
      debugPrint('❌ Erro ao completar ordem: $e');
      return false;
    }
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
}
