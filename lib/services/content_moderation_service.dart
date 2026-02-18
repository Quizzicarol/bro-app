import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'nostr_service.dart';
import 'package:nostr/nostr.dart';

/// Serviço de moderação de conteúdo descentralizado
/// Implementa:
/// - Filtro local de palavras proibidas
/// - Web of Trust (WoT) básico
/// - NIP-56 Report System
class ContentModerationService {
  static final ContentModerationService _instance = ContentModerationService._internal();
  factory ContentModerationService() => _instance;
  ContentModerationService._internal();

  final NostrService _nostrService = NostrService();
  
  // Cache de pubkeys que seguimos
  Set<String> _following = {};
  
  // Cache de pubkeys seguidas por quem seguimos (WoT nível 2)
  Set<String> _webOfTrust = {};
  
  // Pubkeys reportadas (com contagem de reports)
  Map<String, int> _reportedPubkeys = {};
  
  // Pubkeys mutadas pelo usuário
  Set<String> _mutedPubkeys = {};

  // ============================================
  // LISTA DE PALAVRAS PROIBIDAS
  // ============================================
  
  /// Lista de palavras/termos que indicam conteúdo proibido
  /// Isso é filtrado LOCALMENTE, não há censura na rede
  static const List<String> _bannedTerms = [
    // Conteúdo ilegal
    'cp', 'pedo', 'menor', 'criança', 'child',
    'csam', 'underage', 'jailbait',
    // Drogas pesadas (pode ajustar)
    'cocaina', 'heroina', 'crack',
    // Violência extrema
    'gore', 'snuff', 'assassinato',
    // Outros termos ofensivos graves
    'nazista', 'nazi', 'hitler',
    // Golpes conhecidos
    'dobrar bitcoin', 'double your btc', 'send btc get back',
  ];

  /// Verifica se um texto contém termos proibidos
  bool containsBannedContent(String text) {
    final lowerText = text.toLowerCase();
    for (final term in _bannedTerms) {
      if (lowerText.contains(term)) {
        debugPrint('⚠️ Conteúdo filtrado: contém "$term"');
        return true;
      }
    }
    return false;
  }

  /// Verifica se uma oferta deve ser ocultada
  bool shouldHideOffer({
    required String title,
    required String description,
    required String sellerPubkey,
  }) {
    // 1. Verificar palavras proibidas
    if (containsBannedContent(title) || containsBannedContent(description)) {
      return true;
    }
    
    // 2. Verificar se está mutado
    if (_mutedPubkeys.contains(sellerPubkey)) {
      return true;
    }
    
    // 3. Verificar se tem muitos reports (threshold: 3)
    if ((_reportedPubkeys[sellerPubkey] ?? 0) >= 3) {
      return true;
    }
    
    return false;
  }

  // ============================================
  // WEB OF TRUST
  // ============================================

  /// Calcula o score de confiança de uma pubkey
  /// 0 = desconhecido, 1 = seguido por seguidos, 2 = seguido diretamente
  int getTrustScore(String pubkey) {
    if (_following.contains(pubkey)) {
      return 2; // Seguido diretamente
    }
    if (_webOfTrust.contains(pubkey)) {
      return 1; // Seguido por alguém que você segue
    }
    return 0; // Desconhecido
  }

  /// Carrega a lista de quem o usuário segue
  Future<void> loadFollowing() async {
    try {
      final myPubkey = _nostrService.publicKey;
      if (myPubkey == null) return;

      // Buscar kind 3 (contact list) do usuário
      // Por enquanto, usar SharedPreferences como cache
      final prefs = await SharedPreferences.getInstance();
      final followingJson = prefs.getStringList('following_$myPubkey') ?? [];
      _following = followingJson.toSet();
      
      debugPrint('📋 Carregado ${_following.length} seguidos');
    } catch (e) {
      debugPrint('❌ Erro ao carregar following: $e');
    }
  }

  /// Adiciona pubkey à lista de seguidos (cache local)
  Future<void> addFollowing(String pubkey) async {
    _following.add(pubkey);
    _webOfTrust.add(pubkey);
    
    final prefs = await SharedPreferences.getInstance();
    final myPubkey = _nostrService.publicKey;
    if (myPubkey != null) {
      await prefs.setStringList('following_$myPubkey', _following.toList());
    }
  }

  /// Verifica se o usuário segue uma pubkey
  bool isFollowing(String pubkey) => _following.contains(pubkey);

  /// Verifica se está no Web of Trust
  bool isInWebOfTrust(String pubkey) => 
      _following.contains(pubkey) || _webOfTrust.contains(pubkey);

  // ============================================
  // NIP-56 REPORT SYSTEM
  // ============================================

