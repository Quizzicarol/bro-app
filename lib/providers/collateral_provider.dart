import 'package:bro_app/services/log_utils.dart';
import 'package:flutter/foundation.dart';
import '../models/collateral_tier.dart';
import '../services/bitcoin_price_service.dart';
import '../services/local_collateral_service.dart';
import '../services/nostr_service.dart';
import '../services/nostr_order_service.dart';
import '../services/error_utils.dart';

/// Provider para gerenciar garantias (collateral) dos provedores
/// Usa sistema local de garantia (fundos ficam na carteira do próprio provedor)
class CollateralProvider with ChangeNotifier {
  final BitcoinPriceService _priceService = BitcoinPriceService();
  final LocalCollateralService _localCollateralService = LocalCollateralService();

  Map<String, dynamic>? _collateral;
  List<CollateralTier>? _availableTiers;
  double? _btcPriceBrl;
  bool _isLoading = false;
  String? _error;
  LocalCollateral? _localCollateral; // Sistema local de garantia
  int _walletBalanceSats = 0; // Saldo atual da carteira
  int _committedSats = 0; // Sats comprometidos com ordens pendentes (modo cliente)

  Map<String, dynamic>? get collateral => _collateral;
  List<CollateralTier>? get availableTiers => _availableTiers;
  double? get btcPriceBrl => _btcPriceBrl;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get hasCollateral => _collateral != null || _localCollateral != null;
  LocalCollateral? get localCollateral => _localCollateral;
  int get walletBalanceSats => _walletBalanceSats;
  
  /// Saldo EFETIVAMENTE disponível para garantia = carteira - comprometido
  int get effectiveBalanceSats => (_walletBalanceSats - _committedSats).clamp(0, _walletBalanceSats);
  
  int get availableBalanceSats => _localCollateral != null 
      ? _localCollateralService.getAvailableBalance(_localCollateral!, effectiveBalanceSats)
      : effectiveBalanceSats;

  /// Inicializar: carrega preço do Bitcoin e garantia do provedor
  /// IMPORTANTE: committedSats deve conter os sats comprometidos com ordens pendentes do modo cliente
  Future<void> initialize(String providerId, {int? walletBalance, int? committedSats}) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      // v658: iOS LENTO — o tier "desligava" ao entrar no modo Bro porque o
      // initialize() esperava a REDE (preço do BTC) antes de ativar o tier.
      // Como o tier fica salvo LOCALMENTE, carregamos a garantia local PRIMEIRO
      // e ativamos o tier com um preço em cache/fallback (sem esperar a rede).
      // O preço real é buscado em background e recalcula os tiers depois.
      final nostrService = NostrService();
      final pubkey = nostrService.publicKey;
      broLog('🔑 CollateralProvider: carregando tier para pubkey: ${pubkey?.substring(0, 8) ?? "null"}');
      _localCollateralService.setCurrentUser(pubkey);

      // 1. Carregar garantia LOCAL imediatamente (não depende de rede)
      _localCollateral = await _localCollateralService.getCollateral(userPubkey: pubkey);

      // 1b. Registrar saldo e sats comprometidos ANTES de aplicar a garantia
      //     (effectiveBalanceSats depende deles para o available_amount).
      if (walletBalance != null) {
        _walletBalanceSats = walletBalance;
        broLog('💳 Saldo da carteira: $_walletBalanceSats sats');
      }
      if (committedSats != null) {
        _committedSats = committedSats;
        broLog('🔒 Sats comprometidos: $_committedSats sats');
      }

      // 2. Ativar o tier IMEDIATAMENTE com um preço em cache/fallback.
      //    Usa o último preço conhecido (static cache) ou um fallback seguro.
      //    O tier ID e os sats travados NÃO dependem do preço — só os limites
      //    em BRL dependem. Melhor ativar com preço aproximado do que deixar
      //    o tier desligado esperando a rede.
      final cachedPrice = BitcoinPriceService.lastKnownBrlPrice ?? 500000.0; // fallback R$500k
      _btcPriceBrl = cachedPrice;
      _availableTiers = CollateralTier.getAvailableTiers(cachedPrice);
      _applyLocalCollateral();
      _isLoading = false;
      notifyListeners(); // tier ativo AGORA, sem esperar a rede

