import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';

/// Serviço de armazenamento seguro para dados sensíveis
/// 
/// USA CRIPTOGRAFIA AES-256:
/// - iOS: Keychain
/// - Android: AES + KeyStore
/// 
/// NUNCA armazene em SharedPreferences:
/// - Chaves privadas
/// - Mnemonics/Seeds
/// - Tokens de autenticação
/// - Dados financeiros sensíveis
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
  static const String _isProviderMode = 'is_provider_mode';

  // =============== NOSTR KEYS ===============

  /// Salva chaves Nostr de forma segura
  static Future<void> saveNostrKeys({
    required String privateKey,
    required String publicKey,
  }) async {
    try {
      await _storage.write(key: _nostrPrivateKey, value: privateKey);
      await _storage.write(key: _nostrPublicKey, value: publicKey);
      debugPrint('🔐 Chaves Nostr salvas com segurança');
    } catch (e) {
      debugPrint('❌ Erro ao salvar chaves Nostr: $e');
      rethrow;
    }
  }

  /// Recupera chave privada Nostr
  static Future<String?> getNostrPrivateKey() async {
    try {
      return await _storage.read(key: _nostrPrivateKey);
    } catch (e) {
      debugPrint('❌ Erro ao ler chave privada Nostr: $e');
      return null;
    }
  }

  /// Recupera chave pública Nostr
  static Future<String?> getNostrPublicKey() async {
    try {
      return await _storage.read(key: _nostrPublicKey);
    } catch (e) {
      debugPrint('❌ Erro ao ler chave pública Nostr: $e');
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
      debugPrint('🔐 Mnemonic Breez salvo com segurança');
    } catch (e) {
      debugPrint('❌ Erro ao salvar mnemonic Breez: $e');
      rethrow;
    }
  }

  /// Recupera mnemonic do Breez
  static Future<String?> getBreezMnemonic() async {
    try {
      return await _storage.read(key: _breezMnemonic);
    } catch (e) {
      debugPrint('❌ Erro ao ler mnemonic Breez: $e');
      return null;
    }
  }

  /// Verifica se tem mnemonic do Breez
  static Future<bool> hasBreezMnemonic() async {
    final mnemonic = await getBreezMnemonic();
    return mnemonic != null && mnemonic.isNotEmpty;
  }

  // =============== PROVIDER MODE ===============

  /// Salva flag de modo provedor
  static Future<void> setProviderMode(bool isProvider) async {
    try {
      await _storage.write(key: _isProviderMode, value: isProvider.toString());
    } catch (e) {
      debugPrint('❌ Erro ao salvar modo provedor: $e');
    }
  }

  /// Recupera flag de modo provedor
  static Future<bool> isProviderMode() async {
    try {
      final value = await _storage.read(key: _isProviderMode);
      return value == 'true';
    } catch (e) {
      return false;
    }
  }

  // =============== LIMPEZA ===============

  /// Limpa todas as chaves Nostr (logout)
  static Future<void> clearNostrKeys() async {
    try {
      await _storage.delete(key: _nostrPrivateKey);
      await _storage.delete(key: _nostrPublicKey);
      debugPrint('🗑️ Chaves Nostr removidas');
    } catch (e) {
      debugPrint('❌ Erro ao limpar chaves Nostr: $e');
    }
  }

  /// Limpa mnemonic do Breez
  static Future<void> clearBreezMnemonic() async {
    try {
      await _storage.delete(key: _breezMnemonic);
      debugPrint('🗑️ Mnemonic Breez removido');
    } catch (e) {
      debugPrint('❌ Erro ao limpar mnemonic Breez: $e');
    }
  }

  /// Limpa TODOS os dados sensíveis (logout completo)
  static Future<void> clearAll() async {
    try {
      await _storage.deleteAll();
      debugPrint('🗑️ Todos os dados sensíveis removidos');
    } catch (e) {
      debugPrint('❌ Erro ao limpar dados: $e');
    }
  }

  // =============== MIGRAÇÃO ===============

  /// Migra dados de SharedPreferences para SecureStorage
  /// Chamar uma vez durante atualização do app
  static Future<void> migrateFromSharedPreferences() async {
    try {
      // A migração será feita pelos providers individualmente
      // quando detectarem dados no SharedPreferences
      debugPrint('🔄 Verificando migração de dados sensíveis...');
    } catch (e) {
      debugPrint('❌ Erro na migração: $e');
    }
  }
}
