import 'package:flutter/foundation.dart';

/// Decodificador local de boletos bancÃ¡rios brasileiros
/// Suporta boletos tradicionais (47 dÃ­gitos) e boletos de concessionÃ¡rias (48 dÃ­gitos)
class BoletoDecoderService {
  
  /// Decodifica linha digitÃ¡vel do boleto e extrai o valor
  /// Retorna null se nÃ£o for um boleto vÃ¡lido
  static Map<String, dynamic>? decodeBoleto(String code) {
    // Limpar cÃ³digo - remover espaÃ§os, pontos e hÃ­fens
    final cleanCode = code.replaceAll(RegExp(r'[^\d]'), '');
    
    debugPrint('ðŸ” BoletoDecoderService.decodeBoleto()');
    debugPrint('ðŸ” CÃ³digo original: ${code.length} chars');
    debugPrint('ðŸ” CÃ³digo limpo: ${cleanCode.length} dÃ­gitos');
    
    if (cleanCode.isEmpty) {
      debugPrint('âŒ CÃ³digo vazio apÃ³s limpeza');
      return null;
    }
    
    // Boleto bancÃ¡rio tradicional: 47 dÃ­gitos
    if (cleanCode.length == 47) {
      debugPrint('âœ… Detectado boleto bancÃ¡rio (47 dÃ­gitos)');
      return _decodeBoletoTradicional(cleanCode);
    }
    
    // Boleto de concessionÃ¡ria/convÃªnio: 48 dÃ­gitos
    if (cleanCode.length == 48) {
      debugPrint('âœ… Detectado boleto convÃªnio (48 dÃ­gitos)');
      return _decodeBoletoConvenio(cleanCode);
    }
    
    // CÃ³digo de barras direto: 44 dÃ­gitos
    if (cleanCode.length == 44) {
      debugPrint('âœ… Detectado cÃ³digo de barras (44 dÃ­gitos)');
      return _decodeCodigoBarras(cleanCode);
    }
    
    debugPrint('âŒ Tamanho invÃ¡lido: ${cleanCode.length} dÃ­gitos (esperado: 44, 47 ou 48)');
    return null;
  }
  
  /// Decodifica boleto bancÃ¡rio tradicional (47 dÃ­gitos)
  /// Formato: AAABC.CCCCX DDDDD.DDDDDY EEEEE.EEEEEZ K UUUUVVVVVVVVVV
  /// Onde o valor estÃ¡ nos Ãºltimos 10 dÃ­gitos (VVVVVVVVVV)
  static Map<String, dynamic>? _decodeBoletoTradicional(String code) {
    try {
      debugPrint('ðŸ” Decodificando boleto tradicional (47 dÃ­gitos)');
      debugPrint('ðŸ” CÃ³digo: $code');
      
      // Extrair campos da linha digitÃ¡vel
      final campo1 = code.substring(0, 10);   // PosiÃ§Ãµes 1-10
      final campo2 = code.substring(10, 21);  // PosiÃ§Ãµes 11-21
      final campo3 = code.substring(21, 32);  // PosiÃ§Ãµes 22-32
      final campo4 = code.substring(32, 33);  // PosiÃ§Ã£o 33 (dÃ­gito verificador geral)
      final campo5 = code.substring(33, 47);  // PosiÃ§Ãµes 34-47 (vencimento + valor)
      
      debugPrint('ðŸ“Š Campo1: $campo1');
      debugPrint('ðŸ“Š Campo2: $campo2');
      debugPrint('ðŸ“Š Campo3: $campo3');
      debugPrint('ðŸ“Š Campo4: $campo4');
      debugPrint('ðŸ“Š Campo5: $campo5');
      
      // Extrair valor do campo 5 (Ãºltimos 10 dÃ­gitos representam o valor)
      final valorStr = campo5.substring(4, 14); // Pular fator vencimento (4 dÃ­gitos)
      final valorCentavos = int.tryParse(valorStr) ?? 0;
      final valor = valorCentavos / 100.0;
      
      debugPrint('ðŸ’° Valor String: $valorStr');
      debugPrint('ðŸ’° Valor Centavos: $valorCentavos');
      debugPrint('ðŸ’° Valor Final: R\$ $valor');
      
      // Extrair fator de vencimento para calcular data
      final fatorVencimento = int.tryParse(campo5.substring(0, 4)) ?? 0;
      DateTime? dataVencimento;
      if (fatorVencimento > 0) {
        // Base: 07/10/1997
        final dataBase = DateTime(1997, 10, 7);
        dataVencimento = dataBase.add(Duration(days: fatorVencimento));
      }
      
      // Extrair cÃ³digo do banco (3 primeiros dÃ­gitos)
      final codigoBanco = code.substring(0, 3);
      final nomeBanco = _getNomeBanco(codigoBanco);
      
      debugPrint('ðŸ¦ Banco: $nomeBanco ($codigoBanco)');
      debugPrint('ðŸ“… Vencimento: $dataVencimento');
      
      return {
        'success': true,
        'billType': 'boleto',
        'type': 'boleto_bancario',
        'value': valor,
        'merchantName': nomeBanco,
        'bankCode': codigoBanco,
        'dueDate': dataVencimento?.toIso8601String(),
        'barcode': code,
        'message': 'Boleto decodificado localmente',
      };
    } catch (e) {
      debugPrint('âŒ Erro ao decodificar boleto tradicional: $e');
      return null;
    }
  }
  