      // 3. Buscar o preço REAL em background e recalcular (não bloqueia o tier)
      _refreshPriceInBackground();

      // 4. Se não tem garantia local, tentar restaurar do Nostr (background)
      if (_localCollateral == null) {
        broLog('📭 Garantia local não encontrada, buscando no Nostr...');
        await _tryRestoreFromNostr();
        _applyLocalCollateral();
        notifyListeners();
      }
    } catch (e) {
      broLog('❌ Erro ao inicializar CollateralProvider: $e');
      _error = humanizeError(e);
      _isLoading = false;
      notifyListeners();
    }
  }

  /// v658: aplica a garantia local ao formato legado _collateral (compat UI).
  void _applyLocalCollateral() {
    if (_localCollateral != null) {
      broLog('✅ Garantia local carregada: ${_localCollateral!.tierName}');
      _collateral = {
        'current_tier_id': _localCollateral!.tierId,
        'total_collateral': _localCollateral!.lockedSats,
        'locked_amount': _localCollateral!.lockedSats,
        'available_amount': _localCollateralService.getAvailableBalance(_localCollateral!, effectiveBalanceSats),
      };
    } else {
      broLog('📭 Provedor não possui garantia configurada');
      _collateral = null;
    }
  }

  /// v658: busca o preço real do BTC em background e recalcula os tiers.
  /// NÃO bloqueia a ativação do tier — só refina os limites em BRL.
  Future<void> _refreshPriceInBackground() async {
    try {
      final price = await _priceService.getBitcoinPrice();
      if (price != null && price > 0) {
        _btcPriceBrl = price;
        _availableTiers = CollateralTier.getAvailableTiers(price);
        broLog('💰 Preço BTC atualizado em background: R\$ $price');
        _applyLocalCollateral();
        notifyListeners();
      }
    } catch (e) {
      broLog('⚠️ refresh de preço em background falhou (mantendo cache): $e');
    }
  }

  /// Tenta restaurar tier do Nostr quando não encontrado localmente
  Future<void> _tryRestoreFromNostr() async {
    try {
      final nostrService = NostrService();
      final nostrOrderService = NostrOrderService();
      
      final publicKey = nostrService.publicKey;
      if (publicKey == null) {
        broLog('⚠️ PublicKey não disponível para buscar tier no Nostr');
        return;
      }
      
      broLog('🔍 Buscando tier no Nostr para pubkey: $publicKey');
      
      final tierData = await nostrOrderService.fetchProviderTier(publicKey);
      
      if (tierData != null) {
        broLog('✅ Tier encontrado no Nostr: ${tierData['tierName']}');
        
        // Restaurar tier localmente
        _localCollateral = await _localCollateralService.setCollateral(
          tierId: tierData['tierId'],
          tierName: tierData['tierName'],
          requiredSats: tierData['depositedSats'],
          maxOrderBrl: (tierData['maxOrderValue'] as num).toDouble(),
        );
        
        broLog('✅ Tier restaurado do Nostr e salvo localmente');
      } else {
        broLog('📭 Nenhum tier encontrado no Nostr');
      }
    } catch (e) {
      broLog('⚠️ Erro ao buscar tier do Nostr: $e');
    }
  }

  /// Atualizar saldo da carteira
  void updateWalletBalance(int balanceSats) {
    _walletBalanceSats = balanceSats;
    broLog('💳 Saldo atualizado: $_walletBalanceSats sats');
    notifyListeners();
  }

  /// Depositar garantia (SISTEMA LOCAL: trava fundos na carteira do provedor)
  Future<Map<String, dynamic>?> depositCollateral({
    required String providerId,
    required String tierId,
    required int walletBalanceSats,
  }) async {
    if (_availableTiers == null || _btcPriceBrl == null) {
      _error = 'Dados não carregados. Chame initialize() primeiro.';
      notifyListeners();
      return null;
    }

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      // Encontrar tier selecionado
      final tier = _availableTiers!.firstWhere((t) => t.id == tierId);
      
      broLog('💳 Configurando garantia para tier: ${tier.name}');
      broLog('   Valor: ${tier.requiredCollateralSats} sats (R\$ ${tier.requiredCollateralBrl})');

      // Atualizar e verificar saldo da carteira
      _walletBalanceSats = walletBalanceSats;
      
      if (_walletBalanceSats < tier.requiredCollateralSats) {
        _error = 'Saldo insuficiente. Você tem $_walletBalanceSats sats, mas precisa de ${tier.requiredCollateralSats} sats para o tier ${tier.name}.';
        _isLoading = false;
        notifyListeners();
        return null;
      }

      // SISTEMA LOCAL: Salvar garantia localmente (os fundos ficam na carteira)
      _localCollateral = await _localCollateralService.setCollateral(
        tierId: tierId,
        tierName: tier.name,
        requiredSats: tier.requiredCollateralSats,
        maxOrderBrl: tier.maxOrderValueBrl,
      );
      
      // Converter para formato legado
      _collateral = {
        'current_tier_id': tierId,
        'total_collateral': tier.requiredCollateralSats,
        'locked_amount': tier.requiredCollateralSats,
        'available_amount': _localCollateralService.getAvailableBalance(_localCollateral!, _walletBalanceSats),
      };

      broLog('✅ Garantia configurada! Tier: ${tier.name}');
      broLog('   Sats "travados": ${tier.requiredCollateralSats}');
      broLog('   Máximo por ordem: R\$ ${tier.maxOrderValueBrl}');
      
      _isLoading = false;
      notifyListeners();
      
      return {
        'success': true,
        'tier': tier.name,
        'locked_sats': tier.requiredCollateralSats,
        'max_order_brl': tier.maxOrderValueBrl,
      };
    } catch (e) {
      broLog('❌ Erro ao configurar garantia: $e');
      _error = humanizeError(e);
      _isLoading = false;
      notifyListeners();
      return null;
    }
  }

  /// Atualizar garantia do provedor
  Future<void> refreshCollateral(String providerId, {int? walletBalance}) async {
    try {
      // Atualizar saldo da carteira se fornecido
      if (walletBalance != null) {
        _walletBalanceSats = walletBalance;
      }
      
      // Recarregar garantia local
      _localCollateral = await _localCollateralService.getCollateral();
      
      if (_localCollateral != null) {
        _collateral = {
          'current_tier_id': _localCollateral!.tierId,
          'total_collateral': _localCollateral!.lockedSats,
          'locked_amount': _localCollateral!.lockedSats,
          'available_amount': _localCollateralService.getAvailableBalance(_localCollateral!, _walletBalanceSats),
        };
      }
      
      notifyListeners();
    } catch (e) {
      broLog('❌ Erro ao atualizar garantia: $e');
    }
  }

  /// Verificar se pode aceitar uma ordem (sistema local)
  bool canAcceptOrder(double orderValueBrl) {
    // Se tem garantia local, usar sistema local
    if (_localCollateral != null) {
      // IMPORTANTE: Usar effectiveBalanceSats (carteira - sats comprometidos com ordens cliente)
      final canAccept = _localCollateralService.canAcceptOrder(_localCollateral!, orderValueBrl, effectiveBalanceSats);
      broLog('📊 canAcceptOrder (local): R\$ $orderValueBrl -> ${canAccept ? "✅" : "❌"}');
      broLog('   Saldo efetivo: $effectiveBalanceSats sats (total: $_walletBalanceSats, comprometido: $_committedSats)');
      broLog('   Tier ${_localCollateral!.tierName} requer: ${_localCollateral!.lockedSats} sats');
      return canAccept;
    }
    
    // Fallback: sem garantia
    broLog('❌ canAcceptOrder: Sem garantia configurada');
    return false;
  }

  /// Verificar se pode aceitar uma ordem e retornar razão se não puder
  (bool, String?) canAcceptOrderWithReason(double orderValueBrl) {
    if (_localCollateral != null) {
      return _localCollateralService.canAcceptOrderWithReason(
        _localCollateral!,
        orderValueBrl,
        effectiveBalanceSats,
      );
    }
    return (false, 'Sem tier ativo. Configure um tier para aceitar ordens.');
  }

  /// Travar saldo para uma ordem específica
  Future<bool> lockForOrder(String orderId, double orderValueBrl) async {
    if (_localCollateral == null) return false;
    
    _localCollateral = await _localCollateralService.lockForOrder(_localCollateral!, orderId);
    notifyListeners();
    return true;
  }

  /// Destravar saldo quando ordem for concluída/cancelada
  Future<bool> unlockOrder(String orderId) async {
    if (_localCollateral == null) return false;
    
    _localCollateral = await _localCollateralService.unlockOrder(_localCollateral!, orderId);
    notifyListeners();
    return true;
  }

  /// Verificar se pode sacar (sem ordens em aberto)
  bool canWithdraw() {
    if (_localCollateral == null) return true;
    return _localCollateralService.canWithdraw(_localCollateral!);
  }

  /// Remover garantia (liberar para saque)
  Future<bool> removeCollateral() async {
    if (_localCollateral == null) return true;
    
    if (!canWithdraw()) {
      _error = 'Você tem ordens em aberto. Finalize-as antes de remover a garantia.';
      notifyListeners();
      return false;
    }
    
    await _localCollateralService.withdrawAll();
    _localCollateral = null;
    _collateral = null;
    notifyListeners();
    return true;
  }
  
  /// Retorna o valor máximo de ordem que o provedor pode aceitar
  double getMaxOrderValue() {
    final currentTier = getCurrentTier();
    return currentTier?.maxOrderValueBrl ?? 0.0;
  }
  
  /// Retorna mensagem explicativa se não pode aceitar ordem
  String? getCannotAcceptReason(double orderValueBrl) {
    if (_collateral == null) {
      return 'Você precisa depositar uma garantia para aceitar ordens.';
    }
    
    final currentTier = getCurrentTier();
    if (currentTier == null) {
      return 'Deposite uma garantia para desbloquear seu tier.';
    }
    
    if (orderValueBrl > currentTier.maxOrderValueBrl) {
      // Encontrar tier necessário
      final requiredTier = getRequiredTier(orderValueBrl);
      if (requiredTier != null) {
        return 'Seu tier ${currentTier.name} aceita ordens até R\$ ${currentTier.maxOrderValueBrl.toStringAsFixed(0)}.\n\nPara aceitar esta ordem de R\$ ${orderValueBrl.toStringAsFixed(2)}, faça upgrade para o tier ${requiredTier.name}.';
      }
      return 'Esta ordem está acima do seu limite. Faça upgrade de tier.';
    }
    
    return null; // Pode aceitar
  }

  /// Obter tier atual do provedor
  CollateralTier? getCurrentTier() {
    if (_collateral == null || _availableTiers == null) return null;
    
    final currentTierId = _collateral!['current_tier_id'];
    return _availableTiers!.firstWhere(
      (tier) => tier.id == currentTierId,
      orElse: () => _availableTiers!.first,
    );
  }

  /// Obter tier necessário para um valor de ordem
  CollateralTier? getRequiredTier(double orderValueBrl) {
    if (_availableTiers == null || _btcPriceBrl == null) return null;
    return CollateralTier.getTierForOrderValue(orderValueBrl, _btcPriceBrl!);
  }

  /// Limpar erro
  void clearError() {
    _error = null;
    notifyListeners();
  }
}
