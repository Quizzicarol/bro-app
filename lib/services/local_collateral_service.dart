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
/// ⚠️ IMPORTANTE: Dados são isolados POR USUÁRIO usando pubkey!
/// Isso evita vazamento de dados de tier entre usuários diferentes.
/// 
/// Fluxo:
/// 1. Provedor escolhe um tier e "deposita" (reserva sats da própria carteira)
/// 2. Enquanto tiver a garantia reservada, pode aceitar ordens até o limite do tier
/// 3. Quando aceita uma ordem, parte da garantia fica "travada" para aquela ordem
/// 4. Se a ordem for concluída com sucesso, a garantia é liberada
/// 5. Se houver disputa e o provedor perder, a garantia é confiscada
/// 6. Provedor pode "sacar" (remover reserva) se não tiver ordens em aberto
class LocalCollateralService {
  static const String _collateralKeyBase = 'local_collateral';
  static const String _legacyCollateralKey = 'local_collateral'; // Chave antiga (sem pubkey)
  static final FlutterSecureStorage _storage = const FlutterSecureStorage();
  
  // Cache em memória para garantir consistência POR USUÁRIO
  static LocalCollateral? _cachedCollateral;
  static bool _cacheInitialized = false;
  static String? _cachedUserPubkey; // Para invalidar cache quando usuário muda
  
  /// Gera a chave de storage para um usuário específico
  static String _getKeyForUser(String? pubkey) {
    if (pubkey == null || pubkey.isEmpty) {
      return _legacyCollateralKey;
    }
    // Usar primeiros 16 chars do pubkey para a chave
    final shortKey = pubkey.length > 16 ? pubkey.substring(0, 16) : pubkey;
    return '${_collateralKeyBase}_$shortKey';
  }
  
  /// Define o usuário atual e limpa cache se necessário
  void setCurrentUser(String? pubkey) {
    if (_cachedUserPubkey != pubkey) {
      debugPrint('🔄 LocalCollateralService: Usuário mudou de ${_cachedUserPubkey?.substring(0, 8) ?? "null"} para ${pubkey?.substring(0, 8) ?? "null"}');
      _cachedCollateral = null;
      _cacheInitialized = false;
      _cachedUserPubkey = pubkey;
    }
  }

