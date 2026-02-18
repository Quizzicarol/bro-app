/// Decodificador local de boletos bancários brasileiros
/// Suporta boletos tradicionais (47 dígitos) e boletos de concessionárias (48 dígitos)
class BoletoDecoderService {
  
  /// Decodifica linha digitável do boleto e extrai o valor
  /// Retorna null se não for um boleto válido
  static Map<String, dynamic>? decodeBoleto(String code) {
    // Limpar código - remover espaços, pontos e hífens
    final cleanCode = code.replaceAll(RegExp(r'[^\d]'), '');
    
    print('🔍 BoletoDecoderService.decodeBoleto()');
    print('🔍 Código original: ${code.length} chars');
    print('🔍 Código limpo: ${cleanCode.length} dígitos');
    
    if (cleanCode.isEmpty) {
      print('❌ Código vazio após limpeza');
      return null;
    }
    
    // Boleto bancário tradicional: 47 dígitos
    if (cleanCode.length == 47) {
      print('✅ Detectado boleto bancário (47 dígitos)');
      return _decodeBoletoTradicional(cleanCode);
    }
    
    // Boleto de concessionária/convênio: 48 dígitos
    if (cleanCode.length == 48) {
      print('✅ Detectado boleto convênio (48 dígitos)');
      return _decodeBoletoConvenio(cleanCode);
    }
    
    // Código de barras direto: 44 dígitos
    if (cleanCode.length == 44) {
      print('✅ Detectado código de barras (44 dígitos)');
      return _decodeCodigoBarras(cleanCode);
    }
    
    print('❌ Tamanho inválido: ${cleanCode.length} dígitos (esperado: 44, 47 ou 48)');
    return null;
  }
  
  /// Decodifica boleto bancário tradicional (47 dígitos)
  /// Formato: AAABC.CCCCX DDDDD.DDDDDY EEEEE.EEEEEZ K UUUUVVVVVVVVVV
  /// Onde o valor está nos últimos 10 dígitos (VVVVVVVVVV)
  static Map<String, dynamic>? _decodeBoletoTradicional(String code) {
    try {
      print('🔍 Decodificando boleto tradicional (47 dígitos)');
      print('🔍 Código: $code');
      
      // Extrair campos da linha digitável
      final campo1 = code.substring(0, 10);   // Posições 1-10
      final campo2 = code.substring(10, 21);  // Posições 11-21
      final campo3 = code.substring(21, 32);  // Posições 22-32
      final campo4 = code.substring(32, 33);  // Posição 33 (dígito verificador geral)
      final campo5 = code.substring(33, 47);  // Posições 34-47 (vencimento + valor)
      
      print('📊 Campo1: $campo1');
      print('📊 Campo2: $campo2');
      print('📊 Campo3: $campo3');
      print('📊 Campo4: $campo4');
      print('📊 Campo5: $campo5');
      
      // Extrair valor do campo 5 (últimos 10 dígitos representam o valor)
      final valorStr = campo5.substring(4, 14); // Pular fator vencimento (4 dígitos)
      final valorCentavos = int.tryParse(valorStr) ?? 0;
      final valor = valorCentavos / 100.0;
      
      print('💰 Valor String: $valorStr');
      print('💰 Valor Centavos: $valorCentavos');
      print('💰 Valor Final: R\$ $valor');
      
      // Extrair fator de vencimento para calcular data
      final fatorVencimento = int.tryParse(campo5.substring(0, 4)) ?? 0;
      DateTime? dataVencimento;
      if (fatorVencimento > 0) {
        // Base: 07/10/1997
        final dataBase = DateTime(1997, 10, 7);
        dataVencimento = dataBase.add(Duration(days: fatorVencimento));
      }
      
      // Extrair código do banco (3 primeiros dígitos)
      final codigoBanco = code.substring(0, 3);
      final nomeBanco = _getNomeBanco(codigoBanco);
      
      print('🏦 Banco: $nomeBanco ($codigoBanco)');
      print('📅 Vencimento: $dataVencimento');
      
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
      print('❌ Erro ao decodificar boleto tradicional: $e');
      return null;
    }
  }
  
