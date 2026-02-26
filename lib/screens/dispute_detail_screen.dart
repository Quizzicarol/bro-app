import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/order_provider.dart';
import '../services/nostr_order_service.dart';

/// Tela de detalhes de disputa para o mediador (admin)
/// Mostra TODOS os dados da disputa, comprovante, e controles de resolução
class DisputeDetailScreen extends StatefulWidget {
  final Map<String, dynamic> dispute;
  
  const DisputeDetailScreen({super.key, required this.dispute});
  
  @override
  State<DisputeDetailScreen> createState() => _DisputeDetailScreenState();
}

class _DisputeDetailScreenState extends State<DisputeDetailScreen> {
  bool _isLoading = false;
  bool _isResolved = false;
  String? _proofImageData;
  bool _proofEncrypted = false;
  bool _loadingProof = false;
  
  // Provider ID pode ser descoberto dinamicamente se não estiver nos dados da disputa
  String? _resolvedProviderId;
  
  // v235: Histórico de mensagens de mediação
  List<Map<String, dynamic>> _mediatorMessages = [];
  bool _loadingMessages = false;
  
  String get orderId => widget.dispute['orderId'] as String? ?? '';
  String get reason => widget.dispute['reason'] as String? ?? 'Não informado';
  String get description => widget.dispute['description'] as String? ?? '';
  String get openedBy => widget.dispute['openedBy'] as String? ?? 'user';
  String get userPubkey => widget.dispute['userPubkey'] as String? ?? '';
  String get providerId => _resolvedProviderId ?? (widget.dispute['provider_id'] as String? ?? '');
  String get previousStatus => widget.dispute['previous_status'] as String? ?? '';
  String get paymentType => widget.dispute['payment_type'] as String? ?? '';
  String get pixKey => widget.dispute['pix_key'] as String? ?? '';
  String get createdAtStr => widget.dispute['createdAt'] as String? ?? '';
  dynamic get amountBrl => widget.dispute['amount_brl'];
  dynamic get amountSats => widget.dispute['amount_sats'];
  
  @override
  void initState() {
    super.initState();
    _initData();
  }
  
  /// Inicializa dados: busca provedor (se necessário) e comprovante
  Future<void> _initData() async {
    // Se não temos o providerId, tentar descobrir pelo accept event
    final initialProviderId = widget.dispute['provider_id'] as String? ?? '';
    if (initialProviderId.isEmpty) {
      try {
        final nostrService = NostrOrderService();
        final foundProvider = await nostrService.fetchOrderProviderPubkey(orderId);
        if (foundProvider != null && mounted) {
          setState(() => _resolvedProviderId = foundProvider);
          debugPrint('✅ Provider descoberto para disputa: ${foundProvider.substring(0, 8)}');
        }
      } catch (e) {
        debugPrint('⚠️ Erro ao buscar provider: $e');
      }
    }
    _fetchProofImage();
    _fetchMediatorMessages();
  }
  
  /// Busca histórico de mensagens de mediação desta ordem
  Future<void> _fetchMediatorMessages() async {
    if (orderId.isEmpty) return;
    setState(() => _loadingMessages = true);
    
    try {
      final nostrService = NostrOrderService();
      final messages = await nostrService.fetchAllMediatorMessagesForOrder(orderId);
      
      if (mounted) {
        setState(() {
          _mediatorMessages = messages;
          _loadingMessages = false;
        });
      }
    } catch (e) {
      debugPrint('⚠️ Erro ao buscar mensagens: $e');
      if (mounted) setState(() => _loadingMessages = false);
    }
  }
  
