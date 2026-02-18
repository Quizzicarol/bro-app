import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';

/// Servi�o de armazenamento seguro para dados sens�veis
/// 
/// USA CRIPTOGRAFIA AES-256:
/// - iOS: Keychain
/// - Android: AES + KeyStore
/// 
/// NUNCA armazene em SharedPreferences:
/// - Chaves privadas
/// - Mnemonics/Seeds
/// - Tokens de autentica��o
/// - Dados financeiros sens�veis
class SecureStorageService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock,
    ),
  );

  // Keys de armazenamento
  static const String _nostrPrivateKey = 'nostr_private_key';
  static const String _nostrPublicKey = 'nostr_public_key';
  static const String _breezMnemonic = 'breez_mnemonic';
  static const String _isProviderModeBase = 'is_provider_mode'; // Base para chave com pubkey
  static const String _legacyProviderModeKey = 'is_provider_mode'; // Chave legada

  // =============== NOSTR KEYS ===============

  /// Salva chaves Nostr de forma segura
  static Future<void> saveNostrKeys({
    required String privateKey,
    required String publicKey,
  }) async {
    try {
      await _storage.write(key: _nostrPrivateKey, value: privateKey);
      await _storage.write(key: _nostrPublicKey, value: publicKey);
      debugPrint('?? Chaves Nostr salvas com seguran�a');
    } catch (e) {
      debugPrint('? Erro ao salvar chaves Nostr: $e');
      rethrow;
    }
  }

  /// Recupera chave privada Nostr
  static Future<String?> getNostrPrivateKey() async {
    try {
      return await _storage.read(key: _nostrPrivateKey);
    } catch (e) {
      debugPrint('? Erro ao ler chave privada Nostr: $e');
      return null;
    }
  }

  /// Recupera chave p�blica Nostr
  static Future<String?> getNostrPublicKey() async {
    try {
      return await _storage.read(key: _nostrPublicKey);
    } catch (e) {
      debugPrint('? Erro ao ler chave p�blica Nostr: $e');
      return null;
    }
  }

  /// Verifica se tem chaves Nostr salvas
  static Future<bool> hasNostrKeys() async {
    final privateKey = await getNostrPrivateKey();
    final publicKey = await getNostrPublicKey();
    return privateKey != null && publicKey != null;
  }

  // =============== BREEZ MNEMONIC ===============

  /// Salva mnemonic do Breez de forma segura
  static Future<void> saveBreezMnemonic(String mnemonic) async {
    try {
      await _storage.write(key: _breezMnemonic, value: mnemonic);
      debugPrint('?? Mnemonic Breez salvo com seguran�a');
    } catch (e) {
      debugPrint('? Erro ao salvar mnemonic Breez: $e');
      rethrow;
    }
  }

  /// Recupera mnemonic do Breez
  static Future<String?> getBreezMnemonic() async {
    try {
      return await _storage.read(key: _breezMnemonic);
    } catch (e) {
      debugPrint('? Erro ao ler mnemonic Breez: $e');
      return null;
    }
  }

  /// Verifica se tem mnemonic do Breez
  static Future<bool> hasBreezMnemonic() async {
    final mnemonic = await getBreezMnemonic();
    return mnemonic != null && mnemonic.isNotEmpty;
  }

  // =============== PROVIDER MODE ===============
  // ?? IMPORTANTE: isProviderMode � POR USU�RIO (usando pubkey)
  // Isso evita que um usu�rio veja modo provedor de outro

  /// Gera a chave de provider mode para um usu�rio espec�fico
  static String _getProviderModeKey(String? pubkey) {
    if (pubkey == null || pubkey.isEmpty) {
      return _legacyProviderModeKey;
    }
    final shortKey = pubkey.length > 16 ? pubkey.substring(0, 16) : pubkey;
    return '${_isProviderModeBase}_$shortKey';
  }

  /// Salva flag de modo provedor PARA UM USU�RIO ESPEC�FICO
  static Future<void> setProviderMode(bool isProvider, {String? userPubkey}) async {
    try {
      final key = _getProviderModeKey(userPubkey);
      await _storage.write(key: key, value: isProvider.toString());
      debugPrint('?? setProviderMode($isProvider) para key=$key');
    } catch (e) {
      debugPrint('? Erro ao salvar modo provedor: $e');
    }
  }

  /// Recupera flag de modo provedor PARA UM USU�RIO ESPEC�FICO
  static Future<bool> isProviderMode({String? userPubkey}) async {
    try {
      final key = _getProviderModeKey(userPubkey);
      final value = await _storage.read(key: key);
      final result = value == 'true';
      debugPrint('?? isProviderMode: key=$key, value=$result');
      return result;
    } catch (e) {
      return false;
    }
  }
  
  /// Limpa flag de modo provedor (para logout)
  static Future<void> clearProviderMode({String? userPubkey}) async {
    try {
      final key = _getProviderModeKey(userPubkey);
      await _storage.delete(key: key);
      // Tamb�m limpar chave legada
      await _storage.delete(key: _legacyProviderModeKey);
      debugPrint('??? Provider mode removido para key=$key');
    } catch (e) {
      debugPrint('? Erro ao limpar modo provedor: $e');
    }
  }

  // =============== LIMPEZA ===============

  /// Limpa todas as chaves Nostr (logout)
  static Future<void> clearNostrKeys() async {
    try {
      await _storage.delete(key: _nostrPrivateKey);
      await _storage.delete(key: _nostrPublicKey);
      debugPrint('??? Chaves Nostr removidas');
    } catch (e) {
      debugPrint('? Erro ao limpar chaves Nostr: $e');
    }
  }

  /// Limpa mnemonic do Breez
  static Future<void> clearBreezMnemonic() async {
    try {
      await _storage.delete(key: _breezMnemonic);
      debugPrint('??? Mnemonic Breez removido');
    } catch (e) {
      debugPrint('? Erro ao limpar mnemonic Breez: $e');
    }
  }

  /// Limpa TODOS os dados sens�veis (logout completo)
  static Future<void> clearAll() async {
    try {
      await _storage.deleteAll();
      debugPrint('??? Todos os dados sens�veis removidos');
    } catch (e) {
      debugPrint('? Erro ao limpar dados: $e');
    }
  }

  // =============== MIGRA��O ===============

  /// Migra dados de SharedPreferences para SecureStorage
  /// Chamar uma vez durante atualiza��o do app
  static Future<void> migrateFromSharedPreferences() async {
    try {
      // A migra��o ser� feita pelos providers individualmente
      // quando detectarem dados no SharedPreferences
      debugPrint('?? Verificando migra��o de dados sens�veis...');
    } catch (e) {
      debugPrint('? Erro na migra��o: $e');
    }
  }
}
