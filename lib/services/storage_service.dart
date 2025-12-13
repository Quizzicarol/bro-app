import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../config.dart';

class StorageService {
  static final StorageService _instance = StorageService._internal();
  factory StorageService() => _instance;
  StorageService._internal();

  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // ===== NOSTR KEYS =====
  // (usando SharedPreferences - para produÃ§Ã£o, usar flutter_secure_storage)
  
  Future<void> saveNostrKeys({
    required String privateKey,
    required String publicKey,
  }) async {
    if (_prefs == null) await init();
    await _prefs?.setString('nostr_private_key', privateKey);
    await _prefs?.setString('nostr_public_key', publicKey);
    await _prefs?.setBool('is_logged_in', true);
  }

  Future<String?> getNostrPrivateKey() async {
    if (_prefs == null) await init();
    return _prefs?.getString('nostr_private_key');
  }

  Future<String?> getNostrPublicKey() async {
    if (_prefs == null) await init();
    return _prefs?.getString('nostr_public_key');
  }

  Future<bool> isLoggedIn() async {
    if (_prefs == null) await init();
    return _prefs?.getBool('is_logged_in') ?? false;
  }

  // ===== BREEZ - API Key REMOVIDA =====
  // A API key do Breez agora estÃ¡ no backend, NÃƒO no frontend
  // Mantido apenas mnemonic para compatibilidade com cÃ³digo legacy
  
  Future<void> saveBreezMnemonic(String mnemonic) async {
    if (_prefs == null) await init();
    await _prefs?.setString('breez_mnemonic', mnemonic);
  }

  Future<String?> getBreezMnemonic() async {
    if (_prefs == null) await init();
    return _prefs?.getString('breez_mnemonic');
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
}