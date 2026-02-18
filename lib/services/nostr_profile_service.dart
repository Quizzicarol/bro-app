import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Modelo de perfil Nostr
class NostrProfile {
  final String pubkey;
  final String? name;
  final String? displayName;
  final String? picture;
  final String? about;
  final String? nip05;
  final String? banner;
  final String? lud16;

  NostrProfile({
    required this.pubkey,
    this.name,
    this.displayName,
    this.picture,
    this.about,
    this.nip05,
    this.banner,
    this.lud16,
  });

  factory NostrProfile.fromJson(String pubkey, Map<String, dynamic> json) {
    // Função helper para converter seguramente para String?
    String? safeString(dynamic value) {
      if (value == null) return null;
      if (value is String) return value.isEmpty ? null : value;
      return value.toString();
    }
    
    return NostrProfile(
      pubkey: pubkey,
      name: safeString(json['name']),
      displayName: safeString(json['display_name']) ?? safeString(json['displayName']),
      picture: safeString(json['picture']),
      about: safeString(json['about']),
      nip05: safeString(json['nip05']),
      banner: safeString(json['banner']),
      lud16: safeString(json['lud16']),
    );
  }

  /// Retorna o nome de exibicao preferencial
  String get preferredName {
    if (displayName != null && displayName!.isNotEmpty) return displayName!;
    if (name != null && name!.isNotEmpty) return name!;
    return pubkey.substring(0, 8) + '...';
  }
}

/// Servico para buscar perfis Nostr via relays
class NostrProfileService {
  static final NostrProfileService _instance = NostrProfileService._internal();
  factory NostrProfileService() => _instance;
  NostrProfileService._internal();

  // Cache de perfis
  final Map<String, NostrProfile> _profileCache = {};

  // Lista de relays populares
  static const List<String> defaultRelays = [
    'wss://relay.damus.io',
    'wss://relay.nostr.band',
    'wss://nos.lol',
    'wss://relay.snort.social',
    'wss://nostr.wine',
  ];

  /// Busca perfil Nostr pelo pubkey
  Future<NostrProfile?> fetchProfile(String pubkey, {List<String>? relays}) async {
    // Verificar cache primeiro
    if (_profileCache.containsKey(pubkey)) {
      debugPrint('Perfil Nostr encontrado no cache: ${_profileCache[pubkey]?.preferredName}');
      return _profileCache[pubkey];
    }

    final relayList = relays ?? defaultRelays;
    
    for (final relay in relayList) {
      try {
        final profile = await _fetchFromRelay(pubkey, relay);
        if (profile != null) {
          _profileCache[pubkey] = profile;
          debugPrint('Perfil Nostr encontrado: ${profile.preferredName}');
          return profile;
        }
      } catch (e) {
        debugPrint('Erro ao buscar perfil do relay $relay: $e');
      }
    }

    // Se nao encontrou, retorna perfil basico com pubkey
    return NostrProfile(pubkey: pubkey);
  }

  /// Busca perfil de um relay especifico
  Future<NostrProfile?> _fetchFromRelay(String pubkey, String relayUrl) async {
    WebSocketChannel? channel;
    
    try {
      channel = WebSocketChannel.connect(Uri.parse(relayUrl));
      
      // Subscription ID aleatorio
      final subId = 'profile_${DateTime.now().millisecondsSinceEpoch}';
      
      // Criar filtro para buscar evento kind:0 (metadata/profile)
      final filter = {
        'kinds': [0],
        'authors': [pubkey],
        'limit': 1,
      };
      
      // Enviar request REQ
      final reqMessage = jsonEncode(['REQ', subId, filter]);
      channel.sink.add(reqMessage);
      
      debugPrint('Buscando perfil Nostr no relay $relayUrl...');
      
      // Aguardar resposta com timeout
      final completer = Completer<NostrProfile?>();
      Timer? timeoutTimer;
      
      timeoutTimer = Timer(const Duration(seconds: 5), () {
        if (!completer.isCompleted) {
          completer.complete(null);
        }
      });
      
      channel.stream.listen(
        (message) {
          try {
            final data = jsonDecode(message as String) as List;
            
            if (data.isNotEmpty && data[0] == 'EVENT' && data.length >= 3) {
              final event = data[2] as Map<String, dynamic>;
              // Converter content para String de forma segura (pode ser bool em alguns relays!)
              final rawContent = event['content'];
              final content = rawContent is String ? rawContent : rawContent?.toString();
              
              if (content != null && content.isNotEmpty) {
                final profileData = jsonDecode(content) as Map<String, dynamic>;
                final profile = NostrProfile.fromJson(pubkey, profileData);
                
                timeoutTimer?.cancel();
                if (!completer.isCompleted) {
                  completer.complete(profile);
                }
              }
            } else if (data.isNotEmpty && data[0] == 'EOSE') {
              // End of stored events
              timeoutTimer?.cancel();
              if (!completer.isCompleted) {
                completer.complete(null);
              }
            }
          } catch (e) {
            debugPrint('Erro ao processar mensagem do relay: $e');
          }
        },
        onError: (error) {
          debugPrint('Erro no WebSocket: $error');
          timeoutTimer?.cancel();
          if (!completer.isCompleted) {
            completer.complete(null);
          }
        },
        onDone: () {
          timeoutTimer?.cancel();
          if (!completer.isCompleted) {
            completer.complete(null);
          }
        },
      );
      
      final result = await completer.future;
      
      // Fechar subscription
      final closeMessage = jsonEncode(['CLOSE', subId]);
      channel.sink.add(closeMessage);
      
      return result;
    } catch (e) {
      debugPrint('Erro ao conectar ao relay $relayUrl: $e');
      return null;
    } finally {
      await channel?.sink.close();
    }
  }

  /// Limpa o cache de perfis
  void clearCache() {
    _profileCache.clear();
  }

  /// Retorna perfil do cache se existir
  NostrProfile? getCachedProfile(String pubkey) {
    return _profileCache[pubkey];
  }
}
