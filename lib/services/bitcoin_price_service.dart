import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';

/// ServiÃ§o para buscar preÃ§o real do Bitcoin de APIs pÃºblicas
class BitcoinPriceService {
  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
  ));

  /// Busca preÃ§o do Bitcoin em BRL de mÃºltiplas fontes
  static Future<double?> getBitcoinPriceInBRL() async {
    // Tentar Coinbase primeiro
    final coinbasePrice = await _getCoinbasePrice();
    if (coinbasePrice != null) return coinbasePrice;

    // Fallback: Binance
    final binancePrice = await _getBinancePrice();
    if (binancePrice != null) return binancePrice;

    // Fallback: CoinGecko
    final coingeckoPrice = await _getCoingeckoPrice();
    if (coingeckoPrice != null) return coingeckoPrice;

    debugPrint('âŒ NÃ£o foi possÃ­vel buscar preÃ§o do Bitcoin de nenhuma fonte');
    return null;
  }

  /// Coinbase API (mais confiÃ¡vel)
  static Future<double?> _getCoinbasePrice() async {
    try {
      debugPrint('ðŸ“¡ Buscando preÃ§o Bitcoin na Coinbase...');
      final response = await _dio.get('https://api.coinbase.com/v2/exchange-rates?currency=BTC');
      
      final rates = response.data['data']['rates'];
      final brlRate = rates['BRL'];
      
      if (brlRate != null) {
        final price = double.parse(brlRate.toString());
        debugPrint('âœ… Coinbase: R\$ ${price.toStringAsFixed(2)}');
        return price;
      }
    } catch (e) {
      debugPrint('âš ï¸ Erro ao buscar preÃ§o na Coinbase: $e');
    }
    return null;
  }

  /// Binance API
  static Future<double?> _getBinancePrice() async {
    try {
      debugPrint('ðŸ“¡ Buscando preÃ§o Bitcoin na Binance...');
      
      // Buscar BTC/USDT
      final btcUsdtResponse = await _dio.get('https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT');
      final btcUsdt = double.parse(btcUsdtResponse.data['price']);
      
      // Buscar USDT/BRL
      final usdtBrlResponse = await _dio.get('https://api.binance.com/api/v3/ticker/price?symbol=USDTBRL');
      final usdtBrl = double.parse(usdtBrlResponse.data['price']);
      
      final btcBrl = btcUsdt * usdtBrl;
      debugPrint('âœ… Binance: R\$ ${btcBrl.toStringAsFixed(2)}');
      return btcBrl;
    } catch (e) {
      debugPrint('âš ï¸ Erro ao buscar preÃ§o na Binance: $e');
    }
    return null;
  }

  /// CoinGecko API (free, sem autenticaÃ§Ã£o)
  static Future<double?> _getCoingeckoPrice() async {
    try {
      debugPrint('ðŸ“¡ Buscando preÃ§o Bitcoin no CoinGecko...');
      final response = await _dio.get(
        'https://api.coingecko.com/api/v3/simple/price',
        queryParameters: {
          'ids': 'bitcoin',
          'vs_currencies': 'brl',
        },
      );
      
      final price = response.data['bitcoin']['brl'];
      if (price != null) {
        final priceDouble = double.parse(price.toString());
        debugPrint('âœ… CoinGecko: R\$ ${priceDouble.toStringAsFixed(2)}');
        return priceDouble;
      }
    } catch (e) {
      debugPrint('âš ï¸ Erro ao buscar preÃ§o no CoinGecko: $e');
    }
    return null;
  }

  /// Busca preÃ§o com cache (evita mÃºltiplas chamadas em curto perÃ­odo)
  static DateTime? _lastFetch;
  static double? _cachedPrice;
  static const _cacheDuration = Duration(minutes: 2);

  static Future<double?> getBitcoinPriceWithCache() async {
    // Se tem cache vÃ¡lido, retorna
    if (_cachedPrice != null && _lastFetch != null) {
      final age = DateTime.now().difference(_lastFetch!);
      if (age < _cacheDuration) {
        debugPrint('ðŸ’¾ Usando preÃ§o em cache: R\$ ${_cachedPrice!.toStringAsFixed(2)}');
        return _cachedPrice;
      }
    }

    // Busca novo preÃ§o
    final price = await getBitcoinPriceInBRL();
    if (price != null) {
      _cachedPrice = price;
      _lastFetch = DateTime.now();
    }
    return price;
  }

  /// Limpa o cache
  static void clearCache() {
    _cachedPrice = null;
    _lastFetch = null;
  }

  /// Alias para getBitcoinPriceWithCache (para compatibilidade)
  Future<double?> getBitcoinPrice() async {
    return await getBitcoinPriceWithCache();
  }
}
