import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/nostr_service.dart';

/// Tela de chat P2P via Nostr DM
/// Por enquanto usa mensagens simples - futuramente implementar NIP-04 completo
class MarketplaceChatScreen extends StatefulWidget {
  final String recipientPubkey;
  final String recipientName;
  final String? offerTitle;

  const MarketplaceChatScreen({
    super.key,
    required this.recipientPubkey,
    required this.recipientName,
    this.offerTitle,
  });

  @override
  State<MarketplaceChatScreen> createState() => _MarketplaceChatScreenState();
}

class _MarketplaceChatScreenState extends State<MarketplaceChatScreen> {
  final NostrService _nostrService = NostrService();
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<ChatMessage> _messages = [];
  bool _isLoading = false;
  bool _isSending = false;

  @override
  void initState() {
    super.initState();
    
    // Mostrar guia de boas práticas na primeira vez
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showBestPracticesGuide();
    });
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _showBestPracticesGuide() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Row(
          children: [
            Icon(Icons.security, color: Colors.orange),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Negociação Segura',
                style: TextStyle(color: Colors.white, fontSize: 18),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildGuideItem(
                '🔒',
                'Escrow quando possível',
                'Use o sistema de escrow do Bro para pagamentos de contas.',
              ),
              _buildGuideItem(
                '⚡',
                'Prefira Lightning',
                'Pagamentos Lightning são instantâneos e irreversíveis.',
              ),
              _buildGuideItem(
                '🔍',
                'Verifique reputação',
                'Cheque referências e histórico do vendedor.',
              ),
              _buildGuideItem(
                '💬',
                'Documente tudo',
                'Mantenha prints das conversas e comprovantes.',
              ),
              _buildGuideItem(
                '⚠️',
                'Valores pequenos primeiro',
                'Comece com transações menores para testar.',
              ),
              _buildGuideItem(
                '🚫',
                'Nunca compartilhe',
                'Sua seed phrase, chave privada ou senhas.',
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.withOpacity(0.3)),
                ),
                child: const Text(
                  '⚠️ O Bro não é responsável por negociações P2P fora do escrow. Negocie por sua conta e risco.',
                  style: TextStyle(color: Colors.orange, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Entendi'),
          ),
        ],
      ),
    );
  }

  Widget _buildGuideItem(String emoji, String title, String description) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 20)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                Text(
                  description,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _isSending) return;
    
    setState(() => _isSending = true);
    
    try {
      // Adicionar mensagem localmente
      setState(() {
        _messages.add(ChatMessage(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          content: text,
          isFromMe: true,
          timestamp: DateTime.now(),
        ));
      });
      
      _messageController.clear();
      _scrollToBottom();
      
      // TODO: Implementar envio real via Nostr DM (NIP-04)
      // Por enquanto só mostra a mensagem localmente
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('💬 Mensagem salva localmente. DM Nostr em desenvolvimento.'),
            backgroundColor: Colors.blue,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _copyPubkey() {
    Clipboard.setData(ClipboardData(text: widget.recipientPubkey));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Pubkey copiada! Use um cliente Nostr para enviar DM.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.recipientName, style: const TextStyle(fontSize: 16)),
            if (widget.offerTitle != null)
              Text(
                widget.offerTitle!,
                style: const TextStyle(fontSize: 12, color: Colors.white54),
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: _copyPubkey,
            tooltip: 'Copiar Pubkey',
          ),
          IconButton(
            icon: const Icon(Icons.security),
            onPressed: _showBestPracticesGuide,
            tooltip: 'Dicas de Segurança',
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Info banner
            Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, color: Colors.blue, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Chat em desenvolvimento',
                          style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold, fontSize: 12),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Por enquanto, copie a pubkey e use Damus, Amethyst ou Primal para DM.',
                          style: TextStyle(color: Colors.blue.withOpacity(0.8), fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: _copyPubkey,
                    child: const Text('Copiar', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
            
            // Lista de mensagens
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator(color: Colors.orange))
                  : _messages.isEmpty
                      ? _buildEmptyChat()
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.all(16),
                          itemCount: _messages.length,
                          itemBuilder: (context, index) => _buildMessageBubble(_messages[index]),
                        ),
            ),
            
            // Campo de mensagem
            Container(
              padding: const EdgeInsets.all(12),
              decoration: const BoxDecoration(
                color: Color(0xFF1E1E1E),
                border: Border(top: BorderSide(color: Colors.white12)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'Digite sua mensagem...',
                        hintStyle: const TextStyle(color: Colors.white38),
                        filled: true,
                        fillColor: const Color(0xFF2E2E2E),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      ),
                      maxLines: null,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    decoration: const BoxDecoration(
                      color: Colors.orange,
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      icon: _isSending
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                          : const Icon(Icons.send, color: Colors.white),
                      onPressed: _isSending ? null : _sendMessage,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyChat() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.chat_bubble_outline, size: 64, color: Colors.white24),
            const SizedBox(height: 16),
            const Text(
              'Iniciar conversa',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Entre em contato com ${widget.recipientName}',
              style: const TextStyle(color: Colors.white54),
              textAlign: TextAlign.center,
            ),
            if (widget.offerTitle != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '💡 Sobre: "${widget.offerTitle}"',
                  style: const TextStyle(color: Colors.orange, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _copyPubkey,
              icon: const Icon(Icons.copy),
              label: const Text('Copiar Pubkey para DM'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage message) {
    return Align(
      alignment: message.isFromMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color: message.isFromMe ? Colors.orange : const Color(0xFF2E2E2E),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(message.isFromMe ? 16 : 4),
            bottomRight: Radius.circular(message.isFromMe ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              message.content,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _formatTime(message.timestamp),
              style: TextStyle(
                color: message.isFromMe ? Colors.white70 : Colors.white38,
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    
    if (diff.inDays > 0) {
      return '${time.day}/${time.month} ${time.hour}:${time.minute.toString().padLeft(2, '0')}';
    }
    return '${time.hour}:${time.minute.toString().padLeft(2, '0')}';
  }
}

class ChatMessage {
  final String id;
  final String content;
  final bool isFromMe;
  final DateTime timestamp;

  ChatMessage({
    required this.id,
    required this.content,
    required this.isFromMe,
    required this.timestamp,
  });
}
