import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:http/http.dart' as http;

/// Serviço para resolver Lightning Addresses e LNURL (LNURL-pay)
/// Lightning Address: user@domain.com
/// LNURL: lnurl1dp68gurn8ghj7...
/// Resolve para uma invoice BOLT11 que pode ser paga
class LnAddressService {
  static final LnAddressService _instance = LnAddressService._internal();
  factory LnAddressService() => _instance;
  LnAddressService._internal();

  /// Verifica se é um Lightning Address válido
  static bool isLightningAddress(String input) {
    final cleaned = input.trim().toLowerCase();
    // Remove prefixos comuns
    final address = cleaned
        .replaceFirst('lightning:', '')
        .replaceFirst('lnurl:', '');
    
    // Lightning Address: user@domain.com
    return RegExp(r'^[\w\.-]+@[\w\.-]+\.\w{2,}$').hasMatch(address);
  }

  /// Verifica se é um LNURL (bech32 encoded)
  static bool isLnurl(String input) {
    final cleaned = input.trim().toLowerCase();
    return cleaned.startsWith('lnurl1') || cleaned.startsWith('lnurl:');
  }

  /// Extrai o LN Address limpo (sem prefixos)
  static String cleanAddress(String input) {
    return input
        .trim()
        .toLowerCase()
        .replaceFirst('lightning:', '')
        .replaceFirst('lnurl:', '');
  }

  /// Decodifica um LNURL (bech32) para obter a URL original
  static String? decodeLnurl(String lnurl) {
    try {
      String cleaned = lnurl.trim().toLowerCase();
      if (cleaned.startsWith('lnurl:')) {
        cleaned = cleaned.substring(6);
      }
      if (!cleaned.startsWith('lnurl1')) {
        return null;
      }
      
      // Bech32 decode
      // LNURL uses bech32 encoding with "lnurl" as HRP
      const charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
      
      // Find the separator (always '1' and it's the last '1' in the string)
      final separatorIndex = cleaned.lastIndexOf('1');
      if (separatorIndex < 1) return null;
      
      final data = cleaned.substring(separatorIndex + 1);
      
      // Convert from bech32 charset to 5-bit values
      final List<int> values = [];
      for (int i = 0; i < data.length; i++) {
        final idx = charset.indexOf(data[i]);
        if (idx == -1) return null;
        values.add(idx);
      }
      
      // Remove checksum (last 6 values)
      if (values.length < 6) return null;
      final dataValues = values.sublist(0, values.length - 6);
      
      // Convert 5-bit values to 8-bit bytes
      final List<int> bytes = [];
      int acc = 0;
      int bits = 0;
      for (final value in dataValues) {
        acc = (acc << 5) | value;
        bits += 5;
        while (bits >= 8) {
          bits -= 8;
          bytes.add((acc >> bits) & 0xff);
        }
      }
      
      // Convert bytes to string (URL)
      final url = utf8.decode(bytes);
      broLog('🔓 LNURL decodificado: $url');
      return url;
    } catch (e) {
      broLog('❌ Erro ao decodificar LNURL: $e');
      return null;
    }
  }