  /// Busca o comprovante do provedor via Nostr
  /// Usa fetchProofForOrder que pesquisa kind 30081 e 30080 diretamente pelo orderId
  Future<void> _fetchProofImage() async {
    if (orderId.isEmpty) return;
    setState(() => _loadingProof = true);
    
    try {
      final nostrService = NostrOrderService();
      final result = await nostrService.fetchProofForOrder(
        orderId,
        providerPubkey: providerId.isNotEmpty ? providerId : null,
      );
      
      if (!mounted) return;
      
      final proof = result['proofImage'] as String?;
      final encrypted = result['encrypted'] as bool? ?? false;
      final foundProvider = result['providerPubkey'] as String?;
      
      // Se descobrimos o provedor nesta busca, atualizar
      if (foundProvider != null && foundProvider.isNotEmpty && _resolvedProviderId == null && 
          (widget.dispute['provider_id'] as String? ?? '').isEmpty) {
        _resolvedProviderId = foundProvider;
      }
      
      setState(() {
        if (proof != null && proof.isNotEmpty) {
          _proofImageData = proof;
          _proofEncrypted = false;
        } else if (encrypted) {
          _proofEncrypted = true;
        }
      });
    } catch (e) {
      debugPrint('⚠️ Erro ao buscar comprovante: $e');
    } finally {
      if (mounted) setState(() => _loadingProof = false);
    }
  }
  
  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label copiado!'), backgroundColor: Colors.green, duration: const Duration(seconds: 2)),
    );
  }
  
  @override
  Widget build(BuildContext context) {
    String dateStr = '';
    try {
      final dt = DateTime.parse(createdAtStr);
      dateStr = '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      dateStr = createdAtStr;
    }
    
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('⚖️ Detalhes da Disputa', style: TextStyle(fontSize: 18)),
        actions: [
          if (!_isResolved)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              color: const Color(0xFF1A1A2E),
              onSelected: (value) {
                if (value == 'msg_user') _showSendMessageDialog('user');
                if (value == 'msg_provider') _showSendMessageDialog('provider');
                if (value == 'msg_both') _showSendMessageDialog('both');
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'msg_user', child: Row(children: [
                  Icon(Icons.person, color: Colors.blue, size: 18), SizedBox(width: 8),
                  Text('Mensagem ao Usuário', style: TextStyle(color: Colors.white70)),
                ])),
                const PopupMenuItem(value: 'msg_provider', child: Row(children: [
                  Icon(Icons.storefront, color: Colors.green, size: 18), SizedBox(width: 8),
                  Text('Mensagem ao Provedor', style: TextStyle(color: Colors.white70)),
                ])),
                const PopupMenuItem(value: 'msg_both', child: Row(children: [
                  Icon(Icons.groups, color: Colors.orange, size: 18), SizedBox(width: 8),
                  Text('Mensagem a Ambos', style: TextStyle(color: Colors.white70)),
                ])),
              ],
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.orange))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header com status
                  _buildHeader(dateStr),
                  const SizedBox(height: 16),
                  
                  // Dados da ordem
                  _buildOrderInfo(),
                  const SizedBox(height: 16),
                  
                  // Partes envolvidas
                  _buildPartiesInfo(),
                  const SizedBox(height: 16),
                  
                  // Motivo e descrição da disputa
                  _buildDisputeDetails(),
                  const SizedBox(height: 16),
                  
                  // Comprovante
                  _buildProofSection(),
                  const SizedBox(height: 16),
                  
                  // v235: Evidência do usuário (se houver)
                  _buildUserEvidenceSection(),
                  const SizedBox(height: 16),
                  
                  // v235: Histórico de mensagens de mediação
                  _buildMessageHistory(),
                  const SizedBox(height: 24),
                  
                  // Botões de resolução
                  if (!_isResolved) _buildResolutionButtons(),
                  
                  if (_isResolved)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.green.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.green.withOpacity(0.3)),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.check_circle, color: Colors.green, size: 24),
                          SizedBox(width: 8),
                          Text('Disputa Resolvida', style: TextStyle(color: Colors.green, fontSize: 16, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  
                  const SizedBox(height: 40),
                ],
              ),
            ),
    );
  }
  
  Widget _buildHeader(String dateStr) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.orange.withOpacity(0.15), Colors.red.withOpacity(0.05)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withOpacity(0.3)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.2),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.gavel, color: Colors.orange, size: 28),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Disputa Aberta', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.orange)),
                    const SizedBox(height: 4),
                    Text(
                      'Aberta por: ${openedBy == 'user' ? '👤 Usuário' : '🏪 Provedor'}',
                      style: const TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('📅 $dateStr', style: const TextStyle(color: Colors.white54, fontSize: 13)),
              if (previousStatus.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white10,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text('Status anterior: $previousStatus', style: const TextStyle(color: Colors.white54, fontSize: 11)),
                ),
            ],
          ),
        ],
      ),
    );
  }
  
  Widget _buildOrderInfo() {
    return _buildSection(
      title: '📋 Dados da Ordem',
      icon: Icons.receipt_long,
      children: [
        _infoRow('🆔 Ordem', orderId, copyable: true, monospace: true),
        if (amountBrl != null)
          _infoRow('💰 Valor BRL', 'R\$ ${amountBrl is num ? (amountBrl as num).toStringAsFixed(2) : amountBrl}'),
        if (amountSats != null)
          _infoRow('₿ Sats', '$amountSats sats'),
        if (paymentType.isNotEmpty)
          _infoRow('💳 Tipo', paymentType),
        if (pixKey.isNotEmpty)
          _infoRow('🔑 PIX', pixKey, copyable: true),
      ],
    );
  }
  
  Widget _buildPartiesInfo() {
    return _buildSection(
      title: '👥 Partes Envolvidas',
      icon: Icons.people,
      children: [
        if (userPubkey.isNotEmpty) ...[
          _infoRow('👤 Usuário', userPubkey, copyable: true, monospace: true),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => _showSendMessageDialog('user'),
              icon: const Icon(Icons.message, size: 14, color: Colors.blue),
              label: const Text('Enviar Mensagem', style: TextStyle(fontSize: 12, color: Colors.blue)),
              style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 30)),
            ),
          ),
        ],
        if (providerId.isNotEmpty) ...[
          _infoRow('🏪 Provedor', providerId, copyable: true, monospace: true),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => _showSendMessageDialog('provider'),
              icon: const Icon(Icons.message, size: 14, color: Colors.green),
              label: const Text('Enviar Mensagem', style: TextStyle(fontSize: 12, color: Colors.green)),
              style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 30)),
            ),
          ),
        ] else ...[
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Text('🏪 Provedor', style: TextStyle(color: Colors.white54, fontSize: 12)),
                SizedBox(width: 8),
                Expanded(child: Text('Buscando...', style: TextStyle(color: Colors.white38, fontSize: 12, fontStyle: FontStyle.italic), textAlign: TextAlign.right)),
              ],
            ),
          ),
        ],
      ],
    );
  }
  
  Widget _buildDisputeDetails() {
    return _buildSection(
      title: '📌 Motivo da Disputa',
      icon: Icons.warning_amber,
      children: [
        Text(reason, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500)),
        if (description.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text('Descrição detalhada:', style: TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black26,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white10),
            ),
            child: Text(description, style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.5)),
          ),
        ],
      ],
    );
  }
  
  Widget _buildProofSection() {
    return _buildSection(
      title: '📸 Comprovante do Provedor',
      icon: Icons.photo_camera,
      children: [
        if (_loadingProof)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Center(child: Column(
              children: [
                CircularProgressIndicator(color: Colors.orange, strokeWidth: 2),
                SizedBox(height: 8),
                Text('Buscando comprovante nos relays...', style: TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            )),
          )
        else if (_proofImageData != null && _proofImageData!.isNotEmpty) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: _buildProofImageWidget(_proofImageData!),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _showFullScreenImage(_proofImageData!),
              icon: const Icon(Icons.fullscreen, size: 18),
              label: const Text('Ver em Tela Cheia'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.orange,
                side: const BorderSide(color: Colors.orange),
              ),
            ),
          ),
        ] else if (_proofEncrypted) ...
          [Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.amber.withOpacity(0.05),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.amber.withOpacity(0.2)),
            ),
            child: Column(
              children: [
                const Icon(Icons.lock, color: Colors.amber, size: 40),
                const SizedBox(height: 8),
                const Text('Comprovante Criptografado (NIP-44)', style: TextStyle(color: Colors.amber, fontSize: 13, fontWeight: FontWeight.w500)),
                const SizedBox(height: 6),
                const Text(
                  'O comprovante foi enviado criptografado entre provedor e usuário. '
                  'Solicite o comprovante diretamente ao provedor via mensagem.',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => _showSendMessageDialog('provider'),
                  icon: const Icon(Icons.message, size: 16),
                  label: const Text('Solicitar ao Provedor', style: TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.amber,
                    side: const BorderSide(color: Colors.amber),
                  ),
                ),
              ],
            ),
          ),]
        else ...
          [Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.black26,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                const Icon(Icons.image_not_supported, color: Colors.white38, size: 40),
                const SizedBox(height: 8),
                const Text('Comprovante não disponível', style: TextStyle(color: Colors.white38, fontSize: 13)),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _fetchProofImage,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Tentar Novamente', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(foregroundColor: Colors.orange),
                ),
              ],
            ),
          )],
      ],
    );
  }
  
  Widget _buildProofImageWidget(String imageData) {
    try {
      // Data URI (data:image/...)
      if (imageData.startsWith('data:image')) {
        final base64Part = imageData.split(',').last;
        final bytes = base64Decode(base64Part);
        return Image.memory(bytes, fit: BoxFit.contain, width: double.infinity,
          errorBuilder: (_, __, ___) => _imagePlaceholder());
      }
      // HTTP URL
      if (imageData.startsWith('http')) {
        return Image.network(imageData, fit: BoxFit.contain, width: double.infinity,
          errorBuilder: (_, __, ___) => _imagePlaceholder());
      }
      // Raw base64
      final bytes = base64Decode(imageData);
      return Image.memory(bytes, fit: BoxFit.contain, width: double.infinity,
        errorBuilder: (_, __, ___) => _imagePlaceholder());
    } catch (_) {
      return _imagePlaceholder();
    }
  }
  
  Widget _imagePlaceholder() {
    return Container(
      height: 100, color: Colors.black26,
      child: const Center(child: Text('Erro ao carregar imagem', style: TextStyle(color: Colors.white38))),
    );
  }
  
  void _showFullScreenImage(String imageData) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          fit: StackFit.expand,
          children: [
            InteractiveViewer(
              child: Center(child: _buildProofImageWidget(imageData)),
            ),
            Positioned(
              top: 40, right: 16,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 30),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  /// v235: Seção de evidência do usuário (foto/print enviado na disputa)
  Widget _buildUserEvidenceSection() {
    final userEvidence = widget.dispute['user_evidence'] as String?;
    if (userEvidence == null || userEvidence.isEmpty) {
      return const SizedBox.shrink(); // Não mostrar se não há evidência
    }
    
    return _buildSection(
      title: '📎 Evidência do Usuário',
      icon: Icons.attach_file,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: _buildProofImageWidget(userEvidence),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => _showFullScreenImage(userEvidence),
            icon: const Icon(Icons.fullscreen, size: 18),
            label: const Text('Ver em Tela Cheia'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.blue,
              side: const BorderSide(color: Colors.blue),
            ),
          ),
        ),
      ],
    );
  }
  
  /// v235: Histórico de mensagens de mediação
  Widget _buildMessageHistory() {
    return _buildSection(
      title: '💬 Mensagens de Mediação',
      icon: Icons.chat,
      children: [
        if (_loadingMessages)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: Column(
              children: [
                CircularProgressIndicator(color: Colors.orange, strokeWidth: 2),
                SizedBox(height: 8),
                Text('Buscando mensagens...', style: TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            )),
          )
        else if (_mediatorMessages.isEmpty)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                const Icon(Icons.chat_bubble_outline, color: Colors.white24, size: 32),
                const SizedBox(height: 8),
                const Text('Nenhuma mensagem enviada ainda', style: TextStyle(color: Colors.white38, fontSize: 13)),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _fetchMediatorMessages,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Atualizar', style: TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.orange, side: const BorderSide(color: Colors.orange)),
                ),
              ],
            ),
          )
        else ...[
          ..._mediatorMessages.map((msg) => _buildMessageBubble(msg)),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('${_mediatorMessages.length} mensagen${_mediatorMessages.length == 1 ? '' : 's'}',
                style: const TextStyle(color: Colors.white38, fontSize: 11)),
              TextButton.icon(
                onPressed: _fetchMediatorMessages,
                icon: const Icon(Icons.refresh, size: 14),
                label: const Text('Atualizar', style: TextStyle(fontSize: 11)),
                style: TextButton.styleFrom(foregroundColor: Colors.orange, padding: EdgeInsets.zero, minimumSize: const Size(0, 24)),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        // Botões rápidos de envio de mensagem
        Row(
          children: [
            Expanded(
              child: _quickMsgButton('👤 Usuário', Colors.blue, () => _showSendMessageDialog('user')),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _quickMsgButton('🏪 Provedor', Colors.green, () => _showSendMessageDialog('provider')),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _quickMsgButton('👥 Ambos', Colors.orange, () => _showSendMessageDialog('both')),
            ),
          ],
        ),
      ],
    );
  }
  
  Widget _quickMsgButton(String label, Color color, VoidCallback onPressed) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withOpacity(0.5)),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        minimumSize: const Size(0, 32),
      ),
      child: Text(label, style: const TextStyle(fontSize: 10), textAlign: TextAlign.center),
    );
  }
  
  Widget _buildMessageBubble(Map<String, dynamic> msg) {
    final message = msg['message'] as String? ?? '';
    final target = msg['target'] as String? ?? 'both';
    final sentAt = msg['sentAt'] as String? ?? '';
    
    // Formatar data
    String dateStr = '';
    try {
      final dt = DateTime.parse(sentAt);
      dateStr = '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {}
    
    // Cor e ícone baseado no target
    Color targetColor;
    IconData targetIcon;
    String targetLabel;
    switch (target) {
      case 'user':
        targetColor = Colors.blue;
        targetIcon = Icons.person;
        targetLabel = 'Para: Usuário';
        break;
      case 'provider':
        targetColor = Colors.green;
        targetIcon = Icons.storefront;
        targetLabel = 'Para: Provedor';
        break;
      default:
        targetColor = Colors.orange;
        targetIcon = Icons.groups;
        targetLabel = 'Para: Ambos';
    }
    
    // Extrair apenas o corpo da mensagem (remover header formatado)
    String displayMsg = message;
    if (message.contains('\n\n')) {
      final parts = message.split('\n\n');
      if (parts.length > 2) {
        displayMsg = parts.sublist(2).join('\n\n'); // Pegar a partir do 3º bloco
      } else if (parts.length > 1) {
        displayMsg = parts.last;
      }
    }
    
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: targetColor.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: targetColor.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(targetIcon, color: targetColor, size: 14),
              const SizedBox(width: 6),
              Text(targetLabel, style: TextStyle(color: targetColor, fontSize: 11, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(dateStr, style: const TextStyle(color: Colors.white38, fontSize: 10)),
            ],
          ),
          const SizedBox(height: 6),
          Text(displayMsg, style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4)),
        ],
      ),
    );
  }
  
  Widget _buildResolutionButtons() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('⚖️ Resolução', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text(
          'Avalie as evidências e decida a favor de uma das partes. '
          'Uma mensagem será enviada para ambas as partes explicando a decisão. '
          'A resolução será publicada nos relays para auditabilidade.',
          style: TextStyle(color: Colors.white54, fontSize: 13),
        ),
        const SizedBox(height: 16),
        // Botão: Favor do Usuário
        SizedBox(
          width: double.infinity,
          height: 54,
          child: ElevatedButton(
            onPressed: () => _showResolveDialog('resolved_user'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue.shade700,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.person, color: Colors.white, size: 22),
                SizedBox(width: 10),
                Text('Resolver a Favor do USUÁRIO', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Botão: Favor do Provedor
        SizedBox(
          width: double.infinity,
          height: 54,
          child: ElevatedButton(
            onPressed: () => _showResolveDialog('resolved_provider'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green.shade700,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.storefront, color: Colors.white, size: 22),
                SizedBox(width: 10),
                Text('Resolver a Favor do PROVEDOR', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ),
      ],
    );
  }
  
  void _showResolveDialog(String resolveFor) {
    final messageController = TextEditingController();
    final isUser = resolveFor == 'resolved_user';
    
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: Row(
          children: [
            Icon(isUser ? Icons.person : Icons.storefront, color: isUser ? Colors.blue : Colors.green, size: 28),
            const SizedBox(width: 10),
            Expanded(
              child: Text('Resolver a favor do ${isUser ? 'Usuário' : 'Provedor'}',
                style: const TextStyle(color: Colors.white, fontSize: 16)),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Ordem: ${orderId.length > 20 ? '${orderId.substring(0, 20)}...' : orderId}',
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 16),
              Text(
                isUser
                  ? '⚠️ O usuário receberá de volta os sats/garantia.\nO provedor será notificado da decisão.'
                  : '⚠️ O provedor manterá os sats do serviço.\nO usuário será notificado da decisão.',
                style: TextStyle(color: isUser ? Colors.blue.shade200 : Colors.green.shade200, fontSize: 12),
              ),
              const SizedBox(height: 16),
              const Text('Mensagem para ambas as partes:', style: TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 8),
              TextField(
                controller: messageController,
                maxLines: 5,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Explique o motivo da decisão...\n\nEx: Após análise do comprovante, verificamos que o pagamento foi realizado corretamente...',
                  hintStyle: const TextStyle(color: Colors.white24, fontSize: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  filled: true,
                  fillColor: Colors.black26,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () {
              if (messageController.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Escreva a mensagem de resolução'), backgroundColor: Colors.orange),
                );
                return;
              }
              Navigator.pop(ctx);
              _executeResolution(resolveFor, messageController.text.trim());
            },
            style: ElevatedButton.styleFrom(backgroundColor: isUser ? Colors.blue : Colors.green),
            child: const Text('Confirmar Resolução', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
  
  Future<void> _executeResolution(String resolution, String message) async {
    setState(() => _isLoading = true);
    
    try {
      final orderProvider = context.read<OrderProvider>();
      final privateKey = orderProvider.nostrPrivateKey;
      
      if (privateKey == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('❌ Chave privada não disponível'), backgroundColor: Colors.red),
        );
        return;
      }
      
      final nostrService = NostrOrderService();
      
      // 1. Publicar resolução no Nostr (kind 1, tag bro-resolucao)
      final published = await nostrService.publishDisputeResolution(
        privateKey: privateKey,
        orderId: orderId,
        resolution: resolution,
        notes: message,
        userPubkey: userPubkey,
        providerId: providerId,
      );
      
      // 2. Atualizar status da ordem LOCALMENTE (NÃO publicar no Nostr como mediador)
      // CORREÇÃO v1.0.129: O mediador NÃO deve publicar kind 30080 bro_order_update
      // porque isso faz a ordem aparecer na lista do mediador como se fosse dele.
      // O publishDisputeResolution acima já publica um kind 30080 audit com type=bro_dispute_resolution
      // que é processado pelo sync das partes envolvidas.
      final newStatus = resolution == 'resolved_user' ? 'cancelled' : 'completed';
      // Nota: Não chamamos orderProvider.updateOrderStatus nem updateOrderStatusLocal
      // pois ambos publicam kind 30080 com a chave do mediador, poluindo o Nostr.
      
      // 3. Enviar mensagem de resolução para ambas as partes via bro-mediacao
      final resolutionMsg = '⚖️ RESOLUÇÃO DA DISPUTA\n\n'
        'Ordem: ${orderId.length > 8 ? orderId.substring(0, 8) : orderId}...\n'
        'Decisão: ${resolution == 'resolved_user' ? 'A favor do USUÁRIO' : 'A favor do PROVEDOR'}\n\n'
        '$message\n\n'
        'Status atualizado para: ${newStatus == 'cancelled' ? 'Cancelada' : 'Concluída'}';
      
      await nostrService.publishMediatorMessage(
        privateKey: privateKey,
        orderId: orderId,
        message: resolutionMsg,
        target: 'both',
        userPubkey: userPubkey,
        providerId: providerId,
      );
      
      setState(() => _isResolved = true);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(published
              ? '⚖️ Disputa resolvida e publicada no Nostr!'
              : '⚠️ Resolvida localmente, falha ao publicar no Nostr'),
            backgroundColor: published ? Colors.green : Colors.orange,
            duration: const Duration(seconds: 4),
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
      setState(() => _isLoading = false);
    }
  }
  
  /// Dialog para enviar mensagem do mediador (sem resolver a disputa)
  void _showSendMessageDialog(String target) {
    final messageController = TextEditingController();
    String targetLabel;
    Color targetColor;
    
    if (target == 'user') {
      targetLabel = 'Usuário';
      targetColor = Colors.blue;
    } else if (target == 'provider') {
      targetLabel = 'Provedor';
      targetColor = Colors.green;
    } else {
      targetLabel = 'Ambas as Partes';
      targetColor = Colors.orange;
    }
    
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: Row(
          children: [
            Icon(Icons.message, color: targetColor, size: 24),
            const SizedBox(width: 10),
            Expanded(
              child: Text('Mensagem para $targetLabel', style: const TextStyle(color: Colors.white, fontSize: 16)),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Referente à ordem ${orderId.length > 16 ? '${orderId.substring(0, 16)}...' : orderId}',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 12),
              const Text(
                'Use este campo para solicitar mais informações, esclarecer dúvidas ou comunicar decisões parciais.',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: messageController,
                maxLines: 5,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Escreva sua mensagem...',
                  hintStyle: const TextStyle(color: Colors.white24),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  filled: true,
                  fillColor: Colors.black26,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () async {
              if (messageController.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Escreva a mensagem'), backgroundColor: Colors.orange),
                );
                return;
              }
              Navigator.pop(ctx);
              
              final orderProvider = context.read<OrderProvider>();
              final privateKey = orderProvider.nostrPrivateKey;
              if (privateKey == null) return;
              
              final nostrService = NostrOrderService();
              final success = await nostrService.publishMediatorMessage(
                privateKey: privateKey,
                orderId: orderId,
                message: '📩 MENSAGEM DO MEDIADOR\n\n'
                  'Ordem: ${orderId.length > 8 ? orderId.substring(0, 8) : orderId}...\n\n'
                  '${messageController.text.trim()}',
                target: target,
                userPubkey: userPubkey,
                providerId: providerId,
              );
              
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(success ? '✅ Mensagem enviada!' : '❌ Erro ao enviar'),
                    backgroundColor: success ? Colors.green : Colors.red,
                  ),
                );
                // v235: Recarregar mensagens após envio
                if (success) _fetchMediatorMessages();
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: targetColor),
            child: const Text('Enviar', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
  
  // ========== HELPERS ==========
  
  Widget _buildSection({required String title, required IconData icon, required List<Widget> children}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF333333)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
          const Divider(color: Colors.white12, height: 20),
          ...children,
        ],
      ),
    );
  }
  
  Widget _infoRow(String label, String value, {bool copyable = false, bool monospace = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              monospace && value.length > 20 ? '${value.substring(0, 20)}...' : value,
              style: TextStyle(color: Colors.white, fontSize: 13, fontFamily: monospace ? 'monospace' : null),
              textAlign: TextAlign.right,
            ),
          ),
          if (copyable) ...[
            const SizedBox(width: 6),
            GestureDetector(
              onTap: () => _copyToClipboard(value, label),
              child: const Icon(Icons.copy, size: 14, color: Colors.white38),
            ),
          ],
        ],
      ),
    );
  }
}
