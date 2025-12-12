import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:convert';
import 'dart:io';
import '../models/escrow_deposit.dart';
import '../services/order_chat_service.dart';
import '../services/storage_service.dart';

/// Modal de detalhes da ordem com chat provider-cliente
class OrderDetailsModal extends StatefulWidget {
  final Map<String, dynamic> order;
  final bool isProvider;

  const OrderDetailsModal({
    Key? key,
    required this.order,
    required this.isProvider,
  }) : super(key: key);

  @override
  State<OrderDetailsModal> createState() => _OrderDetailsModalState();
}

class _OrderDetailsModalState extends State<OrderDetailsModal> {
  final _chatService = OrderChatService.instance;
  final _storageService = StorageService();
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  
  List<OrderMessage> _messages = [];
  String? _userId;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    _userId = widget.isProvider 
        ? await _storageService.getProviderId()
        : await _storageService.getNostrPublicKey();

    // Carregar mensagens iniciais
    _messages = await _chatService.getMessages(widget.order['id']);

    // Subscrever ao stream de novas mensagens
    _chatService.messagesStream(widget.order['id']).listen((message) {
      if (mounted && !_messages.any((m) => m.id == message.id)) {
        setState(() {
          _messages.add(message);
        });
        _scrollToBottom();
      }
    });

    setState(() => _isLoading = false);
    _scrollToBottom();
  }

  @override
  void dispose() {
    _chatService.stopPolling(widget.order['id']);
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
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

  Future<void> _sendMessage() async {
    if (_messageController.text.trim().isEmpty) return;

    final message = _messageController.text.trim();
    _messageController.clear();

    final success = await _chatService.sendMessage(
      orderId: widget.order['id'],
      senderId: _userId!,
      senderType: widget.isProvider ? 'provider' : 'client',
      message: message,
    );

    if (success) {
      // Recarregar mensagens
      final messages = await _chatService.getMessages(widget.order['id']);
      setState(() => _messages = messages);
      _scrollToBottom();
    }
  }

  Future<void> _pickAndSendReceipt() async {
    final picker = ImagePicker();
    
    // Mostrar opções
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Enviar Comprovante'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt, color: Color(0xFFFF6B35)),
              title: const Text('Tirar Foto'),
              onTap: () => Navigator.pop(context, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library, color: Color(0xFFFF6B35)),
              title: const Text('Escolher da Galeria'),
              onTap: () => Navigator.pop(context, 'gallery'),
            ),
          ],
        ),
      ),
    );

    if (result == null) return;

    final source = result == 'camera' ? ImageSource.camera : ImageSource.gallery;
    final image = await picker.pickImage(source: source, imageQuality: 70);

    if (image == null) return;

    // Converter para base64
    final bytes = await File(image.path).readAsBytes();
    final base64Image = base64Encode(bytes);

    // Enviar
    final success = await _chatService.sendReceipt(
      orderId: widget.order['id'],
      providerId: _userId!,
      fileBase64: base64Image,
      fileType: 'image',
      message: 'Comprovante de pagamento',
    );

    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ Comprovante enviado'),
          backgroundColor: Color(0xFF4CAF50),
        ),
      );

      // Recarregar mensagens
      final messages = await _chatService.getMessages(widget.order['id']);
      setState(() => _messages = messages);
      _scrollToBottom();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(16),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF0A0A0A),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: const Color(0x33FF6B35),
            width: 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.max,
          children: [
            _buildHeader(),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : Column(
                      children: [
                        _buildOrderDetails(),
                        const Divider(color: Color(0x33FF6B35)),
                        Expanded(child: _buildChat()),
                        _buildChatInput(),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Color(0x33FF6B35)),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0x1AFF6B35),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.receipt_long, color: Color(0xFFFF6B35)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Ordem #${widget.order['id'].substring(0, 8)}',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  widget.order['barCode'] ?? 'Sem código',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0x99FFFFFF),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  Widget _buildOrderDetails() {
    final amount = widget.order['amount'] ?? 0.0;
    final fee = widget.order['fee'] ?? 0.0;
    final total = amount + fee;

    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // QR Code do código de barras (se provider)
          if (widget.isProvider && widget.order['barCode'] != null)
            Column(
              children: [
                QrImageView(
                  data: widget.order['barCode'],
                  version: QrVersions.auto,
                  size: 200,
                  backgroundColor: Colors.white,
                ),
                const SizedBox(height: 8),
                Text(
                  widget.order['barCode'],
                  style: const TextStyle(
                    fontSize: 10,
                    fontFamily: 'monospace',
                    color: Color(0x99FFFFFF),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),

          // Valores
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildValueItem('Valor', 'R\$ ${amount.toStringAsFixed(2)}'),
              _buildValueItem('Taxa', 'R\$ ${fee.toStringAsFixed(2)}'),
              _buildValueItem('Total', 'R\$ ${total.toStringAsFixed(2)}', highlight: true),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildValueItem(String label, String value, {bool highlight = false}) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            color: Color(0x99FFFFFF),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: highlight ? const Color(0xFFFF6B35) : Colors.white,
          ),
        ),
      ],
    );
  }

  Widget _buildChat() {
    return Container(
      color: const Color(0x0DFFFFFF),
      child: _messages.isEmpty
          ? const Center(
              child: Text(
                'Nenhuma mensagem ainda',
                style: TextStyle(color: Color(0x66FFFFFF)),
              ),
            )
          : ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final message = _messages[index];
                final isMe = message.senderId == _userId;

                return Align(
                  alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(12),
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.7,
                    ),
                    decoration: BoxDecoration(
                      color: isMe 
                          ? const Color(0xFFFF6B35) 
                          : const Color(0x1AFFFFFF),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (message.hasAttachment)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.network(
                                message.attachmentUrl!,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => 
                                    const Icon(Icons.broken_image),
                              ),
                            ),
                          ),
                        Text(
                          message.message,
                          style: TextStyle(
                            color: isMe ? Colors.white : const Color(0xFFFFFFFF),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _formatTime(message.timestamp),
                          style: TextStyle(
                            fontSize: 10,
                            color: isMe 
                                ? Colors.white70 
                                : const Color(0x99FFFFFF),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }

  Widget _buildChatInput() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: Color(0x33FF6B35)),
        ),
      ),
      child: Row(
        children: [
          // Botão de anexo (só para provider)
          if (widget.isProvider)
            IconButton(
              icon: const Icon(Icons.attach_file, color: Color(0xFFFF6B35)),
              onPressed: _pickAndSendReceipt,
            ),

          // Campo de texto
          Expanded(
            child: TextField(
              controller: _messageController,
              decoration: InputDecoration(
                hintText: 'Digite sua mensagem...',
                filled: true,
                fillColor: const Color(0x0DFFFFFF),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
              onSubmitted: (_) => _sendMessage(),
            ),
          ),

          const SizedBox(width: 8),

          // Botão enviar
          IconButton(
            icon: const Icon(Icons.send, color: Color(0xFFFF6B35)),
            onPressed: _sendMessage,
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inMinutes < 1) return 'agora';
    if (diff.inHours < 1) return '${diff.inMinutes}m';
    if (diff.inDays < 1) return '${diff.inHours}h';
    return '${diff.inDays}d';
  }
}