  /// Resolve um LNURL para obter os dados do LNURL-pay
  Future<Map<String, dynamic>> resolveLnurl(String lnurl) async {
    try {
      final url = decodeLnurl(lnurl);
      if (url == null) {
        return {'success': false, 'error': 'LNURL inválido'};
      }

      broLog('🔍 Resolvendo LNURL...');
      broLog('🌐 URL: $url');

      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        broLog('❌ Erro HTTP ${response.statusCode}: ${response.body}');
        return {
          'success': false,
          'error': 'Não foi possível resolver LNURL (HTTP ${response.statusCode})'
        };
      }

      final data = json.decode(response.body);
      
      // Verificar se é um LNURL-pay válido
      if (data['tag'] != 'payRequest') {
        return {
          'success': false,
          'error': 'LNURL não suporta pagamentos (tag: ${data['tag']})'
        };
      }

      // Extrair informações
      final minSendable = data['minSendable'] as int? ?? 1000;
      final maxSendable = data['maxSendable'] as int? ?? 100000000000;
      final callback = data['callback'] as String?;
      final metadata = data['metadata'] as String?;
      final commentAllowed = data['commentAllowed'] as int? ?? 0;

      broLog('✅ LNURL resolvido!');
      broLog('   Min: ${minSendable ~/ 1000} sats');
      broLog('   Max: ${maxSendable ~/ 1000} sats');
      broLog('   Callback: $callback');

      return {
        'success': true,
        'minSats': minSendable ~/ 1000,
        'maxSats': maxSendable ~/ 1000,
        'callback': callback,
        'metadata': metadata,
        'commentAllowed': commentAllowed,
        'isLnurl': true,
      };
    } catch (e) {
      broLog('❌ Erro ao resolver LNURL: $e');
      return {
        'success': false,
        'error': 'Erro ao resolver LNURL: $e'
      };
    }
  }

  /// Domínios BRIX que devem ser resolvidos via servidor local
  static const _brixDomains = ['brix.app', 'brostr.app', 'brix.brostr.app'];

  /// URL do servidor BRIX (from environment)
  static const String _brixServerUrl = String.fromEnvironment(
    'BRIX_SERVER_URL',
    defaultValue: 'https://brix.brostr.app',
  );

  /// Resolve um Lightning Address para obter os dados LNURL-pay
  /// Retorna os metadados incluindo min/max amounts
  Future<Map<String, dynamic>> resolveLnAddress(String lnAddress) async {
    try {
      final cleaned = cleanAddress(lnAddress);
      final parts = cleaned.split('@');
      
      if (parts.length != 2) {
        return {'success': false, 'error': 'Lightning Address inválido'};
      }

      final username = parts[0];
      final domain = parts[1];
      
      // BRIX addresses route to the BRIX server
      String url;
      if (_brixDomains.contains(domain.toLowerCase())) {
        url = '$_brixServerUrl/.well-known/lnurlp/$username';
        broLog('🔗 BRIX address detected, routing to BRIX server');
      } else {
        url = 'https://$domain/.well-known/lnurlp/$username';
      }
      
      broLog('🔍 Resolvendo LN Address: $lnAddress');
      broLog('🌐 URL: $url');

      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        broLog('❌ Erro HTTP ${response.statusCode}: ${response.body}');
        return {
          'success': false, 
          'error': 'Não foi possível resolver o Lightning Address (HTTP ${response.statusCode})'
        };
      }

      // Validate response is JSON before parsing
      final body = response.body.trim();
      if (body.isEmpty || (!body.startsWith('{') && !body.startsWith('['))) {
        broLog('❌ Resposta não é JSON: ${body.substring(0, body.length > 100 ? 100 : body.length)}');
        return {
          'success': false,
          'error': 'Este endereço não suporta Lightning payments'
        };
      }

      final data = json.decode(body);
      
      // Verificar se é um LNURL-pay válido
      if (data['tag'] != 'payRequest') {
        return {
          'success': false,
          'error': 'Lightning Address não suporta pagamentos'
        };
      }

      // Extrair informações
      final minSendable = data['minSendable'] as int? ?? 1000; // em millisats
      final maxSendable = data['maxSendable'] as int? ?? 100000000000; // em millisats
      final callback = data['callback'] as String?;
      final metadata = data['metadata'] as String?;
      final commentAllowed = data['commentAllowed'] as int? ?? 0;

      broLog('✅ LN Address resolvido!');
      broLog('   Min: ${minSendable ~/ 1000} sats');
      broLog('   Max: ${maxSendable ~/ 1000} sats');
      broLog('   Callback: $callback');

      return {
        'success': true,
        'minSats': minSendable ~/ 1000,
        'maxSats': maxSendable ~/ 1000,
        'callback': callback,
        'metadata': metadata,
        'commentAllowed': commentAllowed,
        'lnAddress': cleaned,
      };
    } catch (e) {
      broLog('❌ Erro ao resolver LN Address: $e');
      return {
        'success': false,
        'error': 'Erro ao resolver Lightning Address: $e'
      };
    }
  }

  /// Obtém uma invoice BOLT11 do Lightning Address ou LNURL para um valor específico
  /// destination: LN Address (user@domain) ou LNURL (lnurl1...)
  /// amountSats: valor em satoshis
  /// comment: comentário opcional (se suportado)
  Future<Map<String, dynamic>> getInvoice({
    required String lnAddress,
    required int amountSats,
    String? comment,
  }) async {
    try {
      Map<String, dynamic> resolved;
      
      // Verificar se é LNURL ou Lightning Address
      if (isLnurl(lnAddress)) {
        resolved = await resolveLnurl(lnAddress);
      } else {
        resolved = await resolveLnAddress(lnAddress);
      }
      
      if (resolved['success'] != true) {
        return resolved;
      }

      final callback = resolved['callback'] as String?;
      final minSats = resolved['minSats'] as int;
      final maxSats = resolved['maxSats'] as int;
      final commentAllowed = resolved['commentAllowed'] as int;

      if (callback == null) {
        return {'success': false, 'error': 'Callback não encontrado'};
      }

      // Validar valor
      if (amountSats < minSats) {
        return {
          'success': false,
          'error': 'Valor mínimo: $minSats sats'
        };
      }

      if (amountSats > maxSats) {
        return {
          'success': false,
          'error': 'Valor máximo: $maxSats sats'
        };
      }

      // Construir URL com o valor em millisats
      final amountMsat = amountSats * 1000;
      
      var invoiceUrl = '$callback${callback.contains('?') ? '&' : '?'}amount=$amountMsat';
      
      // BRIX relay polls for up to 25s, so use 30s timeout for BRIX addresses
      final isBrix = !isLnurl(lnAddress) && _brixDomains.any((d) => lnAddress.toLowerCase().endsWith('@$d') || lnAddress.toLowerCase().endsWith('@brix.$d'));

      // Tell BRIX server this is a BRIX app sender (Spark→Spark direct)
      if (isBrix) {
        invoiceUrl += '&source=brix';
      }

      // Adicionar comentário se permitido
      if (comment != null && comment.isNotEmpty && commentAllowed > 0) {
        final truncatedComment = comment.length > commentAllowed 
            ? comment.substring(0, commentAllowed) 
            : comment;
        invoiceUrl += '&comment=${Uri.encodeComponent(truncatedComment)}';
      }

      broLog('💸 Obtendo invoice para $amountSats sats...');
      broLog('🌐 URL: $invoiceUrl');
      final timeoutDuration = isBrix ? const Duration(seconds: 30) : const Duration(seconds: 15);

      final response = await http.get(
        Uri.parse(invoiceUrl),
        headers: {
          'Accept': 'application/json',
        },
      ).timeout(timeoutDuration);

      if (response.statusCode != 200) {
        broLog('❌ Erro HTTP ${response.statusCode}: ${response.body}');
        return {
          'success': false,
          'error': 'Erro ao obter invoice (HTTP ${response.statusCode})'
        };
      }

      final data = json.decode(response.body);
      
      // Verificar erro na resposta
      if (data['status'] == 'ERROR' || data['reason'] != null) {
        final reason = data['reason'] ?? 'Erro desconhecido';
        return {'success': false, 'error': reason};
      }

      final pr = data['pr'] as String?; // payment request (invoice BOLT11)
      
      if (pr == null || pr.isEmpty) {
        return {'success': false, 'error': 'Invoice não recebida'};
      }

      broLog('✅ Invoice obtida: ${pr.substring(0, 50)}...');

      return {
        'success': true,
        'invoice': pr,
        'amountSats': amountSats,
        'lnAddress': lnAddress,
      };
    } catch (e) {
      broLog('❌ Erro ao obter invoice: $e');
      return {
        'success': false,
        'error': 'Erro ao obter invoice: $e'
      };
    }
  }
}
