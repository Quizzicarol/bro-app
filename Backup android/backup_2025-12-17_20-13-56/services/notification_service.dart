import 'package:flutter/material.dart' show Color;
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Servico de notificacoes locais para alertar o usuario sobre eventos importantes
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
  bool _isInitialized = false;

  /// Inicializa o servico de notificacoes
  Future<void> initialize() async {
    if (_isInitialized) return;

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _notifications.initialize(
      settings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );
    
    _isInitialized = true;
    debugPrint('? NotificationService inicializado');
  }

  void _onNotificationTapped(NotificationResponse response) {
    debugPrint('?? Notificacao clicada: ${response.payload}');
    // Aqui pode navegar para tela especifica baseado no payload
  }

  /// Notifica que uma ordem foi aceita por um Bro
  Future<void> notifyOrderAccepted({
    required String orderId,
    required String broName,
  }) async {
    await _showNotification(
      id: orderId.hashCode,
      title: '? Bro Encontrado!',
      body: '$broName aceitou sua ordem. Aguarde o pagamento.',
      payload: 'order_accepted:$orderId',
    );
  }

  /// Notifica que o pagamento foi realizado e precisa confirmar
  Future<void> notifyPaymentReceived({
    required String orderId,
    required double amount,
  }) async {
    await _showNotification(
      id: orderId.hashCode + 1,
      title: '?? Comprovante Recebido!',
      body: 'Verifique o comprovante de R\$ ${amount.toStringAsFixed(2)} e confirme.',
      payload: 'payment_received:$orderId',
      importance: Importance.high,
    );
  }

  /// Notifica que e necessario confirmar o pagamento
  Future<void> notifyConfirmationRequired({
    required String orderId,
    required int hoursRemaining,
  }) async {
    await _showNotification(
      id: orderId.hashCode + 2,
      title: '?? Confirme o Pagamento',
      body: 'Voce tem $hoursRemaining horas para confirmar. Apos isso, Bitcoin sera liberado para o Bro.',
      payload: 'confirm_required:$orderId',
      importance: Importance.max,
    );
  }

  /// Notifica que ordem foi concluida com sucesso
  Future<void> notifyOrderCompleted({
    required String orderId,
    required double amount,
  }) async {
    await _showNotification(
      id: orderId.hashCode + 3,
      title: '? Troca Concluida!',
      body: 'Sua conta de R\$ ${amount.toStringAsFixed(2)} foi paga com sucesso.',
      payload: 'order_completed:$orderId',
    );
  }

  /// Notifica sobre disputa aberta
  Future<void> notifyDisputeOpened({
    required String orderId,
  }) async {
    await _showNotification(
      id: orderId.hashCode + 4,
      title: '?? Disputa Aberta',
      body: 'Uma disputa foi aberta para sua ordem. Acompanhe o status.',
      payload: 'dispute_opened:$orderId',
      importance: Importance.high,
    );
  }

  /// Notifica sobre nova mensagem Nostr
  Future<void> notifyNewMessage({
    required String senderName,
    required String preview,
  }) async {
    await _showNotification(
      id: DateTime.now().millisecondsSinceEpoch,
      title: '?? Nova Mensagem',
      body: '$senderName: $preview',
      payload: 'new_message:$senderName',
    );
  }

  /// Metodo generico para mostrar notificacao
  Future<void> _showNotification({
    required int id,
    required String title,
    required String body,
    String? payload,
    Importance importance = Importance.defaultImportance,
  }) async {
    if (!_isInitialized) await initialize();

    final androidDetails = AndroidNotificationDetails(
      'bro_app_channel',
      'Bro App',
      channelDescription: 'Notificacoes do Bro App',
      importance: importance,
      priority: importance == Importance.max ? Priority.max : Priority.defaultPriority,
      icon: '@mipmap/ic_launcher',
      color: Color(0xFFFF6B6B),
    );

    final iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _notifications.show(id, title, body, details, payload: payload);
    debugPrint('?? Notificacao enviada: $title');
  }

  /// Cancela uma notificacao especifica
  Future<void> cancelNotification(int id) async {
    await _notifications.cancel(id);
  }

  /// Cancela todas as notificacoes
  Future<void> cancelAll() async {
    await _notifications.cancelAll();
  }
}
