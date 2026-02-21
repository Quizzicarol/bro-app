import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'storage_service.dart';
import 'nostr_service.dart';
import 'pix_decoder_service.dart';
import 'boleto_decoder_service.dart';
import 'bitcoin_price_service.dart';
import '../config.dart';

class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  // Initialize _dio with a safe default so callers before async init() don't hit a
  // LateInitializationError. init() will overwrite options and interceptors.
  late Dio _dio = Dio(BaseOptions(
    baseUrl: AppConfig.defaultBackendUrl,
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 5),
    headers: {
      'Content-Type': 'application/json',
    },
  ));
  String _baseUrl = AppConfig.defaultBackendUrl;
  final _nostrService = NostrService();
  final _storage = StorageService();

  Future<void> init() async {
    _baseUrl = await _storage.getBackendUrl();

    _dio = Dio(BaseOptions(
      baseUrl: _baseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      headers: {
        'Content-Type': 'application/json',
      },
    ));

    // Interceptor para adicionar autenticaÃ§Ã£o Nostr (JWT)
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        // Adicionar header de autenticaÃ§Ã£o Nostr
        final privateKey = _nostrService.privateKey;
        if (privateKey != null) {
          final publicKey = _nostrService.publicKey!;
          final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          
          // Criar token JWT simplificado baseado em Nostr
          final authEvent = _nostrService.createEvent(
            privateKey: privateKey,
            kind: 22242, // NIP-98 HTTP Auth
            content: '',
            tags: [
              ['u', '${options.baseUrl}${options.path}'],
              ['method', options.method],
            ],
          );
          
          // Adicionar header de autenticaÃ§Ã£o
          options.headers['Authorization'] = 'Nostr ${authEvent['id']}';
          options.headers['X-Nostr-Signature'] = authEvent['sig'];
          options.headers['X-Nostr-Pubkey'] = publicKey;
        }
        
        return handler.next(options);
      },
    ));

    // Interceptor para logs
    _dio.interceptors.add(LogInterceptor(
      requestBody: true,
      responseBody: true,
    ));
  }

  // ===== BREEZ SDK ENDPOINTS =====
  // Backend gerencia a API key do Breez, nÃ£o o frontend

  /// POST /api/breez/initialize
  /// Inicializa Breez SDK no backend
  Future<Map<String, dynamic>?> breezInitialize() async {
    try {
      debugPrint('ðŸ”§ Inicializando Breez SDK via backend...');
      final response = await _dio.post('/api/breez/initialize');
      return response.data;
    } catch (e) {
      debugPrint('âŒ Erro ao inicializar Breez: $e');
      return null;
    }
  }

  /// GET /api/breez/balance
  /// ObtÃ©m saldo Lightning
  Future<Map<String, dynamic>?> breezGetBalance() async {
    try {
      final response = await _dio.get('/api/breez/balance');
      return response.data;
    } catch (e) {
      debugPrint('âŒ Erro ao buscar saldo Breez: $e');
      return null;
    }
  }

  /// POST /api/breez/create-invoice
  /// Cria invoice Lightning
  Future<Map<String, dynamic>?> breezCreateInvoice({
    required int amountSats,
    String? description,
    String? orderId,
  }) async {
    try {
      debugPrint('âš¡ Criando invoice de $amountSats sats...');
      final response = await _dio.post('/api/breez/create-invoice', data: {
        'amountSats': amountSats,
        'description': description,
        'orderId': orderId,
      });
      return response.data;
    } catch (e) {
      debugPrint('âŒ Erro ao criar invoice: $e');
      return null;
    }
  }

  /// POST /api/breez/pay-invoice
  /// Paga uma invoice Lightning
  Future<Map<String, dynamic>?> breezPayInvoice({
    required String bolt11,
    int? amountSats,
  }) async {
    try {
      debugPrint('âš¡ Pagando invoice...');
      final response = await _dio.post('/api/breez/pay-invoice', data: {
        'bolt11': bolt11,
        if (amountSats != null) 'amountSats': amountSats,
      });
      return response.data;
    } catch (e) {
      debugPrint('âŒ Erro ao pagar invoice: $e');
      return null;
    }
  }

  /// GET /api/breez/check-payment/:paymentHash
  /// Verifica status de pagamento Lightning
  Future<Map<String, dynamic>?> checkPaymentStatus(String paymentHash) async {
    try {
      final response = await _dio.get('/api/breez/check-payment/$paymentHash');
      return response.data;
    } catch (e) {
      debugPrint('âŒ Erro ao verificar status: $e');
      return null;
    }
  }

  /// POST /api/breez/mark-paid/:paymentHash
  /// Marca invoice como paga manualmente (para testes)
  Future<Map<String, dynamic>?> markInvoiceAsPaid(String paymentHash) async {
    try {
      final response = await _dio.post('/api/breez/mark-paid/$paymentHash');
      return response.data;
    } catch (e) {
      debugPrint('âŒ Erro ao marcar como pago: $e');
      return null;
    }
  }

  /// GET /api/breez/check-payment/:paymentHash
  /// Verifica status de pagamento
  Future<Map<String, dynamic>?> breezCheckPayment(String paymentHash) async {
    try {
      final response = await _dio.get('/api/breez/check-payment/$paymentHash');
      return response.data;
    } catch (e) {
      debugPrint('âŒ Erro ao verificar pagamento: $e');
      return null;
    }
  }

  /// POST /api/breez/simulate-pay
  /// Simula pagamento (apenas para testes/debug)
  Future<Map<String, dynamic>?> breezSimulatePay(String paymentHash) async {
    try {
      debugPrint('ðŸ§ª Simulando pagamento: $paymentHash');
      final response = await _dio.post('/api/breez/simulate-pay', data: {
        'paymentHash': paymentHash,
      });
      return response.data;
    } catch (e) {
      debugPrint('âŒ Erro ao simular pagamento: $e');
      return null;
    }
  }

  /// GET /api/breez/payments
  /// Lista histÃ³rico de pagamentos
  Future<List<dynamic>> breezListPayments() async {
    try {
      final response = await _dio.get('/api/breez/payments');
      return response.data['payments'] ?? [];
    } catch (e) {
      debugPrint('âŒ Erro ao listar pagamentos: $e');
      return [];
    }
  }

  /// POST /api/breez/create-onchain-address
  /// Cria endereÃ§o Bitcoin on-chain para swap
  Future<Map<String, dynamic>?> breezCreateOnchainAddress() async {
    try {
      debugPrint('ðŸ”— Criando endereÃ§o Bitcoin on-chain...');
      final response = await _dio.post('/api/breez/create-onchain-address');
      return response.data;
    } catch (e) {
      debugPrint('âŒ Erro ao criar endereÃ§o on-chain: $e');
      return null;
    }
  }

  // ===== BOLETO =====

  Future<Map<String, dynamic>?> validateBoleto(String code) async {
    try {
      debugPrint('ðŸ” validateBoleto chamado com cÃ³digo: ${code.length} dÃ­gitos');
      debugPrint('ðŸ” CÃ³digo (primeiros 20 chars): ${code.substring(0, code.length > 20 ? 20 : code.length)}...');
      
      // Usar decodificador local sempre (funciona com ou sem backend)
      final result = BoletoDecoderService.decodeBoleto(code);
      
      if (result != null) {
        debugPrint('âœ… Boleto decodificado localmente: ${result['merchantName']}, R\$ ${result['value']}');
        return result;
      }
      
      debugPrint('âš ï¸ Decodificador local retornou null');
      
      // Se decodificaÃ§Ã£o local falhar e nÃ£o estiver em test mode, tenta backend
      if (!AppConfig.testMode) {
        debugPrint('ðŸ“¡ Tentando backend...');
        return await post('/api/validate-boleto', {'code': code});
      }
      
      debugPrint('âŒ NÃ£o foi possÃ­vel decodificar o boleto (test mode, sem backend)');
      return {
        'success': false,
        'error': 'CÃ³digo de boleto invÃ¡lido. Deve ter 44, 47 ou 48 dÃ­gitos.',
      };
    } catch (e) {
      debugPrint('âŒ Erro ao validar boleto: $e');
      return {
        'success': false,
        'error': 'Erro ao processar boleto: $e',
      };
    }
  }

  // ===== PIX =====

  Future<Map<String, dynamic>?> decodePix(String code) async {
    try {
      // Usar decodificador local sempre (funciona com ou sem backend)
      final result = PixDecoderService.decodePix(code);
      if (result != null) {
        debugPrint('âœ… PIX decodificado localmente: ${result['merchantName']}, R\$ ${result['value']}');
        return result;
      }
      
      // Se decodificaÃ§Ã£o local falhar e nÃ£o estiver em test mode, tenta backend
      if (!AppConfig.testMode) {
        return await post('/api/decode-pix', {'code': code});
      }
      
      debugPrint('âŒ NÃ£o foi possÃ­vel decodificar o cÃ³digo PIX');
      return null;
    } catch (e) {
      debugPrint('âŒ Erro ao decodificar PIX: $e');
      return null;
    }
  }

  // ===== BITCOIN =====

  Future<double?> getBitcoinPrice() async {
    try {
      debugPrint('ðŸ“¡ Buscando preÃ§o real do Bitcoin...');
      
      // Buscar preÃ§o real de APIs pÃºblicas
      final realPrice = await BitcoinPriceService.getBitcoinPriceWithCache();
      
      if (realPrice != null) {
        debugPrint('âœ… PreÃ§o real do Bitcoin: R\$ ${realPrice.toStringAsFixed(2)}');
        return realPrice;
      }
      
      // Se falhar e nÃ£o estiver em test mode, tenta backend
      if (!AppConfig.testMode) {
        final result = await get('/api/bitcoin/price');
        final price = result?['price'];
        if (price != null) {
          final priceDouble = (price is num) ? price.toDouble() : double.tryParse(price.toString());
          debugPrint('âœ… PreÃ§o do backend: $priceDouble');
          return priceDouble;
        }
      }
      
      debugPrint('âš ï¸ Usando preÃ§o fallback: R\$ 480.558,00');
      return 480558.0; // Fallback
    } catch (e) {
      debugPrint('âŒ Erro ao buscar preÃ§o Bitcoin: $e');
      return 480558.0; // Fallback
    }
  }

  Future<Map<String, dynamic>?> convertPrice({
    required double amount,
    String currency = 'BRL',
  }) async {
    try {
      // Sempre calcular localmente usando preÃ§o real do Bitcoin
      final btcPrice = await getBitcoinPrice();
      if (btcPrice == null || btcPrice <= 0) {
        debugPrint('âŒ PreÃ§o do Bitcoin invÃ¡lido: $btcPrice');
        return null;
      }
      
      // Calcular conversÃ£o
      // amount estÃ¡ em BRL, converter para BTC e sats
      final btcAmount = amount / btcPrice;
      final satsAmount = (btcAmount * 100000000).round();
      
      // Taxas (ajustÃ¡veis)
      const platformFeePercent = 0.02; // 2% taxa da plataforma
      const providerFeePercent = 0.01; // 1% taxa do provedor
      
      final platformFeeBrl = amount * platformFeePercent;
      final providerFeeBrl = amount * providerFeePercent;
      final totalFeeBrl = platformFeeBrl + providerFeeBrl;
      final totalWithFeesBrl = amount + totalFeeBrl;
      
      final totalSats = ((amount + totalFeeBrl) / btcPrice * 100000000).round();
      final platformFeeSats = (platformFeeBrl / btcPrice * 100000000).round();
      final providerFeeSats = (providerFeeBrl / btcPrice * 100000000).round();
      
      debugPrint('ðŸ’± ConversÃ£o local: R\$ $amount â†’ $satsAmount sats @ R\$ ${btcPrice.toStringAsFixed(2)}/BTC');
      
      return {
        'success': true,
        'amount': amount,
        'currency': currency,
        'bitcoinPrice': btcPrice,
        'btcAmount': btcAmount,
        'sats': satsAmount.toString(),
        'totalSats': totalSats,
        'totalBrl': totalWithFeesBrl,
        'platformFee': platformFeeBrl,
        'platformFeeSats': platformFeeSats,
        'providerFee': providerFeeBrl,
        'providerFeeSats': providerFeeSats,
        'totalFee': totalFeeBrl,
      };
    } catch (e) {
      debugPrint('âŒ Erro ao converter preÃ§o: $e');
      return null;
    }
  }

  // ===== ORDERS =====

  Future<Map<String, dynamic>?> createOrder({
    required String billType,
    required String billCode,
    required double amount,
    required double btcAmount,
    required double btcPrice,
  }) async {
    try {
      final response = await _dio.post('/api/payments/create', data: {
        'billType': billType,
        'billCode': billCode,
        'amount': amount,
        'btcAmount': btcAmount,
        'btcPrice': btcPrice,
      });
      return response.data;
    } catch (e) {
      debugPrint('âŒ Erro ao criar ordem: $e');
      return null;
    }
  }

  Future<List<dynamic>> listOrders({String? status, int limit = 20}) async {
    try {
      final response = await _dio.get('/api/orders/list', queryParameters: {
        if (status != null) 'status': status,
        'limit': limit,
      });
      return response.data['orders'] ?? [];
    } catch (e) {
      debugPrint('âŒ Erro ao listar ordens: $e');
      return [];
    }
  }

  Future<Map<String, dynamic>?> getOrder(String orderId) async {
    try {
      final response = await _dio.get('/api/orders/$orderId');
      return response.data['order'];
    } catch (e) {
      debugPrint('âŒ Erro ao buscar ordem: $e');
      return null;
    }
  }

  Future<bool> acceptOrder(String orderId, String providerId) async {
    try {
      final response = await _dio.post('/api/orders/accept/$orderId', data: {
        'providerId': providerId,
      });
      return response.data['success'] ?? false;
    } catch (e) {
      debugPrint('âŒ Erro ao aceitar ordem: $e');
      return false;
    }
  }

  Future<bool> updateOrderStatus({
    required String orderId,
    required String status,
    String? paymentStatus,
    String? providerId,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      final response = await _dio.post('/api/orders/update-status/$orderId', data: {
        'status': status,
        if (paymentStatus != null) 'paymentStatus': paymentStatus,
        if (providerId != null) 'providerId': providerId,
        if (metadata != null) 'metadata': metadata,
      });
      return response.data['success'] ?? false;
    } catch (e) {
      debugPrint('âŒ Erro ao atualizar status: $e');
      return false;
    }
  }

  // ===== ESCROW =====

  Future<Map<String, dynamic>?> createEscrow({
    required String orderId,
    required double btcAmount,
    int? amountSats,
  }) async {
    try {
      final response = await _dio.post('/api/escrow/create', data: {
        'orderId': orderId,
        'btcAmount': btcAmount,
        if (amountSats != null) 'amountSats': amountSats,
      });
      return response.data;
    } catch (e) {
      debugPrint('âŒ Erro ao criar escrow: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> getEscrow(String escrowId) async {
    try {
      final response = await _dio.get('/api/escrow/$escrowId');
      return response.data['escrow'];
    } catch (e) {
      debugPrint('âŒ Erro ao buscar escrow: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> getEscrowByOrder(String orderId) async {
    try {
      final response = await _dio.get('/api/escrow/order/$orderId');
      return response.data['escrow'];
    } catch (e) {
      debugPrint('âŒ Erro ao buscar escrow da ordem: $e');
      return null;
    }
  }

  Future<bool> fundEscrow(String escrowId) async {
    try {
      final response = await _dio.post('/api/escrow/fund/$escrowId');
      return response.data['success'] ?? false;
    } catch (e) {
      debugPrint('âŒ Erro ao financiar escrow: $e');
      return false;
    }
  }

  Future<bool> releaseEscrow(String escrowId) async {
    try {
      final response = await _dio.post('/api/escrow/release/$escrowId');
      return response.data['success'] ?? false;
    } catch (e) {
      debugPrint('âŒ Erro ao liberar escrow: $e');
      return false;
    }
  }

  // ===== MESSAGES/CHAT =====

  Future<Map<String, dynamic>?> sendMessage({
    required String orderId,
    required String content,
    String? senderId,
    String? senderName,
    bool isProvider = false,
  }) async {
    try {
      final response = await _dio.post('/api/messages/send', data: {
        'orderId': orderId,
        'content': content,
        if (senderId != null) 'senderId': senderId,
        if (senderName != null) 'senderName': senderName,
        'isProvider': isProvider,
      });
      return response.data;
    } catch (e) {
      debugPrint('âŒ Erro ao enviar mensagem: $e');
      return null;
    }
  }

  Future<List<dynamic>> getMessages(String orderId) async {
    try {
      final response = await _dio.get('/api/messages/$orderId');
      return response.data['messages'] ?? [];
    } catch (e) {
      debugPrint('âŒ Erro ao buscar mensagens: $e');
      return [];
    }
  }

  // ===== PROVIDER =====

  Future<Map<String, dynamic>?> getProviderStats(String providerId) async {
    try {
      final response = await _dio.get('/api/provider/stats', queryParameters: {
        'providerId': providerId,
      });
      return response.data['stats'];
    } catch (e) {
      debugPrint('âŒ Erro ao buscar stats: $e');
      return null;
    }
  }

  // ===== HEALTH =====

  Future<Map<String, dynamic>?> healthCheck() async {
    try {
      final response = await _dio.get('/api/health').timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          throw TimeoutException('Backend nÃ£o estÃ¡ respondendo');
        },
      );
      return response.data;
    } catch (e) {
      debugPrint('âŒ Erro no health check: $e');
      if (e is TimeoutException) {
        throw Exception('O servidor nÃ£o estÃ¡ respondendo. Verifique se o backend estÃ¡ rodando em $baseUrl');
      }
      return null;
    }
  }

  // ===== PIX =====

  /// Decodifica cÃ³digo PIX
  Future<Map<String, dynamic>?> decodePixCode(String pixCode) async {
    try {
      debugPrint('ðŸ“¡ Decodificando cÃ³digo PIX...');
      final response = await _dio.post('/api/pix/decode', data: {
        'pixCode': pixCode,
      });
      debugPrint('ðŸ“¨ Resposta da API: ${response.data}');
      return response.data;
    } catch (e) {
      debugPrint('âŒ Erro ao decodificar PIX: $e');
      debugPrint('ðŸ“¨ Resposta da API: null');
      debugPrint('âŒ Resultado invÃ¡lido: null');
      return null;
    }
  }

  /// Processa pagamento PIX
  Future<Map<String, dynamic>> processPixPayment(
    String orderId,
    String pixCode,
    double amount,
  ) async {
    try {
      debugPrint('ðŸ“¡ Processando pagamento PIX...');
      final response = await _dio.post('/api/pix/pay', data: {
        'orderId': orderId,
        'pixCode': pixCode,
        'amount': amount,
      });
      return response.data;
    } catch (e) {
      debugPrint('âŒ Erro ao processar pagamento PIX: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  // ===== SYNC =====

  Future<bool> syncOrders(List<Map<String, dynamic>> orders) async {
    try {
      final response = await _dio.post('/api/orders/sync-from-frontend', data: {
        'frontendOrders': orders,
      });
      return response.data['success'] ?? false;
    } catch (e) {
      debugPrint('âŒ Erro ao sincronizar ordens: $e');
      return false;
    }
  }

  // Update base URL
  void setBaseUrl(String url) {
    _baseUrl = url;
    _dio.options.baseUrl = url;
  }

  // Getters
  String get baseUrl => _baseUrl;

  /// Reseta o ApiService para logout
  void reset() {
    _dio = Dio(BaseOptions(
      baseUrl: AppConfig.defaultBackendUrl,
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
      headers: {
        'Content-Type': 'application/json',
      },
    ));
    _baseUrl = AppConfig.defaultBackendUrl;
  }

  // ===== GENERIC HTTP METHODS =====
  
  /// Generic GET request
  Future<Map<String, dynamic>?> get(String path) async {
    // Test mode: retornar dados mockados
    if (AppConfig.testMode) {
      return await _getMockResponse(path);
    }

    try {
      final response = await _dio.get(path);
      return response.data as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('âŒ Erro no GET $path: $e');
      return null;
    }
  }

  /// Generic POST request
  Future<Map<String, dynamic>?> post(String path, Map<String, dynamic> data) async {
    // Test mode: retornar dados mockados
    if (AppConfig.testMode) {
      return await _getMockResponse(path, data: data);
    }

    try {
      final response = await _dio.post(path, data: data);
      return response.data as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('âŒ Erro no POST $path: $e');
      return null;
    }
  }

  /// Mock responses para test mode
  Future<Map<String, dynamic>> _getMockResponse(String path, {Map<String, dynamic>? data}) async {
    debugPrint('ðŸ§ª TEST MODE: Mock response para $path');

    // PIX decode
    if (path.contains('/api/decode-pix')) {
      final pixCode = data?['code'] ?? '';
      final codeLength = pixCode.toString().length;
      debugPrint('ðŸ” Mock: Decodificando PIX: ${pixCode.toString().substring(0, min<int>(50, codeLength))}');
      return {
        'success': true,
        'billType': 'pix',
        'value': 150.75,
        'merchantName': 'Comerciante Teste Ltda',
        'type': 'PIX Copia e Cola',
        'pixKey': 'teste@email.com',
        'message': 'PIX decodificado com sucesso (mock)',
      };
    }

    // Boleto validate - NÃƒO usar mock, sempre decodificar localmente
    if (path.contains('/api/validate-boleto')) {
      final boletoCode = data?['code'] ?? '';
      debugPrint('âš ï¸ Mock de boleto chamado - decodificaÃ§Ã£o local falhou para: $boletoCode');
      // Retornar erro para forÃ§ar uso do decodificador local
      return {
        'success': false,
        'error': 'DecodificaÃ§Ã£o local falhou - cÃ³digo invÃ¡lido',
      };
    }

    // Bitcoin price
    if (path.contains('/api/bitcoin/price')) {
      return {
        'success': true,
        'price': 350000.00,
        'currency': 'BRL',
        'source': 'mock',
      };
    }

    // Bitcoin convert price
    if (path.contains('/api/bitcoin/convert-price')) {
      final amountBrl = data?['amount'] ?? 100.0;
      // Use real Bitcoin price from BitcoinPriceService
      final btcPrice = await BitcoinPriceService.getBitcoinPriceWithCache() ?? 350000.00;
      final btcAmount = amountBrl / btcPrice;
      final sats = (btcAmount * 100000000).round();
      return {
        'success': true,
        'bitcoinAmount': btcAmount,
        'bitcoinPrice': btcPrice,
        'amountBrl': amountBrl,
        'sats': sats,
      };
    }

    // Escrow endpoints
    if (path.contains('/api/escrow/create')) {
      return {
        'success': true,
        'deposit': {
          'id': 'mock_deposit_${DateTime.now().millisecondsSinceEpoch}',
          'providerId': data?['providerId'] ?? 'mock_provider',
          'amountBrl': data?['amountBrl'] ?? 500,
          'status': 'pending',
          'paymentHash': 'mock_payment_hash_${DateTime.now().millisecondsSinceEpoch}',
          'createdAt': DateTime.now().toIso8601String(),
        },
      };
    }

    if (path.contains('/api/escrow/invoice/')) {
      return {
        'success': true,
        'invoice': 'lnbc1500n1pjqmock...[MOCK_INVOICE]',
      };
    }

    if (path.contains('/api/escrow/deposit/')) {
      return {
        'success': true,
        'deposit': {
          'id': 'mock_deposit',
          'status': 'paid',
          'amountBrl': 500,
        },
      };
    }

    if (path.contains('/api/escrow/provider/') && path.contains('/active')) {
      return {
        'success': true,
        'deposit': {
          'id': 'mock_active_deposit',
          'status': 'active',
          'amountBrl': 500,
        },
      };
    }

    if (path.contains('/api/escrow/release')) {
      return {'success': true, 'message': 'DepÃ³sito liberado (mock)'};
    }

    // Default mock response
    return {
      'success': true,
      'message': 'Mock response (test mode)',
      'data': data,
    };
  }
}
