import 'dart:convert';
import 'dart:typed_data';
import 'package:bip39/bip39.dart' as bip39;
import 'package:pointycastle/export.dart';
import 'package:convert/convert.dart';

/// Serviço NIP-06: Derivação de chaves Nostr a partir de seed BIP-39
/// Permite usar uma única seed para Bitcoin e Nostr
class Nip06Service {
  static final Nip06Service _instance = Nip06Service._internal();
  factory Nip06Service() => _instance;
  Nip06Service._internal();

  /// Path de derivação para Nostr conforme NIP-06
  /// m/44'/1237'/0'/0/0
  static const String nostrDerivationPath = "m/44'/1237'/0'/0/0";

  /// Gerar seed BIP-39 (12 ou 24 palavras)
  String generateMnemonic({int strength = 128}) {
    // strength 128 = 12 palavras, 256 = 24 palavras
    return bip39.generateMnemonic(strength: strength);
  }

  /// Validar mnemonic
  bool validateMnemonic(String mnemonic) {
    return bip39.validateMnemonic(mnemonic);
  }

  /// Converter mnemonic para seed bytes
  Uint8List mnemonicToSeed(String mnemonic, {String passphrase = ''}) {
    return Uint8List.fromList(bip39.mnemonicToSeed(mnemonic, passphrase: passphrase));
  }

  /// Derivar chave privada Nostr de uma seed BIP-39
  /// Seguindo NIP-06: m/44'/1237'/0'/0/0
  String deriveNostrPrivateKey(String mnemonic, {String passphrase = ''}) {
    if (!validateMnemonic(mnemonic)) {
      throw Exception('Mnemonic inválido');
    }

    final seed = mnemonicToSeed(mnemonic, passphrase: passphrase);
    
    // Derivar master key usando HMAC-SHA512
    final masterKey = _deriveMasterKey(seed);
    
    // Seguir path de derivação m/44'/1237'/0'/0/0
    var key = masterKey;
    
    // 44' (purpose - BIP44)
    key = _deriveChild(key, 0x8000002C);
    
    // 1237' (coin type - Nostr)
    key = _deriveChild(key, 0x800004D5);
    
    // 0' (account)
    key = _deriveChild(key, 0x80000000);
    
    // 0 (change)
    key = _deriveChild(key, 0);
    
    // 0 (address index)
    key = _deriveChild(key, 0);
    
    return hex.encode(key.privateKey);
  }

  /// Derivar chave pública a partir da privada
  String derivePublicKey(String privateKeyHex) {
    final privateKeyBytes = Uint8List.fromList(hex.decode(privateKeyHex));
    final privateKeyInt = BigInt.parse(privateKeyHex, radix: 16);
    
    final ecDomain = ECDomainParameters('secp256k1');
    final publicKeyPoint = ecDomain.G * privateKeyInt;
    
    if (publicKeyPoint == null) {
      throw Exception('Falha ao derivar chave pública');
    }
    
    // Retornar apenas coordenada X (32 bytes)
    final xCoord = publicKeyPoint.x!.toBigInteger()!;
    return xCoord.toRadixString(16).padLeft(64, '0');
  }

  /// Derivar par de chaves Nostr de uma seed
  Map<String, String> deriveNostrKeys(String mnemonic, {String passphrase = ''}) {
    final privateKey = deriveNostrPrivateKey(mnemonic, passphrase: passphrase);
    final publicKey = derivePublicKey(privateKey);
    
    return {
      'privateKey': privateKey,
      'publicKey': publicKey,
    };
  }

  /// Derivar master key de seed usando HMAC-SHA512
  _ExtendedKey _deriveMasterKey(Uint8List seed) {
    final hmac = HMac(SHA512Digest(), 128);
    hmac.init(KeyParameter(utf8.encode('Bitcoin seed') as Uint8List));
    
    final output = Uint8List(64);
    hmac.update(seed, 0, seed.length);
    hmac.doFinal(output, 0);
    
    return _ExtendedKey(
      privateKey: output.sublist(0, 32),
      chainCode: output.sublist(32, 64),
    );
  }

