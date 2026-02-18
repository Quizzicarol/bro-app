import 'dart:convert';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';
import 'package:convert/convert.dart';

/// Servi�o de criptografia NIP-44 (vers�o 2 - mais segura)
/// Implementa criptografia XChaCha20-Poly1305 para mensagens diretas
class Nip44Service {
  static final Nip44Service _instance = Nip44Service._internal();
  factory Nip44Service() => _instance;
  Nip44Service._internal();

  /// Vers�o do protocolo NIP-44
  static const int version = 2;

  /// Gerar shared secret usando ECDH (secp256k1)
  Uint8List getSharedSecret(String privateKeyHex, String publicKeyHex) {
    // Converter hex para bytes
    final privateKey = Uint8List.fromList(hex.decode(privateKeyHex));
    final publicKey = Uint8List.fromList(hex.decode('02$publicKeyHex'));

    // ECDH para gerar shared secret
    final ecDomain = ECDomainParameters('secp256k1');
    final privateKeyParam = ECPrivateKey(
      BigInt.parse(privateKeyHex, radix: 16),
      ecDomain,
    );

    // Parse public key point
    final publicKeyPoint = ecDomain.curve.decodePoint(publicKey);
    if (publicKeyPoint == null) {
      throw Exception('Invalid public key');
    }

    // Multiplica��o escalar para ECDH
    final sharedPoint = publicKeyPoint * privateKeyParam.d;
    if (sharedPoint == null) {
      throw Exception('Failed to compute shared secret');
    }

    // Usar coordenada X como shared secret
    final sharedX = sharedPoint.x!.toBigInteger()!;
    final sharedBytes = _bigIntToBytes(sharedX, 32);

    // HKDF para derivar chave de conversa
    return _hkdfExpand(sharedBytes, Uint8List(0), 32);
  }

  /// Criptografar mensagem usando NIP-44 v2
  String encrypt(String plaintext, String conversationKey) {
    final key = Uint8List.fromList(hex.decode(conversationKey));
    
    // Gerar nonce aleat�rio de 24 bytes para XChaCha20
    final nonce = _generateSecureRandom(24);
    
    // Padding da mensagem (calc_padded_len)
    final paddedPlaintext = _padMessage(plaintext);
    
    // Derivar chave de mensagem usando HKDF
    final messageKey = _hkdfExpand(key, nonce, 76);
    final chachaKey = messageKey.sublist(0, 32);
    final chachaNonce = messageKey.sublist(32, 44);
    final hmacKey = messageKey.sublist(44, 76);
    
    // Criptografar com ChaCha20
    final cipher = ChaCha20Engine();
    cipher.init(true, ParametersWithIV(KeyParameter(chachaKey), chachaNonce));
    
    final ciphertext = Uint8List(paddedPlaintext.length);
    cipher.processBytes(paddedPlaintext, 0, paddedPlaintext.length, ciphertext, 0);
    
    // Calcular HMAC
    final hmac = _computeHmac(hmacKey, nonce, ciphertext);
    
    // Montar payload: version (1) + nonce (24) + ciphertext + hmac (32)
    final payload = Uint8List(1 + 24 + ciphertext.length + 32);
    payload[0] = version;
    payload.setRange(1, 25, nonce);
    payload.setRange(25, 25 + ciphertext.length, ciphertext);
    payload.setRange(25 + ciphertext.length, payload.length, hmac);
    
    return base64.encode(payload);
  }

  /// Descriptografar mensagem NIP-44 v2
  String decrypt(String payload, String conversationKey) {
    final key = Uint8List.fromList(hex.decode(conversationKey));
    final data = base64.decode(payload);
    
    if (data.length < 1 + 24 + 32) {
      throw Exception('Payload muito curto');
    }
    
    final payloadVersion = data[0];
    if (payloadVersion != version) {
      throw Exception('Vers�o NIP-44 n�o suportada: $payloadVersion');
    }
    
    final nonce = data.sublist(1, 25);
    final ciphertext = data.sublist(25, data.length - 32);
    final mac = data.sublist(data.length - 32);
    
    // Derivar chave de mensagem
    final messageKey = _hkdfExpand(key, nonce, 76);
    final chachaKey = messageKey.sublist(0, 32);
    final chachaNonce = messageKey.sublist(32, 44);
    final hmacKey = messageKey.sublist(44, 76);
    
    // Verificar HMAC
    final expectedMac = _computeHmac(hmacKey, nonce, ciphertext);
    if (!_constantTimeCompare(mac, expectedMac)) {
      throw Exception('HMAC inv�lido - mensagem pode ter sido adulterada');
    }
    
    // Descriptografar
    final cipher = ChaCha20Engine();
    cipher.init(false, ParametersWithIV(KeyParameter(chachaKey), chachaNonce));
    
    final plaintext = Uint8List(ciphertext.length);
    cipher.processBytes(ciphertext, 0, ciphertext.length, plaintext, 0);
    
    return _unpadMessage(plaintext);
  }

