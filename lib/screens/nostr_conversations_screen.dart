import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/chat_service.dart';
import '../services/storage_service.dart';
import 'marketplace_chat_screen.dart';

/// Modelo para representar uma conversa
class ConversationInfo {
  final String pubkey;
  final String? displayName;
  final ChatMessage? lastMessage;
  final int unreadCount;
  
  ConversationInfo({
    required this.pubkey,
    this.displayName,
    this.lastMessage,
    this.unreadCount = 0,
  });
}

/// Tela de lista de conversas Nostr
class NostrConversationsScreen extends StatefulWidget {
  const NostrConversationsScreen({super.key});

  @override
  State<NostrConversationsScreen> createState() => _NostrConversationsScreenState();
}

class _NostrConversationsScreenState extends State<NostrConversationsScreen> {
  final ChatService _chatService = ChatService();
  final StorageService _storage = StorageService();
  
  List<ConversationInfo> _conversations = [];
  bool _isLoading = true;
  bool _isInitialized = false;
  
  @override
  void initState() {
    super.initState();
    _initializeChat();
  }

  Future<void> _initializeChat() async {
    try {
      setState(() => _isLoading = true);
      
      // Obter chaves Nostr
      final privateKey = await _storage.getData('nostr_private_key');
      final publicKey = await _storage.getData('nostr_public_key');
      
      if (privateKey == null || publicKey == null) {
        setState(() {
          _isLoading = false;
          _isInitialized = false;
        });
        return;
      }
      
      debugPrint('💬 Conversas: Inicializando chat com pubkey ${publicKey.substring(0, 8)}...');
      
      // Inicializar chat service
      await _chatService.initialize(privateKey, publicKey);
      
      setState(() {
        _isInitialized = true;
      });
      
      // Aguardar mais tempo para receber mensagens dos relays (aumentado de 2 para 4 segundos)
      debugPrint('💬 Conversas: Aguardando mensagens dos relays...');
      await Future.delayed(const Duration(seconds: 4));
      
      // Carregar conversas
      await _loadConversations();
      
    } catch (e) {
      debugPrint('❌ Erro ao inicializar chat: $e');
      setState(() {
        _isLoading = false;
        _isInitialized = false;
      });
    }
  }

