/// Serviço para decodificar códigos PIX localmente (sem backend)
class PixDecoderService {
  /// Decodifica um código PIX copia e cola (formato EMV)
  static Map<String, dynamic>? decodePix(String pixCode) {
    try {
      if (!pixCode.startsWith('00020')) {
        return null;
      }

      final data = _parseEmv(pixCode);
      
      // Extrair informações principais
      final merchantName = data['59'] ?? 'Destinatário não informado';
      final merchantCity = data['60'] ?? '';
      final amountStr = data['54'];
      final amount = amountStr != null && amountStr.isNotEmpty 
          ? double.tryParse(amountStr) 
          : null;
      
      // Tentar extrair chave PIX do campo 26 (merchant account information)
      String? pixKey;
      if (data['26'] != null) {
        final field26 = data['26'] as String;
        final subData = _parseEmv(field26);
        pixKey = subData['01']; // Chave PIX geralmente está em 01
      }
      
      return {
        'success': true,
        'billType': 'pix',
        'type': 'PIX Copia e Cola',
        'value': amount ?? 0.0,
        'merchantName': merchantName,
        'merchantCity': merchantCity,
        'pixKey': pixKey,
        'rawData': data,
      };
    } catch (e) {
      print('❌ Erro ao decodificar PIX: $e');
      return null;
    }
  }

  /// Parse do formato EMV (ID-Length-Value)
  static Map<String, String> _parseEmv(String emvString) {
    final Map<String, String> result = {};
    int i = 0;
    
    while (i < emvString.length - 4) {
      try {
        // ID: 2 caracteres
        final id = emvString.substring(i, i + 2);
        i += 2;
        
        // Length: 2 caracteres
        final lengthStr = emvString.substring(i, i + 2);
        final length = int.tryParse(lengthStr);
        if (length == null) break;
        i += 2;
        
        // Value: 'length' caracteres
        if (i + length > emvString.length) break;
        final value = emvString.substring(i, i + length);
        i += length;
        
        result[id] = value;
      } catch (e) {
        break;
      }
    }
    
    return result;
  }

  /// Valida se o código tem formato PIX
  static bool isValidPixFormat(String code) {
    return code.startsWith('00020') && code.length >= 100;
  }

  /// Extrai informações básicas para debug
  static String getPixSummary(String pixCode) {
    final data = decodePix(pixCode);
    if (data == null) return 'PIX inválido';
    
    return '''
PIX Decodificado:
- Beneficiário: ${data['merchantName']}
- Cidade: ${data['merchantCity']}
- Valor: ${data['value'] != null && data['value'] > 0 ? 'R\$ ${data['value'].toStringAsFixed(2)}' : 'Não especificado'}
- Chave PIX: ${data['pixKey'] ?? 'Não identificada'}
''';
  }
}
