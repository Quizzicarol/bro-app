import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:pointycastle/export.dart';

/// Implementação do NIP-04 para mensagens criptografadas Nostr
/// https://github.com/nostr-protocol/nips/blob/master/04.md
class Nip04Service {
  static final Nip04Service _instance = Nip04Service._internal();
  factory Nip04Service() => _instance;
  Nip04Service._internal();

  /// Derivar shared secret usando ECDH (secp256k1)
  Uint8List getSharedSecret(String privateKeyHex, String publicKeyHex) {
    final domain = ECDomainParameters('secp256k1');
    
    // Parse private key
    final privateKeyInt = BigInt.parse(privateKeyHex, radix: 16);
    // ignore: unused_local_variable - usado para validação
    final _ = ECPrivateKey(privateKeyInt, domain);
    
    // Parse public key (adiciona 02 prefix se necessário para compressed key)
    String pubHex = publicKeyHex;
    if (pubHex.length == 64) {
      // Compressed public key - precisa calcular Y
      pubHex = '02$pubHex';
    }
    
    // Decompress public key
    final pubKeyBytes = hex.decode(pubHex);
    final publicKeyPoint = domain.curve.decodePoint(pubKeyBytes);
    
    // ECDH - multiplicar private key pelo public point
    final sharedPoint = publicKeyPoint! * privateKeyInt;
    
    // Usar apenas a coordenada X como shared secret (32 bytes)
    final sharedX = sharedPoint!.x!.toBigInteger()!;
    final sharedBytes = _bigIntToBytes(sharedX, 32);
    
    return sharedBytes;
  }

  /// Criptografar mensagem usando NIP-04 (AES-256-CBC)
  String encrypt(String plaintext, String privateKeyHex, String publicKeyHex) {
    final sharedSecret = getSharedSecret(privateKeyHex, publicKeyHex);
    
    // Gerar IV aleatório de 16 bytes
    final random = Random.secure();
    final iv = Uint8List.fromList(
      List<int>.generate(16, (_) => random.nextInt(256)),
    );
    
    // Setup AES-256-CBC
    final key = KeyParameter(sharedSecret);
    final params = ParametersWithIV<KeyParameter>(key, iv);
    final cipher = CBCBlockCipher(AESEngine())..init(true, params);
    
    // Pad message to block size (PKCS7)
    final plaintextBytes = utf8.encode(plaintext);
    final padded = _pkcs7Pad(plaintextBytes, 16);
    
    // Encrypt
    final encrypted = Uint8List(padded.length);
    var offset = 0;
    while (offset < padded.length) {
      offset += cipher.processBlock(padded, offset, encrypted, offset);
    }
    
    // Format: base64(encrypted)?iv=base64(iv)
    final encryptedBase64 = base64.encode(encrypted);
    final ivBase64 = base64.encode(iv);
    
    return '$encryptedBase64?iv=$ivBase64';
  }

  /// Descriptografar mensagem NIP-04
  String decrypt(String ciphertext, String privateKeyHex, String publicKeyHex) {
    try {
      final sharedSecret = getSharedSecret(privateKeyHex, publicKeyHex);
      
      // Parse format: base64(encrypted)?iv=base64(iv)
      final parts = ciphertext.split('?iv=');
      if (parts.length != 2) {
        throw FormatException('Invalid NIP-04 ciphertext format');
      }
      
      final encryptedBytes = base64.decode(parts[0]);
      final iv = base64.decode(parts[1]);
      
      // Setup AES-256-CBC decrypt
      final key = KeyParameter(sharedSecret);
      final params = ParametersWithIV<KeyParameter>(key, iv);
      final cipher = CBCBlockCipher(AESEngine())..init(false, params);
      
      // Decrypt
      final decrypted = Uint8List(encryptedBytes.length);
      var offset = 0;
      while (offset < encryptedBytes.length) {
        offset += cipher.processBlock(encryptedBytes, offset, decrypted, offset);
      }
      
      // Remove PKCS7 padding
      final unpadded = _pkcs7Unpad(decrypted);
      
      return utf8.decode(unpadded);
    } catch (e) {
      throw Exception('Failed to decrypt NIP-04 message: $e');
    }
  }

  /// PKCS7 padding
  Uint8List _pkcs7Pad(List<int> data, int blockSize) {
    final padLength = blockSize - (data.length % blockSize);
    final padded = Uint8List(data.length + padLength);
    padded.setAll(0, data);
    for (var i = data.length; i < padded.length; i++) {
      padded[i] = padLength;
    }
    return padded;
  }

  /// PKCS7 unpadding
  Uint8List _pkcs7Unpad(Uint8List data) {
    if (data.isEmpty) return data;
    final padLength = data.last;
    if (padLength > data.length || padLength > 16) {
      return data; // Invalid padding, return as-is
    }
    return Uint8List.sublistView(data, 0, data.length - padLength);
  }

  /// Convert BigInt to fixed-size bytes
  Uint8List _bigIntToBytes(BigInt number, int length) {
    final result = Uint8List(length);
    var temp = number;
    for (var i = length - 1; i >= 0; i--) {
      result[i] = (temp & BigInt.from(0xff)).toInt();
      temp = temp >> 8;
    }
    return result;
  }
}
