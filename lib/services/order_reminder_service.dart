import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:bro_app/services/notification_service.dart';

/// Lembretes R3: provedor aos 20/40min para pagar e enviar comprovante em 1h.
/// Apos a prova, o comprador recebe os lembretes de confirmacao de 36h.
/// Cada lembrete eh disparado apenas UMA vez por ordem/milestone/cenario via
/// persistencia em SharedPreferences.
class OrderReminderService {
  static final OrderReminderService _instance = OrderReminderService._internal();
  factory OrderReminderService() => _instance;
  OrderReminderService._internal();

  static const String _sentKey = 'bro_reminders_sent';
  static const Duration _acceptDeadline = Duration(hours: 1);
  static const Duration _confirmationDeadline = Duration(hours: 36);
  static const List<int> _acceptMilestonesMin = [20, 40];
  static const List<int> _confirmationMilestonesH = [24, 30, 35];

  @visibleForTesting
  List<Map<String, String>> debugDueReminders({
    required Map<String, dynamic> order,
    required String currentPubkey,
    required DateTime now,
    Set<String> alreadySent = const {},
  }) => _computeDueReminders(
    order: order,
    currentPubkey: currentPubkey,
    now: now,
    alreadySent: alreadySent,
  ).map((r) => {
    'key': r.key,
    'role': r.targetRole,
    'title': _buildTitle(r),
    'body': _buildBody(r, order['id'].toString()),
  }).toList();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initDone = false;

