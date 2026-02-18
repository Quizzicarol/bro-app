import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Servi�o para resolver Lightning Addresses e LNURL (LNURL-pay)
/// Lightning Address: user@domain.com
/// LNURL: lnurl1dp68gurn8ghj7...
/// Resolve para uma invoice BOLT11 que pode ser paga
class LnAddressService {
  static final LnAddressService _instance = LnAddressService._internal();
  factory LnAddressService() => _instance;
  LnAddressService._internal();

  /// Verifica se � um Lightning Address v�lido
  static bool isLightningAddress(String input) {
    final cleaned = input.trim().toLowerCase();
    // Remove prefixos comuns
    final address = cleaned
        .replaceFirst('lightning:', '')
        .replaceFirst('lnurl:', '');
    
    // Lightning Address: user@domain.com
    return RegExp(r'^[\w\.-]+@[\w\.-]+\.\w{2,}$').hasMatch(address);
  }

  /// Verifica se � um LNURL (bech32 encoded)
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
      debugPrint('?? LNURL decodificado: $url');
      return url;
    } catch (e) {
      debugPrint('? Erro ao decodificar LNURL: $e');
      return null;
    }
  }

  /// Resolve um LNURL para obter os dados do LNURL-pay
  Future<Map<String, dynamic>> resolveLnurl(String lnurl) async {
    try {
      final url = decodeLnurl(lnurl);
      if (url == null) {
        return {'success': false, 'error': 'LNURL inv�lido'};
      }

      debugPrint('?? Resolvendo LNURL...');
      debugPrint('?? URL: $url');

      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        debugPrint('? Erro HTTP ${response.statusCode}: ${response.body}');
        return {
          'success': false,
          'error': 'N�o foi poss�vel resolver LNURL (HTTP ${response.statusCode})'
        };
      }

      final data = json.decode(response.body);
      
      // Verificar se � um LNURL-pay v�lido
      if (data['tag'] != 'payRequest') {
        return {
          'success': false,
          'error': 'LNURL n�o suporta pagamentos (tag: ${data['tag']})'
        };
      }

      // Extrair informa��es
      final minSendable = data['minSendable'] as int? ?? 1000;
      final maxSendable = data['maxSendable'] as int? ?? 100000000000;
      final callback = data['callback'] as String?;
      final metadata = data['metadata'] as String?;
      final commentAllowed = data['commentAllowed'] as int? ?? 0;

      debugPrint('? LNURL resolvido!');
      debugPrint('   Min: ${minSendable ~/ 1000} sats');
      debugPrint('   Max: ${maxSendable ~/ 1000} sats');
      debugPrint('   Callback: $callback');

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
      debugPrint('? Erro ao resolver LNURL: $e');
      return {
        'success': false,
        'error': 'Erro ao resolver LNURL: $e'
      };
    }
  }

  /// Resolve um Lightning Address para obter os dados LNURL-pay
  /// Retorna os metadados incluindo min/max amounts
  Future<Map<String, dynamic>> resolveLnAddress(String lnAddress) async {
    try {
      final cleaned = cleanAddress(lnAddress);
      final parts = cleaned.split('@');
      
      if (parts.length != 2) {
        return {'success': false, 'error': 'Lightning Address inv�lido'};
      }

      final username = parts[0];
      final domain = parts[1];
      
      // LNURL-pay endpoint: https://domain.com/.well-known/lnurlp/username
      final url = 'https://$domain/.well-known/lnurlp/$username';
      
      debugPrint('?? Resolvendo LN Address: $lnAddress');
      debugPrint('?? URL: $url');

      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        debugPrint('? Erro HTTP ${response.statusCode}: ${response.body}');
        return {
          'success': false, 
          'error': 'N�o foi poss�vel resolver o Lightning Address (HTTP ${response.statusCode})'
        };
      }

      final data = json.decode(response.body);
      
      // Verificar se � um LNURL-pay v�lido
      if (data['tag'] != 'payRequest') {
        return {
          'success': false,
          'error': 'Lightning Address n�o suporta pagamentos'
        };
      }

      // Extrair informa��es
      final minSendable = data['minSendable'] as int? ?? 1000; // em millisats
      final maxSendable = data['maxSendable'] as int? ?? 100000000000; // em millisats
      final callback = data['callback'] as String?;
      final metadata = data['metadata'] as String?;
      final commentAllowed = data['commentAllowed'] as int? ?? 0;

      debugPrint('? LN Address resolvido!');
      debugPrint('   Min: ${minSendable ~/ 1000} sats');
      debugPrint('   Max: ${maxSendable ~/ 1000} sats');
      debugPrint('   Callback: $callback');

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
      debugPrint('? Erro ao resolver LN Address: $e');
      return {
        'success': false,
        'error': 'Erro ao resolver Lightning Address: $e'
      };
    }
  }

  /// Obt�m uma invoice BOLT11 do Lightning Address ou LNURL para um valor espec�fico
  /// destination: LN Address (user@domain) ou LNURL (lnurl1...)
  /// amountSats: valor em satoshis
  /// comment: coment�rio opcional (se suportado)
  Future<Map<String, dynamic>> getInvoice({
    required String lnAddress,
    required int amountSats,
    String? comment,
  }) async {
    try {
      Map<String, dynamic> resolved;
      
      // Verificar se � LNURL ou Lightning Address
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
        return {'success': false, 'error': 'Callback n�o encontrado'};
      }

      // Validar valor
      if (amountSats < minSats) {
        return {
          'success': false,
          'error': 'Valor m�nimo: $minSats sats'
        };
      }

      if (amountSats > maxSats) {
        return {
          'success': false,
          'error': 'Valor m�ximo: $maxSats sats'
        };
      }

      // Construir URL com o valor em millisats
      final amountMsat = amountSats * 1000;
      var invoiceUrl = '$callback${callback.contains('?') ? '&' : '?'}amount=$amountMsat';
      
      // Adicionar coment�rio se permitido
      if (comment != null && comment.isNotEmpty && commentAllowed > 0) {
        final truncatedComment = comment.length > commentAllowed 
            ? comment.substring(0, commentAllowed) 
            : comment;
        invoiceUrl += '&comment=${Uri.encodeComponent(truncatedComment)}';
      }

      debugPrint('?? Obtendo invoice para $amountSats sats...');
      debugPrint('?? URL: $invoiceUrl');

      final response = await http.get(
        Uri.parse(invoiceUrl),
        headers: {
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        debugPrint('? Erro HTTP ${response.statusCode}: ${response.body}');
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
        return {'success': false, 'error': 'Invoice n�o recebida'};
      }

      debugPrint('? Invoice obtida: ${pr.substring(0, 50)}...');

      return {
        'success': true,
        'invoice': pr,
        'amountSats': amountSats,
        'lnAddress': lnAddress,
      };
    } catch (e) {
      debugPrint('? Erro ao obter invoice: $e');
      return {
        'success': false,
        'error': 'Erro ao obter invoice: $e'
      };
    }
  }
}
