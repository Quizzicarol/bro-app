import '../config.dart';

/// Breez SDK Spark Configuration
/// A API key � carregada via env.json - veja AppConfig.breezApiKey
class BreezConfig {
  // API Key delegada para AppConfig (fonte �nica de verdade)
  static String get apiKey => AppConfig.breezApiKey;
  
  // Network: MAINNET = Bitcoin REAL, produ��o
  // ?? ATEN��O: MAINNET usa Bitcoin de verdade! Transa��es s�o irrevers�veis!
  static const bool useTestnet = false; // false = MAINNET (PRODU��O)
  static const bool useMainnet = true; // MAINNET ATIVO
}