  Future<void> _ensureInit() async {
    if (_initDone) return;
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      const InitializationSettings(android: androidSettings, iOS: iosSettings),
    );
    _initDone = true;
  }

  /// Checa todas as ordens e dispara lembretes pendentes.
  /// [orders] eh uma lista de mapas serializados (mesmo formato do storage).
  /// [currentPubkey] eh a pubkey do usuario atual (para filtrar papel).
  Future<int> checkAndNotify({
    required List<Map<String, dynamic>> orders,
    required String currentPubkey,
  }) async {
    if (currentPubkey.isEmpty) return 0;
    final prefs = await SharedPreferences.getInstance();
    final sentJson = prefs.getString(_sentKey) ?? '[]';
    final sent = Set<String>.from(jsonDecode(sentJson) as List);

    final now = DateTime.now();
    int shown = 0;

    for (final order in orders) {
      final reminders = _computeDueReminders(
        order: order,
        currentPubkey: currentPubkey,
        now: now,
        alreadySent: sent,
      );
      for (final r in reminders) {
        final ok = await _showReminder(r);
        if (ok) {
          sent.add(r.key);
          shown++;
        }
      }
    }

    if (shown > 0) {
      // Trim: mantem ultimos 500 para evitar crescimento indefinido
      final list = sent.toList();
      if (list.length > 500) list.removeRange(0, list.length - 500);
      await prefs.setString(_sentKey, jsonEncode(list));
      broLog('⏰ [Reminder] $shown lembrete(s) enviado(s)');
    }
    return shown;
  }

  List<_Reminder> _computeDueReminders({
    required Map<String, dynamic> order,
    required String currentPubkey,
    required DateTime now,
    required Set<String> alreadySent,
  }) {
    final result = <_Reminder>[];
    final orderId = order['id']?.toString() ?? '';
    if (orderId.isEmpty) return result;

    final status = order['status']?.toString() ?? '';
    final metadata = (order['metadata'] as Map?)?.cast<String, dynamic>() ?? {};

    // Pula ordens ja auto-liquidadas
    if (metadata['autoLiquidated'] == true) return result;

    final providerId = (order['providerId'] as String?) ??
        (metadata['providerId'] as String?) ??
        (metadata['provider_id'] as String?) ??
        '';
    final userPubkey = order['userPubkey'] as String? ?? '';

    String? scenario;
    String? anchorIso;
    String? targetRole; // 'provider' | 'user'

    if (status == 'accepted') {
      // Cenario A: provedor precisa pagar+subir comprovante
      anchorIso = (order['acceptedAt'] as String?) ??
          (metadata['acceptedAt'] as String?) ??
          (metadata['accepted_at'] as String?);
      scenario = 'A';
      targetRole = 'provider';
      if (providerId != currentPubkey) return result; // so notifica o provedor
    } else if (status == 'accept_expired') {
      anchorIso = (order['acceptedAt'] as String?) ??
          (metadata['acceptedAt'] as String?) ??
          (metadata['accepted_at'] as String?);
      scenario = 'E';
      targetRole = 'user';
      if (userPubkey != currentPubkey) return result;
    } else if (status == 'awaiting_confirmation') {
      // Cenario B: usuario precisa confirmar
      anchorIso = (metadata['receipt_submitted_at'] as String?) ??
          (metadata['proofReceivedAt'] as String?) ??
          (metadata['proofSentAt'] as String?);
      scenario = 'B';
      targetRole = 'user';
      if (userPubkey != currentPubkey) return result; // so notifica o criador
    } else {
      return result;
    }

    if (anchorIso == null || anchorIso.isEmpty) return result;

    DateTime anchor;
    try {
      anchor = DateTime.parse(anchorIso);
    } catch (_) {
      return result;
    }

    final elapsed = now.difference(anchor);
    if (scenario == 'A') {
      if (elapsed >= _acceptDeadline) return result;
      for (final minutes in _acceptMilestonesMin) {
        if (elapsed.inMinutes < minutes) continue;
        final key = '$orderId:A:${minutes}m';
        if (alreadySent.contains(key)) continue;
        result.add(_Reminder(
          key: key,
          orderId: orderId,
          scenario: 'A',
          milestoneMin: minutes,
          targetRole: targetRole,
        ));
      }
      return result;
    }

    if (scenario == 'E') {
      if (elapsed < _acceptDeadline) return result;
      final key = '$orderId:E:60m';
      if (alreadySent.contains(key)) return result;
      result.add(_Reminder(
        key: key,
        orderId: orderId,
        scenario: 'E',
        milestoneMin: 60,
        targetRole: targetRole,
      ));
      return result;
    }

    if (elapsed >= _confirmationDeadline) return result;
    for (final hours in _confirmationMilestonesH) {
      if (elapsed.inHours < hours) continue;
      final key = '$orderId:B:${hours}h';
      if (alreadySent.contains(key)) continue;
      result.add(_Reminder(
        key: key,
        orderId: orderId,
        scenario: 'B',
        milestoneMin: hours * 60,
        targetRole: targetRole,
      ));
    }
    return result;
  }

  Future<bool> _showReminder(_Reminder r) async {
    try {
      await _ensureInit();
      final shortId = r.orderId.length >= 8
          ? r.orderId.substring(0, 8)
          : r.orderId;
      final title = _buildTitle(r);
      final body = _buildBody(r, shortId);
      final payload = 'reminder:${r.scenario}:${r.milestoneMin}m:${r.orderId}';

      // Reusa o dedup global do NotificationService para que os papeis
      // (foreground/background) nao dupliquem a mesma notificacao.
      await NotificationService().showGeneric(
        title: title,
        body: body,
        dedupKey: payload,
      );
      broLog('⏰ [Reminder] $title — $body');
      return true;
    } catch (e) {
      broLog('❌ [Reminder] erro ao mostrar: $e');
      return false;
    }
  }

  String _buildTitle(_Reminder r) {
    if (r.scenario == 'E') return '⏰ Aceite expirado: republicar ou cancelar';
    if (r.scenario == 'A') {
      return r.milestoneMin == 20
          ? '⏰ Faltam 40min para pagar e enviar o comprovante'
          : '🚨 Faltam 20min para pagar e enviar o comprovante';
    }
    if (r.milestoneMin == 35 * 60) return '🚨 Prazo final em 1h!';
    if (r.milestoneMin == 30 * 60) return '⏳ Faltam 6h para confirmar';
    return '⏰ Faltam 12h para confirmar';
  }

  String _buildBody(_Reminder r, String shortId) {
    if (r.scenario == 'E') {
      return 'O Bro não pagou a ordem $shortId em 1 hora. Abra o app para republicar ou cancelar e sacar seus sats.';
    }
    if (r.scenario == 'A') {
      final minutesLeft = 60 - r.milestoneMin;
      return 'Código de pagamento da ordem $shortId disponível por mais ${minutesLeft} minutos para enviar o comprovante. Depois ele será bloqueado e a ordem poderá ser republicada.';
    }
    final hoursLeft = 36 - (r.milestoneMin ~/ 60);
    if (r.milestoneMin == 35 * 60) {
      return 'Confirme o comprovante da ordem $shortId em 1h ou ela sera auto-liquidada a favor do Bro.';
    }
    return 'Confirme o comprovante da ordem $shortId. Faltam ${hoursLeft}h.';
  }
}

class _Reminder {
  final String key;
  final String orderId;
  final String scenario;
  final int milestoneMin;
  final String targetRole;

  _Reminder({
    required this.key,
    required this.orderId,
    required this.scenario,
    required this.milestoneMin,
    required this.targetRole,
  });
}
