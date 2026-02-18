/// Servi�o de valida��o e sanitiza��o de inputs
/// Previne inje��o de c�digo e dados maliciosos
class InputValidationService {
  static final InputValidationService _instance = InputValidationService._internal();
  factory InputValidationService() => _instance;
  InputValidationService._internal();

  /// Sanitiza texto removendo caracteres perigosos
  String sanitizeText(String input, {int maxLength = 500}) {
    if (input.isEmpty) return input;
    
    // Remove caracteres de controle
    String sanitized = input.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '');
    
    // Remove tags HTML/script
    sanitized = sanitized.replaceAll(RegExp(r'<[^>]*>'), '');
    
    // Limita tamanho
    if (sanitized.length > maxLength) {
      sanitized = sanitized.substring(0, maxLength);
    }
    
    return sanitized.trim();
  }
  
  /// Valida e sanitiza valor monet�rio em BRL
  ValidationResult validateBrlAmount(String input) {
    final sanitized = input.replaceAll(RegExp(r'[^\d,.]'), '');
    
    // Converte v�rgula para ponto
    final normalized = sanitized.replaceAll(',', '.');
    
    final amount = double.tryParse(normalized);
    
    if (amount == null) {
      return ValidationResult(
        isValid: false,
        error: 'Valor inv�lido',
      );
    }
    
    if (amount <= 0) {
      return ValidationResult(
        isValid: false,
        error: 'Valor deve ser maior que zero',
      );
    }
    
    if (amount > 100000) {
      return ValidationResult(
        isValid: false,
        error: 'Valor m�ximo excedido (R\$ 100.000)',
      );
    }
    
    return ValidationResult(
      isValid: true,
      sanitizedValue: amount.toString(),
    );
  }
  
  /// Valida chave PIX
  ValidationResult validatePixKey(String input) {
    final sanitized = sanitizeText(input, maxLength: 100);
    
    if (sanitized.isEmpty) {
      return ValidationResult(isValid: false, error: 'Chave PIX obrigat�ria');
    }
    
    // CPF: 11 d�gitos
    if (RegExp(r'^\d{11}$').hasMatch(sanitized)) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized, type: 'cpf');
    }
    
    // CNPJ: 14 d�gitos
    if (RegExp(r'^\d{14}$').hasMatch(sanitized)) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized, type: 'cnpj');
    }
    
    // Email
    if (RegExp(r'^[\w\.-]+@[\w\.-]+\.\w+$').hasMatch(sanitized)) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized.toLowerCase(), type: 'email');
    }
    
    // Telefone: +55 + DDD + n�mero
    final phoneClean = sanitized.replaceAll(RegExp(r'[^\d+]'), '');
    if (RegExp(r'^\+?55?\d{10,11}$').hasMatch(phoneClean)) {
      return ValidationResult(isValid: true, sanitizedValue: phoneClean, type: 'phone');
    }
    
    // Chave aleat�ria: 32 caracteres alfanum�ricos
    if (RegExp(r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$', caseSensitive: false).hasMatch(sanitized)) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized.toLowerCase(), type: 'random');
    }
    
    // PIX copia e cola (come�a com padr�o EMV)
    if (sanitized.startsWith('00020126')) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized, type: 'emv');
    }
    
    return ValidationResult(
      isValid: false,
      error: 'Formato de chave PIX inv�lido',
    );
  }
  
  /// Valida c�digo de barras de boleto
  ValidationResult validateBoletoCode(String input) {
    final sanitized = input.replaceAll(RegExp(r'[^\d]'), '');
    
    if (sanitized.isEmpty) {
      return ValidationResult(isValid: false, error: 'C�digo do boleto obrigat�rio');
    }
    
    // Boleto banc�rio: 47 d�gitos (linha digit�vel)
    if (sanitized.length == 47) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized, type: 'bancario');
    }
    
    // Conv�nio/concession�ria: 48 d�gitos
    if (sanitized.length == 48) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized, type: 'convenio');
    }
    
    // C�digo de barras: 44 d�gitos
    if (sanitized.length == 44) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized, type: 'barcode');
    }
    
    return ValidationResult(
      isValid: false,
      error: 'C�digo de boleto inv�lido (esperado 44, 47 ou 48 d�gitos)',
    );
  }
  
  /// Valida invoice Lightning
  ValidationResult validateLightningInvoice(String input) {
    final sanitized = sanitizeText(input, maxLength: 1000).toLowerCase();
    
    if (sanitized.isEmpty) {
      return ValidationResult(isValid: false, error: 'Invoice obrigat�ria');
    }
    
    // BOLT11: come�a com lnbc (mainnet), lntb (testnet), lnbcrt (regtest)
    if (sanitized.startsWith('lnbc') || 
        sanitized.startsWith('lntb') || 
        sanitized.startsWith('lnbcrt')) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized);
    }
    
    // Lightning Address: user@domain.com
    if (sanitized.contains('@') && RegExp(r'^[\w\.-]+@[\w\.-]+\.\w+$').hasMatch(sanitized)) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized, type: 'lnaddress');
    }
    
    return ValidationResult(
      isValid: false,
      error: 'Invoice Lightning inv�lida',
    );
  }
  
  /// Valida endere�o Bitcoin
  ValidationResult validateBitcoinAddress(String input) {
    final sanitized = sanitizeText(input, maxLength: 100);
    
    if (sanitized.isEmpty) {
      return ValidationResult(isValid: false, error: 'Endere�o obrigat�rio');
    }
    
    // Bech32 (SegWit): come�a com bc1 (mainnet) ou tb1 (testnet)
    if (RegExp(r'^(bc1|tb1)[a-z0-9]{39,59}$', caseSensitive: false).hasMatch(sanitized)) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized, type: 'bech32');
    }
    
    // P2PKH (Legacy): come�a com 1 ou m/n (testnet)
    if (RegExp(r'^[1mn][a-km-zA-HJ-NP-Z1-9]{25,34}$').hasMatch(sanitized)) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized, type: 'p2pkh');
    }
    
    // P2SH: come�a com 3 ou 2 (testnet)
    if (RegExp(r'^[32][a-km-zA-HJ-NP-Z1-9]{25,34}$').hasMatch(sanitized)) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized, type: 'p2sh');
    }
    
    return ValidationResult(
      isValid: false,
      error: 'Endere�o Bitcoin inv�lido',
    );
  }
}

class ValidationResult {
  final bool isValid;
  final String? error;
  final String? sanitizedValue;
  final String? type;
  
  ValidationResult({
    required this.isValid,
    this.error,
    this.sanitizedValue,
    this.type,
  });
}
