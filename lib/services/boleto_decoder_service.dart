/// Decodificador local de boletos banc�rios brasileiros
/// Suporta boletos tradicionais (47 d�gitos) e boletos de concession�rias (48 d�gitos)
class BoletoDecoderService {
  
  /// Decodifica linha digit�vel do boleto e extrai o valor
  /// Retorna null se n�o for um boleto v�lido
  static Map<String, dynamic>? decodeBoleto(String code) {
    // Limpar c�digo - remover espa�os, pontos e h�fens
    final cleanCode = code.replaceAll(RegExp(r'[^\d]'), '');
    
    print('?? BoletoDecoderService.decodeBoleto()');
    print('?? C�digo original: ${code.length} chars');
    print('?? C�digo limpo: ${cleanCode.length} d�gitos');
    
    if (cleanCode.isEmpty) {
      print('? C�digo vazio ap�s limpeza');
      return null;
    }
    
    // Boleto banc�rio tradicional: 47 d�gitos
    if (cleanCode.length == 47) {
      print('? Detectado boleto banc�rio (47 d�gitos)');
      return _decodeBoletoTradicional(cleanCode);
    }
    
    // Boleto de concession�ria/conv�nio: 48 d�gitos
    if (cleanCode.length == 48) {
      print('? Detectado boleto conv�nio (48 d�gitos)');
      return _decodeBoletoConvenio(cleanCode);
    }
    
    // C�digo de barras direto: 44 d�gitos
    if (cleanCode.length == 44) {
      print('? Detectado c�digo de barras (44 d�gitos)');
      return _decodeCodigoBarras(cleanCode);
    }
    
    print('? Tamanho inv�lido: ${cleanCode.length} d�gitos (esperado: 44, 47 ou 48)');
    return null;
  }
  
  /// Decodifica boleto banc�rio tradicional (47 d�gitos)
  /// Formato: AAABC.CCCCX DDDDD.DDDDDY EEEEE.EEEEEZ K UUUUVVVVVVVVVV
  /// Onde o valor est� nos �ltimos 10 d�gitos (VVVVVVVVVV)
  static Map<String, dynamic>? _decodeBoletoTradicional(String code) {
    try {
      print('?? Decodificando boleto tradicional (47 d�gitos)');
      print('?? C�digo: $code');
      
      // Extrair campos da linha digit�vel
      final campo1 = code.substring(0, 10);   // Posi��es 1-10
      final campo2 = code.substring(10, 21);  // Posi��es 11-21
      final campo3 = code.substring(21, 32);  // Posi��es 22-32
      final campo4 = code.substring(32, 33);  // Posi��o 33 (d�gito verificador geral)
      final campo5 = code.substring(33, 47);  // Posi��es 34-47 (vencimento + valor)
      
      print('?? Campo1: $campo1');
      print('?? Campo2: $campo2');
      print('?? Campo3: $campo3');
      print('?? Campo4: $campo4');
      print('?? Campo5: $campo5');
      
      // Extrair valor do campo 5 (�ltimos 10 d�gitos representam o valor)
      final valorStr = campo5.substring(4, 14); // Pular fator vencimento (4 d�gitos)
      final valorCentavos = int.tryParse(valorStr) ?? 0;
      final valor = valorCentavos / 100.0;
      
      print('?? Valor String: $valorStr');
      print('?? Valor Centavos: $valorCentavos');
      print('?? Valor Final: R\$ $valor');
      
      // Extrair fator de vencimento para calcular data
      final fatorVencimento = int.tryParse(campo5.substring(0, 4)) ?? 0;
      DateTime? dataVencimento;
      if (fatorVencimento > 0) {
        // Base: 07/10/1997
        final dataBase = DateTime(1997, 10, 7);
        dataVencimento = dataBase.add(Duration(days: fatorVencimento));
      }
      
      // Extrair c�digo do banco (3 primeiros d�gitos)
      final codigoBanco = code.substring(0, 3);
      final nomeBanco = _getNomeBanco(codigoBanco);
      
      print('?? Banco: $nomeBanco ($codigoBanco)');
      print('?? Vencimento: $dataVencimento');
      
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
      print('? Erro ao decodificar boleto tradicional: $e');
      return null;
    }
  }
  
