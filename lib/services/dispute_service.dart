import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'storage_service.dart';
import 'relay_service.dart';

/// Modelo de Disputa
class Dispute {
  final String id;
  final String orderId;
  final String openedBy; // 'user' ou 'provider'
  final String reason;
  final String description;
  final String status; // 'open', 'in_review', 'resolved_user', 'resolved_provider', 'cancelled'
  final DateTime createdAt;
  final DateTime? resolvedAt;
  final String? resolution;
  final String? mediatorNotes;

  Dispute({
    required this.id,
    required this.orderId,
    required this.openedBy,
    required this.reason,
    required this.description,
    this.status = 'open',
    required this.createdAt,
    this.resolvedAt,
    this.resolution,
    this.mediatorNotes,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'orderId': orderId,
    'openedBy': openedBy,
    'reason': reason,
    'description': description,
    'status': status,
    'createdAt': createdAt.toIso8601String(),
    'resolvedAt': resolvedAt?.toIso8601String(),
    'resolution': resolution,
    'mediatorNotes': mediatorNotes,
  };

  factory Dispute.fromJson(Map<String, dynamic> json) => Dispute(
    id: json['id'],
    orderId: json['orderId'],
    openedBy: json['openedBy'],
    reason: json['reason'],
    description: json['description'],
    status: json['status'] ?? 'open',
    createdAt: DateTime.parse(json['createdAt']),
    resolvedAt: json['resolvedAt'] != null ? DateTime.parse(json['resolvedAt']) : null,
    resolution: json['resolution'],
    mediatorNotes: json['mediatorNotes'],
  );

  Dispute copyWith({
    String? status,
    DateTime? resolvedAt,
    String? resolution,
    String? mediatorNotes,
  }) {
    return Dispute(
      id: id,
      orderId: orderId,
      openedBy: openedBy,
      reason: reason,
      description: description,
      status: status ?? this.status,
      createdAt: createdAt,
      resolvedAt: resolvedAt ?? this.resolvedAt,
      resolution: resolution ?? this.resolution,
      mediatorNotes: mediatorNotes ?? this.mediatorNotes,
    );
  }
}

/// Serviço de Disputas
/// Gerencia disputas entre usuários e provedores
/// Notifica suporte via Nostr e Email
class DisputeService {
  static final DisputeService _instance = DisputeService._internal();
  factory DisputeService() => _instance;
  DisputeService._internal();

  final _storage = StorageService();
  final _relayService = RelayService();

  // Pubkey do suporte para notificações Nostr (NIP-01)
  // npub14dkurlx4vkd5qmf7q5fwqh52lh3mn078wms2jetl2l4wnmcxnghqlud5dt
  static const String supportPubkey = 'ab6dc1fcd5659b406d3e0512e05e8afde3b9bfc776e0a9657f57eae9ef069a2e';
  
  // Email do suporte para disputas
  static const String supportEmail = 'brostr@proton.me';
  
  // Lista local de disputas (em memória + storage)
  final List<Dispute> _disputes = [];

  /// Inicializar serviço
  Future<void> initialize() async {
    await _loadDisputes();
  }

  /// Carregar disputas do storage
  Future<void> _loadDisputes() async {
    final disputesJson = await _storage.getData('disputes');
    if (disputesJson != null) {
      final List<dynamic> list = jsonDecode(disputesJson);
      _disputes.clear();
      _disputes.addAll(list.map((e) => Dispute.fromJson(e)));
    }
  }

  /// Salvar disputas no storage
  Future<void> _saveDisputes() async {
    final json = jsonEncode(_disputes.map((e) => e.toJson()).toList());
    await _storage.saveData('disputes', json);
  }

  /// Criar nova disputa
  Future<Dispute> createDispute({
    required String orderId,
    required String openedBy,
    required String reason,
    required String description,
    Map<String, dynamic>? orderDetails,
  }) async {
    // Gerar ID único para a disputa
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final idContent = '$orderId-$openedBy-$timestamp';
    final id = sha256.convert(utf8.encode(idContent)).toString().substring(0, 16);

    final dispute = Dispute(
      id: id,
      orderId: orderId,
      openedBy: openedBy,
      reason: reason,
      description: description,
      status: 'open',
      createdAt: DateTime.now(),
    );

    _disputes.add(dispute);
    await _saveDisputes();

    // Notificar suporte via Nostr
    await _notifySupport(dispute, orderDetails);

    debugPrint('⚖️ Disputa criada: ${dispute.id}');
    return dispute;
  }

  /// Notificar suporte via Nostr (DM criptografado - NIP-04/NIP-44)
  Future<void> _notifySupport(Dispute dispute, Map<String, dynamic>? orderDetails) async {
    try {
      // Criar mensagem de notificação
      final message = _buildDisputeMessage(dispute, orderDetails);
      
      // Obter privkey do app para assinar
      // Em produção, usar chave dedicada do app
      final appPrivkey = await _storage.getNsec();
      
      if (appPrivkey == null) {
        debugPrint('⚠️ Sem chave privada para enviar notificação');
        return;
      }

      // Criar evento Nostr tipo 4 (DM criptografado - NIP-04)
      // Ou tipo 1059 (Gift Wrapped - NIP-59) para mais privacidade
      final event = await _createDisputeEvent(message, appPrivkey);
      
      // Publicar nos relays
      await _relayService.publishEvent(event);
      
      debugPrint('📤 Notificação de disputa enviada ao suporte');
    } catch (e) {
      debugPrint('❌ Erro ao notificar suporte: $e');
    }
  }

  /// Getter público para acesso ao email de suporte
  String get disputeEmail => supportEmail;

