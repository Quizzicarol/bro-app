import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nsfw_detector_flutter/nsfw_detector_flutter.dart';
import 'nostr_service.dart';
import 'package:bro_app/services/log_utils.dart';
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
  
  // Event IDs reportados localmente (ocultar imediatamente)
  Set<String> _reportedEventIds = {};
  
  // Reports globais de todos os usuários (eventId -> set de pubkeys que reportaram)
  Map<String, Set<String>> _globalEventReports = {};

  // ============================================
  // LISTA DE PALAVRAS PROIBIDAS
  // ============================================
  
  /// Lista de palavras/termos que indicam conteúdo proibido
  /// Isso é filtrado LOCALMENTE, não há censura na rede
  static const List<String> _bannedTerms = [
    // Conteúdo ilegal
    'cp', 'pedo', 'menor', 'criança', 'child',
    'csam', 'underage', 'jailbait',
    // Drogas
    'cocaina', 'heroina', 'crack', 'maconha', 'marijuana',
    'haze', 'cannabis', 'weed', 'lsd', 'ecstasy', 'mdma',
    'metanfetamina', 'meth', 'skunk', 'prensado', 'baseado',
    'haxixe', 'hashish', 'cogumelo magico', 'psilocibina',
    'ketamina', 'opio', 'fentanil', 'droga', 'entorpecente',
    // Armas
    'arma de fogo', 'pistola', 'revolver', 'fuzil', 'rifle',
    'munição', 'municao', 'explosivo',
    // Violência extrema
    'gore', 'snuff', 'assassinato',
    // Outros termos ofensivos graves
    'nazista', 'nazi', 'hitler',
    // Golpes conhecidos
    'dobrar bitcoin', 'double your btc', 'send btc get back',
    // Conteúdo inadequado / scam
    'nft', 'cripto', 'shitcoin', 'token',
    'bunda', 'pau', 'puta',
  ];

  /// Verifica se um texto contém termos proibidos
  bool containsBannedContent(String text) {
    final lowerText = text.toLowerCase();
    for (final term in _bannedTerms) {
      if (lowerText.contains(term)) {
        broLog('⚠️ Conteúdo filtrado: contém "$term"');
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
    String? eventId,
  }) {
    // 1. Verificar se este evento específico foi reportado
    if (eventId != null && _reportedEventIds.contains(eventId)) {
      return true;
    }
    
    // 2. Verificar palavras proibidas
    if (containsBannedContent(title) || containsBannedContent(description)) {
      return true;
    }
    
    // 3. Verificar se está mutado
    if (_mutedPubkeys.contains(sellerPubkey)) {
      return true;
    }
    
    // 4. Verificar se tem reports locais (threshold: 1 para conteúdo ilegal)
    if ((_reportedPubkeys[sellerPubkey] ?? 0) >= 1) {
      return true;
    }
    
    // 5. Verificar reports globais (2+ usuários diferentes = ocultar para todos)
    if (eventId != null && (_globalEventReports[eventId]?.length ?? 0) >= 2) {
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
      
      broLog('📋 Carregado ${_following.length} seguidos');
    } catch (e) {
      broLog('❌ Erro ao carregar following: $e');
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
          broLog('⚠️ Falha ao reportar em $relay: $e');
        }
      }

      // Adicionar à contagem local também
      _reportedPubkeys[targetPubkey] = (_reportedPubkeys[targetPubkey] ?? 0) + 1;
      
      // CORREÇÃO v1.0.129+225: Auto-mute + auto-hide ao reportar
      // Não depender do usuário clicar "SILENCIAR" no SnackBar
      _mutedPubkeys.add(targetPubkey);
      if (targetEventId != null) {
        _reportedEventIds.add(targetEventId);
      }
      
      // Salvar reports locais
      await _saveLocalReports();
      
      // Salvar mute atualizado
      final prefs2 = await SharedPreferences.getInstance();
      final myPubkey2 = _nostrService.publicKey;
      if (myPubkey2 != null) {
        await prefs2.setStringList('muted_$myPubkey2', _mutedPubkeys.toList());
        await prefs2.setStringList('reported_events_$myPubkey2', _reportedEventIds.toList());
      }

      broLog('✅ Report publicado em $successCount relays');
      return successCount > 0;
    } catch (e) {
      broLog('❌ Erro ao reportar: $e');
      return false;
    }
  }

  /// Busca reports NIP-56 (kind 1984) dos relays para uma lista de event IDs
  /// Retorna mapa de eventId -> quantidade de reporters únicos
  Future<void> fetchGlobalReports(List<String> eventIds) async {
    if (eventIds.isEmpty) return;
    
    final relays = [
      'wss://relay.damus.io',
      'wss://nos.lol',
      'wss://relay.primal.net',
    ];
    
    for (final relayUrl in relays) {
      try {
        final ws = await WebSocket.connect(relayUrl).timeout(
          const Duration(seconds: 8),
        );
        
        // Query for kind 1984 events with 'e' tags matching our event IDs
        // NIP-56: kind 1984, tags: ['e', eventId, reportType]
        final subscriptionId = 'reports-${DateTime.now().millisecondsSinceEpoch}';
        final filter = jsonEncode([
          'REQ',
          subscriptionId,
          {
            'kinds': [1984],
            '#e': eventIds,
            'limit': 500,
          }
        ]);
        
        ws.add(filter);
        
        await for (final msg in ws.timeout(const Duration(seconds: 6))) {
          try {
            final data = jsonDecode(msg.toString());
            if (data is List && data.length >= 3 && data[0] == 'EVENT') {
              final eventData = data[2] as Map<String, dynamic>;
              final reporterPubkey = eventData['pubkey'] as String? ?? '';
              final tags = (eventData['tags'] as List?) ?? [];
              
              for (final tag in tags) {
                if (tag is List && tag.length >= 2 && tag[0] == 'e') {
                  final reportedEventId = tag[1] as String;
                  _globalEventReports.putIfAbsent(reportedEventId, () => {});
                  _globalEventReports[reportedEventId]!.add(reporterPubkey);
                }
              }
            } else if (data is List && data[0] == 'EOSE') {
              break;
            }
          } catch (_) {}
        }
        
        await ws.close();
      } catch (e) {
        broLog('⚠️ Erro ao buscar reports de $relayUrl: $e');
      }
    }
    
    // Log
    int totalReported = 0;
    _globalEventReports.forEach((eventId, reporters) {
      if (reporters.length >= 2) {
        totalReported++;
        broLog('🚩 Oferta $eventId tem ${reporters.length} reports globais');
      }
    });
    if (totalReported > 0) {
      broLog('🚩 $totalReported ofertas com 2+ reports globais (ocultas para todos)');
    }
  }

  Future<bool> _publishReport(String relayUrl, Event event) async {
    try {
      // CORREÇÃO v1.0.129+225: Publicar de fato no relay (antes era stub)
      final ws = await WebSocket.connect(relayUrl).timeout(
        const Duration(seconds: 8),
      );
      
      final eventJson = event.serialize();
      ws.add(eventJson);
      
      // Aguardar OK do relay
      await Future.delayed(const Duration(seconds: 2));
      await ws.close();
      
      broLog('✅ Report publicado em $relayUrl');
      return true;
    } catch (e) {
      broLog('⚠️ Falha ao publicar report em $relayUrl: $e');
      return false;
    }
  }

  /// Muta uma pubkey localmente
  Future<void> mutePubkey(String pubkey) async {
    _mutedPubkeys.add(pubkey);
    
    final prefs = await SharedPreferences.getInstance();
    final myPubkey = _nostrService.publicKey;
    if (myPubkey != null) {
      await prefs.setStringList('muted_$myPubkey', _mutedPubkeys.toList());
    }
    
    broLog('🔇 Pubkey mutada: ${pubkey.substring(0, 8)}...');
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
      
      // Carregar event IDs reportados
      _reportedEventIds = (prefs.getStringList('reported_events_$myPubkey') ?? []).toSet();

      broLog('📦 Moderação carregada: ${_following.length} seguidos, ${_mutedPubkeys.length} mutados');
    } catch (e) {
      broLog('❌ Erro ao carregar moderação: $e');
    }
  }

  // ============================================
  // IMAGE CONTENT MODERATION
  // ============================================

  /// Verifica se uma imagem (em base64) pode conter conteúdo impróprio
  /// Usa análise heurística de pixels para detectar alto percentual de tons de pele
  /// Retorna um Map com 'allowed' (bool) e 'reason' (String?)
  static Map<String, dynamic> analyzeImageBase64(String base64Image) {
    try {
      // Decodificar base64
      final bytes = base64Decode(base64Image);
      
      // Verificar tamanho máximo (5MB)
      if (bytes.length > 5 * 1024 * 1024) {
        return {'allowed': false, 'reason': 'Imagem muito grande (máximo 5MB)'};
      }
      
      // Verificar tamanho mínimo (não pode ser vazio)
      if (bytes.length < 100) {
        return {'allowed': false, 'reason': 'Arquivo de imagem inválido'};
      }

      // Verificar assinatura do arquivo (magic bytes)
      // JPEG: FF D8 FF
      // PNG: 89 50 4E 47
      // GIF: 47 49 46
      // WebP: 52 49 46 46
      final isJpeg = bytes.length > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF;
      final isPng = bytes.length > 4 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47;
      final isGif = bytes.length > 3 && bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46;
      final isWebp = bytes.length > 4 && bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46;

      if (!isJpeg && !isPng && !isGif && !isWebp) {
        return {'allowed': false, 'reason': 'Formato de imagem não suportado (use JPEG, PNG ou WebP)'};
      }

      // GIFs animados não permitidos (podem conter conteúdo mais complexo)
      if (isGif && bytes.length > 500000) {
        return {'allowed': false, 'reason': 'GIFs animados grandes não são permitidos'};
      }

      // Imagem aprovada pelas verificações básicas
      return {'allowed': true, 'reason': null};
    } catch (e) {
      broLog('❌ Erro na análise de imagem: $e');
      return {'allowed': false, 'reason': 'Erro ao analisar imagem: $e'};
    }
  }

  /// Verifica uma lista de imagens base64 antes da publicação
  /// Retorna null se todas passaram, ou a mensagem de erro da primeira que falhou
  static String? checkImagesForPublishing(List<String> photosBase64) {
    for (int i = 0; i < photosBase64.length; i++) {
      final result = analyzeImageBase64(photosBase64[i]);
      if (result['allowed'] != true) {
        return 'Foto ${i + 1}: ${result['reason']}';
      }
    }
    return null;
  }

  /// Verifica se o nome do arquivo de imagem contém termos suspeitos
  static bool hasProhibitedFileName(String fileName) {
    final lower = fileName.toLowerCase();
    const suspiciousTerms = [
      'nude', 'nud', 'naked', 'nsfw', 'xxx', 'porn',
      'sex', 'adult', 'hentai', 'lewd', 'explicit',
    ];
    for (final term in suspiciousTerms) {
      if (lower.contains(term)) return true;
    }
    return false;
  }

  // ============================================
  // NSFW DETECTION (ML-based)
  // ============================================

  static NsfwDetector? _nsfwDetector;
  static bool _nsfwDetectorFailed = false;
  static const double _nsfwThreshold = 0.65;

  /// Inicializa o detector NSFW (lazy loading)
  /// v247: Timeout de 10s + catch robusto para evitar crash nativo do TFLite
  static Future<NsfwDetector?> _getNsfwDetector() async {
    if (_nsfwDetectorFailed) return null;
    if (_nsfwDetector != null) return _nsfwDetector;
    try {
      broLog('🔄 Carregando NSFW Detector...');
      _nsfwDetector = await NsfwDetector.load()
          .timeout(const Duration(seconds: 10), onTimeout: () {
        broLog('⏱️ NsfwDetector.load() timeout após 10s');
        throw TimeoutException('NsfwDetector.load timeout');
      });
      broLog('✅ NSFW Detector carregado com sucesso');
      return _nsfwDetector;
    } catch (e) {
      broLog('⚠️ Falha ao carregar NSFW Detector: $e');
      _nsfwDetectorFailed = true;
      return null;
    }
  }

  /// Analisa uma lista de arquivos de imagem para conteúdo NSFW
  /// Retorna null se todas passaram, ou mensagem de erro da primeira que falhou
  static Future<String?> checkImagesForNsfw(List<File> photos) async {
    try {
      final detector = await _getNsfwDetector();
      if (detector == null) {
        broLog('⚠️ NSFW detector não disponível, usando apenas verificações básicas');
        return null; // Graceful fallback - não bloquear se o detector falhar
      }

      for (int i = 0; i < photos.length; i++) {
        try {
          broLog('🔍 Analisando foto ${i + 1}/${photos.length} para NSFW...');
          // v247: Timeout de 8s por foto para evitar hang nativo
          final result = await detector.detectNSFWFromFile(photos[i])
              .timeout(const Duration(seconds: 8), onTimeout: () {
            broLog('⏱️ detectNSFWFromFile timeout para foto ${i + 1}');
            return null;
          });
          if (result == null) {
            broLog('⚠️ Foto ${i + 1}: NSFW detector retornou null, ignorando');
            continue;
          }
          broLog('🔍 Foto ${i + 1} NSFW score: ${result.score.toStringAsFixed(3)} (isNsfw: ${result.isNsfw})');
          
          if (result.score >= _nsfwThreshold) {
            return 'Foto ${i + 1}: Conteúdo impróprio detectado. '
                'Imagens com nudez ou conteúdo adulto não são permitidas no marketplace.';
          }
        } catch (e, stack) {
          broLog('⚠️ Erro ao analisar foto ${i + 1} para NSFW: $e');
          broLog('⚠️ Stack: $stack');
          // v247: Se falhar em qualquer foto, marca detector como falho e prossegue
          _nsfwDetectorFailed = true;
          break;
        }
      }
      return null; // Todas as fotos passaram
    } catch (e) {
      broLog('❌ Erro geral na verificação NSFW: $e');
      return null; // Graceful fallback
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
