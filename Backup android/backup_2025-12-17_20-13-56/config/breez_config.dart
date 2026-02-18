/// Breez SDK Spark Configuration
class BreezConfig {
  // API Key da Breez (Carol Souza - Area Bitcoin)
  static const String apiKey = 'MIIBjDCCAT6gAwIBAgIHPom4vIYNvzAFBgMrZXAwEDEOMAwGA1UEAxMFQnJlZXowHhcNMjUxMDEyMTY0NTA4WhcNMzUxMDEwMTY0NTA4WjBAMSgwJgYDVQQKEx9BcmVhIEJpdGNvaW4gYW5kIEJpdGNvaW4gQ29kZXJzMRQwEgYDVQQDEwtDYXJvbCBTb3V6YTAqMAUGAytlcAMhANCD9cvfIDwcoiDKKYdT9BunHLS2/OuKzV8NS0SzqV13o4GGMIGDMA4GA1UdDwEB/wQEAwIFoDAMBgNVHRMBAf8EAjAAMB0GA1UdDgQWBBTaOaPuXmtLDTJVv++VYBiQr9gHCTAfBgNVHSMEGDAWgBTeqtaSVvON53SSFvxMtiCyayiYazAjBgNVHREEHDAagRhjYXJvbEBhcmVhYml0Y29pbi5jb20uYnIwBQYDK2VwA0EAXZHGqrPXd8IVwVt7VNj3cKiYsdTo2Lz2B8HnR2Knd//bfoyO6MmBZHD0nszCIBLZTaiUiqgBN18YHfJnymK8DA==';
  
  // Network: MAINNET = Bitcoin REAL, produção
  // ⚠️ ATENÇÃO: MAINNET usa Bitcoin de verdade! Transações são irreversíveis!
  static const bool useTestnet = false; // false = MAINNET (PRODUÇÃO)
  static const bool useMainnet = true; // MAINNET ATIVO
}
