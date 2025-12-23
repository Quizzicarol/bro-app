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
    
    // Verificar se há chaves antigas
    final oldPubKey = await _secureStorage.read(key: 'nostr_public_key');
    if (oldPubKey != null && oldPubKey != publicKey) {
      debugPrint('⚠️ SOBRESCREVENDO chave Nostr antiga!');
      debugPrint('   Antiga: ${oldPubKey.substring(0, 16)}...');
      debugPrint('   Nova: ${publicKey.substring(0, 16)}...');
    }
    
    // Salvar em armazenamento seguro (sobrescreve qualquer valor anterior)
    await _secureStorage.write(key: 'nostr_private_key', value: privateKey);
    await _secureStorage.write(key: 'nostr_public_key', value: publicKey);
    await _prefs?.setBool('is_logged_in', true);
    debugPrint('🔐 Chaves Nostr salvas com segurança: ${publicKey.substring(0, 16)}...');
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

  // ===== BREEZ MNEMONIC (VINCULADO AO USUÁRIO NOSTR) =====
  // CRÍTICO: Cada usuário Nostr tem SUA PRÓPRIA seed!
  // Seeds são salvas com chave baseada no pubkey do usuário.
  // Isso garante que NUNCA uma seed seja compartilhada entre usuários!
  
  /// Gera a chave de armazenamento para a seed de um usuário específico
  String _getSeedKeyForUser(String pubkey) {
    return 'breez_seed_${pubkey.substring(0, 16)}';
  }
  
  String _getSeedBackupKeyForUser(String pubkey) {
    return 'bm_backup_${pubkey.substring(0, 16)}';
  }
  
  // Ofusca a seed para armazenamento secundário (não é criptografia forte, apenas ofuscação)
  String _obfuscateSeed(String seed) {
    final bytes = utf8.encode(seed);
    final obfuscated = bytes.map((b) => b ^ 0x5A).toList(); // XOR simples
    return base64.encode(obfuscated);
  }
  
  String _deobfuscateSeed(String obfuscated) {
    try {
      final bytes = base64.decode(obfuscated);
      final deobfuscated = bytes.map((b) => b ^ 0x5A).toList();
      return utf8.decode(deobfuscated);
    } catch (e) {
      return '';
    }
  }
  
  /// Salva mnemonic VINCULADO ao usuário Nostr específico
  /// CRÍTICO: Cada pubkey tem sua própria seed isolada!
  /// CRÍTICO: NUNCA sobrescreve uma seed existente para proteger fundos!
  Future<void> saveBreezMnemonic(String mnemonic, {String? ownerPubkey, bool forceOverwrite = false}) async {
    if (_prefs == null) await init();
    
    // Pegar pubkey do dono (usuário atual)
    final pubkey = ownerPubkey ?? await getNostrPublicKey();
    
    if (pubkey == null || pubkey.isEmpty) {
      debugPrint('❌ ERRO: Tentando salvar seed sem usuário logado!');
      return;
    }
    
    final seedKey = _getSeedKeyForUser(pubkey);
    final backupKey = _getSeedBackupKeyForUser(pubkey);
    
    // PROTEÇÃO: Verificar se já existe seed para este usuário
    if (!forceOverwrite) {
      // Verificar SecureStorage
      String? existingSeed = await _secureStorage.read(key: seedKey);
      
      // Se não encontrou no SecureStorage, verificar backup
      if (existingSeed == null || existingSeed.isEmpty) {
        final backupObfuscated = _prefs?.getString(backupKey);
        if (backupObfuscated != null && backupObfuscated.isNotEmpty) {
          existingSeed = _deobfuscateSeed(backupObfuscated);
        }
      }
      
      if (existingSeed != null && existingSeed.isNotEmpty && existingSeed.split(' ').length == 12) {
        final existingWords = existingSeed.split(' ').take(2).join(' ');
        final newWords = mnemonic.split(' ').take(2).join(' ');
        
        if (existingWords != newWords) {
          debugPrint('🛡️ PROTEÇÃO: Seed existente NÃO será sobrescrita!');
          debugPrint('   Existente: $existingWords...');
          debugPrint('   Tentando salvar: $newWords...');
          debugPrint('   Use forceOverwrite=true nas configs para mudar.');
          return; // NÃO SOBRESCREVER!
        } else {
          debugPrint('✅ Seed idêntica, atualizando backup');
        }
      }
    }
    
    // BACKUP 1: SecureStorage com chave POR USUÁRIO
    await _secureStorage.write(key: seedKey, value: mnemonic);
    
    // BACKUP 2: SharedPreferences com ofuscação POR USUÁRIO
    final obfuscated = _obfuscateSeed(mnemonic);
    await _prefs?.setString(backupKey, obfuscated);
    
    debugPrint('🔐 Seed ÚNICA salva para usuário: ${pubkey.substring(0, 16)}...');
    debugPrint('   Chave: $seedKey (${mnemonic.split(" ").length} palavras)');
  }
  
  /// Força a troca de seed (usado nas configurações avançadas)
  Future<void> forceUpdateBreezMnemonic(String mnemonic, {String? ownerPubkey}) async {
    debugPrint('⚠️ FORÇANDO atualização de seed...');
    await saveBreezMnemonic(mnemonic, ownerPubkey: ownerPubkey, forceOverwrite: true);
  }
  
  /// Retorna o pubkey do dono da seed atual (se houver)
  Future<String?> getMnemonicOwner() async {
    if (_prefs == null) await init();
    final pubkey = await getNostrPublicKey();
    if (pubkey == null) return null;
    
    // Verificar se existe seed para este usuário
    final seedKey = _getSeedKeyForUser(pubkey);
    final mnemonic = await _secureStorage.read(key: seedKey);
    
    if (mnemonic != null && mnemonic.isNotEmpty) {
      return pubkey;
    }
    return null;
  }

  /// Retorna a seed do usuário atual (ou de um pubkey específico)
  /// CRÍTICO: Retorna apenas a seed DO USUÁRIO LOGADO!
  Future<String?> getBreezMnemonic({String? forPubkey}) async {
    if (_prefs == null) await init();
    
    // Usar pubkey fornecido ou do usuário atual
    final pubkey = forPubkey ?? await getNostrPublicKey();
    
    if (pubkey == null || pubkey.isEmpty) {
      debugPrint('⚠️ getBreezMnemonic: Nenhum usuário logado');
      return null;
    }
    
    final seedKey = _getSeedKeyForUser(pubkey);
    final backupKey = _getSeedBackupKeyForUser(pubkey);
    
    debugPrint('🔍 Buscando seed para usuário: ${pubkey.substring(0, 16)}...');
    debugPrint('   Chave de busca: $seedKey');
    debugPrint('   Backup key: $backupKey');
    
    // DEBUG: Listar todas as seeds salvas
    final allKeys = _prefs?.getKeys() ?? {};
    final seedKeys = allKeys.where((k) => k.startsWith('bm_backup_') || k.startsWith('breez_seed_')).toList();
    debugPrint('📦 Seeds salvas no storage: $seedKeys');
    
    // TENTAR 1: SecureStorage (preferido)
    String? mnemonic = await _secureStorage.read(key: seedKey);
    debugPrint('   SecureStorage[$seedKey]: ${mnemonic != null ? "${mnemonic.split(' ').take(2).join(' ')}... (${mnemonic.split(' ').length} palavras)" : "NULL"}');
    
    if (mnemonic != null && mnemonic.isNotEmpty && mnemonic.split(' ').length == 12) {
      debugPrint('✅ Seed encontrada no SecureStorage para este usuário');
      return mnemonic;
    }
    
    // TENTAR 2: SharedPreferences backup
    final backupObfuscated = _prefs?.getString(backupKey);
    debugPrint('   SharedPrefs[$backupKey]: ${backupObfuscated != null ? "EXISTE" : "NULL"}');
    if (backupObfuscated != null && backupObfuscated.isNotEmpty) {
      mnemonic = _deobfuscateSeed(backupObfuscated);
      if (mnemonic.isNotEmpty && mnemonic.split(' ').length == 12) {
        debugPrint('✅ Seed recuperada do backup para este usuário');
        // Restaurar no SecureStorage
        await _secureStorage.write(key: seedKey, value: mnemonic);
        return mnemonic;
      }
    }
    
    // TENTAR 3: Migrar seed antiga (global) se este é o primeiro usuário
    final legacySeed = await _migrateLegacySeedIfNeeded(pubkey);
    if (legacySeed != null) {
      return legacySeed;
    }
    
    debugPrint('❌ Nenhuma seed encontrada para este usuário - precisa gerar nova!');
    return null;
  }
  
  /// Migra seed antiga (formato global) para o novo formato por usuário
  /// Só acontece UMA VEZ para compatibilidade com versões anteriores
  Future<String?> _migrateLegacySeedIfNeeded(String pubkey) async {
    // Verificar se já migrou
    final migrated = _prefs?.getBool('seed_migrated_v2') ?? false;
    if (migrated) return null;
    
    debugPrint('🔄 Verificando seed legada para migração...');
    
    // Tentar ler seed antiga (formato global)
    String? legacySeed = await _secureStorage.read(key: 'breez_mnemonic');
    
    if (legacySeed == null || legacySeed.isEmpty) {
      // Tentar backup antigo
      final legacyBackup = _prefs?.getString('bm_backup_v1');
      if (legacyBackup != null && legacyBackup.isNotEmpty) {
        legacySeed = _deobfuscateSeed(legacyBackup);
      }
    }
    
    if (legacySeed != null && legacySeed.isNotEmpty && legacySeed.split(' ').length == 12) {
      // Verificar se a seed antiga pertencia a este usuário
      final legacyOwner = _prefs?.getString('bm_owner_pubkey');
      
      if (legacyOwner == pubkey) {
        debugPrint('✅ Migrando seed legada para novo formato (mesmo usuário)');
        await saveBreezMnemonic(legacySeed, ownerPubkey: pubkey);
        await _prefs?.setBool('seed_migrated_v2', true);
        return legacySeed;
      } else {
        debugPrint('⚠️ Seed legada pertence a outro usuário - não migrar');
        // Marcar como migrado para não tentar de novo
        await _prefs?.setBool('seed_migrated_v2', true);
      }
    }
    
    return null;
  }
  
  /// Verifica se o usuário atual já tem uma seed
  Future<bool> hasBreezMnemonicForCurrentUser() async {
    final seed = await getBreezMnemonic();
    return seed != null && seed.isNotEmpty;
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
  
  /// Faz logout do usuário atual SEM apagar a seed
  /// A seed é preservada para permitir login futuro com a mesma conta
  Future<void> logout() async {
    if (_prefs == null) await init();
    
    // Preservar seeds de TODOS os usuários antes de limpar
    final allKeys = _prefs?.getKeys() ?? <String>{};
    final seedBackups = <String, String>{};
    
    for (final key in allKeys) {
      // Preservar backups de seeds (formato: bm_backup_<pubkey>)
      if (key.startsWith('bm_backup_')) {
        final value = _prefs?.getString(key);
        if (value != null) {
          seedBackups[key] = value;
          debugPrint('💾 Preservando seed backup: $key');
        }
      }
    }
    
    // Limpar SharedPreferences
    await _prefs?.clear();
    
    // Restaurar seeds
    for (final entry in seedBackups.entries) {
      await _prefs?.setString(entry.key, entry.value);
    }
    
    debugPrint('🚪 Logout concluído - ${seedBackups.length} seeds preservadas');
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
  
  // ===== DEBUG: LISTAR TODAS AS SEEDS ARMAZENADAS =====
  
  /// Lista todas as seeds armazenadas para debug
  /// Retorna um mapa com pubkey_prefix -> seed_info
  Future<Map<String, Map<String, dynamic>>> debugListAllStoredSeeds() async {
    if (_prefs == null) await init();
    
    final result = <String, Map<String, dynamic>>{};
    
    // Listar todas as chaves que começam com breez_seed_
    final allKeys = _prefs?.getKeys() ?? {};
    
    // Seed legada (global)
    final legacySeed = await _secureStorage.read(key: 'breez_mnemonic');
    if (legacySeed != null && legacySeed.isNotEmpty) {
      result['legacy_global'] = {
        'source': 'SecureStorage (legacy)',
        'wordCount': legacySeed.split(' ').length,
        'first2Words': '${legacySeed.split(' ')[0]} ${legacySeed.split(' ')[1]}',
      };
    }
    
    // Backup legado
    final legacyBackup = _prefs?.getString('bm_backup_v1');
    if (legacyBackup != null && legacyBackup.isNotEmpty) {
      final decoded = _deobfuscateSeed(legacyBackup);
      if (decoded.isNotEmpty) {
        result['legacy_backup'] = {
          'source': 'SharedPrefs backup (legacy)',
          'wordCount': decoded.split(' ').length,
          'first2Words': decoded.isNotEmpty ? '${decoded.split(' ')[0]} ${decoded.split(' ')[1]}' : '?',
        };
      }
    }
    
    // Verificar seeds por usuário no SecureStorage
    // Não conseguimos listar todas as chaves do SecureStorage diretamente,
    // mas podemos verificar as chaves conhecidas baseado nos backups
    for (final key in allKeys) {
      if (key.startsWith('bm_backup_')) {
        final pubkeyPrefix = key.replaceFirst('bm_backup_', '');
        final backupValue = _prefs?.getString(key);
        if (backupValue != null && backupValue.isNotEmpty) {
          final decoded = _deobfuscateSeed(backupValue);
          if (decoded.isNotEmpty && decoded.split(' ').length == 12) {
            result['user_$pubkeyPrefix'] = {
              'source': 'Per-user backup ($key)',
              'pubkeyPrefix': pubkeyPrefix,
              'wordCount': decoded.split(' ').length,
              'first2Words': '${decoded.split(' ')[0]} ${decoded.split(' ')[1]}',
            };
          }
        }
      }
    }
    
    // Seed do usuário atual
    final currentPubkey = await getNostrPublicKey();
    if (currentPubkey != null) {
      final currentSeed = await getBreezMnemonic();
      if (currentSeed != null && currentSeed.isNotEmpty) {
        result['CURRENT_USER'] = {
          'source': 'Current user (${currentPubkey.substring(0, 16)})',
          'pubkeyPrefix': currentPubkey.substring(0, 16),
          'wordCount': currentSeed.split(' ').length,
          'first2Words': '${currentSeed.split(' ')[0]} ${currentSeed.split(' ')[1]}',
        };
      }
    }
    
    debugPrint('🔍 DEBUG: Seeds armazenadas encontradas: ${result.length}');
    result.forEach((key, value) {
      debugPrint('   $key: ${value['first2Words']} (${value['wordCount']} palavras) - ${value['source']}');
    });
    
    return result;
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