  /// Configurar garantia para um tier
  Future<LocalCollateral> setCollateral({
    required String tierId,
    required String tierName,
    required int requiredSats,
    required double maxOrderBrl,
    String? userPubkey,
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
    
    final key = _getKeyForUser(userPubkey ?? _cachedUserPubkey);
    final jsonStr = json.encode(collateral.toJson());
    debugPrint('💾 setCollateral: Salvando tier $tierName ($requiredSats sats) para key=$key');
    debugPrint('💾 setCollateral: JSON=$jsonStr');
    
    await _storage.write(key: key, value: jsonStr);
    debugPrint('💾 setCollateral: Salvo no FlutterSecureStorage');
    
    // IMPORTANTE: Atualizar cache em memória
    _cachedCollateral = collateral;
    _cacheInitialized = true;
    _cachedUserPubkey = userPubkey ?? _cachedUserPubkey;
    debugPrint('💾 setCollateral: Cache atualizado para user ${_cachedUserPubkey?.substring(0, 8) ?? "null"}');
    
    // Verificar se realmente salvou
    final verify = await _storage.read(key: key);
    debugPrint('💾 setCollateral: Verificação pós-save: ${verify != null ? "OK" : "FALHOU"}');
    
    return collateral;
  }

  /// Obter garantia atual do usuário
  Future<LocalCollateral?> getCollateral({String? userPubkey}) async {
    try {
      final effectivePubkey = userPubkey ?? _cachedUserPubkey;
      
      // Se cache é para este usuário e já foi inicializado
      if (_cacheInitialized && _cachedUserPubkey == effectivePubkey && _cachedCollateral != null) {
        debugPrint('🔍 getCollateral: Usando cache - ${_cachedCollateral!.tierName}');
        return _cachedCollateral;
      }
      
      // SEMPRE tentar ler do storage para garantir dados mais recentes
      final key = _getKeyForUser(effectivePubkey);
      final dataStr = await _storage.read(key: key);
      
      debugPrint('🔍 getCollateral: key=$key');
      debugPrint('🔍 getCollateral: dataStr=${dataStr?.substring(0, (dataStr?.length ?? 0).clamp(0, 100)) ?? "null"}...');
      
      if (dataStr == null) {
        debugPrint('📭 getCollateral: Nenhuma garantia salva para usuário ${effectivePubkey?.substring(0, 8) ?? "null"}');
        _cacheInitialized = true;
        _cachedCollateral = null;
        _cachedUserPubkey = effectivePubkey;
        return null;
      }
      
      final collateral = LocalCollateral.fromJson(json.decode(dataStr));
      // Atualizar cache
      _cachedCollateral = collateral;
      _cacheInitialized = true;
      _cachedUserPubkey = effectivePubkey;
      debugPrint('✅ getCollateral: Tier ${collateral.tierName} (${collateral.requiredSats} sats) - Cache atualizado');
      return collateral;
    } catch (e) {
      debugPrint('❌ Erro ao carregar garantia local: $e');
      return null;
    }
  }

  /// Verificar se tem garantia configurada
  Future<bool> hasCollateral({String? userPubkey}) async {
    // Se cache é para este usuário
    final effectivePubkey = userPubkey ?? _cachedUserPubkey;
    if (_cacheInitialized && _cachedUserPubkey == effectivePubkey) {
      return _cachedCollateral != null;
    }
    final collateral = await getCollateral(userPubkey: userPubkey);
    return collateral != null;
  }
  
  /// Limpar cache (para forçar reload)
  static void clearCache() {
    _cachedCollateral = null;
    _cacheInitialized = false;
    _cachedUserPubkey = null;
    debugPrint('🗑️ Cache de collateral limpo');
  }
  
  /// 🧹 Limpar dados de colateral do usuário atual (para logout)
  Future<void> clearUserCollateral({String? userPubkey}) async {
    final key = _getKeyForUser(userPubkey ?? _cachedUserPubkey);
    await _storage.delete(key: key);
    debugPrint('🗑️ Collateral removido para key=$key');
    
    // Também limpar chave legada se existir
    await _storage.delete(key: _legacyCollateralKey);
    debugPrint('🗑️ Collateral legado removido');
    
    clearCache();
  }

  /// Verificar se pode aceitar uma ordem de determinado valor
  /// Retorna (canAccept, reason) - reason explica porque não pode aceitar
  (bool, String?) canAcceptOrderWithReason(LocalCollateral collateral, double orderValueBrl, int walletBalanceSats) {
    // Primeiro verificar se valor da ordem está dentro do limite do tier
    if (orderValueBrl > collateral.maxOrderBrl) {
      debugPrint('❌ canAcceptOrder: Ordem R\$ $orderValueBrl > limite R\$ ${collateral.maxOrderBrl}');
      return (false, 'Ordem acima do limite do tier (máx R\$ ${collateral.maxOrderBrl.toStringAsFixed(0)})');
    }
    
    // 🔥 TOLERÂNCIA DE 10% - Permitir pequenas oscilações do Bitcoin
    final tolerancePercent = 0.10; // 10%
    final minRequired = (collateral.lockedSats * (1 - tolerancePercent)).round();
    
    // Verificar se carteira tem saldo suficiente (com tolerância)
    if (walletBalanceSats < minRequired) {
      final deficit = collateral.lockedSats - walletBalanceSats;
      debugPrint('❌ canAcceptOrder: Saldo insuficiente ($walletBalanceSats < $minRequired com tolerância 10%)');
      return (false, 'Saldo insuficiente: faltam $deficit sats para manter o tier ${collateral.tierName}');
    }
    
    debugPrint('✅ canAcceptOrder: OK - ordem R\$ $orderValueBrl (limite R\$ ${collateral.maxOrderBrl})');
    return (true, null);
  }

  /// Verificar se pode aceitar uma ordem de determinado valor (mantido para compatibilidade)
  bool canAcceptOrder(LocalCollateral collateral, double orderValueBrl, int walletBalanceSats) {
    final (canAccept, _) = canAcceptOrderWithReason(collateral, orderValueBrl, walletBalanceSats);
    return canAccept;
  }

  /// Travar garantia para uma ordem
  Future<LocalCollateral> lockForOrder(LocalCollateral collateral, String orderId, {String? userPubkey}) async {
    final updated = collateral.copyWith(
      activeOrders: collateral.activeOrders + 1,
    );
    
    final key = _getKeyForUser(userPubkey ?? _cachedUserPubkey);
    await _storage.write(key: key, value: json.encode(updated.toJson()));
    _cachedCollateral = updated;
    
    debugPrint('🔒 Ordem $orderId travada. Total ordens: ${updated.activeOrders}');
    return updated;
  }

  /// Destravar garantia de uma ordem
  Future<LocalCollateral> unlockOrder(LocalCollateral collateral, String orderId, {String? userPubkey}) async {
    final newActiveOrders = collateral.activeOrders > 0 ? collateral.activeOrders - 1 : 0;
    
    final updated = collateral.copyWith(
      activeOrders: newActiveOrders,
    );
    
    final key = _getKeyForUser(userPubkey ?? _cachedUserPubkey);
    await _storage.write(key: key, value: json.encode(updated.toJson()));
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
  Future<void> withdrawAll({String? userPubkey}) async {
    final key = _getKeyForUser(userPubkey ?? _cachedUserPubkey);
    await _storage.delete(key: key);
    _cachedCollateral = null;
    _cacheInitialized = false;
    debugPrint('✅ Garantia local removida para key=$key');
  }
}