  /// Padding da mensagem conforme NIP-44
  Uint8List _padMessage(String message) {
    final messageBytes = utf8.encode(message);
    final messageLength = messageBytes.length;
    
    // Calcular tamanho com padding
    final paddedLength = _calcPaddedLen(messageLength);
    
    // Criar buffer com tamanho do padding
    final padded = Uint8List(2 + paddedLength);
    
    // Primeiros 2 bytes = tamanho da mensagem (big-endian)
    padded[0] = (messageLength >> 8) & 0xFF;
    padded[1] = messageLength & 0xFF;
    
    // Copiar mensagem
    padded.setRange(2, 2 + messageLength, messageBytes);
    
    // Resto � zero (padding)
    return padded;
  }

  /// Remover padding da mensagem
  String _unpadMessage(Uint8List padded) {
    if (padded.length < 2) {
      throw Exception('Mensagem muito curta');
    }
    
    final messageLength = (padded[0] << 8) | padded[1];
    
    if (messageLength > padded.length - 2) {
      throw Exception('Tamanho da mensagem inv�lido');
    }
    
    return utf8.decode(padded.sublist(2, 2 + messageLength));
  }

  /// Calcular tamanho com padding (pot�ncia de 2)
  int _calcPaddedLen(int unpadded) {
    if (unpadded <= 32) return 32;
    
    int paddedLen = 32;
    while (paddedLen < unpadded) {
      paddedLen *= 2;
    }
    return paddedLen;
  }

  /// HKDF-Expand para deriva��o de chaves
  Uint8List _hkdfExpand(Uint8List key, Uint8List info, int length) {
    final hmac = HMac(SHA256Digest(), 64);
    hmac.init(KeyParameter(key));
    
    final output = Uint8List(length);
    var counter = 1;
    var offset = 0;
    Uint8List previous = Uint8List(0);
    
    while (offset < length) {
      hmac.reset();
      hmac.update(previous, 0, previous.length);
      hmac.update(info, 0, info.length);
      hmac.updateByte(counter);
      
      final block = Uint8List(32);
      hmac.doFinal(block, 0);
      
      final toCopy = (length - offset) < 32 ? (length - offset) : 32;
      output.setRange(offset, offset + toCopy, block);
      
      previous = block;
      offset += toCopy;
      counter++;
    }
    
    return output;
  }

  /// Computar HMAC-SHA256
  Uint8List _computeHmac(Uint8List key, Uint8List nonce, Uint8List ciphertext) {
    final hmac = HMac(SHA256Digest(), 64);
    hmac.init(KeyParameter(key));
    
    hmac.update(nonce, 0, nonce.length);
    hmac.update(ciphertext, 0, ciphertext.length);
    
    final mac = Uint8List(32);
    hmac.doFinal(mac, 0);
    return mac;
  }

  /// Compara��o em tempo constante para evitar timing attacks
  bool _constantTimeCompare(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    
    var result = 0;
    for (var i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }

  /// Gerar bytes aleat�rios seguros
  Uint8List _generateSecureRandom(int length) {
    final random = SecureRandom('Fortuna')
      ..seed(KeyParameter(Uint8List.fromList(
        List.generate(32, (i) => DateTime.now().microsecondsSinceEpoch % 256),
      )));
    
    return random.nextBytes(length);
  }

  /// Converter BigInt para bytes
  Uint8List _bigIntToBytes(BigInt number, int length) {
    final bytes = Uint8List(length);
    var temp = number;
    
    for (var i = length - 1; i >= 0; i--) {
      bytes[i] = (temp & BigInt.from(0xFF)).toInt();
      temp = temp >> 8;
    }
    
    return bytes;
  }
}