  /// Decodifica boleto de concessionÃ¡ria/convÃªnio (48 dÃ­gitos)
  /// Usado para contas de luz, Ã¡gua, gÃ¡s, IPTU, telecomunicaÃ§Ãµes, etc.
  /// Estrutura: ABCD.EEEEEEEEEE-F GGGG.GGGGGGG-H IIII.IIIIIII-J KKKK.KKKKKKK-L
  static Map<String, dynamic>? _decodeBoletoConvenio(String code) {
    try {
      debugPrint('ðŸ” Decodificando boleto convÃªnio (48 dÃ­gitos)');
      debugPrint('ðŸ” CÃ³digo: $code');
      
      // Estrutura do cÃ³digo de barras de convÃªnio (48 dÃ­gitos na linha digitÃ¡vel):
      // A linha digitÃ¡vel tem 4 campos de 12 dÃ­gitos cada (48 total)
      // O cÃ³digo de barras original tem 44 dÃ­gitos
      
      // Para extrair o valor, precisamos reconstruir o cÃ³digo de barras:
      // Linha digitÃ¡vel: AAAAAAAAAAA-X BBBBBBBBBBB-Y CCCCCCCCCCC-Z DDDDDDDDDDD-W
      // CÃ³digo barras:   AAAAAAAAAAA   BBBBBBBBBBB   CCCCCCCCCCC   DDDDDDDDDDD
      
      // Remover dÃ­gitos verificadores (posiÃ§Ãµes 12, 24, 36, 48)
      final campo1 = code.substring(0, 11);   // 11 dÃ­gitos
      final campo2 = code.substring(12, 23);  // 11 dÃ­gitos
      final campo3 = code.substring(24, 35);  // 11 dÃ­gitos
      final campo4 = code.substring(36, 47);  // 11 dÃ­gitos
      
      final codigoBarras = campo1 + campo2 + campo3 + campo4; // 44 dÃ­gitos
      
      debugPrint('ðŸ“Š Campo1: $campo1');
      debugPrint('ðŸ“Š Campo2: $campo2');
      debugPrint('ðŸ“Š Campo3: $campo3');
      debugPrint('ðŸ“Š Campo4: $campo4');
      debugPrint('ðŸ“Š CÃ³digo de barras: $codigoBarras');
      
      // No cÃ³digo de barras de convÃªnio (44 dÃ­gitos):
      // PosiÃ§Ã£o 1: Identificador do produto (8 = arrecadaÃ§Ã£o)
      // PosiÃ§Ã£o 2: Identificador do segmento
      // PosiÃ§Ã£o 3: Identificador de valor efetivo ou referÃªncia
      // PosiÃ§Ã£o 4: DÃ­gito verificador geral
      // PosiÃ§Ãµes 5-15: Valor (11 dÃ­gitos, com 2 casas decimais)
      // PosiÃ§Ãµes 16-44: InformaÃ§Ãµes da empresa/convÃªnio
      
      final identificador = codigoBarras.substring(0, 1);
      final segmentoCode = codigoBarras.substring(1, 2);
      final tipoValor = codigoBarras.substring(2, 3);
      
      // Valor estÃ¡ nas posiÃ§Ãµes 5-15 (Ã­ndices 4-14) = 11 dÃ­gitos
      final valorStr = codigoBarras.substring(4, 15);
      final valorCentavos = int.tryParse(valorStr) ?? 0;
      final valor = valorCentavos / 100.0;
      
      debugPrint('ðŸ’° Identificador: $identificador');
      debugPrint('ðŸ’° Segmento: $segmentoCode');
      debugPrint('ðŸ’° Tipo Valor: $tipoValor');
      debugPrint('ðŸ’° Valor String: $valorStr');
      debugPrint('ðŸ’° Valor Centavos: $valorCentavos');
      debugPrint('ðŸ’° Valor Final: R\$ $valor');
      
      // Identificar o tipo de convÃªnio pelo segmento
      String tipoConvenio = 'ConvÃªnio';
      switch (segmentoCode) {
        case '1':
          tipoConvenio = 'Prefeituras';
          break;
        case '2':
          tipoConvenio = 'Saneamento';
          break;
        case '3':
          tipoConvenio = 'Energia/GÃ¡s';
          break;
        case '4':
          tipoConvenio = 'TelecomunicaÃ§Ãµes';
          break;
        case '5':
          tipoConvenio = 'Ã“rgÃ£os Governamentais';
          break;
        case '6':
          tipoConvenio = 'Carnes e Assemelhados';
          break;
        case '7':
          tipoConvenio = 'Multas de TrÃ¢nsito';
          break;
        case '8':
          tipoConvenio = 'Uso exclusivo do banco';
          break;
        case '9':
          tipoConvenio = 'Outros';
          break;
      }
      
      debugPrint('ðŸ¢ Tipo: $tipoConvenio');
      
      return {
        'success': true,
        'billType': 'boleto',
        'type': 'boleto_convenio',
        'value': valor,
        'merchantName': tipoConvenio,
        'segmento': segmentoCode,
        'barcode': code,
        'message': 'Boleto de convÃªnio decodificado localmente',
      };
    } catch (e) {
      debugPrint('âŒ Erro ao decodificar boleto convÃªnio: $e');
      return null;
    }
  }
  
