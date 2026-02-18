import '../config.dart';

/// Breez SDK Spark Configuration
/// A API key é carregada via env.json — veja AppConfig.breezApiKey
class BreezConfig {
  // API Key delegada para AppConfig (fonte única de verdade)
  static String get apiKey => AppConfig.breezApiKey;
  
  // Network: MAINNET = Bitcoin REAL, produção
  // ⚠️ ATENÇÃO: MAINNET usa Bitcoin de verdade! Transações são irreversíveis!
  static const bool useTestnet = false; // false = MAINNET (PRODUÇÃO)
  static const bool useMainnet = true; // MAINNET ATIVO
}