  Future<void> _loadConversations() async {
    try {
      // Forçar refresh das mensagens dos relays
      await _chatService.refreshAllMessages();
      
      // Aguardar mais um pouco para receber respostas
      await Future.delayed(const Duration(seconds: 2));
      
      final pubkeys = _chatService.getConversations();
      final conversations = <ConversationInfo>[];
      
      debugPrint('💬 Conversas: ${pubkeys.length} conversas encontradas');
      debugPrint('💬 Conversas: ${_chatService.totalCachedMessages} mensagens no cache');
      
      for (final pubkey in pubkeys) {
        final messages = _chatService.getMessages(pubkey);
        final lastMessage = messages.isNotEmpty ? messages.last : null;
        
        debugPrint('   - ${pubkey.substring(0, 8)}...: ${messages.length} mensagens');
        
        // Tentar obter nome salvo
        final savedName = await _storage.getData('contact_name_$pubkey');
        
        conversations.add(ConversationInfo(
          pubkey: pubkey,
          displayName: savedName,
          lastMessage: lastMessage,
          unreadCount: 0, // TODO: implementar contagem de não lidos
        ));
      }
      
      // Ordenar por última mensagem
      conversations.sort((a, b) {
        if (a.lastMessage == null && b.lastMessage == null) return 0;
        if (a.lastMessage == null) return 1;
        if (b.lastMessage == null) return -1;
        return b.lastMessage!.timestamp.compareTo(a.lastMessage!.timestamp);
      });
      
      setState(() {
        _conversations = conversations;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('❌ Erro ao carregar conversas: $e');
      setState(() => _isLoading = false);
    }
  }

  String _formatPubkey(String pubkey) {
    if (pubkey.length < 16) return pubkey;
    return '${pubkey.substring(0, 8)}...${pubkey.substring(pubkey.length - 8)}';
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    
    if (diff.inDays > 7) {
      return '${time.day}/${time.month}/${time.year}';
    } else if (diff.inDays > 0) {
      return '${diff.inDays}d atrás';
    } else if (diff.inHours > 0) {
      return '${diff.inHours}h atrás';
    } else if (diff.inMinutes > 0) {
      return '${diff.inMinutes}m atrás';
    } else {
      return 'Agora';
    }
  }

  void _openChat(ConversationInfo conversation) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => MarketplaceChatScreen(
          sellerPubkey: conversation.pubkey,
          sellerName: conversation.displayName ?? _formatPubkey(conversation.pubkey),
        ),
      ),
    ).then((_) => _loadConversations());
  }

  void _copyPubkey(String pubkey) {
    Clipboard.setData(ClipboardData(text: pubkey));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Pubkey copiado!'),
        backgroundColor: Color(0xFF1E3A5F),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _renameContact(ConversationInfo conversation) async {
    final controller = TextEditingController(text: conversation.displayName ?? '');
    
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Renomear contato'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Nome do contato',
            hintText: 'Ex: João do P2P',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1E3A5F),
            ),
            child: const Text('Salvar', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    
    if (result != null && result.isNotEmpty) {
      await _storage.saveData('contact_name_${conversation.pubkey}', result);
      _loadConversations();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E3A5F),
        foregroundColor: Colors.white,
        title: const Text('Mensagens Nostr'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadConversations,
            tooltip: 'Atualizar',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Conectando aos relays...'),
                ],
              ),
            )
          : !_isInitialized
              ? _buildNotConfigured()
              : _conversations.isEmpty
                  ? _buildEmptyState()
                  : _buildConversationsList(),
    );
  }

  Widget _buildNotConfigured() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.vpn_key_off,
                size: 48,
                color: Colors.orange,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Identidade Nostr não configurada',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Acesse Configurações > Identidade Nostr para configurar suas chaves e poder enviar/receber mensagens criptografadas.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Voltar'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1E3A5F),
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFF1E3A5F).withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.chat_bubble_outline,
                size: 48,
                color: Color(0xFF1E3A5F),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Nenhuma conversa',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1E3A5F),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Suas conversas do marketplace P2P aparecerão aqui.\n\nInicie uma conversa acessando uma oferta e clicando em "Contatar vendedor".',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.blue.shade200),
              ),
              child: const Row(
                children: [
                  Icon(Icons.lock_outline, color: Color(0xFF1976D2)),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Todas as mensagens são criptografadas de ponta a ponta usando NIP-04',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFF1976D2),
                      ),
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

  Widget _buildConversationsList() {
    return RefreshIndicator(
      onRefresh: _loadConversations,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _conversations.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final conversation = _conversations[index];
          return _buildConversationTile(conversation);
        },
      ),
    );
  }

  Widget _buildConversationTile(ConversationInfo conversation) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: const Color(0xFF1E3A5F),
        child: Text(
          (conversation.displayName ?? 'N')[0].toUpperCase(),
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              conversation.displayName ?? _formatPubkey(conversation.pubkey),
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (conversation.lastMessage != null)
            Text(
              _formatTime(conversation.lastMessage!.timestamp),
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade600,
              ),
            ),
        ],
      ),
      subtitle: conversation.lastMessage != null
          ? Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  if (conversation.lastMessage!.isFromMe)
                    const Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: Icon(Icons.done_all, size: 14, color: Colors.grey),
                    ),
                  Expanded(
                    child: Text(
                      conversation.lastMessage!.content,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade700,
                      ),
                    ),
                  ),
                ],
              ),
            )
          : Text(
              'Clique para iniciar conversa',
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey.shade500,
                fontStyle: FontStyle.italic,
              ),
            ),
      trailing: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert, color: Colors.grey),
        onSelected: (value) {
          switch (value) {
            case 'copy':
              _copyPubkey(conversation.pubkey);
              break;
            case 'rename':
              _renameContact(conversation);
              break;
          }
        },
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: 'rename',
            child: Row(
              children: [
                Icon(Icons.edit, size: 20),
                SizedBox(width: 12),
                Text('Renomear'),
              ],
            ),
          ),
          const PopupMenuItem(
            value: 'copy',
            child: Row(
              children: [
                Icon(Icons.copy, size: 20),
                SizedBox(width: 12),
                Text('Copiar pubkey'),
              ],
            ),
          ),
        ],
      ),
      onTap: () => _openChat(conversation),
    );
  }
}