  /// Derivar child key (hardened ou normal)
  _ExtendedKey _deriveChild(_ExtendedKey parent, int index) {
    final hmac = HMac(SHA512Digest(), 128);
    hmac.init(KeyParameter(parent.chainCode));
    
    final data = Uint8List(37);
    
    if (index >= 0x80000000) {
      // Hardened derivation
      data[0] = 0x00;
      data.setRange(1, 33, parent.privateKey);
    } else {
      // Normal derivation - usar public key
      final pubKey = _getCompressedPublicKey(parent.privateKey);
      data.setRange(0, 33, pubKey);
    }
    
    // Index em big-endian
    data[33] = (index >> 24) & 0xFF;
    data[34] = (index >> 16) & 0xFF;
    data[35] = (index >> 8) & 0xFF;
    data[36] = index & 0xFF;
    
    final output = Uint8List(64);
    hmac.update(data, 0, data.length);
    hmac.doFinal(output, 0);
    
    // Nova private key = (parent + derived) mod n
    final parentInt = _bytesToBigInt(parent.privateKey);
    final derivedInt = _bytesToBigInt(output.sublist(0, 32));
    
    final ecDomain = ECDomainParameters('secp256k1');
    final newPrivateInt = (parentInt + derivedInt) % ecDomain.n;
    
    return _ExtendedKey(
      privateKey: _bigIntToBytes(newPrivateInt, 32),
      chainCode: output.sublist(32, 64),
    );
  }

  /// Obter public key comprimida
  Uint8List _getCompressedPublicKey(Uint8List privateKey) {
    final privateInt = _bytesToBigInt(privateKey);
    final ecDomain = ECDomainParameters('secp256k1');
    final publicPoint = ecDomain.G * privateInt;
    
    if (publicPoint == null) {
      throw Exception('Falha ao calcular public key');
    }
    
    final x = publicPoint.x!.toBigInteger()!;
    final y = publicPoint.y!.toBigInteger()!;
    
    final compressed = Uint8List(33);
    compressed[0] = y.isOdd ? 0x03 : 0x02;
    
    final xBytes = _bigIntToBytes(x, 32);
    compressed.setRange(1, 33, xBytes);
    
    return compressed;
  }

  BigInt _bytesToBigInt(Uint8List bytes) {
    return BigInt.parse(hex.encode(bytes), radix: 16);
  }

  Uint8List _bigIntToBytes(BigInt number, int length) {
    final hexStr = number.toRadixString(16).padLeft(length * 2, '0');
    return Uint8List.fromList(hex.decode(hexStr));
  }
  
  /// CRÍTICO: Deriva uma seed BIP-39 DETERMINÍSTICA da chave privada Nostr
  /// Isso permite que: mesma chave Nostr = mesma seed Breez = SEMPRE
  /// Mesmo após desinstalar e reinstalar o app!
  /// 
  /// Processo:
  /// 1. Faz HMAC-SHA512 da chave com salt "bro-wallet-seed"
  /// 2. Usa os primeiros 16 bytes (128 bits) como entropia
  /// 3. Converte entropia em mnemonic BIP-39 de 12 palavras
  String deriveSeedFromNostrKey(String privateKeyHex) {
    // Validar chave
    if (privateKeyHex.length != 64) {
      throw Exception('Chave privada inválida: deve ter 64 caracteres hex');
    }
    
    final privateKeyBytes = Uint8List.fromList(hex.decode(privateKeyHex));
    
    // Usar HMAC-SHA512 com salt específico para gerar entropia determinística
    // O salt garante que não colidamos com outras derivações
    final hmac = HMac(SHA512Digest(), 128);
    final salt = utf8.encode('bro-wallet-seed-v1') as Uint8List;
    hmac.init(KeyParameter(salt));
    
    final output = Uint8List(64);
    hmac.update(privateKeyBytes, 0, privateKeyBytes.length);
    hmac.doFinal(output, 0);
    
    // Usar os primeiros 16 bytes (128 bits) como entropia para seed de 12 palavras
    final entropy = output.sublist(0, 16);
    
    // Converter entropia em mnemonic BIP-39
    final mnemonic = bip39.entropyToMnemonic(hex.encode(entropy));
    
    return mnemonic;
  }
  
  /// Verifica se uma seed foi derivada de uma chave Nostr
  /// Útil para confirmar que a seed correta está sendo usada
  bool verifySeedMatchesKey(String privateKeyHex, String mnemonic) {
    try {
      final derivedMnemonic = deriveSeedFromNostrKey(privateKeyHex);
      return derivedMnemonic == mnemonic;
    } catch (e) {
      return false;
    }
  }
}

/// Chave estendida BIP-32
class _ExtendedKey {
  final Uint8List privateKey;
  final Uint8List chainCode;
  
  _ExtendedKey({required this.privateKey, required this.chainCode});
}
