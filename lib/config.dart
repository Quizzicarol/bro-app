/// Configuracao centralizada do Bro App
///
/// Secrets são carregados via --dart-define-from-file=env.json
/// Veja env.example.json para as variáveis necessárias.
///
/// Build local:  flutter run --dart-define-from-file=env.json
/// Build CI:     gerado automaticamente pelo script pre-build
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
  
  /// URL do backend — definido via env.json (BACKEND_URL)
  /// Fallback: https://api.bro.app (produção)
  ///
  /// Valores comuns para desenvolvimento:
  ///   Emulador Android: http://10.0.2.2:3002
  ///   Dispositivo físico: http://<SEU_IP>:3002
  static const String defaultBackendUrl = String.fromEnvironment(
    'BACKEND_URL',
    defaultValue: 'https://api.bro.app',
  );

  // ============================================
  // BREEZ SDK (Lightning Network)
  // ============================================
  
  /// API Key do Breez SDK — definido via env.json (BREEZ_API_KEY)
  /// Obtenha seu certificado em https://breez.technology
  static const String breezApiKey = String.fromEnvironment('BREEZ_API_KEY');

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
  /// Definido via env.json (PLATFORM_LIGHTNING_ADDRESS)
  static const String platformLightningAddress = String.fromEnvironment(
    'PLATFORM_LIGHTNING_ADDRESS',
  );
  
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
