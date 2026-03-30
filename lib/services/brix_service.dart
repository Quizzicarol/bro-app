import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:nostr/nostr.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:bro_app/services/storage_service.dart';

class BrixService {
  static final BrixService _instance = BrixService._internal();
  factory BrixService() => _instance;
  BrixService._internal();

  static const String _brixServerUrl = String.fromEnvironment(
    'BRIX_SERVER_URL',
    defaultValue: 'https://brix.brostr.app',
  );

  late final Dio _dio = Dio(BaseOptions(
    baseUrl: _brixServerUrl,
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 15),
    headers: {'Content-Type': 'application/json'},
  ));

  String get serverUrl => _brixServerUrl;

  String? _privateKey;

  /// Initialize NIP-98 credentials for cryptographically signed requests.
  Future<void> initCredentials() async {
    if (_privateKey != null) return;
    final storage = StorageService();
    _privateKey = await storage.getNostrPrivateKey();
  }

  /// Create Options with NIP-98 signed Authorization header.
  Options _signedOptions(String path, String method, {String? pubkey}) {
    final headers = <String, String>{};
    if (pubkey != null) headers['x-nostr-pubkey'] = pubkey;
    if (_privateKey != null) {
      try {
        final url = '$_brixServerUrl$path';
        final event = Event.from(
          kind: 27235,
          tags: [['u', url], ['method', method]],
          content: '',
          privkey: _privateKey!,
        );
        final eventMap = {
          'id': event.id,
          'pubkey': event.pubkey,
          'created_at': event.createdAt,
          'kind': event.kind,
          'tags': event.tags,
          'content': event.content,
          'sig': event.sig,
        };
        headers['Authorization'] = 'Nostr ${base64Encode(utf8.encode(jsonEncode(eventMap)))}';
      } catch (_) {}
    }
    return Options(headers: headers);
  }

  /// Check if a username is available
  Future<BrixUsernameCheckResult> checkUsername(String username) async {
    try {
      final response = await _dio.get('/brix/check-username/$username');
      final data = response.data;
      return BrixUsernameCheckResult(
        available: data['available'] == true,
        error: data['error'] as String?,
      );
    } on DioException catch (e) {
      return BrixUsernameCheckResult(available: false, error: 'Erro de conexão', isConnectionError: true);
    } catch (e) {
      return BrixUsernameCheckResult(available: false, error: 'Erro de conexão', isConnectionError: true);
    }
  }

  /// Register with username + phone + email
  Future<BrixRegisterResult> register({
    required String username,
    String? phone,
    String? email,
    String? nostrPubkey,
  }) async {
    try {
      final response = await _dio.post('/brix/register', data: {
        'username': username,
        if (phone != null && phone.isNotEmpty) 'phone': phone,
        if (email != null && email.isNotEmpty) 'email': email,
      }, options: Options(headers: {
        if (nostrPubkey != null) 'x-nostr-pubkey': nostrPubkey,
      }));
      final data = response.data;
      return BrixRegisterResult(
        success: data['success'] == true,
        userId: data['user_id'] as String?,
        username: data['username'] as String?,
        devCode: data['dev_code'] as String?,
        error: data['error'] as String?,
        verified: data['verified'] == true,
        brixAddress: data['brix_address'] as String?,
      );
    } on DioException catch (e) {
      final msg = e.response?.data?['error'] ?? 'Servidor BRIX indisponível';
      return BrixRegisterResult(success: false, error: msg.toString());
    } catch (e) {
      return BrixRegisterResult(success: false, error: 'Erro ao conectar ao servidor BRIX');
    }
  }

  /// Verify the 6-digit code
  Future<BrixVerifyResult> verify({
    required String userId,
    required String code,
  }) async {
    try {
      final response = await _dio.post('/brix/verify', data: {
        'user_id': userId,
        'code': code,
      });
      final data = response.data;
      return BrixVerifyResult(
        success: data['success'] == true,
        brixAddress: data['brix_address'] as String?,
        username: data['username'] as String?,
        error: data['error'] as String?,
      );
    } on DioException catch (e) {
      final msg = e.response?.data?['error'] ?? 'Servidor BRIX indisponível';
      return BrixVerifyResult(success: false, error: msg.toString());
    } catch (e) {
      return BrixVerifyResult(success: false, error: 'Erro ao conectar ao servidor BRIX');
    }
  }

  /// Resend verification code
  Future<BrixRegisterResult> resend({required String userId}) async {
    try {
      final response = await _dio.post('/brix/resend', data: {
        'user_id': userId,
      });
      final data = response.data;
      return BrixRegisterResult(
        success: data['success'] == true,
        userId: userId,
        devCode: data['dev_code'] as String?,
        error: data['error'] as String?,
      );
    } on DioException catch (e) {
      final msg = e.response?.data?['error'] ?? 'Servidor BRIX indisponível';
      return BrixRegisterResult(success: false, error: msg.toString());
    } catch (e) {
      return BrixRegisterResult(success: false, error: 'Erro ao conectar ao servidor BRIX');
    }
  }

  /// Get the BRIX address for a given Nostr pubkey
  Future<BrixAddressResult> getAddress(String pubkey) async {
    try {
      final response = await _dio.get('/brix/address/$pubkey',
        options: _signedOptions('/brix/address/$pubkey', 'GET', pubkey: pubkey),
      );
      final data = response.data;
      return BrixAddressResult(
        hasAddress: true,
        address: data['brix_address'] as String?,
        username: data['username'] as String?,
        phone: data['phone'] as String?,
        email: data['email'] as String?,
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return BrixAddressResult(hasAddress: false);
      }
      return BrixAddressResult(hasAddress: false);
    } catch (e) {
      return BrixAddressResult(hasAddress: false);
    }
  }

  /// Find BRIX by email (fallback for web-created BRIX)
  Future<BrixAddressResult> findByEmail(String email) async {
    try {
      final response = await _dio.get(
        '/brix/find-by-email/${Uri.encodeComponent(email)}',
        options: _signedOptions('/brix/find-by-email/${Uri.encodeComponent(email)}', 'GET'),
      );
      final data = response.data;
      return BrixAddressResult(
        hasAddress: true,
        address: data['brix_address'] as String?,
        username: data['username'] as String?,
        phone: data['phone'] as String?,
        email: data['email'] as String?,
        hasWebPubkey: data['has_web_pubkey'] == true,
      );
    } on DioException catch (e) {
      return BrixAddressResult(hasAddress: false);
    } catch (e) {
      return BrixAddressResult(hasAddress: false);
    }
  }

  /// Link a real nostr pubkey to a web-created BRIX
  Future<BrixVerifyResult> linkPubkey({required String username, required String nostrPubkey}) async {
    try {
      final response = await _dio.post('/brix/link-pubkey',
        data: {
          'username': username,
          'nostr_pubkey': nostrPubkey,
        },
        options: _signedOptions('/brix/link-pubkey', 'POST', pubkey: nostrPubkey),
      );
      final data = response.data;
      return BrixVerifyResult(
        success: data?['success'] == true,
        brixAddress: data?['brix_address'] as String?,
        username: data?['username'] as String?,
      );
    } on DioException catch (e) {
      final msg = e.response?.data?['error'] ?? 'Erro ao vincular BRIX';
      return BrixVerifyResult(success: false, error: msg.toString());
    } catch (e) {
      return BrixVerifyResult(success: false, error: 'Erro ao conectar ao servidor BRIX');
    }
  }

  /// Get pending payments for a pubkey
  Future<List<BrixPendingPayment>> getPendingPayments(String pubkey) async {
    try {
      final response = await _dio.get('/brix/pending-payments',
        options: _signedOptions('/brix/pending-payments', 'GET', pubkey: pubkey),
      );
      final data = response.data;
      final payments = data['payments'] as List? ?? [];
      return payments
          .map((p) => BrixPendingPayment(
                id: p['id'] as String,
                amountSats: p['amount_sats'] as int,
                senderNote: p['sender_note'] as String?,
                createdAt: p['created_at'] as String,
              ))
          .toList();
    } catch (e) {
      broLog('[BRIX] Error fetching pending payments: $e');
      return [];
    }
  }

  /// Health check
  Future<bool> isServerAvailable() async {
    try {
      final response = await _dio.get('/health');
      return response.data?['status'] == 'ok';
    } catch (e) {
      return false;
    }
  }

  /// Resolve phone, email, or username to a BRIX address
  Future<BrixResolveResult> resolve(String query) async {
    try {
      final response = await _dio.get(
        '/brix/resolve/${Uri.encodeComponent(query)}',
        options: _signedOptions('/brix/resolve/${Uri.encodeComponent(query)}', 'GET'),
      );
      final data = response.data;
      if (data['found'] == true) {
        return BrixResolveResult(
          found: true,
          brixAddress: data['brix_address'] as String?,
          username: data['username'] as String?,
          matchedBy: data['matched_by'] as String?,
          nostrPubkey: data['nostr_pubkey'] as String?,
        );
      }
      return BrixResolveResult(found: false);
    } catch (e) {
      return BrixResolveResult(found: false, error: 'Erro ao conectar ao servidor BRIX');
    }
  }

  /// Poll for pending invoice requests (called when BRIX is active)
  Future<List<BrixInvoiceRequest>> getInvoiceRequests(String pubkey, {String? username}) async {
    try {
      String path = '/brix/invoice-requests/$pubkey';
      if (username != null && username.isNotEmpty) {
        path += '?username=${Uri.encodeComponent(username)}';
      }
      final response = await _dio.get(path,
        options: _signedOptions('/brix/invoice-requests/$pubkey', 'GET', pubkey: pubkey),
      );
      final data = response.data;
      final requests = data['requests'] as List? ?? [];
      return requests.map((r) => BrixInvoiceRequest(
        id: r['id'] as String,
        amountSats: r['amount_sats'] as int,
        createdAt: r['created_at'] as String,
        comment: r['comment'] as String?,
      )).toList();
    } on DioException catch (e) {
      if (e.response?.statusCode == 403) {
        broLog('[BRIX] 403 Unauthorized polling invoice-requests');
      } else if (e.type == DioExceptionType.connectionTimeout || e.type == DioExceptionType.receiveTimeout) {
        broLog('[BRIX] Timeout polling invoice-requests');
      }
      return [];
    } catch (e) {
      broLog('[BRIX] Error polling invoice-requests: $e');
      return [];
    }
  }

  /// Submit a generated invoice for a pending request
  Future<bool> submitInvoice(String requestId, String invoice, String pubkey) async {
    try {
      final response = await _dio.post('/brix/submit-invoice',
        data: {'request_id': requestId, 'invoice': invoice},
        options: _signedOptions('/brix/submit-invoice', 'POST', pubkey: pubkey),
      );
      return response.data?['success'] == true;
    } catch (e) {
      return false;
    }
  }

  /// Claim a pending offline payment by submitting a recipient invoice
  Future<bool> claimPayment(String paymentId, String invoice, String pubkey) async {
    try {
      final response = await _dio.post('/brix/claim',
        data: {'payment_id': paymentId, 'invoice': invoice},
        options: _signedOptions('/brix/claim', 'POST', pubkey: pubkey),
      );
      return response.data?['success'] == true;
    } catch (e) {
      broLog('[BRIX] Error claiming payment: $e');
      return false;
    }
  }

  /// Request contact update (sends verification code to new contact)
  Future<BrixRegisterResult> updateContact({
    String? phone,
    String? email,
    required String pubkey,
  }) async {
    try {
      final response = await _dio.post('/brix/update-contact',
        data: {
          if (phone != null && phone.isNotEmpty) 'phone': phone,
          if (email != null && email.isNotEmpty) 'email': email,
        },
        options: _signedOptions('/brix/update-contact', 'POST', pubkey: pubkey),
      );
      final data = response.data;
      return BrixRegisterResult(
        success: data['success'] == true,
        devCode: data['dev_code'] as String?,
        error: data['error'] as String?,
      );
    } on DioException catch (e) {
      final msg = e.response?.data?['error'] ?? 'Erro ao atualizar';
      return BrixRegisterResult(success: false, error: msg.toString());
    } catch (e) {
      return BrixRegisterResult(success: false, error: 'Erro de conexão');
    }
  }

  /// Confirm contact update with verification code
  Future<BrixVerifyResult> confirmUpdate({
    required String code,
    required String pubkey,
    String? phone,
    String? email,
  }) async {
    try {
      final response = await _dio.post('/brix/confirm-update',
        data: {
          'code': code,
          if (phone != null && phone.isNotEmpty) 'phone': phone,
          if (email != null && email.isNotEmpty) 'email': email,
        },
        options: _signedOptions('/brix/confirm-update', 'POST', pubkey: pubkey),
      );
      final data = response.data;
      return BrixVerifyResult(
        success: data['success'] == true,
        brixAddress: data['brix_address'] as String?,
        error: data['error'] as String?,
      );
    } on DioException catch (e) {
      final msg = e.response?.data?['error'] ?? 'Código inválido';
      return BrixVerifyResult(success: false, error: msg.toString());
    } catch (e) {
      return BrixVerifyResult(success: false, error: 'Erro de conexão');
    }
  }

  /// Register FCM push token with BRIX server for offline notifications
  Future<bool> registerPushToken(String fcmToken, String pubkey) async {
    try {
      final response = await _dio.post('/brix/register-push',
        data: {'fcm_token': fcmToken},
        options: _signedOptions('/brix/register-push', 'POST', pubkey: pubkey),
      );
      return response.data?['success'] == true;
    } catch (e) {
      broLog('[BRIX] Error registering push token: $e');
      return false;
    }
  }

  /// Claim all web-created BRIX accounts with same email as the caller.
  /// Links them to the caller's pubkey so the relay picks up their invoices.
  Future<List<String>> claimWebAccounts(String pubkey) async {
    try {
      final response = await _dio.post('/brix/claim-web-accounts',
        options: _signedOptions('/brix/claim-web-accounts', 'POST', pubkey: pubkey),
      );
      final linked = response.data?['linked'] as List? ?? [];
      return linked.cast<String>();
    } catch (e) {
      return [];
    }
  }
}

