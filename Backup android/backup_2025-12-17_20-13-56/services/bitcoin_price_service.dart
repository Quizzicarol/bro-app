import 'package:dio/dio.dart';

/// Serviço para buscar preço real do Bitcoin de APIs públicas
class BitcoinPriceService {
  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
  ));

  /// Busca preço do Bitcoin em BRL de múltiplas fontes
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

    print('❌ Não foi possível buscar preço do Bitcoin de nenhuma fonte');
    return null;
  }

  /// Coinbase API (mais confiável)
  static Future<double?> _getCoinbasePrice() async {
    try {
      print('📡 Buscando preço Bitcoin na Coinbase...');
      final response = await _dio.get('https://api.coinbase.com/v2/exchange-rates?currency=BTC');
      
      final rates = response.data['data']['rates'];
      final brlRate = rates['BRL'];
      
      if (brlRate != null) {
        final price = double.parse(brlRate.toString());
        print('✅ Coinbase: R\$ ${price.toStringAsFixed(2)}');
        return price;
      }
    } catch (e) {
      print('⚠️ Erro ao buscar preço na Coinbase: $e');
    }
    return null;
  }

  /// Binance API
  static Future<double?> _getBinancePrice() async {
    try {
      print('📡 Buscando preço Bitcoin na Binance...');
      
      // Buscar BTC/USDT
      final btcUsdtResponse = await _dio.get('https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT');
      final btcUsdt = double.parse(btcUsdtResponse.data['price']);
      
      // Buscar USDT/BRL
      final usdtBrlResponse = await _dio.get('https://api.binance.com/api/v3/ticker/price?symbol=USDTBRL');
      final usdtBrl = double.parse(usdtBrlResponse.data['price']);
      
      final btcBrl = btcUsdt * usdtBrl;
      print('✅ Binance: R\$ ${btcBrl.toStringAsFixed(2)}');
      return btcBrl;
    } catch (e) {
      print('⚠️ Erro ao buscar preço na Binance: $e');
    }
    return null;
  }

  /// CoinGecko API (free, sem autenticação)
  static Future<double?> _getCoingeckoPrice() async {
    try {
      print('📡 Buscando preço Bitcoin no CoinGecko...');
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
        print('✅ CoinGecko: R\$ ${priceDouble.toStringAsFixed(2)}');
        return priceDouble;
      }
    } catch (e) {
      print('⚠️ Erro ao buscar preço no CoinGecko: $e');
    }
    return null;
  }

  /// Busca preço com cache (evita múltiplas chamadas em curto período)
  static DateTime? _lastFetch;
  static double? _cachedPrice;
  static const _cacheDuration = Duration(minutes: 2);

  static Future<double?> getBitcoinPriceWithCache() async {
    // Se tem cache válido, retorna
    if (_cachedPrice != null && _lastFetch != null) {
      final age = DateTime.now().difference(_lastFetch!);
      if (age < _cacheDuration) {
        print('💾 Usando preço em cache: R\$ ${_cachedPrice!.toStringAsFixed(2)}');
        return _cachedPrice;
      }
    }

    // Busca novo preço
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