  /// Decodifica cÃ³digo de barras direto (44 dÃ­gitos)
  static Map<String, dynamic>? _decodeCodigoBarras(String code) {
    try {
      // CÃ³digo de barras de boleto bancÃ¡rio (44 dÃ­gitos):
      // PosiÃ§Ãµes 1-3: CÃ³digo do banco
      // PosiÃ§Ã£o 4: CÃ³digo da moeda (9 = Real)
      // PosiÃ§Ã£o 5: DÃ­gito verificador geral
      // PosiÃ§Ãµes 6-9: Fator de vencimento
      // PosiÃ§Ãµes 10-19: Valor (10 dÃ­gitos, 8 inteiros + 2 decimais)
      // PosiÃ§Ãµes 20-44: Campo livre
      
      final codigoBanco = code.substring(0, 3);
      final fatorVencimento = int.tryParse(code.substring(5, 9)) ?? 0;
      final valorStr = code.substring(9, 19);
      final valorCentavos = int.tryParse(valorStr) ?? 0;
      final valor = valorCentavos / 100.0;
      
      DateTime? dataVencimento;
      if (fatorVencimento > 0) {
        final dataBase = DateTime(1997, 10, 7);
        dataVencimento = dataBase.add(Duration(days: fatorVencimento));
      }
      
      final nomeBanco = _getNomeBanco(codigoBanco);
      
      return {
        'success': true,
        'billType': 'boleto',
        'type': 'codigo_barras',
        'value': valor,
        'merchantName': nomeBanco,
        'bankCode': codigoBanco,
        'dueDate': dataVencimento?.toIso8601String(),
        'barcode': code,
        'message': 'CÃ³digo de barras decodificado localmente',
      };
    } catch (e) {
      debugPrint('âŒ Erro ao decodificar cÃ³digo de barras: $e');
      return null;
    }
  }
  
