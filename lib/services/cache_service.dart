import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/order.dart';

/// Serviço de cache para dados offline
/// Permite acessar histórico e dados mesmo sem internet
class CacheService {
  static final CacheService _instance = CacheService._internal();
  factory CacheService() => _instance;
  CacheService._internal();

  SharedPreferences? _prefs;
  
  // Chaves de cache
  static const String _keyBtcPrice = 'cache_btc_price';
  static const String _keyBtcPriceTime = 'cache_btc_price_time';
  static const String _keyOrders = 'cache_orders';
  static const String _keyOrdersTime = 'cache_orders_time';
  static const String _keyUserProfile = 'cache_user_profile';
  static const String _keyNostrProfiles = 'cache_nostr_profiles';
  
  // Tempos de expiração (em minutos)
  static const int _btcPriceExpiry = 5; // 5 minutos
  static const int _ordersExpiry = 60; // 1 hora
  static const int _profileExpiry = 1440; // 24 horas
  
  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }
  
  Future<SharedPreferences> get prefs async {
    await init();
    return _prefs!;
  }

  // ============================================
  // PREÇO DO BITCOIN
  // ============================================
  
  /// Salva preço do Bitcoin no cache
  Future<void> cacheBtcPrice(double price) async {
    final p = await prefs;
    await p.setDouble(_keyBtcPrice, price);
    await p.setInt(_keyBtcPriceTime, DateTime.now().millisecondsSinceEpoch);
    broLog('💾 BTC price cached: R\$ ${price.toStringAsFixed(2)}');
  }
  
  /// Obtém preço do Bitcoin do cache (se não expirado)
  Future<double?> getCachedBtcPrice() async {
    final p = await prefs;
    final cacheTime = p.getInt(_keyBtcPriceTime);
    
    if (cacheTime == null) return null;
    
    final cacheDate = DateTime.fromMillisecondsSinceEpoch(cacheTime);
    final isExpired = DateTime.now().difference(cacheDate).inMinutes > _btcPriceExpiry;
    
    if (isExpired) {
      broLog('⏰ BTC price cache expired');
      return null;
    }
    
    final price = p.getDouble(_keyBtcPrice);
    broLog('📦 BTC price from cache: R\$ ${price?.toStringAsFixed(2)}');
    return price;
  }

  // ============================================
  // HISTÓRICO DE ORDENS
  // ============================================
  
  /// Salva ordens no cache para acesso offline
  Future<void> cacheOrders(List<Order> orders) async {
    final p = await prefs;
    final ordersJson = orders.map((o) => o.toJson()).toList();
    await p.setString(_keyOrders, jsonEncode(ordersJson));
    await p.setInt(_keyOrdersTime, DateTime.now().millisecondsSinceEpoch);
    broLog('💾 ${orders.length} orders cached');
  }
  
  /// Obtém ordens do cache
  Future<List<Order>?> getCachedOrders({bool ignoreExpiry = false}) async {
    final p = await prefs;
    final cacheTime = p.getInt(_keyOrdersTime);
    
    if (cacheTime == null) return null;
    
    if (!ignoreExpiry) {
      final cacheDate = DateTime.fromMillisecondsSinceEpoch(cacheTime);
      final isExpired = DateTime.now().difference(cacheDate).inMinutes > _ordersExpiry;
      
      if (isExpired) {
        broLog('⏰ Orders cache expired');
        return null;
      }
    }
    
    final ordersString = p.getString(_keyOrders);
    if (ordersString == null) return null;
    
    try {
      final ordersJson = jsonDecode(ordersString) as List;
      final orders = ordersJson.map((json) => Order.fromJson(json)).toList();
      broLog('📦 ${orders.length} orders from cache');
      return orders;
    } catch (e) {
      broLog('❌ Error parsing cached orders: $e');
      return null;
    }
  }
  
  /// Adiciona uma ordem ao cache existente
  Future<void> addOrderToCache(Order order) async {
    final cachedOrders = await getCachedOrders(ignoreExpiry: true) ?? [];
    
    // Remove ordem existente com mesmo ID (se houver)
    cachedOrders.removeWhere((o) => o.id == order.id);
    
    // Adiciona nova ordem no início
    cachedOrders.insert(0, order);
    
    // Mantém apenas as últimas 100 ordens
    final trimmedOrders = cachedOrders.take(100).toList();
    
    await cacheOrders(trimmedOrders);
  }
  
  /// Atualiza uma ordem específica no cache
  Future<void> updateOrderInCache(String orderId, String newStatus) async {
    final cachedOrders = await getCachedOrders(ignoreExpiry: true);
    if (cachedOrders == null) return;
    
    final index = cachedOrders.indexWhere((o) => o.id == orderId);
    if (index == -1) return;
    
    // Cria copia com novo status
    final updatedOrder = Order(
      id: cachedOrders[index].id,
      billType: cachedOrders[index].billType,
      billCode: cachedOrders[index].billCode,
      amount: cachedOrders[index].amount,
      btcAmount: cachedOrders[index].btcAmount,
      btcPrice: cachedOrders[index].btcPrice,
      status: newStatus,
      createdAt: cachedOrders[index].createdAt,
      providerFee: cachedOrders[index].providerFee,
      platformFee: cachedOrders[index].platformFee,
      total: cachedOrders[index].total,
    );
    
    cachedOrders[index] = updatedOrder;
    await cacheOrders(cachedOrders);
    broLog('📝 Order $orderId updated in cache to $newStatus');
  }

  // ============================================
  // PERFIS NOSTR
  // ============================================
  
  /// Salva perfil Nostr no cache
  Future<void> cacheNostrProfile(String pubkey, Map<String, dynamic> profile) async {
    final p = await prefs;
    final profiles = await _getNostrProfilesMap();
    profiles[pubkey] = {
      'profile': profile,
      'cachedAt': DateTime.now().millisecondsSinceEpoch,
    };
    await p.setString(_keyNostrProfiles, jsonEncode(profiles));
    broLog('💾 Nostr profile cached: ${pubkey.substring(0, 8)}...');
  }
  
  /// Obtém perfil Nostr do cache
  Future<Map<String, dynamic>?> getCachedNostrProfile(String pubkey) async {
    final profiles = await _getNostrProfilesMap();
    final entry = profiles[pubkey];
    
    if (entry == null) return null;
    
    final cachedAt = entry['cachedAt'] as int;
    final cacheDate = DateTime.fromMillisecondsSinceEpoch(cachedAt);
    final isExpired = DateTime.now().difference(cacheDate).inMinutes > _profileExpiry;
    
    if (isExpired) {
      broLog('⏰ Nostr profile cache expired: ${pubkey.substring(0, 8)}...');
      return null;
    }
    
    return entry['profile'] as Map<String, dynamic>?;
  }
  
  Future<Map<String, dynamic>> _getNostrProfilesMap() async {
    final p = await prefs;
    final profilesString = p.getString(_keyNostrProfiles);
    if (profilesString == null) return {};
    
    try {
      return Map<String, dynamic>.from(jsonDecode(profilesString));
    } catch (e) {
      return {};
    }
  }

  // ============================================
  // UTILIDADES
  // ============================================
  
  /// Limpa todo o cache
  Future<void> clearAll() async {
    final p = await prefs;
    await p.remove(_keyBtcPrice);
    await p.remove(_keyBtcPriceTime);
    await p.remove(_keyOrders);
    await p.remove(_keyOrdersTime);
    await p.remove(_keyUserProfile);
    await p.remove(_keyNostrProfiles);
    broLog('🗑️ All cache cleared');
  }
  
  /// Obtém tamanho estimado do cache
  Future<String> getCacheSize() async {
    final p = await prefs;
    int totalBytes = 0;
    
    for (final key in p.getKeys()) {
      if (key.startsWith('cache_')) {
        final value = p.getString(key);
        if (value != null) {
          totalBytes += value.length;
        }
      }
    }
    
    if (totalBytes < 1024) {
      return '$totalBytes bytes';
    } else if (totalBytes < 1024 * 1024) {
      return '${(totalBytes / 1024).toStringAsFixed(1)} KB';
    } else {
      return '${(totalBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
  }
  
  /// Retorna data/hora do último cache de ordens
  Future<DateTime?> getOrdersCacheTime() async {
    final p = await prefs;
    final cacheTime = p.getInt(_keyOrdersTime);
    if (cacheTime == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(cacheTime);
  }
}
