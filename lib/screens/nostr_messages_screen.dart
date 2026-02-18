import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/storage_service.dart';

class NostrMessagesScreen extends StatefulWidget {
  const NostrMessagesScreen({Key? key}) : super(key: key);

  @override
  State<NostrMessagesScreen> createState() => _NostrMessagesScreenState();
}

class _NostrMessagesScreenState extends State<NostrMessagesScreen> {
  final _storage = StorageService();
  final _messageController = TextEditingController();
  final _recipientController = TextEditingController();
  
  String? _myPublicKey;
  List<Map<String, dynamic>> _conversations = [];
  Map<String, dynamic>? _selectedConversation;
  List<Map<String, dynamic>> _messages = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _messageController.dispose();
    _recipientController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    final publicKey = await _storage.getNostrPublicKey();
    setState(() {
      _myPublicKey = publicKey;
      _isLoading = false;
      // Mock conversations for demo
      _conversations = [
        {
          'id': '1',
          'name': 'Suporte Bro',
          'pubkey': 'npub1support...',
          'lastMessage': 'Como posso ajudar?',
          'timestamp': DateTime.now().subtract(const Duration(minutes: 5)),
          'unread': 1,
        },
        {
          'id': '2', 
          'name': 'Provedor #42',
          'pubkey': 'npub1prov42...',
          'lastMessage': 'Pagamento confirmado ?',
          'timestamp': DateTime.now().subtract(const Duration(hours: 2)),
          'unread': 0,
        },
      ];
    });
  }

  void _selectConversation(Map<String, dynamic> conversation) {
    setState(() {
      _selectedConversation = conversation;
      // Mock messages
      _messages = [
        {
          'id': '1',
          'content': 'Ol�! Preciso de ajuda com um pagamento.',
          'sender': _myPublicKey,
          'timestamp': DateTime.now().subtract(const Duration(minutes: 10)),
        },
        {
          'id': '2',
          'content': 'Claro! Qual � o problema?',
          'sender': conversation['pubkey'],
          'timestamp': DateTime.now().subtract(const Duration(minutes: 8)),
        },
        {
          'id': '3',
          'content': 'Como posso ajudar?',
          'sender': conversation['pubkey'],
          'timestamp': DateTime.now().subtract(const Duration(minutes: 5)),
        },
      ];
    });
  }

  void _sendMessage() {
    if (_messageController.text.trim().isEmpty) return;
    
    setState(() {
      _messages.add({
        'id': DateTime.now().millisecondsSinceEpoch.toString(),
        'content': _messageController.text.trim(),
        'sender': _myPublicKey,
        'timestamp': DateTime.now(),
      });
    });
    
    _messageController.clear();
    
    // TODO: Implementar envio real via Nostr NIP-04 (DMs criptografadas)
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('?? Mensagem enviada (demo)'),
        backgroundColor: Color(0xFF9C27B0),
        duration: Duration(seconds: 1),
      ),
    );
  }

  void _startNewConversation() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Nova Conversa',
          style: TextStyle(color: Colors.white),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _recipientController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: 'npub ou hex do destinat�rio',
                labelStyle: const TextStyle(color: Color(0x99FFFFFF)),
                prefixIcon: const Icon(Icons.person_outline, color: Color(0xFF9C27B0)),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0x33FFFFFF)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFF9C27B0)),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              '?? Cole a chave p�blica Nostr (npub...) da pessoa com quem deseja conversar',
              style: TextStyle(color: Color(0x99FFFFFF), fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () {
              if (_recipientController.text.trim().isNotEmpty) {
                Navigator.pop(context);
                setState(() {
                  _conversations.insert(0, {
                    'id': DateTime.now().millisecondsSinceEpoch.toString(),
                    'name': 'Novo contato',
                    'pubkey': _recipientController.text.trim(),
                    'lastMessage': '',
                    'timestamp': DateTime.now(),
                    'unread': 0,
                  });
                });
                _recipientController.clear();
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF9C27B0),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Iniciar', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xF70A0A0A),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () {
            if (_selectedConversation != null) {
              setState(() => _selectedConversation = null);
            } else {
              Navigator.pop(context);
            }
          },
        ),
        title: Text(
          _selectedConversation != null 
            ? _selectedConversation!['name'] 
            : 'Mensagens Nostr',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          if (_selectedConversation != null)
            IconButton(
              icon: const Icon(Icons.info_outline, color: Colors.white70),
              onPressed: () {
                // Mostrar info do contato
                _showContactInfo();
              },
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(
            color: const Color(0x33FF6B35),
            height: 1,
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF9C27B0)))
          : _selectedConversation != null
              ? _buildChatView()
              : _buildConversationsList(),
      floatingActionButton: _selectedConversation == null
          ? FloatingActionButton(
              onPressed: _startNewConversation,
              backgroundColor: const Color(0xFF9C27B0),
              child: const Icon(Icons.edit, color: Colors.white),
            )
          : null,
    );
  }

  Widget _buildConversationsList() {
    if (_conversations.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0x1A9C27B0),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.chat_bubble_outline,
                size: 64,
                color: Color(0xFF9C27B0),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Nenhuma conversa ainda',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Inicie uma conversa privada via Nostr',
              style: TextStyle(color: Color(0x99FFFFFF)),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _startNewConversation,
              icon: const Icon(Icons.add, color: Colors.white),
              label: const Text('Nova Conversa', style: TextStyle(color: Colors.white)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF9C27B0),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _conversations.length,
      itemBuilder: (context, index) {
        final conv = _conversations[index];
        return _buildConversationTile(conv);
      },
    );
  }

  Widget _buildConversationTile(Map<String, dynamic> conversation) {
    final hasUnread = (conversation['unread'] ?? 0) > 0;
    
    return GestureDetector(
      onTap: () => _selectConversation(conversation),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0x0DFFFFFF),
          border: Border.all(
            color: hasUnread ? const Color(0xFF9C27B0) : const Color(0x33FFFFFF),
            width: hasUnread ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF9C27B0), Color(0xFFBA68C8)],
                ),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  conversation['name'][0].toUpperCase(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          conversation['name'],
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: hasUnread ? FontWeight.w700 : FontWeight.w500,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        _formatTime(conversation['timestamp']),
                        style: TextStyle(
                          color: hasUnread ? const Color(0xFF9C27B0) : const Color(0x99FFFFFF),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          conversation['lastMessage'] ?? '',
                          style: TextStyle(
                            color: hasUnread ? Colors.white70 : const Color(0x99FFFFFF),
                            fontSize: 14,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (hasUnread)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF9C27B0),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${conversation['unread']}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChatView() {
    return Column(
      children: [
        // Info banner
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: const Color(0x1A9C27B0),
          child: Row(
            children: const [
              Icon(Icons.lock_outline, color: Color(0xFF9C27B0), size: 16),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Mensagens criptografadas via NIP-04',
                  style: TextStyle(color: Color(0xB3FFFFFF), fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        
        // Messages list
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            reverse: true,
            itemCount: _messages.length,
            itemBuilder: (context, index) {
              final message = _messages[_messages.length - 1 - index];
              final isMe = message['sender'] == _myPublicKey;
              return _buildMessageBubble(message, isMe);
            },
          ),
        ),
        
        // Input field
        Container(
          padding: const EdgeInsets.all(16),
          decoration: const BoxDecoration(
            color: Color(0xFF1A1A1A),
            border: Border(top: BorderSide(color: Color(0x33FFFFFF))),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _messageController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Digite sua mensagem...',
                    hintStyle: const TextStyle(color: Color(0x66FFFFFF)),
                    filled: true,
                    fillColor: const Color(0x0DFFFFFF),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: _sendMessage,
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Color(0xFF9C27B0), Color(0xFFBA68C8)],
                    ),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.send, color: Colors.white, size: 20),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMessageBubble(Map<String, dynamic> message, bool isMe) {
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: isMe ? const Color(0xFF9C27B0) : const Color(0x1AFFFFFF),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isMe ? 16 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              message['content'],
              style: const TextStyle(color: Colors.white, fontSize: 15),
            ),
            const SizedBox(height: 4),
            Text(
              _formatTime(message['timestamp']),
              style: TextStyle(
                color: isMe ? const Color(0xB3FFFFFF) : const Color(0x66FFFFFF),
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showContactInfo() {
    if (_selectedConversation == null) return;
    
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF9C27B0), Color(0xFFBA68C8)],
                ),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  _selectedConversation!['name'][0].toUpperCase(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _selectedConversation!['name'],
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: _selectedConversation!['pubkey']));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('?? Chave p�blica copiada'),
                    backgroundColor: Color(0xFF9C27B0),
                  ),
                );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0x0DFFFFFF),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _selectedConversation!['pubkey'],
                      style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 12),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.copy, color: Color(0x99FFFFFF), size: 14),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildContactAction(Icons.payments, 'Enviar Sats', () {
                  Navigator.pop(context);
                  // TODO: Navegar para tela de pagamento
                }),
                _buildContactAction(Icons.qr_code, 'Ver QR', () {
                  Navigator.pop(context);
                  // TODO: Mostrar QR code
                }),
                _buildContactAction(Icons.block, 'Bloquear', () {
                  Navigator.pop(context);
                  // TODO: Bloquear contato
                }),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildContactAction(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0x0DFFFFFF),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: const Color(0xFF9C27B0), size: 24),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 12),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime? time) {
    if (time == null) return '';
    final now = DateTime.now();
    final diff = now.difference(time);
    
    if (diff.inMinutes < 1) return 'agora';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${time.day}/${time.month}';
  }
}
