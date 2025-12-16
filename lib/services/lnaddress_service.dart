import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Serviço para resolver Lightning Addresses (LNURL-pay)
/// Lightning Address: user@domain.com
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

  /// Extrai o LN Address limpo (sem prefixos)
  static String cleanAddress(String input) {
    return input
        .trim()
        .toLowerCase()
        .replaceFirst('lightning:', '')
        .replaceFirst('lnurl:', '');
  }

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
      
      // LNURL-pay endpoint: https://domain.com/.well-known/lnurlp/username
      final url = 'https://$domain/.well-known/lnurlp/$username';
      
      debugPrint('🔍 Resolvendo LN Address: $lnAddress');
      debugPrint('🌐 URL: $url');

      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        debugPrint('❌ Erro HTTP ${response.statusCode}: ${response.body}');
        return {
          'success': false, 
          'error': 'Não foi possível resolver o Lightning Address (HTTP ${response.statusCode})'
        };
      }

      final data = json.decode(response.body);
      
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

      debugPrint('✅ LN Address resolvido!');
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
      debugPrint('❌ Erro ao resolver LN Address: $e');
      return {
        'success': false,
        'error': 'Erro ao resolver Lightning Address: $e'
      };
    }
  }

  /// Obtém uma invoice BOLT11 do Lightning Address para um valor específico
  /// amountSats: valor em satoshis
  /// comment: comentário opcional (se suportado)
  Future<Map<String, dynamic>> getInvoice({
    required String lnAddress,
    required int amountSats,
    String? comment,
  }) async {
    try {
      // Primeiro, resolver o LN Address para obter o callback
      final resolved = await resolveLnAddress(lnAddress);
      
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
      
      // Adicionar comentário se permitido
      if (comment != null && comment.isNotEmpty && commentAllowed > 0) {
        final truncatedComment = comment.length > commentAllowed 
            ? comment.substring(0, commentAllowed) 
            : comment;
        invoiceUrl += '&comment=${Uri.encodeComponent(truncatedComment)}';
      }

      debugPrint('💸 Obtendo invoice para $amountSats sats...');
      debugPrint('🌐 URL: $invoiceUrl');

      final response = await http.get(
        Uri.parse(invoiceUrl),
        headers: {
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        debugPrint('❌ Erro HTTP ${response.statusCode}: ${response.body}');
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

      debugPrint('✅ Invoice obtida: ${pr.substring(0, 50)}...');

      return {
        'success': true,
        'invoice': pr,
        'amountSats': amountSats,
        'lnAddress': lnAddress,
      };
    } catch (e) {
      debugPrint('❌ Erro ao obter invoice: $e');
      return {
        'success': false,
        'error': 'Erro ao obter invoice: $e'
      };
    }
  }
}