class BrixUsernameCheckResult {
  final bool available;
  final String? error;
  final bool isConnectionError;

  BrixUsernameCheckResult({required this.available, this.error, this.isConnectionError = false});
}

class BrixRegisterResult {
  final bool success;
  final String? userId;
  final String? username;
  final String? devCode;
  final String? error;
  final bool verified;
  final String? brixAddress;

  BrixRegisterResult({required this.success, this.userId, this.username, this.devCode, this.error, this.verified = false, this.brixAddress});
}

class BrixVerifyResult {
  final bool success;
  final String? brixAddress;
  final String? username;
  final String? error;

  BrixVerifyResult({required this.success, this.brixAddress, this.username, this.error});
}

class BrixAddressResult {
  final bool hasAddress;
  final String? address;
  final String? username;
  final String? phone;
  final String? email;
  final bool hasWebPubkey;

  BrixAddressResult({required this.hasAddress, this.address, this.username, this.phone, this.email, this.hasWebPubkey = false});
}

class BrixPendingPayment {
  final String id;
  final int amountSats;
  final String? senderNote;
  final String createdAt;

  BrixPendingPayment({
    required this.id,
    required this.amountSats,
    this.senderNote,
    required this.createdAt,
  });
}

class BrixResolveResult {
  final bool found;
  final String? brixAddress;
  final String? username;
  final String? matchedBy;
  final String? nostrPubkey;
  final String? error;

  BrixResolveResult({required this.found, this.brixAddress, this.username, this.matchedBy, this.nostrPubkey, this.error});
}

class BrixInvoiceRequest {
  final String id;
  final int amountSats;
  final String createdAt;
  final String? comment;

  BrixInvoiceRequest({required this.id, required this.amountSats, required this.createdAt, this.comment});
}
