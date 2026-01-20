import 'package:flutter/foundation.dart';
import '../models/collateral_tier.dart';
import '../services/bitcoin_price_service.dart';
import '../services/local_collateral_service.dart';
import '../services/nostr_service.dart';
import '../services/nostr_order_service.dart';

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
      // Carregar preço do Bitcoin
      _btcPriceBrl = await _priceService.getBitcoinPrice();
      debugPrint('💰 Preço do Bitcoin: R\$ $_btcPriceBrl');

      if (_btcPriceBrl == null) {
        throw Exception('Não foi possível obter o preço do Bitcoin');
      }

      // Carregar tiers disponíveis
      _availableTiers = CollateralTier.getAvailableTiers(_btcPriceBrl!);
      debugPrint('📊 Tiers disponíveis: ${_availableTiers!.length}');

      // Usar saldo da carteira se fornecido
      if (walletBalance != null) {
        _walletBalanceSats = walletBalance;
        debugPrint('💳 Saldo da carteira: $_walletBalanceSats sats');
      }
      
      // Registrar sats comprometidos com ordens pendentes
      if (committedSats != null) {
        _committedSats = committedSats;
        debugPrint('🔒 Sats comprometidos (ordens pendentes): $_committedSats sats');
        debugPrint('💰 Saldo efetivo para garantia: $effectiveBalanceSats sats');
      }

      // IMPORTANTE: Limpar cache para forçar releitura do storage
      // Isso garante que sempre temos os dados mais recentes ao entrar no modo Bro
      LocalCollateralService.clearCache();
      
      // SISTEMA LOCAL: Carregar garantia local (fundos ficam na carteira do provedor)
      _localCollateral = await _localCollateralService.getCollateral();
      
      // Se não tem garantia local, tentar buscar do Nostr
      if (_localCollateral == null) {
        debugPrint('📭 Garantia local não encontrada, buscando no Nostr...');
        await _tryRestoreFromNostr();
      }
      
      if (_localCollateral != null) {
        debugPrint('✅ Garantia local carregada: ${_localCollateral!.tierName}');
        debugPrint('   Sats travados: ${_localCollateral!.lockedSats}');
        debugPrint('   Ordens ativas: ${_localCollateral!.activeOrders}');
        
        // Converter garantia local para formato legado (compatibilidade)
        // IMPORTANTE: Usar effectiveBalanceSats ao invés de _walletBalanceSats
        _collateral = {
          'current_tier_id': _localCollateral!.tierId,
          'total_collateral': _localCollateral!.lockedSats,
          'locked_amount': _localCollateral!.lockedSats,
          'available_amount': _localCollateralService.getAvailableBalance(_localCollateral!, effectiveBalanceSats),
        };
      } else {
        debugPrint('📭 Provedor não possui garantia configurada');
        _collateral = null;
      }

      _isLoading = false;
      notifyListeners();
    } catch (e) {
      debugPrint('❌ Erro ao inicializar CollateralProvider: $e');
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Tenta restaurar tier do Nostr quando não encontrado localmente
  Future<void> _tryRestoreFromNostr() async {
    try {
      final nostrService = NostrService();
      final nostrOrderService = NostrOrderService();
      
      final publicKey = nostrService.publicKey;
      if (publicKey == null) {
        debugPrint('⚠️ PublicKey não disponível para buscar tier no Nostr');
        return;
      }
      
      debugPrint('🔍 Buscando tier no Nostr para pubkey: $publicKey');
      
      final tierData = await nostrOrderService.fetchProviderTier(publicKey);
      
      if (tierData != null) {
        debugPrint('✅ Tier encontrado no Nostr: ${tierData['tierName']}');
        
        // Restaurar tier localmente
        _localCollateral = await _localCollateralService.setCollateral(
          tierId: tierData['tierId'],
          tierName: tierData['tierName'],
          requiredSats: tierData['depositedSats'],
          maxOrderBrl: (tierData['maxOrderValue'] as num).toDouble(),
        );
        
        debugPrint('✅ Tier restaurado do Nostr e salvo localmente');
      } else {
        debugPrint('📭 Nenhum tier encontrado no Nostr');
      }
    } catch (e) {
      debugPrint('⚠️ Erro ao buscar tier do Nostr: $e');
    }
  }

  /// Atualizar saldo da carteira
  void updateWalletBalance(int balanceSats) {
    _walletBalanceSats = balanceSats;
    debugPrint('💳 Saldo atualizado: $_walletBalanceSats sats');
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
      
      debugPrint('💳 Configurando garantia para tier: ${tier.name}');
      debugPrint('   Valor: ${tier.requiredCollateralSats} sats (R\$ ${tier.requiredCollateralBrl})');

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

      debugPrint('✅ Garantia configurada! Tier: ${tier.name}');
      debugPrint('   Sats "travados": ${tier.requiredCollateralSats}');
      debugPrint('   Máximo por ordem: R\$ ${tier.maxOrderValueBrl}');
      
      _isLoading = false;
      notifyListeners();
      
      return {
        'success': true,
        'tier': tier.name,
        'locked_sats': tier.requiredCollateralSats,
        'max_order_brl': tier.maxOrderValueBrl,
      };
    } catch (e) {
      debugPrint('❌ Erro ao configurar garantia: $e');
      _error = e.toString();
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
      debugPrint('❌ Erro ao atualizar garantia: $e');
    }
  }

  /// Verificar se pode aceitar uma ordem (sistema local)
  bool canAcceptOrder(double orderValueBrl) {
    // Se tem garantia local, usar sistema local
    if (_localCollateral != null) {
      // IMPORTANTE: Usar effectiveBalanceSats (carteira - sats comprometidos com ordens cliente)
      final canAccept = _localCollateralService.canAcceptOrder(_localCollateral!, orderValueBrl, effectiveBalanceSats);
      debugPrint('📊 canAcceptOrder (local): R\$ $orderValueBrl -> ${canAccept ? "✅" : "❌"}');
      debugPrint('   Saldo efetivo: $effectiveBalanceSats sats (total: $_walletBalanceSats, comprometido: $_committedSats)');
      debugPrint('   Tier ${_localCollateral!.tierName} requer: ${_localCollateral!.lockedSats} sats');
      return canAccept;
    }
    
    // Fallback: sem garantia
    debugPrint('❌ canAcceptOrder: Sem garantia configurada');
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
