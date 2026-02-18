import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../config.dart';

class StorageService {
  static final StorageService _instance = StorageService._internal();
  factory StorageService() => _instance;
  StorageService._internal();

  SharedPreferences? _prefs;
  
  // Armazenamento seguro para dados sensíveis
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock,
    ),
  );

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    // Migrar dados antigos para armazenamento seguro
    await _migrateToSecureStorage();
  }
  
  // Migrar dados de SharedPreferences para SecureStorage
  Future<void> _migrateToSecureStorage() async {
    try {
      // Verificar se já migrou
      final migrated = _prefs?.getBool('_migrated_to_secure_v1') ?? false;
      if (migrated) return;
      
      // Migrar chaves Nostr
      final oldPrivKey = _prefs?.getString('nostr_private_key');
      final oldPubKey = _prefs?.getString('nostr_public_key');
      if (oldPrivKey != null && oldPrivKey.isNotEmpty) {
        await _secureStorage.write(key: 'nostr_private_key', value: oldPrivKey);
        await _prefs?.remove('nostr_private_key');
        debugPrint('🔄 Chave privada Nostr migrada para armazenamento seguro');
      }
      if (oldPubKey != null && oldPubKey.isNotEmpty) {
        await _secureStorage.write(key: 'nostr_public_key', value: oldPubKey);
        await _prefs?.remove('nostr_public_key');
        debugPrint('🔄 Chave pública Nostr migrada para armazenamento seguro');
      }
      
      // Migrar mnemonic Breez
      final oldMnemonic = _prefs?.getString('breez_mnemonic');
      if (oldMnemonic != null && oldMnemonic.isNotEmpty) {
        await _secureStorage.write(key: 'breez_mnemonic', value: oldMnemonic);
        await _prefs?.remove('breez_mnemonic');
        debugPrint('🔄 Mnemonic Breez migrado para armazenamento seguro');
      }
      
      // Marcar como migrado
      await _prefs?.setBool('_migrated_to_secure_v1', true);
      debugPrint('✅ Migração para armazenamento seguro concluída');
    } catch (e) {
      debugPrint('⚠️ Erro na migração: $e');
    }
  }

  // ===== NOSTR KEYS (ARMAZENAMENTO SEGURO) =====
  
  Future<void> saveNostrKeys({
    required String privateKey,
    required String publicKey,
  }) async {
    if (_prefs == null) await init();
    // Salvar em armazenamento seguro
    await _secureStorage.write(key: 'nostr_private_key', value: privateKey);
    await _secureStorage.write(key: 'nostr_public_key', value: publicKey);
    await _prefs?.setBool('is_logged_in', true);
    debugPrint('🔐 Chaves Nostr salvas com segurança');
  }

  Future<String?> getNostrPrivateKey() async {
    if (_prefs == null) await init();
    return await _secureStorage.read(key: 'nostr_private_key');
  }

  Future<String?> getNostrPublicKey() async {
    if (_prefs == null) await init();
    return await _secureStorage.read(key: 'nostr_public_key');
  }

  Future<bool> isLoggedIn() async {
    if (_prefs == null) await init();
    return _prefs?.getBool('is_logged_in') ?? false;
  }

  // ===== BREEZ MNEMONIC (ARMAZENAMENTO SEGURO) =====
  
  Future<void> saveBreezMnemonic(String mnemonic) async {
    if (_prefs == null) await init();
    await _secureStorage.write(key: 'breez_mnemonic', value: mnemonic);
    debugPrint('🔐 Mnemonic Breez salvo com segurança');
  }

  Future<String?> getBreezMnemonic() async {
    if (_prefs == null) await init();
    return await _secureStorage.read(key: 'breez_mnemonic');
  }

  Future<void> setFirstTimeSeedShown(bool shown) async {
    if (_prefs == null) await init();
    await _prefs?.setBool('first_time_seed_shown', shown);
  }

  Future<bool> isFirstTimeSeedShown() async {
    if (_prefs == null) await init();
    return _prefs?.getBool('first_time_seed_shown') ?? false;
  }

  // ===== BACKEND URL =====
  
  Future<void> saveBackendUrl(String url) async {
    if (_prefs == null) await init();
    await _prefs?.setString('backend_url', url);
  }

  Future<String> getBackendUrl() async {
    if (_prefs == null) await init();
    // Import AppConfig at top: import '../config.dart';
    return _prefs?.getString('backend_url') ?? AppConfig.defaultBackendUrl;
  }

  // ===== USER PREFERENCES =====
  
  Future<void> setUserType(String type) async {
    if (_prefs == null) await init();
    await _prefs?.setString('user_type', type);
  }

  Future<String?> getUserType() async {
    if (_prefs == null) await init();
    return _prefs?.getString('user_type');
  }

  // ===== THEME =====
  
  Future<void> setDarkMode(bool isDark) async {
    if (_prefs == null) await init();
    await _prefs?.setBool('dark_mode', isDark);
  }

  Future<bool> isDarkMode() async {
    if (_prefs == null) await init();
    return _prefs?.getBool('dark_mode') ?? false;
  }

  // ===== ORDERS CACHE =====
  
  Future<void> cacheOrders(String ordersJson) async {
    if (_prefs == null) await init();
    await _prefs?.setString('cached_orders', ordersJson);
  }

  Future<String?> getCachedOrders() async {
    if (_prefs == null) await init();
    return _prefs?.getString('cached_orders');
  }

  // ===== PROVIDER ID =====
  
  Future<void> saveProviderId(String providerId) async {
    if (_prefs == null) await init();
    await _prefs?.setString('provider_id', providerId);
  }

  Future<String?> getProviderId() async {
    if (_prefs == null) await init();
    return _prefs?.getString('provider_id');
  }

  // ===== USER ID =====
  
  Future<void> saveUserId(String userId) async {
    if (_prefs == null) await init();
    await _prefs?.setString('user_id', userId);
  }

  Future<String?> getUserId() async {
    if (_prefs == null) await init();
    // Se nÃ£o houver user_id, usar public key do Nostr como ID
    String? userId = _prefs?.getString('user_id');
    if (userId == null) {
      userId = await getNostrPublicKey();
    }
    return userId;
  }

  // ===== CLEAR DATA =====
  
  Future<void> logout() async {
    if (_prefs == null) await init();
    await _prefs?.clear();
  }

  Future<void> clearAll() async {
    if (_prefs == null) await init();
    await _prefs?.clear();
  }

  // ===== RELAYS =====
  
  Future<void> saveRelays(List<String> relays) async {
    if (_prefs == null) await init();
    await _prefs?.setString('nostr_relays', jsonEncode(relays));
  }

  Future<List<String>?> getRelays() async {
    if (_prefs == null) await init();
    final relaysJson = _prefs?.getString('nostr_relays');
    if (relaysJson != null) {
      return List<String>.from(jsonDecode(relaysJson));
    }
    return null;
  }

  // ===== PRIVACY SETTINGS =====
  
  Future<void> saveTorEnabled(bool enabled) async {
    if (_prefs == null) await init();
    await _prefs?.setBool('tor_enabled', enabled);
  }

  Future<bool> getTorEnabled() async {
    if (_prefs == null) await init();
    return _prefs?.getBool('tor_enabled') ?? false;
  }

  Future<void> saveNip44Enabled(bool enabled) async {
    if (_prefs == null) await init();
    await _prefs?.setBool('nip44_enabled', enabled);
  }

  Future<bool> getNip44Enabled() async {
    if (_prefs == null) await init();
    return _prefs?.getBool('nip44_enabled') ?? true; // Default true
  }

  Future<void> saveHideBalance(bool hide) async {
    if (_prefs == null) await init();
    await _prefs?.setBool('hide_balance', hide);
  }

  Future<bool> getHideBalance() async {
    if (_prefs == null) await init();
    return _prefs?.getBool('hide_balance') ?? false;
  }

  Future<void> saveShareReceipts(bool share) async {
    if (_prefs == null) await init();
    await _prefs?.setBool('share_receipts', share);
  }

  Future<bool> getShareReceipts() async {
    if (_prefs == null) await init();
    return _prefs?.getBool('share_receipts') ?? false;
  }

  // ===== GENERIC DATA STORAGE =====
  
  Future<void> saveData(String key, String value) async {
    if (_prefs == null) await init();
    await _prefs?.setString(key, value);
  }

  Future<String?> getData(String key) async {
    if (_prefs == null) await init();
    return _prefs?.getString(key);
  }

  Future<void> removeData(String key) async {
    if (_prefs == null) await init();
    await _prefs?.remove(key);
  }

  // ===== NSEC (Nostr Private Key in bech32) =====
  
  Future<String?> getNsec() async {
    // Retorna a private key hex (seria convertida para nsec em produÃ§Ã£o)
    return await getNostrPrivateKey();
  }

  // ===== NOSTR PROFILE =====

  Future<void> saveNostrProfile({
    String? name,
    String? displayName,
    String? picture,
    String? about,
  }) async {
    if (_prefs == null) await init();
    if (name != null) await _prefs?.setString('nostr_profile_name', name);
    if (displayName != null) await _prefs?.setString('nostr_profile_display_name', displayName);
    if (picture != null) await _prefs?.setString('nostr_profile_picture', picture);
    if (about != null) await _prefs?.setString('nostr_profile_about', about);
  }

  Future<String?> getNostrProfileName() async {
    if (_prefs == null) await init();
    return _prefs?.getString('nostr_profile_display_name') ?? _prefs?.getString('nostr_profile_name');
  }

  Future<String?> getNostrProfilePicture() async {
    if (_prefs == null) await init();
    return _prefs?.getString('nostr_profile_picture');
  }

  Future<String?> getNostrProfileAbout() async {
    if (_prefs == null) await init();
    return _prefs?.getString('nostr_profile_about');
  }

  Future<void> clearNostrProfile() async {
    if (_prefs == null) await init();
    await _prefs?.remove('nostr_profile_name');
    await _prefs?.remove('nostr_profile_display_name');
    await _prefs?.remove('nostr_profile_picture');
    await _prefs?.remove('nostr_profile_about');
  }
  
  // ===== LOGOUT / LIMPAR DADOS SENSÍVEIS =====
  
  Future<void> clearAllSecureData() async {
    try {
      // Limpar armazenamento seguro
      await _secureStorage.delete(key: 'nostr_private_key');
      await _secureStorage.delete(key: 'nostr_public_key');
      await _secureStorage.delete(key: 'breez_mnemonic');
      
      // Limpar flags de login
      if (_prefs == null) await init();
      await _prefs?.setBool('is_logged_in', false);
      await _prefs?.setBool('first_time_seed_shown', false);
      
      // Limpar perfil
      await clearNostrProfile();
      
      debugPrint('🗑️ Todos os dados sensíveis foram removidos com segurança');
    } catch (e) {
      debugPrint('❌ Erro ao limpar dados sensíveis: $e');
    }
  }
}