  /// Decodifica boleto de concessionária/convênio (48 dígitos)
  /// Usado para contas de luz, água, gás, IPTU, telecomunicações, etc.
  /// Estrutura: ABCD.EEEEEEEEEE-F GGGG.GGGGGGG-H IIII.IIIIIII-J KKKK.KKKKKKK-L
  static Map<String, dynamic>? _decodeBoletoConvenio(String code) {
    try {
      print('🔍 Decodificando boleto convênio (48 dígitos)');
      print('🔍 Código: $code');
      
      // Estrutura do código de barras de convênio (48 dígitos na linha digitável):
      // A linha digitável tem 4 campos de 12 dígitos cada (48 total)
      // O código de barras original tem 44 dígitos
      
      // Para extrair o valor, precisamos reconstruir o código de barras:
      // Linha digitável: AAAAAAAAAAA-X BBBBBBBBBBB-Y CCCCCCCCCCC-Z DDDDDDDDDDD-W
      // Código barras:   AAAAAAAAAAA   BBBBBBBBBBB   CCCCCCCCCCC   DDDDDDDDDDD
      
      // Remover dígitos verificadores (posições 12, 24, 36, 48)
      final campo1 = code.substring(0, 11);   // 11 dígitos
      final campo2 = code.substring(12, 23);  // 11 dígitos
      final campo3 = code.substring(24, 35);  // 11 dígitos
      final campo4 = code.substring(36, 47);  // 11 dígitos
      
      final codigoBarras = campo1 + campo2 + campo3 + campo4; // 44 dígitos
      
      print('📊 Campo1: $campo1');
      print('📊 Campo2: $campo2');
      print('📊 Campo3: $campo3');
      print('📊 Campo4: $campo4');
      print('📊 Código de barras: $codigoBarras');
      
      // No código de barras de convênio (44 dígitos):
      // Posição 1: Identificador do produto (8 = arrecadação)
      // Posição 2: Identificador do segmento
      // Posição 3: Identificador de valor efetivo ou referência
      // Posição 4: Dígito verificador geral
      // Posições 5-15: Valor (11 dígitos, com 2 casas decimais)
      // Posições 16-44: Informações da empresa/convênio
      
      final identificador = codigoBarras.substring(0, 1);
      final segmentoCode = codigoBarras.substring(1, 2);
      final tipoValor = codigoBarras.substring(2, 3);
      
      // Valor está nas posições 5-15 (índices 4-14) = 11 dígitos
      final valorStr = codigoBarras.substring(4, 15);
      final valorCentavos = int.tryParse(valorStr) ?? 0;
      final valor = valorCentavos / 100.0;
      
      print('💰 Identificador: $identificador');
      print('💰 Segmento: $segmentoCode');
      print('💰 Tipo Valor: $tipoValor');
      print('💰 Valor String: $valorStr');
      print('💰 Valor Centavos: $valorCentavos');
      print('💰 Valor Final: R\$ $valor');
      
      // Identificar o tipo de convênio pelo segmento
      String tipoConvenio = 'Convênio';
      switch (segmentoCode) {
        case '1':
          tipoConvenio = 'Prefeituras';
          break;
        case '2':
          tipoConvenio = 'Saneamento';
          break;
        case '3':
          tipoConvenio = 'Energia/Gás';
          break;
        case '4':
          tipoConvenio = 'Telecomunicações';
          break;
        case '5':
          tipoConvenio = 'Órgãos Governamentais';
          break;
        case '6':
          tipoConvenio = 'Carnes e Assemelhados';
          break;
        case '7':
          tipoConvenio = 'Multas de Trânsito';
          break;
        case '8':
          tipoConvenio = 'Uso exclusivo do banco';
          break;
        case '9':
          tipoConvenio = 'Outros';
          break;
      }
      
      print('🏢 Tipo: $tipoConvenio');
      
      return {
        'success': true,
        'billType': 'boleto',
        'type': 'boleto_convenio',
        'value': valor,
        'merchantName': tipoConvenio,
        'segmento': segmentoCode,
        'barcode': code,
        'message': 'Boleto de convênio decodificado localmente',
      };
    } catch (e) {
      print('❌ Erro ao decodificar boleto convênio: $e');
      return null;
    }
  }
  
  /// Decodifica código de barras direto (44 dígitos)
  static Map<String, dynamic>? _decodeCodigoBarras(String code) {
    try {
      // Código de barras de boleto bancário (44 dígitos):
      // Posições 1-3: Código do banco
      // Posição 4: Código da moeda (9 = Real)
      // Posição 5: Dígito verificador geral
      // Posições 6-9: Fator de vencimento
      // Posições 10-19: Valor (10 dígitos, 8 inteiros + 2 decimais)
      // Posições 20-44: Campo livre
      
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
        'message': 'Código de barras decodificado localmente',
      };
    } catch (e) {
      print('❌ Erro ao decodificar código de barras: $e');
      return null;
    }
  }
  
  /// Retorna o nome do banco pelo código
  static String _getNomeBanco(String codigo) {
    final bancos = {
      '001': 'Banco do Brasil',
      '033': 'Santander',
      '104': 'Caixa Econômica',
      '237': 'Bradesco',
      '341': 'Itaú',
      '356': 'Banco Real',
      '389': 'Mercantil do Brasil',
      '399': 'HSBC',
      '422': 'Safra',
      '453': 'Rural',
      '633': 'Rendimento',
      '652': 'Itaú Unibanco',
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
      '204': 'Bradesco Cartões',
      '225': 'Brascan',
      '044': 'BVA',
      '263': 'Cacique',
      '473': 'Caixa Geral',
      '040': 'Cargill',
      '745': 'Citibank',
      '477': 'Citibank',
      '081': 'Concórdia',
      '707': 'Daycoval',
      '487': 'Deutsche',
      '751': 'Dresdner',
      '064': 'Goldman Sachs',
      '062': 'Hipercard',
      '399': 'HSBC',
      '168': 'HSBC Finance',
      '492': 'ING',
      '998': 'Itaú',
      '652': 'Itaú Holding',
      '341': 'Itaú Unibanco',
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
      '613': 'Pecúnia',
      '094': 'Petra',
      '643': 'Pine',
      '747': 'Rabobank',
      '633': 'Rendimento',
      '741': 'Ribeirão Preto',
      '453': 'Rural',
      '422': 'Safra',
      '033': 'Santander',
      '955': 'Santander',
      '250': 'Schahin',
      '749': 'Simples',
      '366': 'Société Générale',
      '637': 'Sofisa',
      '012': 'Standard',
      '082': 'Topázio',
      '464': 'Sumitomo',
      '634': 'Triângulo',
      '208': 'UBS Pactual',
      '116': 'Único',
      '655': 'Votorantim',
      '610': 'VR',
      '370': 'Mizuho',
      '021': 'Banestes',
      '719': 'Banif',
      '755': 'Bank of America',
      '744': 'BankBoston',
      '073': 'BB Cartões',
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
      '184': 'Itaú BBA',
      '479': 'Itaú Bank Boston',
      '604': 'Industrial do Brasil',
      '320': 'Industrial e Comercial',
      '653': 'Indusval',
    };
    
    return bancos[codigo] ?? 'Banco $codigo';
  }
}
