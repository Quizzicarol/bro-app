/// Configuracao centralizada do Bro App
/// 
/// ⚠️ CHECKLIST PARA PRODUÇÃO:
/// [x] testMode = false
/// [x] providerTestMode = false  
/// [ ] defaultBackendUrl = URL do backend de produção
/// [ ] Verificar breezApiKey está correto
/// [ ] Remover logs de debug sensíveis
/// 
class AppConfig {
  // ============================================
  // MODO DE DESENVOLVIMENTO
  // ============================================
  // ⚠️ SEGURANÇA: Em produção, ambos DEVEM ser FALSE!
  //
  // Para desenvolvimento local, crie um arquivo config_dev.dart
  // e faça override dessas constantes
  // ============================================
  
  /// Modo de teste - usa dados mockados, sem backend real
  /// ⚠️ PRODUÇÃO: DEVE SER FALSE
  static const bool testMode = false; // DESATIVADO para teste de garantias
  
  /// Permite provedores sem garantia depositada
  /// ⚠️ PRODUÇÃO: DEVE SER FALSE
  static const bool providerTestMode = false; // DESATIVADO - corrigir persistência!

  // ============================================
  // BACKEND API
  // ============================================
  
  /// URL do backend para emulador Android
  static const String _emulatorUrl = 'http://10.0.2.2:3002';
  
  /// URL do backend para dispositivo fisico (mesmo WiFi)
  static const String _localDeviceUrl = 'http://192.168.0.100:3002';
  
  /// URL do backend de producao
  static const String _productionUrl = 'https://api.bro.app';
  
  /// URL ativa - mude conforme ambiente
  static const String defaultBackendUrl = _emulatorUrl;

  // ============================================
  // BREEZ SDK (Lightning Network)
  // ============================================
  
  /// API Key do Breez SDK (certificado nodeless)
  /// Este e um certificado publico, NAO e uma chave secreta
  static const String breezApiKey = '''MIIBjDCCAT6gAwIBAgIHPom4vIYNvzAFBgMrZXAwEDEOMAwGA1UEAxMFQnJlZXowHhcNMjUxMDEyMTY0NTA4WhcNMzUxMDEwMTY0NTA4WjBAMSgwJgYDVQQKEx9BcmVhIEJpdGNvaW4gYW5kIEJpdGNvaW4gQ29kZXJzMRQwEgYDVQQDEwtDYXJvbCBTb3V6YTAqMAUGAytlcAMhANCD9cvfIDwcoiDKKYdT9BunHLS2/OuKzV8NS0SzqV13o4GGMIGDMA4GA1UdDwEB/wQEAwIFoDAMBgNVHRMBAf8EAjAAMB0GA1UdDgQWBBTaOaPuXmtLDTJVv++VYBiQr9gHCTAfBgNVHSMEGDAWgBTeqtaSVvON53SSFvxMtiCyayiYazAjBgNVHREEHDAagRhjYXJvbEBhcmVhYml0Y29pbi5jb20uYnIwBQYDK2VwA0EAXZHGqrPXd8IVwVt7VNj3cKiYsdTo2Lz2B8HnR2Knd//bfoyO6MmBZHD0nszCIBLZTaiUiqgBN18YHfJnymK8DA==''';

  // ============================================
  // APP INFO
  // ============================================
  
  static const String appName = 'Bro';
  static const String appVersion = '1.0.0';
  static const int buildNumber = 1;
  
  /// Bundle ID para iOS
  static const String iosBundleId = 'app.bro.mobile';
  
  /// Package name para Android
  static const String androidPackage = 'app.bro.mobile';

  // ============================================
  // NETWORK (Bitcoin)
  // ============================================
  
  /// true = MAINNET (Bitcoin real), false = TESTNET
  static const bool useMainnet = true;

  // ============================================
  // FEATURES
  // ============================================
  
  static const bool enableProviderMode = true;
  static const bool enableNotifications = true;
  static const bool enableClassifieds = true;
  static const bool enableChat = true;

  // ============================================
  // TAXAS E LIMITES
  // ============================================
  
  /// Taxa do provedor Bro (3% - vai para a carteira Lightning do Bro)
  static const double providerFeePercent = 0.03;
  
  /// Taxa da plataforma (2% - vai para manutenção da plataforma)
  static const double platformFeePercent = 0.02;
  
  /// Taxa total cobrada do usuário (5%)
  static const double totalFeePercent = providerFeePercent + platformFeePercent;
  
  /// Endereço Lightning da plataforma para receber taxas (2%)
  /// Lightning Address para receber as taxas de manutenção da plataforma
  static const String platformLightningAddress = 'tutoriais@coinos.io';
  
  // ============================================
  // TAXAS LIQUID (Boltz Swap) - Embutidas no spread
  // ============================================
  
  /// Taxa percentual do Boltz para swaps Lightning <-> Liquid
  static const double liquidSwapFeePercent = 0.0025; // 0.25%
  
  /// Taxa fixa base do Boltz em sats (claim + lockup)
  static const int liquidSwapFeeBaseSats = 200; // ~200 sats fixo
  
  /// Taxa da rede Liquid para transações
  static const int liquidNetworkFeeSats = 50; // ~50 sats
  
  /// Taxa total fixa do Liquid em sats
  static const int liquidTotalFixedFeeSats = liquidSwapFeeBaseSats + liquidNetworkFeeSats;
  
  /// Valor mínimo para usar Liquid (abaixo disso a taxa é muito alta proporcionalmente)
  static const int liquidMinAmountSats = 1000;
  
  /// Indica se deve usar Liquid como fallback quando Spark falha
  static const bool enableLiquidFallback = true;
  
  /// Limite minimo em sats
  static const int minPaymentSats = 1000;
  
  /// Limite maximo em sats (1M = ~R\ em dez/2025)
  static const int maxPaymentSats = 1000000;

  // ============================================
  // TIMEOUTS
  // ============================================
  
  static const int apiTimeoutSeconds = 30;
  static const int invoiceExpirySeconds = 3600; // 1 hora
  static const int orderExpiryHours = 24;
  
  // ============================================
  // HELPERS
  // ============================================
  
  /// Retorna true se esta em modo de desenvolvimento
  static bool get isDevelopment => testMode || providerTestMode;
  
  /// Retorna true se esta pronto para producao
  static bool get isProduction => !testMode && !providerTestMode;
}
