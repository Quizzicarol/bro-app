import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Modelo de garantia local
class LocalCollateral {
  final String tierId;
  final String tierName;
  final int requiredSats;
  final int lockedSats;
  final int activeOrders;
  final double maxOrderBrl;
  final DateTime createdAt;
  final DateTime updatedAt;

  LocalCollateral({
    required this.tierId,
    required this.tierName,
    required this.requiredSats,
    required this.lockedSats,
    required this.activeOrders,
    required this.maxOrderBrl,
    required this.createdAt,
    required this.updatedAt,
  });

  factory LocalCollateral.fromJson(Map<String, dynamic> json) {
    return LocalCollateral(
      tierId: json['tier_id'] ?? '',
      tierName: json['tier_name'] ?? '',
      requiredSats: json['required_sats'] ?? 0,
      lockedSats: json['locked_sats'] ?? 0,
      activeOrders: json['active_orders'] ?? 0,
      maxOrderBrl: (json['max_order_brl'] ?? 0).toDouble(),
      createdAt: DateTime.tryParse(json['created_at'] ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(json['updated_at'] ?? '') ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'tier_id': tierId,
      'tier_name': tierName,
      'required_sats': requiredSats,
      'locked_sats': lockedSats,
      'active_orders': activeOrders,
      'max_order_brl': maxOrderBrl,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  LocalCollateral copyWith({
    String? tierId,
    String? tierName,
    int? requiredSats,
    int? lockedSats,
    int? activeOrders,
    double? maxOrderBrl,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return LocalCollateral(
      tierId: tierId ?? this.tierId,
      tierName: tierName ?? this.tierName,
      requiredSats: requiredSats ?? this.requiredSats,
      lockedSats: lockedSats ?? this.lockedSats,
      activeOrders: activeOrders ?? this.activeOrders,
      maxOrderBrl: maxOrderBrl ?? this.maxOrderBrl,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }
}

/// Serviço para gerenciar garantia LOCAL do provedor
/// A garantia é uma "reserva contábil" - o provedor precisa manter esse saldo
/// na carteira para poder aceitar ordens.
/// 
/// Fluxo:
/// 1. Provedor escolhe um tier e "deposita" (reserva sats da própria carteira)
/// 2. Enquanto tiver a garantia reservada, pode aceitar ordens até o limite do tier
/// 3. Quando aceita uma ordem, parte da garantia fica "travada" para aquela ordem
/// 4. Se a ordem for concluída com sucesso, a garantia é liberada
/// 5. Se houver disputa e o provedor perder, a garantia é confiscada
/// 6. Provedor pode "sacar" (remover reserva) se não tiver ordens em aberto
class LocalCollateralService {
  static const String _collateralKey = 'local_collateral';
  static final FlutterSecureStorage _storage = const FlutterSecureStorage();
  
  // Cache em memória para garantir consistência
  static LocalCollateral? _cachedCollateral;
  static bool _cacheInitialized = false;

  /// Configurar garantia para um tier
  Future<LocalCollateral> setCollateral({
    required String tierId,
    required String tierName,
    required int requiredSats,
    required double maxOrderBrl,
  }) async {
    final collateral = LocalCollateral(
      tierId: tierId,
      tierName: tierName,
      requiredSats: requiredSats,
      lockedSats: requiredSats, // Trava o valor requerido
      activeOrders: 0,
      maxOrderBrl: maxOrderBrl,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    
    final jsonStr = json.encode(collateral.toJson());
    debugPrint('💾 setCollateral: Salvando tier $tierName ($requiredSats sats)');
    debugPrint('💾 setCollateral: JSON=$jsonStr');
    
    await _storage.write(key: _collateralKey, value: jsonStr);
    debugPrint('💾 setCollateral: Salvo no FlutterSecureStorage');
    
    // IMPORTANTE: Atualizar cache em memória
    _cachedCollateral = collateral;
    _cacheInitialized = true;
    debugPrint('💾 setCollateral: Cache atualizado');
    
    // Verificar se realmente salvou
    final verify = await _storage.read(key: _collateralKey);
    debugPrint('💾 setCollateral: Verificação pós-save: ${verify != null ? "OK" : "FALHOU"}');
    
    return collateral;
  }

  /// Obter garantia atual
  Future<LocalCollateral?> getCollateral() async {
    try {
      // Se cache já foi inicializado, usar cache
      if (_cacheInitialized && _cachedCollateral != null) {
        debugPrint('🔍 getCollateral: Usando cache - ${_cachedCollateral!.tierName}');
        return _cachedCollateral;
      }
      
      final dataStr = await _storage.read(key: _collateralKey);
      
      debugPrint('🔍 getCollateral: key=$_collateralKey');
      debugPrint('🔍 getCollateral: dataStr=${dataStr?.substring(0, (dataStr?.length ?? 0).clamp(0, 100)) ?? "null"}...');
      
      if (dataStr == null) {
        debugPrint('📭 getCollateral: Nenhuma garantia salva');
        _cacheInitialized = true; // Marcar como inicializado mesmo se null
        return null;
      }
      
      final collateral = LocalCollateral.fromJson(json.decode(dataStr));
      // Atualizar cache
      _cachedCollateral = collateral;
      _cacheInitialized = true;
      debugPrint('✅ getCollateral: Tier ${collateral.tierName} (${collateral.requiredSats} sats) - Cache atualizado');
      return collateral;
    } catch (e) {
      debugPrint('❌ Erro ao carregar garantia local: $e');
      return null;
    }
  }

  /// Verificar se tem garantia configurada
  Future<bool> hasCollateral() async {
    // Verificar cache primeiro
    if (_cacheInitialized) {
      return _cachedCollateral != null;
    }
    final collateral = await getCollateral();
    return collateral != null;
  }
  
  /// Limpar cache (para forçar reload do SharedPreferences)
  static void clearCache() {
    _cachedCollateral = null;
    _cacheInitialized = false;
    debugPrint('🗑️ Cache de collateral limpo');
  }

  /// Verificar se pode aceitar uma ordem de determinado valor
  /// Retorna (canAccept, reason) - reason explica porque não pode aceitar
  (bool, String?) canAcceptOrderWithReason(LocalCollateral collateral, double orderValueBrl, int walletBalanceSats) {
    // Verificar se carteira tem saldo suficiente para a garantia
    if (walletBalanceSats < collateral.lockedSats) {
      final deficit = collateral.lockedSats - walletBalanceSats;
      debugPrint('❌ canAcceptOrder: Saldo insuficiente ($walletBalanceSats < ${collateral.lockedSats})');
      return (false, 'Saldo insuficiente: faltam $deficit sats para manter o tier ${collateral.tierName}');
    }
    
    // Verificar se valor da ordem está dentro do limite do tier
    if (orderValueBrl > collateral.maxOrderBrl) {
      debugPrint('❌ canAcceptOrder: Ordem R\$ $orderValueBrl > limite R\$ ${collateral.maxOrderBrl}');
      return (false, 'Ordem acima do limite do tier (máx R\$ ${collateral.maxOrderBrl.toStringAsFixed(0)})');
    }
    
    debugPrint('✅ canAcceptOrder: OK');
    return (true, null);
  }

  /// Verificar se pode aceitar uma ordem de determinado valor (mantido para compatibilidade)
  bool canAcceptOrder(LocalCollateral collateral, double orderValueBrl, int walletBalanceSats) {
    final (canAccept, _) = canAcceptOrderWithReason(collateral, orderValueBrl, walletBalanceSats);
    return canAccept;
  }

  /// Travar garantia para uma ordem
  Future<LocalCollateral> lockForOrder(LocalCollateral collateral, String orderId) async {
    final updated = collateral.copyWith(
      activeOrders: collateral.activeOrders + 1,
    );
    
    await _storage.write(key: _collateralKey, value: json.encode(updated.toJson()));
    _cachedCollateral = updated;
    
    debugPrint('🔒 Ordem $orderId travada. Total ordens: ${updated.activeOrders}');
    return updated;
  }

  /// Destravar garantia de uma ordem
  Future<LocalCollateral> unlockOrder(LocalCollateral collateral, String orderId) async {
    final newActiveOrders = collateral.activeOrders > 0 ? collateral.activeOrders - 1 : 0;
    
    final updated = collateral.copyWith(
      activeOrders: newActiveOrders,
    );
    
    await _storage.write(key: _collateralKey, value: json.encode(updated.toJson()));
    _cachedCollateral = updated;
    
    debugPrint('🔓 Ordem $orderId liberada. Total ordens: ${updated.activeOrders}');
    return updated;
  }

  /// Obter saldo disponível (carteira - travado)
  int getAvailableBalance(LocalCollateral collateral, int walletBalanceSats) {
    final available = walletBalanceSats - collateral.lockedSats;
    return available > 0 ? available : 0;
  }

  /// Verificar se pode sacar (remover garantia)
  bool canWithdraw(LocalCollateral collateral) {
    return collateral.activeOrders == 0;
  }

  /// Remover garantia completamente
  Future<void> withdrawAll() async {
    await _storage.delete(key: _collateralKey);
    _cachedCollateral = null;
    _cacheInitialized = false;
    debugPrint('✅ Garantia local removida');
  }
}
