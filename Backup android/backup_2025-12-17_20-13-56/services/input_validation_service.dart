/// Serviço de validação e sanitização de inputs
/// Previne injeção de código e dados maliciosos
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
  
  /// Valida e sanitiza valor monetário em BRL
  ValidationResult validateBrlAmount(String input) {
    final sanitized = input.replaceAll(RegExp(r'[^\d,.]'), '');
    
    // Converte vírgula para ponto
    final normalized = sanitized.replaceAll(',', '.');
    
    final amount = double.tryParse(normalized);
    
    if (amount == null) {
      return ValidationResult(
        isValid: false,
        error: 'Valor inválido',
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
        error: 'Valor máximo excedido (R\$ 100.000)',
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
      return ValidationResult(isValid: false, error: 'Chave PIX obrigatória');
    }
    
    // CPF: 11 dígitos
    if (RegExp(r'^\d{11}$').hasMatch(sanitized)) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized, type: 'cpf');
    }
    
    // CNPJ: 14 dígitos
    if (RegExp(r'^\d{14}$').hasMatch(sanitized)) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized, type: 'cnpj');
    }
    
    // Email
    if (RegExp(r'^[\w\.-]+@[\w\.-]+\.\w+$').hasMatch(sanitized)) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized.toLowerCase(), type: 'email');
    }
    
    // Telefone: +55 + DDD + número
    final phoneClean = sanitized.replaceAll(RegExp(r'[^\d+]'), '');
    if (RegExp(r'^\+?55?\d{10,11}$').hasMatch(phoneClean)) {
      return ValidationResult(isValid: true, sanitizedValue: phoneClean, type: 'phone');
    }
    
    // Chave aleatória: 32 caracteres alfanuméricos
    if (RegExp(r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$', caseSensitive: false).hasMatch(sanitized)) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized.toLowerCase(), type: 'random');
    }
    
    // PIX copia e cola (começa com padrão EMV)
    if (sanitized.startsWith('00020126')) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized, type: 'emv');
    }
    
    return ValidationResult(
      isValid: false,
      error: 'Formato de chave PIX inválido',
    );
  }
  
  /// Valida código de barras de boleto
  ValidationResult validateBoletoCode(String input) {
    final sanitized = input.replaceAll(RegExp(r'[^\d]'), '');
    
    if (sanitized.isEmpty) {
      return ValidationResult(isValid: false, error: 'Código do boleto obrigatório');
    }
    
    // Boleto bancário: 47 dígitos (linha digitável)
    if (sanitized.length == 47) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized, type: 'bancario');
    }
    
    // Convênio/concessionária: 48 dígitos
    if (sanitized.length == 48) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized, type: 'convenio');
    }
    
    // Código de barras: 44 dígitos
    if (sanitized.length == 44) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized, type: 'barcode');
    }
    
    return ValidationResult(
      isValid: false,
      error: 'Código de boleto inválido (esperado 44, 47 ou 48 dígitos)',
    );
  }
  
  /// Valida invoice Lightning
  ValidationResult validateLightningInvoice(String input) {
    final sanitized = sanitizeText(input, maxLength: 1000).toLowerCase();
    
    if (sanitized.isEmpty) {
      return ValidationResult(isValid: false, error: 'Invoice obrigatória');
    }
    
    // BOLT11: começa com lnbc (mainnet), lntb (testnet), lnbcrt (regtest)
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
      error: 'Invoice Lightning inválida',
    );
  }
  
  /// Valida endereço Bitcoin
  ValidationResult validateBitcoinAddress(String input) {
    final sanitized = sanitizeText(input, maxLength: 100);
    
    if (sanitized.isEmpty) {
      return ValidationResult(isValid: false, error: 'Endereço obrigatório');
    }
    
    // Bech32 (SegWit): começa com bc1 (mainnet) ou tb1 (testnet)
    if (RegExp(r'^(bc1|tb1)[a-z0-9]{39,59}$', caseSensitive: false).hasMatch(sanitized)) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized, type: 'bech32');
    }
    
    // P2PKH (Legacy): começa com 1 ou m/n (testnet)
    if (RegExp(r'^[1mn][a-km-zA-HJ-NP-Z1-9]{25,34}$').hasMatch(sanitized)) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized, type: 'p2pkh');
    }
    
    // P2SH: começa com 3 ou 2 (testnet)
    if (RegExp(r'^[32][a-km-zA-HJ-NP-Z1-9]{25,34}$').hasMatch(sanitized)) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized, type: 'p2sh');
    }
    
    return ValidationResult(
      isValid: false,
      error: 'Endereço Bitcoin inválido',
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