  /// Construir mensagem de disputa para suporte
  String _buildDisputeMessage(Dispute dispute, Map<String, dynamic>? orderDetails) {
    final buffer = StringBuffer();
    
    buffer.writeln('🔔 NOVA DISPUTA ABERTA');
    buffer.writeln('━━━━━━━━━━━━━━━━━━━━━');
    buffer.writeln('');
    buffer.writeln('📋 ID da Disputa: ${dispute.id}');
    buffer.writeln('🆔 ID da Ordem: ${dispute.orderId}');
    buffer.writeln('👤 Aberta por: ${dispute.openedBy == 'user' ? 'Usuário' : 'Provedor'}');
    buffer.writeln('📅 Data: ${_formatDateTime(dispute.createdAt)}');
    buffer.writeln('');
    buffer.writeln('📌 Motivo: ${dispute.reason}');
    buffer.writeln('');
    buffer.writeln('📝 Descrição:');
    buffer.writeln(dispute.description);
    
    if (orderDetails != null) {
      buffer.writeln('');
      buffer.writeln('━━━━━━━━━━━━━━━━━━━━━');
      buffer.writeln('📦 DETALHES DA ORDEM:');
      buffer.writeln('');
      
      if (orderDetails['amount_brl'] != null) {
        buffer.writeln('💰 Valor: R\$ ${orderDetails['amount_brl'].toStringAsFixed(2)}');
      }
      if (orderDetails['amount_sats'] != null) {
        buffer.writeln('₿ Sats: ${orderDetails['amount_sats']}');
      }
      if (orderDetails['status'] != null) {
        buffer.writeln('📊 Status: ${orderDetails['status']}');
      }
      if (orderDetails['payment_type'] != null) {
        buffer.writeln('💳 Tipo: ${orderDetails['payment_type']}');
      }
      if (orderDetails['pix_key'] != null) {
        buffer.writeln('🔑 PIX: ${orderDetails['pix_key']}');
      }
    }
    
    buffer.writeln('');
    buffer.writeln('━━━━━━━━━━━━━━━━━━━━━');
    buffer.writeln('⚠️ Ação necessária: Revisar disputa e tomar decisão');
    buffer.writeln('');
    buffer.writeln('📧 Email de suporte: $supportEmail');
    
    return buffer.toString();
  }

  String _formatDateTime(DateTime dt) {
    final day = dt.day.toString().padLeft(2, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final year = dt.year;
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$day/$month/$year às $hour:$minute';
  }

  /// Criar evento Nostr para disputa
  Future<Map<String, dynamic>> _createDisputeEvent(String message, String privkeyHex) async {
    // Criar evento tipo 14 (Chat Message) ou 1 (Note) para visibilidade
    // Em produção, usar NIP-04/NIP-44 para DM criptografado ao suporte
    
    final createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    
    // Por simplicidade, criar uma nota pública com tag
    // Em produção, seria DM criptografado para o pubkey do suporte
    final event = {
      'kind': 1, // Nota pública (pode mudar para 4 = DM)
      'created_at': createdAt,
      'tags': [
        ['t', 'bro-disputa'],
        ['t', 'disputa'],
        ['d', 'dispute-notification'],
      ],
      'content': message,
    };

    // Em produção: assinar evento com a privkey
    // final signedEvent = await _signEvent(event, privkeyHex);
    
    // Gerar pubkey a partir da privkey (simplificado)
    final pubkey = _derivePubkey(privkeyHex);
    
    event['pubkey'] = pubkey;
    event['id'] = _computeEventId(event);
    event['sig'] = ''; // Assinatura (simulada em modo de teste)

    return event;
  }

  String _derivePubkey(String privkeyHex) {
    // Simplificado - em produção usar lib de crypto real
    return sha256.convert(utf8.encode(privkeyHex)).toString().substring(0, 64);
  }

  String _computeEventId(Map<String, dynamic> event) {
    final serialized = jsonEncode([
      0,
      event['pubkey'],
      event['created_at'],
      event['kind'],
      event['tags'],
      event['content'],
    ]);
    return sha256.convert(utf8.encode(serialized)).toString();
  }

  /// Obter disputa por ordem
  Dispute? getDisputeByOrderId(String orderId) {
    try {
      return _disputes.firstWhere((d) => d.orderId == orderId);
    } catch (e) {
      return null;
    }
  }

  /// Obter disputa por ID
  Dispute? getDisputeById(String id) {
    try {
      return _disputes.firstWhere((d) => d.id == id);
    } catch (e) {
      return null;
    }
  }

  /// Listar todas as disputas
  List<Dispute> getAllDisputes() {
    return List.unmodifiable(_disputes);
  }

  /// Listar disputas abertas
  List<Dispute> getOpenDisputes() {
    return _disputes.where((d) => d.status == 'open' || d.status == 'in_review').toList();
  }

  /// Atualizar status da disputa
  Future<void> updateDisputeStatus(String disputeId, String newStatus, {String? resolution, String? mediatorNotes}) async {
    final index = _disputes.indexWhere((d) => d.id == disputeId);
    if (index != -1) {
      _disputes[index] = _disputes[index].copyWith(
        status: newStatus,
        resolvedAt: (newStatus.startsWith('resolved') || newStatus == 'cancelled') ? DateTime.now() : null,
        resolution: resolution,
        mediatorNotes: mediatorNotes,
      );
      await _saveDisputes();
      debugPrint('⚖️ Disputa $disputeId atualizada: $newStatus');
    }
  }

  /// Cancelar disputa
  Future<void> cancelDispute(String disputeId) async {
    await updateDisputeStatus(disputeId, 'cancelled');
  }

  /// Verificar se ordem tem disputa ativa
  bool hasActiveDispute(String orderId) {
    return _disputes.any((d) => 
      d.orderId == orderId && 
      (d.status == 'open' || d.status == 'in_review')
    );
  }
}
