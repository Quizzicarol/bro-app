import 'dart:convert';
import 'package:crypto/crypto.dart' as crypto;
import 'package:nostr/nostr.dart';
import 'log_utils.dart';
import 'storage_service.dart';

/// v747 (auditoria B3): assinatura NIP-98 reutilizável pra chamadas HTTP
/// fora do ApiService/BrixService (ex.: o canal billcode-fallback, que criava
/// um Dio "nu" sem auth — qualquer um podia ler/escrever blobs de billCode).
///
/// Mesmo formato do BrixService: header `Authorization: Nostr <base64(event)>`
/// kind 27235 com tags u/method (+ payload = sha256 do corpo quando houver).
/// O backend valida passivamente (req.verifiedPubkey) — rollout em 2 fases:
/// app assina já; backend passa a EXIGIR quando BILLCODE_FALLBACK_AUTH=required.
Future<Map<String, String>> nip98Headers({
  required String url,
  required String method,
  Object? body,
}) async {
  final headers = <String, String>{};
  try {
    final storage = StorageService();
    final privKey = await storage.getNostrPrivateKey();
    if (privKey == null || privKey.isEmpty) return headers;
    final tags = <List<String>>[
      ['u', url],
      ['method', method],
    ];
    if (body != null) {
      // DEVE bater com o que o Dio envia (jsonEncode do Map)
      final bodyJson = jsonEncode(body);
      tags.add(['payload', crypto.sha256.convert(utf8.encode(bodyJson)).toString()]);
    }
    final event = Event.from(
      kind: 27235,
      tags: tags,
      content: '',
      privkey: privKey,
    );
    final eventMap = {
      'id': event.id,
      'pubkey': event.pubkey,
      'created_at': event.createdAt,
      'kind': event.kind,
      'tags': event.tags,
      'content': event.content,
      'sig': event.sig,
    };
    headers['Authorization'] = 'Nostr ${base64Encode(utf8.encode(jsonEncode(eventMap)))}';
  } catch (e) {
    broLog('⚠️ nip98Headers: $e');
  }
  return headers;
}
