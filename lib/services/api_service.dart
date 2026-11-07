import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart' as _crypto;
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:bro_app/services/push_diag.dart';
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

  /// v270: Expor Dio para que EscrowService possa reusar (com NIP-98 auth)
  Dio get dio => _dio;

  String _sha256Hex(List<int> bytes) =>
      _crypto.sha256.convert(bytes).toString();

  Future<void> init() async {
    // v536: SEMPRE usar AppConfig.defaultBackendUrl (vem de env.json no build).
    // O storage override era feature de dev e causava bugs em producao:
    // URLs como http://10.0.2.2:3002 (emulador Android) eram persistidas e
    // vazavam para dispositivos reais (via backup/restore do Android).
    // Isso fazia TODAS as chamadas ao backend darem timeout, quebrando push
    // notifications, order_update, notifyUser, etc.
    _baseUrl = AppConfig.defaultBackendUrl;

    // Limpar qualquer URL stale que tenha sido salva em versoes antigas
    try {
      final saved = await _storage.getBackendUrl();
      if (saved != _baseUrl) {
        broLog('[API] Overriding stale saved URL: $saved ? $_baseUrl');
        PushDiag.log('api: override stale $saved ? $_baseUrl');
        await _storage.saveBackendUrl(_baseUrl);
      }
    } catch (_) {}

    // v537: Log a URL em uso para diagnostico definitivo + timeouts maiores (20s)
    PushDiag.log('api: init baseUrl=$_baseUrl');

    _dio = Dio(BaseOptions(
      baseUrl: _baseUrl,
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 20),
      headers: {
        'Content-Type': 'application/json',
      },
    ));

    // Interceptor para adicionar autenticação Nostr (JWT)
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        // Adicionar header de autenticação Nostr
        final privateKey = _nostrService.privateKey;
        if (privateKey != null) {
          final publicKey = _nostrService.publicKey!;

          // v566: bind auth event to body via NIP-98 payload tag
          final tags = <List<String>>[
            ['u', '${options.baseUrl}${options.path}'],
            ['method', options.method],
          ];
          final method = options.method.toUpperCase();
          if (options.data != null && (method == 'POST' || method == 'PUT' || method == 'PATCH' || method == 'DELETE')) {
            try {
              String bodyStr;
              if (options.data is String) {
                bodyStr = options.data as String;
              } else {
                bodyStr = json.encode(options.data);
              }
              final hash = _sha256Hex(utf8.encode(bodyStr));
              tags.add(['payload', hash]);
            } catch (_) {/* if encoding fails, skip payload tag � server is lenient */}
          }

          // Criar token JWT simplificado baseado em Nostr
          final authEvent = _nostrService.createEvent(
            privateKey: privateKey,
            kind: 22242, // NIP-98 HTTP Auth
            content: '',
            tags: tags,
          );
          
          // Enviar evento NIP-98 completo como base64 (n�o apenas o eventId)
          final eventJson = {
            'id': authEvent['id'],
            'pubkey': publicKey,
            'created_at': authEvent['created_at'],
            'kind': authEvent['kind'],
            'tags': authEvent['tags'],
            'content': authEvent['content'] ?? '',
            'sig': authEvent['sig'],
          };
          final eventBase64 = base64Encode(utf8.encode(json.encode(eventJson)));
          options.headers['Authorization'] = 'Nostr $eventBase64';
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
  // Backend gerencia a API key do Breez, não o frontend

  /// POST /api/breez/initialize
  /// Inicializa Breez SDK no backend
  Future<Map<String, dynamic>?> breezInitialize() async {
    try {
      broLog('🔧 Inicializando Breez SDK via backend...');
      final response = await _dio.post('/api/breez/initialize');
      return response.data;
    } catch (e) {
      broLog('❌ Erro ao inicializar Breez: $e');
      return null;
    }
  }

  /// GET /api/breez/balance
  /// Obtém saldo Lightning
  Future<Map<String, dynamic>?> breezGetBalance() async {
    try {
      final response = await _dio.get('/api/breez/balance');
      return response.data;
    } catch (e) {
      broLog('❌ Erro ao buscar saldo Breez: $e');
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
      broLog('⚡ Criando invoice de $amountSats sats...');
      final response = await _dio.post('/api/breez/create-invoice', data: {
        'amountSats': amountSats,
        'description': description,
        'orderId': orderId,
      });
      return response.data;
    } catch (e) {
      broLog('❌ Erro ao criar invoice: $e');
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
      broLog('⚡ Pagando invoice...');
      final response = await _dio.post('/api/breez/pay-invoice', data: {
        'bolt11': bolt11,
        if (amountSats != null) 'amountSats': amountSats,
      });
      return response.data;
    } catch (e) {
      broLog('❌ Erro ao pagar invoice: $e');
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
      broLog('❌ Erro ao verificar status: $e');
      return null;
    }
  }

  // v744 (auditoria A2): markInvoiceAsPaid e breezSimulatePay REMOVIDOS � endpoints de teste que marcavam invoice paga sem dinheiro real. Nao existem no backend e nada chamava (codigo morto perigoso).

  /// GET /api/breez/check-payment/:paymentHash
  /// Verifica status de pagamento
  Future<Map<String, dynamic>?> breezCheckPayment(String paymentHash) async {
    try {
      final response = await _dio.get('/api/breez/check-payment/$paymentHash');
      return response.data;
    } catch (e) {
      broLog('❌ Erro ao verificar pagamento: $e');
      return null;
    }
  }

  /// GET /api/breez/payments
  /// Lista histórico de pagamentos
  Future<List<dynamic>> breezListPayments() async {
    try {
      final response = await _dio.get('/api/breez/payments');
      return response.data['payments'] ?? [];
    } catch (e) {
      broLog('❌ Erro ao listar pagamentos: $e');
      return [];
    }
  }

  /// POST /api/breez/create-onchain-address
  /// Cria endereço Bitcoin on-chain para swap
  Future<Map<String, dynamic>?> breezCreateOnchainAddress() async {
    try {
      broLog('🔗 Criando endereço Bitcoin on-chain...');
      final response = await _dio.post('/api/breez/create-onchain-address');
      return response.data;
    } catch (e) {
      broLog('❌ Erro ao criar endereço on-chain: $e');
      return null;
    }
  }

  // ===== BOLETO =====

  Future<Map<String, dynamic>?> validateBoleto(String code) async {
    try {
      broLog('🔍 validateBoleto chamado com código: ${code.length} dígitos');
      broLog('🔍 Código (primeiros 20 chars): ${code.substring(0, code.length > 20 ? 20 : code.length)}...');
      
      // Usar decodificador local sempre (funciona com ou sem backend)
      final result = BoletoDecoderService.decodeBoleto(code);
      
      if (result != null) {
        broLog('✅ Boleto decodificado localmente: ${result['merchantName']}, R\$ ${result['value']}');
        return result;
      }
      
      broLog('⚠️ Decodificador local retornou null');
      
      // Se decodificação local falhar e não estiver em test mode, tenta backend
      if (!AppConfig.testMode) {
        broLog('📡 Tentando backend...');
        return await post('/api/validate-boleto', {'code': code});
      }
      
      broLog('❌ Não foi possível decodificar o boleto (test mode, sem backend)');
      return {
        'success': false,
        'error': 'Código de boleto inválido. Deve ter 44, 47 ou 48 dígitos.',
      };
    } catch (e) {
      broLog('❌ Erro ao validar boleto: $e');
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
        broLog('✅ PIX decodificado localmente: ${result['merchantName']}, R\$ ${result['value']}');
        return result;
      }
      
      // Se decodificação local falhar e não estiver em test mode, tenta backend
      if (!AppConfig.testMode) {
        return await post('/api/decode-pix', {'code': code});
      }
      
      broLog('❌ Não foi possível decodificar o código PIX');
      return null;
    } catch (e) {
      broLog('❌ Erro ao decodificar PIX: $e');
      return null;
    }
  }

  // ===== BITCOIN =====

  Future<double?> getBitcoinPrice() async {
    try {
      broLog('📡 Buscando preço real do Bitcoin...');
      
      // Buscar preço real de APIs públicas
      final realPrice = await BitcoinPriceService.getBitcoinPriceWithCache();
      
      if (realPrice != null) {
        broLog('✅ Preço real do Bitcoin: R\$ ${realPrice.toStringAsFixed(2)}');
        return realPrice;
      }
      
      // Se falhar e não estiver em test mode, tenta backend
      if (!AppConfig.testMode) {
        final result = await get('/api/bitcoin/price');
        final price = result?['price'];
        if (price != null) {
          final priceDouble = (price is num) ? price.toDouble() : double.tryParse(price.toString());
          broLog('✅ Preço do backend: $priceDouble');
          return priceDouble;
        }
      }
      
      broLog('⚠️ Usando preço fallback: R\$ 480.558,00');
      return 480558.0; // Fallback
    } catch (e) {
      broLog('❌ Erro ao buscar preço Bitcoin: $e');
      return 480558.0; // Fallback
    }
  }

  Future<Map<String, dynamic>?> convertPrice({
    required double amount,
    String currency = 'BRL',
  }) async {
    try {
      // Sempre calcular localmente usando preço real do Bitcoin
      final btcPrice = await getBitcoinPrice();
      if (btcPrice == null || btcPrice <= 0) {
        broLog('❌ Preço do Bitcoin inválido: $btcPrice');
        return null;
      }
      
      // Calcular conversão
      // amount está em BRL, converter para BTC e sats
      final btcAmount = amount / btcPrice;
      final satsAmount = (btcAmount * 100000000).round();
      
      // Taxas centralizadas em AppConfig
      const platformFeePercent = AppConfig.platformFeePercent; // 2%
      const providerFeePercent = AppConfig.providerFeePercent; // 3%
      
      final platformFeeBrl = amount * platformFeePercent;
      final providerFeeBrl = amount * providerFeePercent;
      final totalFeeBrl = platformFeeBrl + providerFeeBrl;
      final totalWithFeesBrl = amount + totalFeeBrl;
      
      final totalSats = ((amount + totalFeeBrl) / btcPrice * 100000000).round();
      final platformFeeSats = (platformFeeBrl / btcPrice * 100000000).round();
      final providerFeeSats = (providerFeeBrl / btcPrice * 100000000).round();
      
      broLog('💱 Conversão local: R\$ $amount → $satsAmount sats @ R\$ ${btcPrice.toStringAsFixed(2)}/BTC');
      
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
      broLog('❌ Erro ao converter preço: $e');
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
      broLog('❌ Erro ao criar ordem: $e');
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
      broLog('❌ Erro ao listar ordens: $e');
      return [];
    }
  }

  Future<Map<String, dynamic>?> getOrder(String orderId) async {
    try {
      final response = await _dio.get('/api/orders/$orderId');
      return response.data['order'];
    } catch (e) {
      broLog('❌ Erro ao buscar ordem: $e');
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
      broLog('❌ Erro ao aceitar ordem: $e');
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
      broLog('❌ Erro ao atualizar status: $e');
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
      broLog('❌ Erro ao criar escrow: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> getEscrow(String escrowId) async {
    try {
      final response = await _dio.get('/api/escrow/$escrowId');
      return response.data['escrow'];
    } catch (e) {
      broLog('❌ Erro ao buscar escrow: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> getEscrowByOrder(String orderId) async {
    try {
      final response = await _dio.get('/api/escrow/order/$orderId');
      return response.data['escrow'];
    } catch (e) {
      broLog('❌ Erro ao buscar escrow da ordem: $e');
      return null;
    }
  }

  Future<bool> fundEscrow(String escrowId) async {
    try {
      final response = await _dio.post('/api/escrow/fund/$escrowId');
      return response.data['success'] ?? false;
    } catch (e) {
      broLog('❌ Erro ao financiar escrow: $e');
      return false;
    }
  }

  Future<bool> releaseEscrow(String escrowId) async {
    try {
      final response = await _dio.post('/api/escrow/release/$escrowId');
      return response.data['success'] ?? false;
    } catch (e) {
      broLog('❌ Erro ao liberar escrow: $e');
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
      broLog('❌ Erro ao enviar mensagem: $e');
      return null;
    }
  }

  Future<List<dynamic>> getMessages(String orderId) async {
    try {
      final response = await _dio.get('/api/messages/$orderId');
      return response.data['messages'] ?? [];
    } catch (e) {
      broLog('❌ Erro ao buscar mensagens: $e');
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
      broLog('❌ Erro ao buscar stats: $e');
      return null;
    }
  }

  // ===== HEALTH =====

  Future<Map<String, dynamic>?> healthCheck() async {
    try {
      final response = await _dio.get('/api/health').timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          throw TimeoutException('Backend não está respondendo');
        },
      );
      return response.data;
    } catch (e) {
      broLog('❌ Erro no health check: $e');
      if (e is TimeoutException) {
        throw Exception('O servidor não está respondendo. Verifique se o backend está rodando em $baseUrl');
      }
      return null;
    }
  }

  // ===== PIX =====

  /// Decodifica código PIX
  Future<Map<String, dynamic>?> decodePixCode(String pixCode) async {
    try {
      broLog('📡 Decodificando código PIX...');
      final response = await _dio.post('/api/pix/decode', data: {
        'pixCode': pixCode,
      });
      broLog('📨 Resposta da API: ${response.data}');
      return response.data;
    } catch (e) {
      broLog('❌ Erro ao decodificar PIX: $e');
      broLog('📨 Resposta da API: null');
      broLog('❌ Resultado inválido: null');
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
      broLog('📡 Processando pagamento PIX...');
      final response = await _dio.post('/api/pix/pay', data: {
        'orderId': orderId,
        'pixCode': pixCode,
        'amount': amount,
      });
      return response.data;
    } catch (e) {
      broLog('❌ Erro ao processar pagamento PIX: $e');
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
      broLog('❌ Erro ao sincronizar ordens: $e');
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
      broLog('❌ Erro no GET $path: $e');
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
      broLog('❌ Erro no POST $path: $e');
      return null;
    }
  }
  // ===== AI DISPUTE AGENT ENDPOINTS (Phase 4) =====

  /// GET /agent/pending - Lista an�lises pendentes do agente IA
  Future<List<Map<String, dynamic>>> getAgentPendingAnalyses() async {
    try {
      final response = await _dio.get('/agent/pending');
      final data = response.data;
      if (data['success'] == true && data['analyses'] != null) {
        return List<Map<String, dynamic>>.from(data['analyses']);
      }
      return [];
    } catch (e) {
      broLog('? Erro ao buscar an�lises do agente: $e');
      return [];
    }
  }

  /// GET /agent/analysis/:orderId - Detalhes da an�lise de uma disputa
  Future<Map<String, dynamic>?> getAgentAnalysis(String orderId) async {
    try {
      final response = await _dio.get('/agent/analysis/$orderId');
      return response.data as Map<String, dynamic>?;
    } catch (e) {
      broLog('? Erro ao buscar an�lise do agente: $e');
      return null;
    }
  }

  /// POST /agent/approve - Aprovar sugest�o do agente
  Future<bool> approveAgentAnalysis(String orderId) async {
    try {
      final response = await _dio.post('/agent/approve', data: {
        'orderId': orderId,
      });
      return response.data?['success'] == true;
    } catch (e) {
      broLog('? Erro ao aprovar an�lise: $e');
      return false;
    }
  }

  /// POST /agent/reject - Rejeitar sugest�o do agente
  Future<bool> rejectAgentAnalysis(String orderId, {required String humanDecision}) async {
    try {
      final response = await _dio.post('/agent/reject', data: {
        'orderId': orderId,
        'humanDecision': humanDecision,
      });
      return response.data?['success'] == true;
    } catch (e) {
      broLog('? Erro ao rejeitar an�lise: $e');
      return false;
    }
  }

  /// GET /agent/status - Estat�sticas do agente IA
  Future<Map<String, dynamic>?> getAgentStats() async {
    try {
      final response = await _dio.get('/agent/status');
      return response.data as Map<String, dynamic>?;
    } catch (e) {
      broLog('? Erro ao buscar stats do agente: $e');
      return null;
    }
  }
  /// Mock responses para test mode
  Future<Map<String, dynamic>> _getMockResponse(String path, {Map<String, dynamic>? data}) async {
    broLog('🧪 TEST MODE: Mock response para $path');

    // PIX decode
    if (path.contains('/api/decode-pix')) {
      final pixCode = data?['code'] ?? '';
      final codeLength = pixCode.toString().length;
      broLog('🔍 Mock: Decodificando PIX: ${pixCode.toString().substring(0, min<int>(50, codeLength))}');
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

    // Boleto validate - NÃO usar mock, sempre decodificar localmente
    if (path.contains('/api/validate-boleto')) {
      final boletoCode = data?['code'] ?? '';
      broLog('⚠️ Mock de boleto chamado - decodificação local falhou para: $boletoCode');
      // Retornar erro para forçar uso do decodificador local
      return {
        'success': false,
        'error': 'Decodificação local falhou - código inválido',
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
      return {'success': true, 'message': 'Depósito liberado (mock)'};
    }

    // Default mock response
    return {
      'success': true,
      'message': 'Mock response (test mode)',
      'data': data,
    };
  }

  // ===== PUSH NOTIFICATION ENDPOINTS =====

  // v576: cached build number, populated lazily on first registerPushToken call
  // so the server can warn users on outdated apps that may not handle the
  // NIP-44-only billCode protocol (v575+).
  static int? _cachedAppBuild;
  Future<int?> _getAppBuild() async {
    if (_cachedAppBuild != null) return _cachedAppBuild;
    try {
      final info = await PackageInfo.fromPlatform();
      _cachedAppBuild = int.tryParse(info.buildNumber);
    } catch (_) {
      // Non-fatal: server tolerates missing app_build (treats as outdated)
    }
    return _cachedAppBuild;
  }

  /// Register FCM token with the backend for order push notifications
  Future<bool> registerPushToken(String fcmToken, {bool? providerEnabled}) async {
    try {
      PushDiag.log('api: POST /push/register-token base=$_baseUrl');
      final appBuild = await _getAppBuild();
      final response = await _dio.post('/push/register-token', data: {
        'fcm_token': fcmToken,
        if (providerEnabled != null) 'provider_enabled': providerEnabled,
        if (appBuild != null) 'app_build': appBuild,
      });
      final ok = response.data?['ok'] == true;
      broLog('[PUSH] Backend token registered: $ok (push_enabled=${response.data?['push_enabled']})');
      PushDiag.log('api: register response status=${response.statusCode} ok=$ok body=${response.data}');
      return ok;
    } on DioException catch (e) {
      final msg = 'type=${e.type.name} code=${e.response?.statusCode} msg=${e.message} body=${e.response?.data}';
      broLog('[PUSH] Backend token registration failed: $msg');
      PushDiag.log('api: register FAIL $msg');
      return false;
    } catch (e) {
      broLog('[PUSH] Backend token registration failed: $e');
      PushDiag.log('api: register EXC $e');
      return false;
    }
  }

  /// v544: Toggle whether this pubkey receives 'Nova ordem disponivel'
  /// broadcast pushes. Called when the user enters/exits provider mode.
  Future<bool> setProviderPushStatus(bool enabled) async {
    try {
      final response = await _dio.post('/push/provider-status', data: {
        'enabled': enabled,
      });
      final ok = response.data?['ok'] == true;
      broLog('[PUSH] Provider status=$enabled ok=$ok');
      return ok;
    } on DioException catch (e) {
      broLog('[PUSH] setProviderPushStatus failed: ${e.message}');
      return false;
    } catch (e) {
      broLog('[PUSH] setProviderPushStatus failed: $e');
      return false;
    }
  }

  /// v588: Tell the backend which payment methods this provider is willing to
  /// handle. The watchtower uses this list to filter "new order available"
  /// broadcasts so the provider is only notified about orders in those
  /// currencies/methods. Empty/null on the server is treated as "all".
  Future<bool> setProviderPaymentMethods(List<String> methods) async {
    try {
      final response = await _dio.post('/push/payment-methods', data: {
        'methods': methods,
      });
      final ok = response.data?['ok'] == true;
      broLog('[PUSH] Provider methods (${methods.length}) ok=$ok');
      return ok;
    } on DioException catch (e) {
      broLog('[PUSH] setProviderPaymentMethods failed: ${e.message}');
      return false;
    } catch (e) {
      broLog('[PUSH] setProviderPaymentMethods failed: $e');
      return false;
    }
  }

  /// v594: Tell the backend which non-BRL currencies this provider is willing
  /// to handle (ISO-4217 codes). BRL is implicit. Watchtower filters non-BRL
  /// "new order" broadcasts accordingly.
  Future<bool> setProviderAcceptedCurrencies(List<String> currencies) async {
    try {
      final response = await _dio.post('/push/accepted-currencies', data: {
        'currencies': currencies,
      });
      final ok = response.data?['ok'] == true;
      broLog('[PUSH] Provider currencies (${currencies.length}) ok=$ok');
      return ok;
    } on DioException catch (e) {
      broLog('[PUSH] setProviderAcceptedCurrencies failed: ${e.message}');
      return false;
    } catch (e) {
      broLog('[PUSH] setProviderAcceptedCurrencies failed: $e');
      return false;
    }
  }

  /// v524: Ask backend whether our FCM token is registered.
  /// Used to detect silent registration failures on iOS
  /// (where getToken() may return null intermittently).
  /// Returns null on network error so callers can distinguish from a real "not registered" answer.
  Future<bool?> diagnosePushToken() async {
    try {
      final response = await _dio.get('/push/diagnose');
      return response.data?['registered'] == true;
    } on DioException catch (e) {
      final msg = 'type=${e.type.name} code=${e.response?.statusCode} msg=${e.message}';
      broLog('[PUSH] Backend diagnose failed: $msg');
      PushDiag.log('api: diagnose FAIL $msg');
      return null;
    } catch (e) {
      broLog('[PUSH] Backend diagnose failed: $e');
      return null;
    }
  }

  /// Send a push notification to another user via the backend
  Future<bool> notifyUser({
    required String targetPubkey,
    required String type,
    String? subtype,
    String? orderId,
  }) async {
    try {
      final response = await _dio.post('/push/notify', data: {
        'target_pubkey': targetPubkey,
        'type': type,
        if (subtype != null) 'subtype': subtype,
        if (orderId != null) 'order_id': orderId,
      });
      final ok = response.data?['ok'] == true;
      PushDiag.log('api: notify status=${response.statusCode} ok=$ok body=${response.data}');
      return ok;
    } on DioException catch (e) {
      final msg = 'type=${e.type.name} code=${e.response?.statusCode} msg=${e.message} body=${e.response?.data}';
      PushDiag.log('api: notify FAIL $msg');
      broLog('[PUSH] Notify failed: $msg');
      return false;
    } catch (e) {
      PushDiag.log('api: notify EXC $e');
      broLog('[PUSH] Notify failed: $e');
      return false;
    }
  }

  /// v539: Envia push de teste para si mesmo via endpoint dedicado
  /// (o /push/notify bloqueia self-notify).
  Future<bool> testSelfPush() async {
    try {
      final response = await _dio.post('/push/test-self');
      final ok = response.data?['ok'] == true;
      PushDiag.log('api: test-self status=${response.statusCode} ok=$ok body=${response.data}');
      return ok;
    } on DioException catch (e) {
      final msg = 'type=${e.type.name} code=${e.response?.statusCode} msg=${e.message} body=${e.response?.data}';
      PushDiag.log('api: test-self FAIL $msg');
      return false;
    } catch (e) {
      PushDiag.log('api: test-self EXC $e');
      return false;
    }
  }
}
