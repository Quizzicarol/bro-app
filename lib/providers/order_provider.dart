import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../services/api_service.dart';
import '../services/nostr_service.dart';
import '../models/order.dart';
import '../config.dart';

class OrderProvider with ChangeNotifier {
  final ApiService _apiService = ApiService();
  final NostrService _nostrService = NostrService();

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
    
    if (AppConfig.testMode) {
      await _loadSavedOrders();
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
    
    if (AppConfig.testMode) {
      await _loadSavedOrders();
    }
    
    _isInitialized = true;
    notifyListeners();
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
      // Test mode: criar ordem local
      if (AppConfig.testMode) {
        debugPrint('🧪 TEST MODE: Criando ordem local');
        
        // Calcular taxas (5% provider + 2% platform)
        final providerFee = amount * 0.05;
        final platformFee = amount * 0.02;
        final total = amount + providerFee + platformFee;
        
        final order = Order(
          id: const Uuid().v4(),
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
    // Em modo teste, não buscar do backend (manter ordens locais)
    if (AppConfig.testMode) {
      debugPrint('📦 Modo teste: não buscando ordens do backend (mantendo locais)');
      return;
    }
    
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final ordersData = await _apiService.listOrders(status: status);
      _orders = ordersData.map((data) => Order.fromJson(data)).toList();
    } catch (e) {
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
}
