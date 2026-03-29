import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';

/// Serviço de criptografia simétrica para billCode.
///
/// Usa ChaCha20 + HMAC-SHA256 com chave derivada do app secret.
/// Qualquer instância do app pode encriptar/decriptar.
/// Impede scrapers/bots de lerem billCodes nos relays públicos.
///
/// O billCode encriptado é armazenado como: "BRO1:" + base64(nonce + ciphertext + hmac)
class BillCodeCryptoService {
  static final BillCodeCryptoService _instance = BillCodeCryptoService._internal();
  factory BillCodeCryptoService() => _instance;
  BillCodeCryptoService._internal();

  /// Prefixo que identifica um billCode encriptado (vs plaintext legacy)
  static const String encryptedPrefix = 'BRO1:';

  /// Chave mestra do app — compilada via --dart-define-from-file
  static const String _appSecret = String.fromEnvironment(
    'BILLCODE_KEY',
    defaultValue: '',
  );

  /// Verifica se o serviço está habilitado (chave configurada)
  bool get isEnabled => _appSecret.isNotEmpty;

  /// Deriva chave de 32 bytes a partir do app secret + salt
  Uint8List _deriveKey(String salt) {
    final input = utf8.encode('$_appSecret:$salt:bro-billcode-v1');
    final hash = crypto.sha256.convert(input);
    return Uint8List.fromList(hash.bytes);
  }

  /// Gera bytes aleatórios criptograficamente seguros
  Uint8List _secureRandom(int length) {
    final rng = math.Random.secure();
    return Uint8List.fromList(List.generate(length, (_) => rng.nextInt(256)));
  }

  /// Encripta um billCode. Retorna string com prefixo "BRO1:".
  /// Se o serviço não estiver habilitado, retorna o plaintext.
  String encrypt(String billCode) {
    if (!isEnabled || billCode.isEmpty) return billCode;

    final nonce = _secureRandom(12);
    final key = _deriveKey(base64.encode(nonce));

    // ChaCha20
    final cipher = ChaCha20Engine();
    cipher.init(true, ParametersWithIV(KeyParameter(key), nonce));

    final plainBytes = utf8.encode(billCode);
    final ciphertext = Uint8List(plainBytes.length);
    cipher.processBytes(Uint8List.fromList(plainBytes), 0, plainBytes.length, ciphertext, 0);

    // HMAC-SHA256 sobre nonce + ciphertext
    final hmacInput = Uint8List(nonce.length + ciphertext.length);
    hmacInput.setRange(0, nonce.length, nonce);
    hmacInput.setRange(nonce.length, hmacInput.length, ciphertext);
    final hmac = crypto.Hmac(crypto.sha256, key);
    final mac = hmac.convert(hmacInput).bytes;

    // Payload: nonce(12) + ciphertext(n) + mac(32)
    final payload = Uint8List(12 + ciphertext.length + 32);
    payload.setRange(0, 12, nonce);
    payload.setRange(12, 12 + ciphertext.length, ciphertext);
    payload.setRange(12 + ciphertext.length, payload.length, mac);

    return '$encryptedPrefix${base64.encode(payload)}';
  }

  /// Decripta um billCode. Aceita tanto "BRO1:..." quanto plaintext.
  /// Retrocompatível: se não tem prefixo, retorna como está.
  String decrypt(String value) {
    if (value.isEmpty) return value;
    if (!value.startsWith(encryptedPrefix)) return value; // plaintext legacy

    if (!isEnabled) return ''; // não consegue decriptar sem chave

    try {
      final b64 = value.substring(encryptedPrefix.length);
      final payload = base64.decode(b64);

      if (payload.length < 12 + 32 + 1) return ''; // muito curto

      final nonce = payload.sublist(0, 12);
      final ciphertext = payload.sublist(12, payload.length - 32);
      final mac = payload.sublist(payload.length - 32);

      final key = _deriveKey(base64.encode(nonce));

      // Verificar HMAC
      final hmacInput = Uint8List(nonce.length + ciphertext.length);
      hmacInput.setRange(0, nonce.length, nonce);
      hmacInput.setRange(nonce.length, hmacInput.length, ciphertext);
      final hmac = crypto.Hmac(crypto.sha256, key);
      final expectedMac = hmac.convert(hmacInput).bytes;

      // Comparação constante
      bool valid = mac.length == expectedMac.length;
      for (int i = 0; i < mac.length && i < expectedMac.length; i++) {
        valid = valid && (mac[i] == expectedMac[i]);
      }
      if (!valid) return ''; // HMAC falhou

      // Decriptar
      final cipher = ChaCha20Engine();
      cipher.init(false, ParametersWithIV(KeyParameter(key), nonce));
      final plainBytes = Uint8List(ciphertext.length);
      cipher.processBytes(ciphertext, 0, ciphertext.length, plainBytes, 0);

      return utf8.decode(plainBytes);
    } catch (_) {
      return ''; // falha silenciosa — pode ser formato inválido
    }
  }

  /// Verifica se um valor é um billCode encriptado
  static bool isEncrypted(String value) => value.startsWith(encryptedPrefix);
}