  /// Decodifica boleto de concession�ria/conv�nio (48 d�gitos)
  /// Usado para contas de luz, �gua, g�s, IPTU, telecomunica��es, etc.
  /// Estrutura: ABCD.EEEEEEEEEE-F GGGG.GGGGGGG-H IIII.IIIIIII-J KKKK.KKKKKKK-L
  static Map<String, dynamic>? _decodeBoletoConvenio(String code) {
    try {
      print('?? Decodificando boleto conv�nio (48 d�gitos)');
      print('?? C�digo: $code');
      
      // Estrutura do c�digo de barras de conv�nio (48 d�gitos na linha digit�vel):
      // A linha digit�vel tem 4 campos de 12 d�gitos cada (48 total)
      // O c�digo de barras original tem 44 d�gitos
      
      // Para extrair o valor, precisamos reconstruir o c�digo de barras:
      // Linha digit�vel: AAAAAAAAAAA-X BBBBBBBBBBB-Y CCCCCCCCCCC-Z DDDDDDDDDDD-W
      // C�digo barras:   AAAAAAAAAAA   BBBBBBBBBBB   CCCCCCCCCCC   DDDDDDDDDDD
      
      // Remover d�gitos verificadores (posi��es 12, 24, 36, 48)
      final campo1 = code.substring(0, 11);   // 11 d�gitos
      final campo2 = code.substring(12, 23);  // 11 d�gitos
      final campo3 = code.substring(24, 35);  // 11 d�gitos
      final campo4 = code.substring(36, 47);  // 11 d�gitos
      
      final codigoBarras = campo1 + campo2 + campo3 + campo4; // 44 d�gitos
      
      print('?? Campo1: $campo1');
      print('?? Campo2: $campo2');
      print('?? Campo3: $campo3');
      print('?? Campo4: $campo4');
      print('?? C�digo de barras: $codigoBarras');
      
      // No c�digo de barras de conv�nio (44 d�gitos):
      // Posi��o 1: Identificador do produto (8 = arrecada��o)
      // Posi��o 2: Identificador do segmento
      // Posi��o 3: Identificador de valor efetivo ou refer�ncia
      // Posi��o 4: D�gito verificador geral
      // Posi��es 5-15: Valor (11 d�gitos, com 2 casas decimais)
      // Posi��es 16-44: Informa��es da empresa/conv�nio
      
      final identificador = codigoBarras.substring(0, 1);
      final segmentoCode = codigoBarras.substring(1, 2);
      final tipoValor = codigoBarras.substring(2, 3);
      
      // Valor est� nas posi��es 5-15 (�ndices 4-14) = 11 d�gitos
      final valorStr = codigoBarras.substring(4, 15);
      final valorCentavos = int.tryParse(valorStr) ?? 0;
      final valor = valorCentavos / 100.0;
      
      print('?? Identificador: $identificador');
      print('?? Segmento: $segmentoCode');
      print('?? Tipo Valor: $tipoValor');
      print('?? Valor String: $valorStr');
      print('?? Valor Centavos: $valorCentavos');
      print('?? Valor Final: R\$ $valor');
      
      // Identificar o tipo de conv�nio pelo segmento
      String tipoConvenio = 'Conv�nio';
      switch (segmentoCode) {
        case '1':
          tipoConvenio = 'Prefeituras';
          break;
        case '2':
          tipoConvenio = 'Saneamento';
          break;
        case '3':
          tipoConvenio = 'Energia/G�s';
          break;
        case '4':
          tipoConvenio = 'Telecomunica��es';
          break;
        case '5':
          tipoConvenio = '�rg�os Governamentais';
          break;
        case '6':
          tipoConvenio = 'Carnes e Assemelhados';
          break;
        case '7':
          tipoConvenio = 'Multas de Tr�nsito';
          break;
        case '8':
          tipoConvenio = 'Uso exclusivo do banco';
          break;
        case '9':
          tipoConvenio = 'Outros';
          break;
      }
      
      print('?? Tipo: $tipoConvenio');
      
      return {
        'success': true,
        'billType': 'boleto',
        'type': 'boleto_convenio',
        'value': valor,
        'merchantName': tipoConvenio,
        'segmento': segmentoCode,
        'barcode': code,
        'message': 'Boleto de conv�nio decodificado localmente',
      };
    } catch (e) {
      print('? Erro ao decodificar boleto conv�nio: $e');
      return null;
    }
  }
  
