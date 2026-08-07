import 'dart:async';
import 'package:flutter/material.dart';
import '../services/nostr_order_service.dart';
import '../l10n/app_localizations.dart';

/// v631: Chat de disputa visível às 3 partes (comprador, provedor, mediador).
/// Cada mensagem é cifrada par-a-par (NIP-44) para as outras duas partes.
/// Widget reutilizado nas telas do comprador, do provedor e do admin.
///
/// [recipientPubkeys] deve conter as pubkeys das OUTRAS duas partes (não a minha).
/// [myRole] identifica quem escreve: 'user' | 'provider' | 'admin'.
class DisputeChat extends StatefulWidget {
  final String orderId;
  final String myPrivateKey;
  final String myRole; // 'user' | 'provider' | 'admin'
  final List<String> recipientPubkeys; // as OUTRAS duas partes

  const DisputeChat({
    Key? key,
    required this.orderId,
    required this.myPrivateKey,
    required this.myRole,
    required this.recipientPubkeys,
  }) : super(key: key);

  @override
  State<DisputeChat> createState() => _DisputeChatState();
}

class _DisputeChatState extends State<DisputeChat> {
  final NostrOrderService _svc = NostrOrderService();
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<Map<String, dynamic>> _messages = [];
  bool _loading = true;
  bool _sending = false;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _load();
    // Auto-refresh periódico (sem botão manual de sync — regra do app).
    _pollTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _load(silent: true),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) setState(() => _loading = true);
    try {
      final msgs = await _svc.fetchDisputeChatMessages(
        widget.orderId,
        myPrivateKey: widget.myPrivateKey,
      );
      if (!mounted) return;
      final grew = msgs.length != _messages.length;
      setState(() {
        _messages = msgs;
        _loading = false;
      });
      if (grew) _scrollToEnd();
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;

    final t = AppLocalizations.of(context);
    final recipients =
        widget.recipientPubkeys.where((p) => p.trim().isNotEmpty).toList();
    if (recipients.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.t('dispute_chat_no_parties'))),
      );
      return;
    }

    setState(() => _sending = true);
    try {
      final ok = await _svc.publishDisputeChatMessage(
        privateKey: widget.myPrivateKey,
        orderId: widget.orderId,
        message: text,
        senderRole: widget.myRole,
        recipientPubkeys: recipients,
      );
      if (!mounted) return;
      if (ok) {
        _controller.clear();
        await _load(silent: true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.t('dispute_chat_send_failed'))),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _roleLabel(String role) {
    final t = AppLocalizations.of(context);
    switch (role) {
      case 'user':
        return t.t('dispute_chat_role_buyer');
      case 'provider':
        return t.t('dispute_chat_role_provider');
      case 'admin':
        return t.t('dispute_chat_role_mediator');
      default:
        return t.t('dispute_chat_role_participant');
    }
  }

  Color _roleColor(String role) {
    switch (role) {
      case 'user':
        return Colors.blue.shade600;
      case 'provider':
        return Colors.green.shade600;
      case 'admin':
        return Colors.deepPurple.shade400;
      default:
        return Colors.grey.shade600;
    }
  }

  String _formatTime(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      final two = (int n) => n.toString().padLeft(2, '0');
      return '${two(dt.day)}/${two(dt.month)} ${two(dt.hour)}:${two(dt.minute)}';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = AppLocalizations.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Cabeçalho
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
            child: Row(
              children: [
                const Icon(Icons.forum_outlined, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.t('dispute_chat_title'),
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      Text(
                        t.t('dispute_chat_subtitle'),
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_loading)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          // Lista de mensagens
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 80, maxHeight: 340),
            child: _messages.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Center(
                      child: Text(
                        _loading
                            ? t.t('dispute_chat_loading')
                            : t.t('dispute_chat_empty'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    itemCount: _messages.length,
                    itemBuilder: (context, i) => _bubble(_messages[i]),
                  ),
          ),
          const Divider(height: 1),
          // Campo de envio
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.newline,
                    decoration: InputDecoration(
                      hintText: t.t('dispute_chat_hint'),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                _sending
                    ? const Padding(
                        padding: EdgeInsets.all(10),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        icon: const Icon(Icons.send),
                        color: theme.colorScheme.primary,
                        onPressed: _send,
                      ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubble(Map<String, dynamic> m) {
    final isMine = m['isMine'] == true;
    final role = (m['senderRole'] as String?) ?? '';
    final roleColor = _roleColor(role);
    final text = (m['message'] as String?) ?? '';
    final time = _formatTime((m['sentAt'] as String?) ?? '');

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.72,
        ),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isMine
              ? roleColor.withValues(alpha: 0.15)
              : Colors.grey.withValues(alpha: 0.12),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(12),
            topRight: const Radius.circular(12),
            bottomLeft: Radius.circular(isMine ? 12 : 2),
            bottomRight: Radius.circular(isMine ? 2 : 12),
          ),
          border: Border.all(color: roleColor.withValues(alpha: 0.4)),
        ),
        child: Column(
          crossAxisAlignment:
              isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _roleLabel(role),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: roleColor,
              ),
            ),
            const SizedBox(height: 2),
            Text(text, style: const TextStyle(fontSize: 14)),
            if (time.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(
                time,
                style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
