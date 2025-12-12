import 'package:flutter/foundation.dart';
import '../models/collateral_tier.dart';
import '../services/escrow_service.dart';
import '../services/bitcoin_price_service.dart';
import 'package:breez_sdk_spark_flutter/breez_sdk_spark.dart' as spark;

/// Provider para gerenciar garantias (collateral) dos provedores
class CollateralProvider with ChangeNotifier {
  final EscrowService _escrowService = EscrowService();
  final BitcoinPriceService _priceService = BitcoinPriceService();

  Map<String, dynamic>? _collateral;
  List<CollateralTier>? _availableTiers;
  double? _btcPriceBrl;
  bool _isLoading = false;
  String? _error;

  Map<String, dynamic>? get collateral => _collateral;
  List<CollateralTier>? get availableTiers => _availableTiers;
  double? get btcPriceBrl => _btcPriceBrl;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get hasCollateral => _collateral != null;

  /// Inicializar: carrega preço do Bitcoin e garantia do provedor
  Future<void> initialize(String providerId) async {
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

      // Carregar garantia do provedor
      _collateral = await _escrowService.getProviderCollateral(providerId);
      if (_collateral != null) {
        final totalCollateral = _collateral!['total_collateral'] ?? 0;
        debugPrint('✅ Garantia carregada: $totalCollateral sats');
      } else {
        debugPrint('📭 Provedor não possui garantia depositada');
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

  /// Depositar garantia (criar invoice)
  Future<Map<String, dynamic>?> depositCollateral({
    required String providerId,
    required String tierId,
    required spark.BreezSdk sdk,
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
      
      debugPrint('💳 Depositando garantia para tier: ${tier.name}');
      debugPrint('   Valor: ${tier.requiredCollateralSats} sats (R\$ ${tier.requiredCollateralBrl})');

      // Criar invoice
      final result = await _escrowService.depositCollateral(
        tierId: tierId,
        amountSats: tier.requiredCollateralSats,
      );

      debugPrint('✅ Invoice criada: ${result['invoice']}');
      
      _isLoading = false;
      notifyListeners();
      
      return result;
    } catch (e) {
      debugPrint('❌ Erro ao depositar garantia: $e');
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
      return null;
    }
  }

  /// Atualizar garantia do provedor
  Future<void> refreshCollateral(String providerId) async {
    try {
      _collateral = await _escrowService.getProviderCollateral(providerId);
      notifyListeners();
    } catch (e) {
      debugPrint('❌ Erro ao atualizar garantia: $e');
    }
  }

  /// Verificar se pode aceitar uma ordem
  bool canAcceptOrder(double orderValueBrl) {
    if (_collateral == null || _btcPriceBrl == null) return false;
    // Simplificado: sempre retornar true em modo teste
    return true;
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