  /// Retorna o nome do banco pelo cÃ³digo
  static String _getNomeBanco(String codigo) {
    final bancos = {
      '001': 'Banco do Brasil',
      '033': 'Santander',
      '104': 'Caixa EconÃ´mica',
      '237': 'Bradesco',
      '341': 'ItaÃº',
      '356': 'Banco Real',
      '389': 'Mercantil do Brasil',
      '399': 'HSBC',
      '422': 'Safra',
      '453': 'Rural',
      '633': 'Rendimento',
      '652': 'ItaÃº Unibanco',
      '745': 'Citibank',
      '756': 'Sicoob',
      '748': 'Sicredi',
      '077': 'Inter',
      '260': 'Nubank',
      '336': 'C6 Bank',
      '212': 'Original',
      '655': 'Votorantim',
      '246': 'ABC Brasil',
      '025': 'Alfa',
      '641': 'Alvorada',
      '029': 'Banerj',
      '000': 'Bankpar',
      '740': 'Barclays',
      '107': 'BBM',
      '031': 'Beg',
      '096': 'BM&F',
      '318': 'BMG',
      '752': 'BNP Paribas',
      '248': 'Boavista',
      '218': 'Bonsucesso',
      '065': 'Bracce',
      '036': 'Bradesco BBI',
      '394': 'Bradesco Financiamentos',
      '204': 'Bradesco CartÃµes',
      '225': 'Brascan',
      '044': 'BVA',
      '263': 'Cacique',
      '473': 'Caixa Geral',
      '040': 'Cargill',
      '745': 'Citibank',
      '477': 'Citibank',
      '081': 'ConcÃ³rdia',
      '707': 'Daycoval',
      '487': 'Deutsche',
      '751': 'Dresdner',
      '064': 'Goldman Sachs',
      '062': 'Hipercard',
      '399': 'HSBC',
      '168': 'HSBC Finance',
      '492': 'ING',
      '998': 'ItaÃº',
      '652': 'ItaÃº Holding',
      '341': 'ItaÃº Unibanco',
      '079': 'JBS',
      '376': 'J.P. Morgan',
      '074': 'J. Safra',
      '600': 'Luso Brasileiro',
      '389': 'Mercantil do Brasil',
      '746': 'Modal',
      '045': 'Opportunity',
      '079': 'Original Agro',
      '623': 'Pan',
      '611': 'Paulista',
      '613': 'PecÃºnia',
      '094': 'Petra',
      '643': 'Pine',
      '747': 'Rabobank',
      '633': 'Rendimento',
      '741': 'RibeirÃ£o Preto',
      '453': 'Rural',
      '422': 'Safra',
      '033': 'Santander',
      '955': 'Santander',
      '250': 'Schahin',
      '749': 'Simples',
      '366': 'SociÃ©tÃ© GÃ©nÃ©rale',
      '637': 'Sofisa',
      '012': 'Standard',
      '082': 'TopÃ¡zio',
      '464': 'Sumitomo',
      '634': 'TriÃ¢ngulo',
      '208': 'UBS Pactual',
      '116': 'Ãšnico',
      '655': 'Votorantim',
      '610': 'VR',
      '370': 'Mizuho',
      '021': 'Banestes',
      '719': 'Banif',
      '755': 'Bank of America',
      '744': 'BankBoston',
      '073': 'BB CartÃµes',
      '078': 'BES',
      '069': 'BPN',
      '070': 'BRB',
      '249': 'Credicard',
      '075': 'CR2',
      '088': 'Fator',
      '233': 'GE Capital',
      '612': 'Guanabara',
      '630': 'Intercap',
      '077': 'Inter',
      '653': 'Indusval',
      '249': 'Investcred',
      '184': 'ItaÃº BBA',
      '479': 'ItaÃº Bank Boston',
      '604': 'Industrial do Brasil',
      '320': 'Industrial e Comercial',
      '653': 'Indusval',
    };
    
    return bancos[codigo] ?? 'Banco $codigo';
  }
}