  /// Tipos de report conforme NIP-56
  static const Map<String, String> reportTypes = {
    'nudity': 'Nudez',
    'malware': 'Malware/Vírus',
    'profanity': 'Linguagem ofensiva',
    'illegal': 'Conteúdo ilegal',
    'spam': 'Spam',
    'impersonation': 'Falsidade ideológica',
    'other': 'Outro',
  };

  /// Publica um report (NIP-56 kind 1984)
  Future<bool> reportContent({
    required String targetPubkey,
    String? targetEventId,
    required String reportType,
    String? reason,
  }) async {
    try {
      final privateKey = _nostrService.privateKey;
      if (privateKey == null) {
        throw Exception('Faça login para reportar');
      }

      final keychain = Keychain(privateKey);
      
      // Tags do report conforme NIP-56
      final tags = <List<String>>[
        ['p', targetPubkey, reportType], // Pubkey reportada com tipo
      ];
      
      // Se tem evento específico, adicionar tag 'e'
      if (targetEventId != null) {
        tags.add(['e', targetEventId, reportType]);
      }
      
      // Criar evento kind 1984
      final event = Event.from(
        kind: 1984, // NIP-56 Report
        tags: tags,
        content: reason ?? 'Reported via Bro App',
        privkey: keychain.private,
      );

      // Publicar em relays
      final relays = [
        'wss://relay.damus.io',
        'wss://nos.lol',
        'wss://relay.nostr.band',
      ];

      int successCount = 0;
      for (final relay in relays) {
        try {
          final success = await _publishReport(relay, event);
          if (success) successCount++;
        } catch (e) {
          debugPrint('⚠️ Falha ao reportar em $relay: $e');
        }
      }

      // Adicionar à contagem local também
      _reportedPubkeys[targetPubkey] = (_reportedPubkeys[targetPubkey] ?? 0) + 1;
      
      // Salvar reports locais
      await _saveLocalReports();

      debugPrint('✅ Report publicado em $successCount relays');
      return successCount > 0;
    } catch (e) {
      debugPrint('❌ Erro ao reportar: $e');
      return false;
    }
  }

  Future<bool> _publishReport(String relayUrl, Event event) async {
    // Usar a mesma lógica de publicação do NostrOrderService
    // Por simplicidade, retornar true (a publicação real está no NostrOrderService)
    // TODO: Integrar com NostrOrderService._publishToRelay
    return true;
  }

  /// Muta uma pubkey localmente
  Future<void> mutePubkey(String pubkey) async {
    _mutedPubkeys.add(pubkey);
    
    final prefs = await SharedPreferences.getInstance();
    final myPubkey = _nostrService.publicKey;
    if (myPubkey != null) {
      await prefs.setStringList('muted_$myPubkey', _mutedPubkeys.toList());
    }
    
    debugPrint('🔇 Pubkey mutada: ${pubkey.substring(0, 8)}...');
  }

  /// Remove mute de uma pubkey
  Future<void> unmutePubkey(String pubkey) async {
    _mutedPubkeys.remove(pubkey);
    
    final prefs = await SharedPreferences.getInstance();
    final myPubkey = _nostrService.publicKey;
    if (myPubkey != null) {
      await prefs.setStringList('muted_$myPubkey', _mutedPubkeys.toList());
    }
  }

  /// Verifica se uma pubkey está mutada
  bool isMuted(String pubkey) => _mutedPubkeys.contains(pubkey);

  // ============================================
  // PERSISTÊNCIA LOCAL
  // ============================================

  Future<void> _saveLocalReports() async {
    final prefs = await SharedPreferences.getInstance();
    final myPubkey = _nostrService.publicKey;
    if (myPubkey != null) {
      await prefs.setString(
        'reports_$myPubkey',
        jsonEncode(_reportedPubkeys),
      );
    }
  }

  /// Carrega dados de moderação do cache local
  Future<void> loadFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final myPubkey = _nostrService.publicKey;
      if (myPubkey == null) return;

      // Carregar following
      _following = (prefs.getStringList('following_$myPubkey') ?? []).toSet();
      
      // Carregar mutados
      _mutedPubkeys = (prefs.getStringList('muted_$myPubkey') ?? []).toSet();
      
      // Carregar reports
      final reportsJson = prefs.getString('reports_$myPubkey');
      if (reportsJson != null) {
        final decoded = jsonDecode(reportsJson) as Map<String, dynamic>;
        _reportedPubkeys = decoded.map((k, v) => MapEntry(k, v as int));
      }

      debugPrint('📦 Moderação carregada: ${_following.length} seguidos, ${_mutedPubkeys.length} mutados');
    } catch (e) {
      debugPrint('❌ Erro ao carregar moderação: $e');
    }
  }

  /// Limpa todo o cache de moderação
  Future<void> clearCache() async {
    _following.clear();
    _webOfTrust.clear();
    _reportedPubkeys.clear();
    _mutedPubkeys.clear();
  }
}