  /// Decodifica c�digo de barras direto (44 d�gitos)
  static Map<String, dynamic>? _decodeCodigoBarras(String code) {
    try {
      // C�digo de barras de boleto banc�rio (44 d�gitos):
      // Posi��es 1-3: C�digo do banco
      // Posi��o 4: C�digo da moeda (9 = Real)
      // Posi��o 5: D�gito verificador geral
      // Posi��es 6-9: Fator de vencimento
      // Posi��es 10-19: Valor (10 d�gitos, 8 inteiros + 2 decimais)
      // Posi��es 20-44: Campo livre
      
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
        'message': 'C�digo de barras decodificado localmente',
      };
    } catch (e) {
      print('? Erro ao decodificar c�digo de barras: $e');
      return null;
    }
  }
  
  /// Retorna o nome do banco pelo c�digo
  static String _getNomeBanco(String codigo) {
    final bancos = {
      '001': 'Banco do Brasil',
      '033': 'Santander',
      '104': 'Caixa Econ�mica',
      '237': 'Bradesco',
      '341': 'Ita�',
      '356': 'Banco Real',
      '389': 'Mercantil do Brasil',
      '399': 'HSBC',
      '422': 'Safra',
      '453': 'Rural',
      '633': 'Rendimento',
      '652': 'Ita� Unibanco',
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
      '204': 'Bradesco Cart�es',
      '225': 'Brascan',
      '044': 'BVA',
      '263': 'Cacique',
      '473': 'Caixa Geral',
      '040': 'Cargill',
      '745': 'Citibank',
      '477': 'Citibank',
      '081': 'Conc�rdia',
      '707': 'Daycoval',
      '487': 'Deutsche',
      '751': 'Dresdner',
      '064': 'Goldman Sachs',
      '062': 'Hipercard',
      '399': 'HSBC',
      '168': 'HSBC Finance',
      '492': 'ING',
      '998': 'Ita�',
      '652': 'Ita� Holding',
      '341': 'Ita� Unibanco',
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
      '613': 'Pec�nia',
      '094': 'Petra',
      '643': 'Pine',
      '747': 'Rabobank',
      '633': 'Rendimento',
      '741': 'Ribeir�o Preto',
      '453': 'Rural',
      '422': 'Safra',
      '033': 'Santander',
      '955': 'Santander',
      '250': 'Schahin',
      '749': 'Simples',
      '366': 'Soci�t� G�n�rale',
      '637': 'Sofisa',
      '012': 'Standard',
      '082': 'Top�zio',
      '464': 'Sumitomo',
      '634': 'Tri�ngulo',
      '208': 'UBS Pactual',
      '116': '�nico',
      '655': 'Votorantim',
      '610': 'VR',
      '370': 'Mizuho',
      '021': 'Banestes',
      '719': 'Banif',
      '755': 'Bank of America',
      '744': 'BankBoston',
      '073': 'BB Cart�es',
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
      '184': 'Ita� BBA',
      '479': 'Ita� Bank Boston',
      '604': 'Industrial do Brasil',
      '320': 'Industrial e Comercial',
      '653': 'Indusval',
    };
    
    return bancos[codigo] ?? 'Banco $codigo';
  }
}
