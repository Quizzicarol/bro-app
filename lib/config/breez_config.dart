/// Breez SDK Spark Configuration
class BreezConfig {
  // API Key da Breez (Carol Souza - Area Bitcoin)
  static const String apiKey = 'REDACTED_BREEZ_CERTIFICATE';
  
  // Network: MAINNET = Bitcoin REAL, produção
  // ⚠️ ATENÇÃO: MAINNET usa Bitcoin de verdade! Transações são irreversíveis!
  static const bool useTestnet = false; // false = MAINNET (PRODUÇÃO)
  static const bool useMainnet = true; // MAINNET ATIVO
}
