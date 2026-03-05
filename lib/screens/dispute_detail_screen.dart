import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../providers/order_provider.dart';
import '../services/nip44_service.dart';
import '../services/nostr_order_service.dart';
import '../services/storage_service.dart';
import '../services/api_service.dart';

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
  String? _fetchedE2eId; // v236: E2E ID buscado do comprovante
  
  // v235: Histórico de mensagens de mediação
  List<Map<String, dynamic>> _mediatorMessages = [];
  bool _loadingMessages = false;
  
  // v236: Evidências de ambas as partes
  List<Map<String, dynamic>> _allEvidence = [];
  bool _loadingEvidence = false;
  
  // v247: Histórico de disputas perdidas das partes
  int _userDisputeLosses = 0;
  int _providerDisputeLosses = 0;
  bool _loadingLosses = false;

  // Phase 4: AI Agent suggestion
  Map<String, dynamic>? _agentAnalysis;
  
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
  
  // Singleton NIP-44 para descriptografia
  Nip44Service __getNip44() => Nip44Service();
  
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
    _fetchAllEvidence(); // v236
    _fetchDisputeLosses(); // v247
    _fetchExistingResolution(); // v248: Verificar se já foi resolvida
    _fetchAgentAnalysis(); // Phase 4: AI Agent
  }
  
  /// v248: Verifica se a disputa já foi resolvida anteriormente
  Future<void> _fetchExistingResolution() async {
    if (orderId.isEmpty) return;
    try {
      // 1. Verificar resolução LOCAL primeiro (mais confiável que relay)
      final locallyResolved = await StorageService().isDisputeResolved(orderId);
      if (locallyResolved && mounted) {
        setState(() {
          _isResolved = true;
        });
        final localRes = await StorageService().getLocalDisputeResolution(orderId);
        debugPrint('⚖️ Disputa $orderId já resolvida (local): $localRes');
        return;
      }
      
      // 2. Verificar no relay Nostr
      final nostrService = NostrOrderService();
      final resolution = await nostrService.fetchDisputeResolution(orderId);
      if (resolution != null && mounted) {
        setState(() {
          _isResolved = true;
        });
        // Persistir localmente para futuras consultas
        final resText = resolution['resolution'] as String? ?? 'resolved';
        await StorageService().markDisputeResolved(orderId, resText);
        debugPrint('⚖️ Disputa $orderId já resolvida (Nostr): ${resolution['resolution']}');
      }
    } catch (e) {
      debugPrint('⚠️ Erro ao verificar resolução existente: $e');
    }
  }
  
  /// v236: Busca todas as evidências de disputa enviadas pelas partes
  Future<void> _fetchAllEvidence() async {
    if (orderId.isEmpty) return;
    setState(() => _loadingEvidence = true);
    
    try {
      final nostrService = NostrOrderService();
      // 🔓 Passar chave privada do admin para descriptografar evidências NIP-44
      final orderProvider = context.read<OrderProvider>();
      final adminPrivKey = orderProvider.nostrPrivateKey;
      final evidence = await nostrService.fetchDisputeEvidence(orderId, adminPrivateKey: adminPrivKey);
      
      if (mounted) {
        setState(() {
          _allEvidence = evidence;
          _loadingEvidence = false;
        });
      }
    } catch (e) {
      debugPrint('⚠️ Erro ao buscar evidências: $e');
      if (mounted) setState(() => _loadingEvidence = false);
    }
  }
  /// v247: Busca historico de disputas perdidas pelas partes envolvidas
  Future<void> _fetchDisputeLosses() async {
    setState(() => _loadingLosses = true);
    try {
      final nostrService = NostrOrderService();
      
      // Buscar perdas do usuário
      if (userPubkey.isNotEmpty) {
        final userLosses = await nostrService.fetchDisputeLosses(userPubkey);
        if (mounted) {
          setState(() => _userDisputeLosses = userLosses.length);
        }
      }
      
      // Buscar perdas do provedor
      if (providerId.isNotEmpty) {
        final providerLosses = await nostrService.fetchDisputeLosses(providerId);
        if (mounted) {
          setState(() => _providerDisputeLosses = providerLosses.length);
        }
      }
    } catch (e) {
      debugPrint('⚠️ Erro ao buscar histórico de disputas: $e');
    } finally {
      if (mounted) setState(() => _loadingLosses = false);
    }
  }
  
  /// 
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
  /// Passa a chave privada do admin para descriptografar proofImage NIP-44
  Future<void> _fetchProofImage() async {
    if (orderId.isEmpty) return;
    setState(() => _loadingProof = true);
    
    try {
      // Obter chave privada do admin para descriptografar NIP-44
      String? adminPrivKey;
      try {
        final orderProvider = context.read<OrderProvider>();
        adminPrivKey = orderProvider.nostrPrivateKey;
      } catch (_) {}
      
      final nostrService = NostrOrderService();
      final result = await nostrService.fetchProofForOrder(
        orderId,
        providerPubkey: providerId.isNotEmpty ? providerId : null,
        privateKey: adminPrivKey,
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
        // v236: Guardar E2E ID se veio do comprovante
        final e2e = result['e2eId'] as String?;
        if (e2e != null && e2e.isNotEmpty) {
          _fetchedE2eId = e2e;
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
                  
                  // v247: Histórico de disputas perdidas
                  _buildDisputeHistoryWarning(),
                  const SizedBox(height: 16),
                  
                  // Motivo e descrição da disputa
                  _buildDisputeDetails(),
                  const SizedBox(height: 16),
                  
                  // Comprovante
                  _buildProofSection(),
                  const SizedBox(height: 16),
                  
                  // v236: Validação E2E do PIX
                  _buildE2eValidationSection(),
                  const SizedBox(height: 16),
                  
                  // v235: Evidência do usuário (se houver)
                  _buildUserEvidenceSection(),
                  const SizedBox(height: 16),
                  
                  // v236: Todas as evidências de disputa (ambas as partes)
                  _buildAllEvidenceSection(),
                  const SizedBox(height: 16),
                  
                  // v246: Upload de imagem do mediador (criptografada)
                  if (!_isResolved) _buildMediatorImageUploadSection(),
                  if (!_isResolved) const SizedBox(height: 16),
                  
                  // v235: Histórico de mensagens de mediação
                  _buildMessageHistory(),
                  const SizedBox(height: 16),
                  
                  // Phase 4: Sugestão do AI Agent
                  if (!_isResolved) _buildAgentSuggestion(),
                  if (!_isResolved) const SizedBox(height: 16),
                  
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
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 8,
            runSpacing: 6,
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
  
  /// v247: Mostra alertas se alguma das partes já perdeu disputas anteriores
  Widget _buildDisputeHistoryWarning() {
    if (_loadingLosses) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Center(child: SizedBox(width: 20, height: 20, 
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange))),
      );
    }
    
    if (_userDisputeLosses == 0 && _providerDisputeLosses == 0) {
      return const SizedBox.shrink();
    }
    
    return _buildSection(
      title: '⚠️ Histórico de Disputas',
      icon: Icons.warning_amber,
      children: [
        if (_userDisputeLosses > 0)
          Container(
            padding: const EdgeInsets.all(10),
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: Colors.red.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.red.withOpacity(0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.person, color: Colors.red, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'USUÁRIO — $_userDisputeLosses disputa${_userDisputeLosses > 1 ? 's' : ''} perdida${_userDisputeLosses > 1 ? 's' : ''}',
                        style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      Text(
                        _userDisputeLosses >= 3 
                            ? '🚨 REINCIDENTE! Este usuário já perdeu $_userDisputeLosses disputas. Possível má-fé.'
                            : 'Este usuário já teve decisão desfavorável em disputa anterior.',
                        style: TextStyle(color: Colors.red.shade200, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        if (_providerDisputeLosses > 0)
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.withOpacity(0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.storefront, color: Colors.orange, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'PROVEDOR — $_providerDisputeLosses disputa${_providerDisputeLosses > 1 ? 's' : ''} perdida${_providerDisputeLosses > 1 ? 's' : ''}',
                        style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      Text(
                        _providerDisputeLosses >= 3 
                            ? '🚨 REINCIDENTE! Este provedor já perdeu $_providerDisputeLosses disputas. Possível fraude recorrente.'
                            : 'Este provedor já teve decisão desfavorável em disputa anterior.',
                        style: TextStyle(color: Colors.orange.shade200, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
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
  /// v236: Validação cruzada do E2E ID do PIX
  Widget _buildE2eValidationSection() {
    // Buscar E2E ID dos dados do comprovante (pode vir do evento bro-complete)
    final e2eId = _fetchedE2eId ?? 
                  widget.dispute['e2eId'] as String? ?? 
                  widget.dispute['proof_e2eId'] as String? ?? '';
    
    if (e2eId.isEmpty) {
      return _buildSection(
        title: '🔍 Validação E2E do PIX',
        icon: Icons.fingerprint,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.yellow.withOpacity(0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.yellow.withOpacity(0.2)),
            ),
            child: const Row(
              children: [
                Icon(Icons.warning_amber, color: Colors.yellow, size: 18),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Provedor não informou o código E2E do PIX. Solicite via mensagem para validação cruzada.',
                    style: TextStyle(color: Colors.yellow, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }
    
    // Validar formato do E2E
    // Formato padrão: E + 8 dígitos ISPB + 14 dígitos datetime + 11 caracteres alfanuméricos
    // Ex: E09089356202602251806abc123def45
    final e2eRegex = RegExp(r'^E(\d{8})(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(.+)$');
    final match = e2eRegex.firstMatch(e2eId);
    
    // Dados da disputa para cruzamento
    final disputeDate = widget.dispute['createdAt'] as String? ?? '';
    final amount = widget.dispute['amount_brl']?.toString() ?? '';
    
    // ISPB conhecidos (principais bancos)
    const ispbMap = {
      '00000000': 'Banco do Brasil',
      '00360305': 'Caixa Econômica',
      '60701190': 'Itaú',
      '60746948': 'Bradesco',
      '90400888': 'Santander',
      '00416968': 'Banco Inter',
      '18236120': 'Nu Pagamentos (Nubank)',
      '09089356': 'Efí (antigo Gerencianet)',
      '13140088': 'PagBank/PagSeguro',
      '60394079': 'Mercado Pago',
      '11165756': 'C6 Bank',
      '07679404': 'Banco Original',
      '92894922': 'Banrisul',
      '01181521': 'Stone',
    };
    
    List<Widget> validationItems = [];
    
    if (match != null) {
      final ispb = match.group(1)!;
      final year = match.group(2)!;
      final month = match.group(3)!;
      final day = match.group(4)!;
      final hour = match.group(5)!;
      final minute = match.group(6)!;
      final second = match.group(7)!;
      
      final bankName = ispbMap[ispb] ?? 'Banco ISPB $ispb';
      final dateFromE2e = '$day/$month/$year $hour:$minute:$second';
      
      // Verificar se data do E2E bate com período da disputa
      bool dateMatch = true;
      if (disputeDate.isNotEmpty) {
        try {
          final disputeDt = DateTime.parse(disputeDate);
          final e2eDt = DateTime(
            int.parse(year), int.parse(month), int.parse(day),
            int.parse(hour), int.parse(minute), int.parse(second),
          );
          // Deve ser antes da disputa e dentro de 48h
          final diff = disputeDt.difference(e2eDt);
          dateMatch = diff.inHours >= 0 && diff.inHours <= 48;
        } catch (_) {}
      }
      
      validationItems = [
        _e2eValidationRow('📐 Formato', '✅ Válido', Colors.green),
        _e2eValidationRow('🏦 Banco Origem', '$bankName (ISPB: $ispb)', 
          ispbMap.containsKey(ispb) ? Colors.green : Colors.orange),
        _e2eValidationRow('📅 Data no E2E', dateFromE2e, 
          dateMatch ? Colors.green : Colors.red),
        if (!dateMatch)
          _e2eValidationRow('⚠️ Alerta', 'Data do E2E não corresponde ao período da ordem', Colors.red),
      ];
    } else {
      // Formato inválido
      validationItems = [
        _e2eValidationRow('📐 Formato', '❌ Inválido — não corresponde ao padrão do BCB', Colors.red),
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text(
            'Formato esperado: E + 8 dígitos ISPB + data/hora + hash',
            style: TextStyle(color: Colors.white38, fontSize: 11),
          ),
        ),
      ];
    }
    
    return _buildSection(
      title: '🔍 Validação E2E do PIX',
      icon: Icons.fingerprint,
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.cyan.withOpacity(0.05),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.fingerprint, color: Colors.cyan, size: 16),
                  const SizedBox(width: 6),
                  Expanded(
                    child: SelectableText(
                      e2eId,
                      style: const TextStyle(
                        color: Colors.cyan,
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              const Divider(color: Colors.white12),
              const SizedBox(height: 6),
              ...validationItems,
            ],
          ),
        ),
      ],
    );
  }
  
  Widget _e2eValidationRow(String label, String value, Color valueColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ),
          Expanded(
            child: Text(value, style: TextStyle(color: valueColor, fontSize: 12, fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }

  Widget _buildUserEvidenceSection() {
    String? userEvidence = widget.dispute['user_evidence'] as String?;
    
    // 🔓 Tentar descriptografar se a evidência está encriptada com NIP-44
    if (userEvidence == '[encrypted:nip44v2]') {
      final encryptedPayload = widget.dispute['user_evidence_nip44'] as String?;
      final senderPubkey = widget.dispute['userPubkey'] as String? ?? '';
      if (encryptedPayload != null && senderPubkey.isNotEmpty) {
        try {
          final orderProvider = context.read<OrderProvider>();
          final adminPrivKey = orderProvider.nostrPrivateKey;
          if (adminPrivKey != null) {
            final nip44 = __getNip44();
            userEvidence = nip44.decryptBetween(encryptedPayload, adminPrivKey, senderPubkey);
            debugPrint('🔓 user_evidence descriptografada com NIP-44');
          }
        } catch (e) {
          debugPrint('⚠️ Falha ao descriptografar user_evidence: $e');
          userEvidence = null;
        }
      } else {
        userEvidence = null;
      }
    }
    
    if (userEvidence == null || userEvidence.isEmpty) {
      return const SizedBox.shrink(); // Não mostrar se não há evidência
    }
    
    return _buildSection(
      title: '📎 Evidência do Usuário',
      icon: Icons.attach_file,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: _buildProofImageWidget(userEvidence!),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => _showFullScreenImage(userEvidence!),
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
  
  /// v236: Seção com TODAS as evidências enviadas pelas partes durante a disputa
  Widget _buildAllEvidenceSection() {
    if (_allEvidence.isEmpty && !_loadingEvidence) {
      return const SizedBox.shrink();
    }
    
    return _buildSection(
      title: '📂 Evidências das Partes (${_allEvidence.length})',
      icon: Icons.folder_open,
      children: [
        if (_loadingEvidence)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: Column(children: [
              CircularProgressIndicator(color: Colors.blue, strokeWidth: 2),
              SizedBox(height: 8),
              Text('Buscando evidências...', style: TextStyle(color: Colors.white54, fontSize: 12)),
            ])),
          )
        else ...[
          ..._allEvidence.asMap().entries.map((entry) {
            final idx = entry.key;
            final ev = entry.value;
            final role = ev['senderRole'] as String? ?? 'unknown';
            final desc = ev['description'] as String? ?? '';
            final image = ev['image'] as String? ?? '';
            final sentAt = ev['sentAt'] as String? ?? '';
            final isUser = role == 'user';
            final isMediator = role == 'mediator'; // v246
            
            // v246: Cor por papel
            final roleColor = isMediator ? Colors.purple : (isUser ? Colors.blue : Colors.green);
            final roleLabel = isMediator ? 'Mediador' : (isUser ? 'Usuário' : 'Provedor');
            final roleIcon = isMediator ? Icons.gavel : (isUser ? Icons.person : Icons.storefront);
            
            String dateStr = '';
            try {
              final dt = DateTime.parse(sentAt);
              dateStr = '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
            } catch (_) {}
            
            return Container(
              margin: EdgeInsets.only(bottom: idx < _allEvidence.length - 1 ? 12 : 0),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: roleColor.withOpacity(0.06),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: roleColor.withOpacity(0.2)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(roleIcon, color: roleColor, size: 16),
                      const SizedBox(width: 6),
                      Text(roleLabel,
                        style: TextStyle(color: roleColor, 
                          fontWeight: FontWeight.bold, fontSize: 12)),
                      const Spacer(),
                      if (dateStr.isNotEmpty)
                        Text(dateStr, style: const TextStyle(color: Colors.white38, fontSize: 11)),
                    ],
                  ),
                  if (desc.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(desc, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  ],
                  if (image.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: _buildProofImageWidget(image),
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => _showFullScreenImage(image),
                        icon: const Icon(Icons.fullscreen, size: 16),
                        label: const Text('Ver em Tela Cheia', style: TextStyle(fontSize: 11)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: roleColor,
                          side: BorderSide(color: roleColor.withOpacity(0.5)),
                          padding: const EdgeInsets.symmetric(vertical: 6),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            );
          }),
          const SizedBox(height: 8),
          Center(
            child: TextButton.icon(
              onPressed: _fetchAllEvidence,
              icon: const Icon(Icons.refresh, size: 14),
              label: const Text('Atualizar Evidências', style: TextStyle(fontSize: 11)),
              style: TextButton.styleFrom(foregroundColor: Colors.blue),
            ),
          ),
        ],
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

  /// v236: Chip de mensagem pré-definida para pedir evidências
  Widget _predefinedMsgChip(TextEditingController controller, String label, String message) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 10, color: Colors.white70)),
      backgroundColor: const Color(0xFF2A2A3E),
      side: BorderSide(color: Colors.white.withOpacity(0.1)),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      onPressed: () {
        controller.text = message;
        controller.selection = TextSelection.fromPosition(
          TextPosition(offset: message.length),
        );
      },
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
  
  /// v246: Seção para o mediador subir imagens como evidência
  /// Imagens são criptografadas com NIP-44 para cada parte envolvida
  Widget _buildMediatorImageUploadSection() {
    return _buildSection(
      title: '📎 Evidência do Mediador',
      icon: Icons.add_photo_alternate,
      children: [
        const Text(
          'Suba imagens que documentam a decisão. Elas serão criptografadas (NIP-44) e visíveis apenas para as partes envolvidas.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _pickAndUploadMediatorImage(ImageSource.gallery),
                icon: const Icon(Icons.photo_library, size: 18),
                label: const Text('Galeria'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.purple,
                  side: const BorderSide(color: Colors.purple),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _pickAndUploadMediatorImage(ImageSource.camera),
                icon: const Icon(Icons.camera_alt, size: 18),
                label: const Text('Câmera'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.purple,
                  side: const BorderSide(color: Colors.purple),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
  
  /// v246: Selecionar e enviar imagem como evidência do mediador
  /// Criptografa com NIP-44 para ambas as partes (user + provider)
  Future<void> _pickAndUploadMediatorImage(ImageSource source) async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: source, 
        maxWidth: 600, // v247: Reduzida para caber nos relays Nostr
        maxHeight: 600, 
        imageQuality: 40,
      );
      if (picked == null) return;
      
      final file = File(picked.path);
      final bytes = await file.readAsBytes();
      final imageBase64 = base64Encode(bytes);
      
      // Mostrar dialog para adicionar descrição antes de enviar
      if (!mounted) return;
      final descController = TextEditingController();
      
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A2E),
          title: const Row(
            children: [
              Icon(Icons.add_photo_alternate, color: Colors.purple, size: 24),
              SizedBox(width: 10),
              Expanded(child: Text('Enviar Evidência', style: TextStyle(color: Colors.white, fontSize: 16))),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Preview da imagem
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    bytes,
                    height: 150,
                    width: double.infinity,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.purple.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.purple.withOpacity(0.3)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.lock, color: Colors.purple, size: 16),
                      SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Criptografada NIP-44 — visível apenas para as partes',
                          style: TextStyle(color: Colors.purple, fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: descController,
                  maxLines: 3,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Descrição da evidência (opcional)...',
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
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.purple),
              child: const Text('Enviar Criptografado', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
      
      if (confirm != true || !mounted) return;
      
      setState(() => _isLoading = true);
      
      final orderProvider = context.read<OrderProvider>();
      final privateKey = orderProvider.nostrPrivateKey;
      if (privateKey == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('❌ Chave privada não disponível'), backgroundColor: Colors.red),
        );
        setState(() => _isLoading = false);
        return;
      }
      
      final nostrService = NostrOrderService();
      
      // Publicar evidência do mediador como senderRole 'mediator'
      final success = await nostrService.publishDisputeEvidence(
        privateKey: privateKey,
        orderId: orderId,
        senderRole: 'mediator',
        imageBase64: imageBase64,
        description: descController.text.trim().isNotEmpty 
            ? '⚖️ Evidência do Mediador: ${descController.text.trim()}'
            : '⚖️ Evidência do Mediador',
      );
      
      setState(() => _isLoading = false);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(success 
                ? '✅ Evidência enviada e criptografada!' 
                : '❌ Erro ao enviar evidência'),
            backgroundColor: success ? Colors.green : Colors.red,
          ),
        );
        // Recarregar evidências
        if (success) _fetchAllEvidence();
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // ========== Phase 4: AI Agent Suggestion ==========

  Future<void> _fetchAgentAnalysis() async {
    if (orderId.isEmpty) return;
    try {
      final analysis = await ApiService().getAgentAnalysis(orderId);
      if (analysis != null && analysis['success'] == true && mounted) {
        setState(() => _agentAnalysis = analysis['analysis'] as Map<String, dynamic>?);
      }
    } catch (e) {
      debugPrint('⚠️ Agent analysis não disponível: $e');
    }
  }

  Widget _buildAgentSuggestion() {
    if (_agentAnalysis == null) return const SizedBox.shrink();

    final confidence = (_agentAnalysis!['confidence'] ?? 0.0) as num;
    final recommendation = _agentAnalysis!['suggestion'] ?? '';
    final reason = _agentAnalysis!['reason'] ?? '';
    final tier = _agentAnalysis!['tier'] ?? 0;

    Color confidenceColor;
    if (confidence >= 0.9) {
      confidenceColor = Colors.green;
    } else if (confidence >= 0.6) {
      confidenceColor = Colors.amber;
    } else {
      confidenceColor = Colors.red;
    }

    String recLabel;
    IconData recIcon;
    switch (recommendation) {
      case 'resolved_user':
        recLabel = 'Favor do Usuário';
        recIcon = Icons.person;
        break;
      case 'resolved_provider':
        recLabel = 'Favor do Provedor';
        recIcon = Icons.storefront;
        break;
      case 'escalate':
        recLabel = 'Escalar para humano';
        recIcon = Icons.escalator_warning;
        break;
      default:
        recLabel = recommendation;
        recIcon = Icons.help_outline;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.purple.withOpacity(0.15), Colors.blue.withOpacity(0.05)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.purple.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.smart_toy, color: Colors.purple, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Sugestão do AI Agent',
                  style: TextStyle(
                    color: Colors.purple,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: confidenceColor.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${(confidence * 100).toStringAsFixed(0)}%',
                  style: TextStyle(
                    color: confidenceColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(recIcon, color: Colors.white70, size: 18),
              const SizedBox(width: 8),
              Text(
                recLabel,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '(Tier $tier)',
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
          ),
          if (reason.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              reason,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
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
      
      // v239: Também enviar como DM NIP-04 para aparecer na caixa de entrada
      // (compatível com versões antigas do app)
      if (userPubkey.isNotEmpty) {
        await nostrService.sendAdminNip04DM(
          adminPrivateKey: privateKey,
          recipientPubkey: userPubkey,
          message: '⚖️ [Bro Mediação] $resolutionMsg',
        );
      }
      if (providerId.isNotEmpty) {
        await nostrService.sendAdminNip04DM(
          adminPrivateKey: privateKey,
          recipientPubkey: providerId,
          message: '⚖️ [Bro Mediação] $resolutionMsg',
        );
      }
      
      // v270: Persistir resolução localmente para não depender do relay
      await StorageService().markDisputeResolved(orderId, resolution);
      
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
              const SizedBox(height: 8),
              // v236: Mensagens pré-definidas para pedir evidências
              const Text('Mensagens rápidas:', style: TextStyle(color: Colors.white38, fontSize: 11)),
              const SizedBox(height: 4),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  if (target == 'user' || target == 'both') ...[
                    _predefinedMsgChip(messageController, '📋 Pedir print do beneficiário',
                      'Por favor, acesse o site/app da empresa beneficiária (ex: SANEPAR, CEMIG, CPFL) e envie um print mostrando que a conta consta como NÃO PAGA/EM ABERTO. Isso nos ajuda a resolver sua disputa mais rápido.'),
                    _predefinedMsgChip(messageController, '🏦 Pedir print do Registrato',
                      'Por favor, acesse registrato.bcb.gov.br (login via gov.br), vá em "Consultas" > "PIX" e envie um print da lista de PIX recebidos na data do pagamento. Este é um documento oficial do Banco Central.'),
                  ],
                  if (target == 'provider' || target == 'both') ...[
                    _predefinedMsgChip(messageController, '📸 Pedir comprovante completo',
                      'Por favor, envie o comprovante completo do PIX com todos os dados visíveis: valor, data/hora, chave PIX destino, código E2E (endToEndId) e nome do beneficiário.'),
                    _predefinedMsgChip(messageController, '🏦 Pedir Registrato do provedor',
                      'Por favor, acesse registrato.bcb.gov.br (login via gov.br), vá em "Consultas" > "PIX" e envie um print da lista de PIX enviados na data do pagamento. Este documento do Banco Central comprova o envio.'),
                  ],
                  _predefinedMsgChip(messageController, '⏰ Prazo 24h',
                    'Você tem 24 horas para enviar as evidências solicitadas. Caso não envie, a disputa será resolvida com base nas evidências disponíveis.'),
                  _predefinedMsgChip(messageController, '⚖️ Solicitar evidências (ambos)',
                    'Prezado(a), estamos mediando esta disputa e precisamos da colaboração de ambas as partes para uma resolução justa.\n\n'
                    '📌 O QUE PRECISAMOS:\n\n'
                    '1️⃣ COMPROVANTE COMPLETO DO PIX — com valor, data/hora, chave PIX destino, nome do beneficiário e código E2E (endToEndId). Disponível nos detalhes da transação no app do seu banco.\n\n'
                    '2️⃣ PRINT DO REGISTRATO (Banco Central) — acesse registrato.bcb.gov.br → login com gov.br → Consultas → PIX → Transações. Filtre pela data do pagamento. Este é um documento oficial e irrefutável do BCB.\n\n'
                    '3️⃣ PRINT DO SITE DO BENEFICIÁRIO — se for conta de serviço (SANEPAR, CEMIG, CPFL, etc.), acesse o site/app da empresa e envie print mostrando o status da conta (paga ou em aberto).\n\n'
                    '� PRIVACIDADE: Todas as evidências enviadas são criptografadas de ponta a ponta (NIP-44) e visíveis APENAS para o mediador. Nenhum outro usuário do Nostr pode ver seus dados.\n\n'
                    '📲 COMO ENVIAR:\n'
                    '• Atualize o app Bro para a versão mais recente\n'
                    '• ⚠️ IMPORTANTE: Antes de atualizar, anote suas 12 palavras de recuperação (seed). Após a atualização pode ser necessário reinserir.\n'
                    '• Faça login, acesse a ordem em disputa e toque no botão "Enviar Evidência / Comprovante"\n'
                    '• Você pode enviar várias evidências\n\n'
                    '⏰ PRAZO: 24 horas para envio. Após esse prazo, a disputa será resolvida com base nas evidências disponíveis.'),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: messageController,
                maxLines: 5,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Escreva sua mensagem ou toque uma rápida acima...',
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
              final msgText = '📩 MENSAGEM DO MEDIADOR\n\n'
                  'Ordem: ${orderId.length > 8 ? orderId.substring(0, 8) : orderId}...\n\n'
                  '${messageController.text.trim()}';
              final success = await nostrService.publishMediatorMessage(
                privateKey: privateKey,
                orderId: orderId,
                message: msgText,
                target: target,
                userPubkey: userPubkey,
                providerId: providerId,
              );
              
              // v239: Também enviar como DM NIP-04 para caixa de entrada Nostr
              // (compatível com versões antigas do app)
              if (success) {
                final dmMsg = '📩 [Bro Mediação] ${messageController.text.trim()}\n\n(Ordem: ${orderId.length > 8 ? orderId.substring(0, 8) : orderId}...)';
                if ((target == 'user' || target == 'both') && userPubkey.isNotEmpty) {
                  await nostrService.sendAdminNip04DM(
                    adminPrivateKey: privateKey,
                    recipientPubkey: userPubkey,
                    message: dmMsg,
                  );
                }
                if ((target == 'provider' || target == 'both') && providerId.isNotEmpty) {
                  await nostrService.sendAdminNip04DM(
                    adminPrivateKey: privateKey,
                    recipientPubkey: providerId,
                    message: dmMsg,
                  );
                }
              }
              
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
