import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:provider/provider.dart';
import '../providers/order_provider.dart';
import '../providers/breez_provider_export.dart';
import '../providers/breez_liquid_provider.dart';
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
  String? _resolvedDirection; // v338: 'resolved_provider' ou 'resolved_user'
  bool _adminPaidProvider = false;
  bool _isAdminPaying = false;
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
          broLog('✅ Provider descoberto para disputa: ${foundProvider.substring(0, 8)}');
        }
      } catch (e) {
        broLog('⚠️ Erro ao buscar provider: $e');
      }
    }
    // Aguardar dados essenciais ANTES de rodar análise forense
    // (proof, evidence, losses são necessários para análise precisa)
    await Future.wait([
      _fetchProofImage(),
      _fetchAllEvidence(), // v236
      _fetchDisputeLosses(), // v247
    ]);
    _fetchMediatorMessages();
    _fetchExistingResolution(); // v248: Verificar se já foi resolvida
    _fetchAgentAnalysis(); // Phase 4: AI Agent — agora com dados carregados
  }
  
  /// v248: Verifica se a disputa já foi resolvida anteriormente
  Future<void> _fetchExistingResolution() async {
    if (orderId.isEmpty) return;
    try {
      // 1. Verificar resolução LOCAL primeiro (mais confiável que relay)
      final locallyResolved = await StorageService().isDisputeResolved(orderId);
      if (locallyResolved && mounted) {
        final localRes = await StorageService().getLocalDisputeResolution(orderId);
        setState(() {
          _isResolved = true;
          _resolvedDirection = localRes;
        });
        broLog('⚖️ Disputa $orderId já resolvida (local): $localRes');
        return;
      }
      
      // 2. Verificar no relay Nostr
      final nostrService = NostrOrderService();
      final resolution = await nostrService.fetchDisputeResolution(orderId);
      if (resolution != null && mounted) {
        final resText = resolution['resolution'] as String? ?? 'resolved';
        setState(() {
          _isResolved = true;
          _resolvedDirection = resText;
        });
        // Persistir localmente para futuras consultas
        await StorageService().markDisputeResolved(orderId, resText);
        broLog('⚖️ Disputa $orderId já resolvida (Nostr): ${resolution['resolution']}');
      }
    } catch (e) {
      broLog('⚠️ Erro ao verificar resolução existente: $e');
    }
  }
  
  /// v236: Busca todas as evidências de disputa enviadas pelas partes
  Future<void> _fetchAllEvidence() async {
    if (orderId.isEmpty) return;
    setState(() => _loadingEvidence = true);
    
    try {
      final nostrService = NostrOrderService();
      // 🔓 Usar chave do admin logado para descriptografar evidências NIP-44
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
      broLog('⚠️ Erro ao buscar evidências: $e');
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
      broLog('⚠️ Erro ao buscar histórico de disputas: $e');
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
      broLog('⚠️ Erro ao buscar mensagens: $e');
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
      // 🔓 Usar chave do admin logado para descriptografar NIP-44
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
      broLog('⚠️ Erro ao buscar comprovante: $e');
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
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.check_circle, color: Colors.green, size: 24),
                          const SizedBox(width: 8),
                          Text(
                            _resolvedDirection == 'resolved_provider'
                                ? 'Resolvida a Favor do Provedor'
                                : _resolvedDirection == 'resolved_user'
                                    ? 'Resolvida a Favor do Usuário'
                                    : 'Disputa Resolvida',
                            style: const TextStyle(color: Colors.green, fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  
                  // v338: Botão para admin pagar provedor diretamente
                  if (_isResolved && _resolvedDirection == 'resolved_provider' && !_adminPaidProvider) ...[
                    const SizedBox(height: 12),
                    _buildAdminPayProviderButton(),
                  ],
                  if (_adminPaidProvider) ...[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.green.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.bolt, color: Colors.green, size: 20),
                          SizedBox(width: 8),
                          Text('✅ Provedor pago com sucesso!', style: TextStyle(color: Colors.green, fontSize: 14, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ],
                  
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
            broLog('🔓 user_evidence descriptografada com NIP-44');
          }
        } catch (e) {
          broLog('⚠️ Falha ao descriptografar user_evidence: $e');
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
    
    // Tentar análise do backend primeiro
    try {
      final analysis = await ApiService().getAgentAnalysis(orderId);
      if (analysis != null && analysis['success'] == true && mounted) {
        setState(() => _agentAnalysis = analysis['analysis'] as Map<String, dynamic>?);
        if (_agentAnalysis != null) return; // Backend respondeu com análise
      }
    } catch (e) {
      broLog('⚠️ Agent backend não disponível: $e');
    }
    
    // Fallback: análise heurística local (funciona sem backend)
    if (mounted) {
      final localAnalysis = _runLocalHeuristics();
      if (localAnalysis != null) {
        setState(() => _agentAnalysis = localAnalysis);
        broLog('🤖 Análise heurística local aplicada: ${localAnalysis['suggestion']} (${((localAnalysis['confidence'] as num) * 100).toStringAsFixed(0)}%)');
      }
    }
  }

  /// Análise forense local — investiga comprovante, E2E PIX, cruzamento de
  /// dados e padrões de fraude. Princípio: comprovante sem prova verificável
  /// (E2E válido) não tem valor. Imagem sozinha NÃO prova pagamento.
  Map<String, dynamic>? _runLocalHeuristics() {
    final dispute = widget.dispute;
    final disputeOpenedBy = openedBy;
    final disputeReason = reason;
    final disputeDescription = description;
    final hasUserEvidence = (dispute['user_evidence_nip44'] as String?)?.isNotEmpty == true &&
        (dispute['user_evidence_nip44'] as String).length > 100;
    final hasProofImage = _proofImageData != null && _proofImageData!.isNotEmpty;
    final isPix = paymentType.toLowerCase().contains('pix') || pixKey.isNotEmpty;

    // Pontuação: positivo = favorece provedor, negativo = favorece usuário
    double score = 0;
    List<Map<String, dynamic>> findings = [];
    
    // Flags compostas para cruzamento
    bool proofHasValidE2e = false;
    bool proofMissingE2e = false;
    bool proofHasInvalidE2e = false;
    bool proofImageExists = hasProofImage;
    bool e2eDateMismatch = false;

    // ═══════════════════════════════════════════
    // 1. VALIDAÇÃO E2E DO PIX (ANÁLISE MAIS IMPORTANTE)
    // Um PIX real SEMPRE gera um E2E. Sem E2E = sem prova de transação.
    // ═══════════════════════════════════════════
    if (isPix) {
      final e2eId = _fetchedE2eId ?? 
                    dispute['e2eId'] as String? ?? 
                    dispute['proof_e2eId'] as String? ?? '';
      
      if (e2eId.isEmpty) {
        proofMissingE2e = true;
        score -= 0.35;
        findings.add({'icon': '🔴', 'text': 'Código E2E do PIX AUSENTE — toda transação PIX gera um identificador E2E único e obrigatório. Sem ele, é impossível comprovar que qualquer pagamento PIX foi realizado. Comprovante sem E2E não tem validade.', 'severity': 'red'});
      } else {
        final e2eRegex = RegExp(r'^E(\d{8})(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(.+)$');
        final match = e2eRegex.firstMatch(e2eId);
        
        if (match != null) {
          final ispb = match.group(1)!;
          final year = match.group(2)!;
          final month = match.group(3)!;
          final day = match.group(4)!;
          final hour = match.group(5)!;
          final minute = match.group(6)!;
          
          const ispbMap = {
            '00000000': 'Banco do Brasil', '00360305': 'Caixa Econômica',
            '60701190': 'Itaú', '60746948': 'Bradesco', '90400888': 'Santander',
            '00416968': 'Banco Inter', '18236120': 'Nubank', '09089356': 'Efí/Gerencianet',
            '13140088': 'PagBank/PagSeguro', '60394079': 'Mercado Pago',
            '11165756': 'C6 Bank', '07679404': 'Banco Original',
            '92894922': 'Banrisul', '01181521': 'Stone',
          };
          
          proofHasValidE2e = true;
          score += 0.15;
          findings.add({'icon': '🟢', 'text': 'E2E com formato válido do Banco Central', 'severity': 'green'});
          
          final bankName = ispbMap[ispb];
          if (bankName != null) {
            score += 0.05;
            findings.add({'icon': '🟢', 'text': 'Banco de origem identificado: $bankName (ISPB: $ispb)', 'severity': 'green'});
          } else {
            findings.add({'icon': '🟡', 'text': 'ISPB $ispb não reconhecido — banco menor ou código incomum', 'severity': 'yellow'});
          }
          
          // Cruzar data do E2E com data da ordem/disputa
          if (createdAtStr.isNotEmpty) {
            try {
              final disputeDt = DateTime.parse(createdAtStr);
              final e2eDt = DateTime(
                int.parse(year), int.parse(month), int.parse(day),
                int.parse(hour), int.parse(minute),
              );
              final diff = disputeDt.difference(e2eDt);
              
              if (diff.inHours < 0) {
                e2eDateMismatch = true;
                score -= 0.40;
                findings.add({'icon': '🔴', 'text': 'FRAUDE PROVÁVEL: Data do E2E ($day/$month/$year $hour:$minute) é POSTERIOR à abertura da disputa — PIX teria sido feito depois da reclamação. Isto é impossível em transação legítima.', 'severity': 'red'});
              } else if (diff.inHours <= 48) {
                score += 0.10;
                findings.add({'icon': '🟢', 'text': 'Data do E2E ($day/$month/$year $hour:$minute) compatível com o período da ordem', 'severity': 'green'});
              } else {
                e2eDateMismatch = true;
                score -= 0.20;
                findings.add({'icon': '🔴', 'text': 'Data do E2E ($day/$month/$year $hour:$minute) é de ${diff.inDays} dias ANTES da disputa — possível reutilização de comprovante antigo', 'severity': 'red'});
              }
            } catch (_) {}
          }

          final tail = match.group(8) ?? '';
          if (tail.length < 8) {
            score -= 0.10;
            findings.add({'icon': '🔴', 'text': 'Hash do E2E truncado ($tail) — código parece ter sido editado ou digitado manualmente', 'severity': 'red'});
          }
        } else {
          proofHasInvalidE2e = true;
          score -= 0.30;
          findings.add({'icon': '🔴', 'text': 'E2E "$e2eId" com formato INVÁLIDO — não segue o padrão do Banco Central (E + 8 dígitos ISPB + datetime + hash). Código provavelmente fabricado ou copiado de outro contexto.', 'severity': 'red'});
        }
      }
    }

    // ═══════════════════════════════════════════
    // 2. ANÁLISE DO COMPROVANTE (IMAGEM)
    // IMPORTANTE: Imagem de comprovante SEM E2E válido não prova nada.
    // Qualquer pessoa pode fabricar uma imagem de "transferência".
    // ═══════════════════════════════════════════
    if (hasProofImage) {
      final proofBytes = _proofImageData!.length;
      final estimatedImageBytes = (proofBytes * 0.75).round();
      final sizeKB = (estimatedImageBytes / 1024).toStringAsFixed(1);

      if (isPix && (proofMissingE2e || proofHasInvalidE2e)) {
        // Comprovante PIX SEM E2E válido = suspeito por definição
        score -= 0.20;
        findings.add({'icon': '🔴', 'text': 'Provedor enviou imagem de comprovante ($sizeKB KB) mas SEM código E2E válido — uma imagem sozinha NÃO comprova pagamento PIX. Qualquer pessoa pode fabricar ou editar uma captura de tela de transferência.', 'severity': 'red'});
      } else if (isPix && proofHasValidE2e && !e2eDateMismatch) {
        // Comprovante PIX COM E2E válido e data ok = forte evidência
        if (estimatedImageBytes < 3000) {
          findings.add({'icon': '🟡', 'text': 'Imagem do comprovante muito pequena ($sizeKB KB) mas E2E válido — prova parcial', 'severity': 'yellow'});
        } else {
          score += 0.10;
          findings.add({'icon': '🟢', 'text': 'Comprovante ($sizeKB KB) acompanhado de E2E válido — evidência consistente', 'severity': 'green'});
        }
      } else if (!isPix) {
        // Pagamento não-PIX: comprovante tem mais peso (sem E2E para validar)
        if (estimatedImageBytes < 3000) {
          score -= 0.10;
          findings.add({'icon': '🟡', 'text': 'Comprovante muito pequeno ($sizeKB KB) — pode ser imagem fabricada', 'severity': 'yellow'});
        } else {
          score += 0.05;
          findings.add({'icon': '🟡', 'text': 'Comprovante enviado ($sizeKB KB) — verificação visual necessária (sem E2E para validar automaticamente)', 'severity': 'yellow'});
        }
      }
      
      // Verificar formato de imagem
      final b64 = _proofImageData!.trim();
      final looksLikeJpeg = b64.startsWith('/9j/') || b64.startsWith('/9j');
      final looksLikePng = b64.startsWith('iVBOR');
      final hasDataUri = b64.startsWith('data:image/');
      if (!looksLikeJpeg && !looksLikePng && !hasDataUri && b64.length > 100) {
        score -= 0.05;
        findings.add({'icon': '🟡', 'text': 'Formato da imagem não identificado (não é JPEG/PNG padrão) — pode ser arquivo corrompido ou manipulado', 'severity': 'yellow'});
      }
    } else if (_proofEncrypted) {
      score -= 0.10;
      findings.add({'icon': '🟡', 'text': 'Comprovante criptografado (NIP-44) — não foi possível analisar. Solicite ao provedor que reenvie.', 'severity': 'yellow'});
    } else {
      // Sem comprovante nenhum
      score -= 0.30;
      findings.add({'icon': '🔴', 'text': 'Provedor NÃO enviou nenhum comprovante de pagamento — se o provedor alega ter pago, deveria ter prova. Ausência de comprovante é forte indício contra o provedor.', 'severity': 'red'});
    }

    // ═══════════════════════════════════════════
    // 2b. VERIFICAÇÃO DE CÓDIGO DE AUTENTICAÇÃO
    // Comprovantes bancários reais SEMPRE têm código de autenticação.
    // Se o comprovante é apenas uma imagem SEM dados verificáveis, é suspeito.
    // ═══════════════════════════════════════════
    final authCode = widget.dispute['authCode'] as String? ?? 
                     widget.dispute['authentication_code'] as String? ?? '';
    final transactionId = widget.dispute['transactionId'] as String? ?? 
                          widget.dispute['transaction_id'] as String? ?? '';
    
    if (proofImageExists && isPix) {
      if (authCode.isEmpty && transactionId.isEmpty && (proofMissingE2e || proofHasInvalidE2e)) {
        score -= 0.20;
        findings.add({'icon': '🚨', 'text': 'VERIFICAÇÃO OBRIGATÓRIA: O comprovante NÃO tem nenhum código verificável (E2E, autenticação, ou ID de transação). '
            'Comprovantes PIX reais SEMPRE contêm: (1) Código E2E, (2) Código de autenticação, (3) ID da transação, (4) Nome do destinatário. '
            'ABRA A IMAGEM e verifique se esses dados estão presentes. Se a imagem não tem esses campos, é fabricada.', 'severity': 'red'});
      }
      
      // Instrução explícita para o admin
      findings.add({'icon': '🔎', 'text': 'CHECKLIST para verificar na imagem do comprovante:\n'
          '• Código de autenticação (sequência alfanumérica única)\n'
          '• Nome do banco emissor\n'
          '• Nome do destinatário (deve corresponder ao dono da chave PIX)\n'
          '• Data e hora da transação (deve ser compatível com a ordem)\n'
          '• Valor exato (deve corresponder ao valor da ordem)\n'
          'Se QUALQUER desses itens estiver ausente ou inconsistente, o comprovante é FALSO.', 'severity': 'blue'});
    }

    // ═══════════════════════════════════════════
    // 3. ANÁLISE DA DISPUTA (QUEM ABRIU E POR QUÊ)
    // ═══════════════════════════════════════════
    final isNoResponse = disputeReason.contains('não respondeu') || 
        disputeReason.contains('no_response') ||
        disputeReason.contains('provider_no_response') ||
        disputeReason.contains('Provedor não respondeu');
    
    final isPaymentIssue = disputeReason.contains('pagamento') ||
        disputeReason.contains('payment') ||
        disputeReason.contains('não receb') ||
        disputeReason.contains('not_received') ||
        disputeReason.contains('valor') ||
        disputeReason.contains('falso') ||
        disputeReason.contains('fake');

    if (disputeOpenedBy == 'user') {
      if (isNoResponse) {
        score -= 0.20;
        findings.add({'icon': '🔴', 'text': 'Usuário relata que provedor NÃO RESPONDEU — abandono de ordem pelo provedor. Sats do escrow devem retornar ao usuário.', 'severity': 'red'});
      } else if (isPaymentIssue && !proofHasValidE2e) {
        score -= 0.15;
        findings.add({'icon': '🔴', 'text': 'Usuário contesta o pagamento E provedor não tem prova verificável (E2E) — evidência favorece o usuário', 'severity': 'red'});
      } else if (isPaymentIssue && proofHasValidE2e) {
        findings.add({'icon': '🔵', 'text': 'Usuário contesta o pagamento, mas provedor tem E2E válido — verificar se valores e datas conferem', 'severity': 'blue'});
      } else {
        findings.add({'icon': '🔵', 'text': 'Disputa aberta pelo usuário — analisar evidências do provedor', 'severity': 'blue'});
      }
    } else if (disputeOpenedBy == 'provider') {
      if (hasUserEvidence) {
        score -= 0.10;
        findings.add({'icon': '🟠', 'text': 'Provedor abriu disputa mas o usuário já enviou evidência — analisar consistência', 'severity': 'yellow'});
      } else {
        findings.add({'icon': '🔵', 'text': 'Provedor abriu disputa — verificar se tem comprovante/E2E para justificar', 'severity': 'blue'});
      }
    }

    // Descrição da disputa
    if (disputeDescription.length >= 80) {
      findings.add({'icon': '🔵', 'text': 'Descrição detalhada (${disputeDescription.length} caracteres)', 'severity': 'blue'});
    } else if (disputeDescription.length < 20 && disputeOpenedBy == 'provider') {
      score -= 0.05;
      findings.add({'icon': '🟡', 'text': 'Provedor abriu disputa com descrição muito curta (${disputeDescription.length} caracteres) — pouca justificativa', 'severity': 'yellow'});
    }

    // ═══════════════════════════════════════════
    // 4. ANÁLISE DE EVIDÊNCIAS DAS PARTES
    // ═══════════════════════════════════════════
    if (_allEvidence.isNotEmpty) {
      final userEvidences = _allEvidence.where((e) => e['senderRole'] == 'user').toList();
      final providerEvidences = _allEvidence.where((e) => e['senderRole'] == 'provider').toList();
      
      if (userEvidences.isNotEmpty && providerEvidences.isEmpty) {
        score -= 0.10;
        findings.add({'icon': '🔴', 'text': 'Usuário enviou ${userEvidences.length} evidência(s) durante a disputa, provedor NÃO enviou nenhuma — provedor não se defendeu', 'severity': 'red'});
      } else if (providerEvidences.isNotEmpty && userEvidences.isEmpty) {
        // Provedor enviou evidência extra, mas sem E2E ainda não vale muito
        if (proofHasValidE2e) {
          score += 0.05;
          findings.add({'icon': '🟢', 'text': 'Provedor enviou ${providerEvidences.length} evidência(s) extra — reforça defesa com E2E válido', 'severity': 'green'});
        } else {
          findings.add({'icon': '🟡', 'text': 'Provedor enviou ${providerEvidences.length} evidência(s) extra mas sem E2E válido — imagens adicionais não substituem prova de transação', 'severity': 'yellow'});
        }
      } else if (userEvidences.isNotEmpty && providerEvidences.isNotEmpty) {
        findings.add({'icon': '🔵', 'text': 'Ambas as partes enviaram evidências (${userEvidences.length} do usuário, ${providerEvidences.length} do provedor)', 'severity': 'blue'});
      }
    } else if (!_loadingEvidence) {
      findings.add({'icon': '🟡', 'text': 'Nenhuma evidência adicional enviada pelas partes durante a disputa', 'severity': 'yellow'});
    }

    // ═══════════════════════════════════════════
    // 5. HISTÓRICO DE REINCIDÊNCIA
    // ═══════════════════════════════════════════
    if (_userDisputeLosses >= 3) {
      score += 0.10;
      findings.add({'icon': '🔴', 'text': '⚠️ Usuário REINCIDENTE: $_userDisputeLosses disputas perdidas — perfil de risco alto', 'severity': 'red'});
    } else if (_userDisputeLosses >= 1) {
      score += 0.03;
      findings.add({'icon': '🟡', 'text': 'Usuário perdeu $_userDisputeLosses disputa(s) anteriormente', 'severity': 'yellow'});
    }
    if (_providerDisputeLosses >= 3) {
      score -= 0.15;
      findings.add({'icon': '🔴', 'text': '⚠️ Provedor REINCIDENTE: $_providerDisputeLosses disputas perdidas — perfil de GOLPISTA', 'severity': 'red'});
    } else if (_providerDisputeLosses >= 1) {
      score -= 0.05;
      findings.add({'icon': '🟡', 'text': 'Provedor perdeu $_providerDisputeLosses disputa(s) anteriormente', 'severity': 'yellow'});
    }

    // ═══════════════════════════════════════════
    // 6. CRUZAMENTO DE VALORES
    // ═══════════════════════════════════════════
    final brl = amountBrl;
    final sats = amountSats;
    if (brl != null && sats != null) {
      final brlVal = double.tryParse(brl.toString()) ?? 0;
      final satsVal = double.tryParse(sats.toString()) ?? 0;

      if (brlVal > 0 && satsVal > 0) {
        final satsPerBrl = satsVal / brlVal;
        if (satsPerBrl < 50 || satsPerBrl > 10000) {
          score -= 0.05;
          findings.add({'icon': '🟡', 'text': 'Proporção sats/BRL incomum: ${satsPerBrl.toStringAsFixed(0)} sats/R\$ — valores da ordem podem estar incorretos', 'severity': 'yellow'});
        }
      }
      
      if (brlVal == 0 && satsVal == 0) {
        findings.add({'icon': '🟡', 'text': 'Valores da ordem são zero — dados incompletos', 'severity': 'yellow'});
      }
    }

    // ═══════════════════════════════════════════
    // 7. SINAIS COMPOSTOS (cruzamento de red flags)
    // ═══════════════════════════════════════════
    if (isPix && proofImageExists && (proofMissingE2e || proofHasInvalidE2e)) {
      // Padrão clássico de golpe: envia imagem mas sem E2E
      score -= 0.15;
      findings.add({'icon': '🚨', 'text': 'PADRÃO SUSPEITO: Provedor enviou imagem de "comprovante" mas sem código E2E verificável. Este é o padrão mais comum de comprovante falso — imagem fabricada ou de outra transação.', 'severity': 'red'});
    }
    if (isPix && proofHasValidE2e && e2eDateMismatch) {
      score -= 0.10;
      findings.add({'icon': '🚨', 'text': 'INCONSISTÊNCIA: E2E existe mas a data não bate com a ordem — possível reutilização de comprovante de outra transação.', 'severity': 'red'});
    }
    if (disputeOpenedBy == 'user' && !proofHasValidE2e && !hasUserEvidence) {
      // Nem usuário nem provedor tem prova forte, mas provedor deveria ter
      findings.add({'icon': '🔵', 'text': 'Nenhuma das partes tem prova verificável, mas o ônus da prova é do PROVEDOR (quem alega ter pago deve provar). Na dúvida, escrow retorna ao usuário.', 'severity': 'blue'});
    }

    // ═══════════════════════════════════════════
    // VEREDITO: Converter score em decisão
    // Limiar baixo: score <= -0.15 já sugere favor do usuário
    // Provedor precisa score >= 0.25 (prova forte) para ganhar
    // ═══════════════════════════════════════════
    String suggestion;
    double confidence;
    String summaryReason;

    final redFlags = findings.where((f) => f['severity'] == 'red').length;
    final greenFlags = findings.where((f) => f['severity'] == 'green').length;

    if (score <= -0.15) {
      suggestion = 'resolved_user';
      confidence = (0.60 + (-score - 0.15) * 0.6).clamp(0.55, 0.95);
      if (redFlags >= 3) {
        summaryReason = '🚨 VEREDITO: Forte indicação de FRAUDE do provedor — $redFlags irregularidades detectadas. Recomenda-se resolver a favor do USUÁRIO.';
      } else {
        summaryReason = '🔍 VEREDITO: Evidências insuficientes ou suspeitas do provedor ($redFlags red flag(s)). Recomenda-se resolver a favor do USUÁRIO.';
      }
    } else if (score >= 0.25) {
      suggestion = 'resolved_provider';
      confidence = (0.60 + (score - 0.25) * 0.5).clamp(0.55, 0.90);
      summaryReason = '🔍 VEREDITO: Provedor apresentou provas verificáveis ($greenFlags indicador(es) positivo(s)). Comprovante e E2E compatíveis com a ordem.';
    } else if (score >= 0.10) {
      suggestion = 'escalate';
      confidence = (0.45 + score * 0.3).clamp(0.40, 0.60);
      summaryReason = '🔍 VEREDITO: Provedor tem evidência parcial mas insuficiente para decisão automática. Revisão detalhada recomendada.';
    } else {
      suggestion = 'escalate';
      confidence = (0.50 + (-score) * 0.3).clamp(0.45, 0.65);
      summaryReason = '🔍 VEREDITO: Evidências pendentes ou contraditórias. Tendência contra o provedor mas requer confirmação do mediador.';
    }

    // Tier
    int tier;
    if (confidence >= 0.90) {
      tier = 1; // AUTO
    } else if (confidence >= 0.60) {
      tier = 2; // SUGGEST
    } else {
      tier = 3; // ESCALATE
    }
    
    return {
      'suggestion': suggestion,
      'confidence': confidence,
      'reason': summaryReason,
      'findings': findings,
      'redFlags': redFlags,
      'greenFlags': greenFlags,
      'score': score,
      'tier': tier,
      'source': 'local_heuristic',
    };
  }

  Widget _buildAgentSuggestion() {
    if (_agentAnalysis == null) return const SizedBox.shrink();

    final confidence = (_agentAnalysis!['confidence'] ?? 0.0) as num;
    final recommendation = _agentAnalysis!['suggestion'] ?? '';
    final reason = _agentAnalysis!['reason'] ?? '';
    final tier = _agentAnalysis!['tier'] ?? 0;
    final isLocal = _agentAnalysis!['source'] == 'local_heuristic';
    final agentLabel = isLocal ? 'Análise Heurística (local)' : 'Sugestão do AI Agent';
    final findings = _agentAnalysis!['findings'] as List<Map<String, dynamic>>?;
    final redFlags = _agentAnalysis!['redFlags'] as int? ?? 0;
    final greenFlags = _agentAnalysis!['greenFlags'] as int? ?? 0;

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
              Expanded(
                child: Text(
                  agentLabel,
                  style: const TextStyle(
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
          // Botão re-analisar (roda heurística novamente com dados atualizados)
          if (isLocal) ...[  
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  final updated = _runLocalHeuristics();
                  if (updated != null && mounted) {
                    setState(() => _agentAnalysis = updated);
                  }
                },
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Reanalisar com dados atuais', style: TextStyle(fontSize: 12)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.purple,
                  side: const BorderSide(color: Colors.purple),
                  padding: const EdgeInsets.symmetric(vertical: 6),
                ),
              ),
            ),
          ],
          // Mostrar indicadores resumidos
          if (redFlags > 0 || greenFlags > 0) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                if (redFlags > 0) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('🔴 $redFlags red flag${redFlags > 1 ? 's' : ''}',
                      style: const TextStyle(color: Colors.redAccent, fontSize: 11)),
                  ),
                  const SizedBox(width: 6),
                ],
                if (greenFlags > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.green.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('🟢 $greenFlags ok',
                      style: const TextStyle(color: Colors.greenAccent, fontSize: 11)),
                  ),
              ],
            ),
          ],
          // Mostrar findings detalhados
          if (findings != null && findings.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Divider(color: Colors.white12),
            const SizedBox(height: 6),
            const Text('Relatório de Investigação:',
              style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            ...findings.map((f) {
              final severity = f['severity'] as String? ?? 'yellow';
              Color textColor;
              switch (severity) {
                case 'red': textColor = Colors.redAccent; break;
                case 'green': textColor = Colors.greenAccent; break;
                case 'blue': textColor = Colors.lightBlueAccent; break;
                default: textColor = Colors.amber;
              }
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(f['icon'] as String? ?? '•', style: const TextStyle(fontSize: 11)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        f['text'] as String? ?? '',
                        style: TextStyle(color: textColor, fontSize: 11, height: 1.3),
                      ),
                    ),
                  ],
                ),
              );
            }),
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
  
  /// v338: Botão para admin/mediador pagar o provedor diretamente da sua carteira
  Widget _buildAdminPayProviderButton() {
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: ElevatedButton(
        onPressed: _isAdminPaying ? null : _handleAdminPayProvider,
        style: ElevatedButton.styleFrom(
          backgroundColor: _isAdminPaying ? Colors.grey : const Color(0xFFFF6B6B),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: _isAdminPaying
            ? const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                  SizedBox(width: 10),
                  Text('Pagando provedor...', style: TextStyle(color: Colors.white, fontSize: 15)),
                ],
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.bolt, color: Colors.white, size: 22),
                  const SizedBox(width: 10),
                  Text(
                    '⚡ Pagar Provedor (${amountSats ?? '?'} sats)',
                    style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
      ),
    );
  }

  /// v338: Admin paga o provedor diretamente buscando o invoice do evento COMPLETE
  Future<void> _handleAdminPayProvider() async {
    if (_isAdminPaying) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('⚡ Pagar Provedor'),
        content: Text(
          'Você vai pagar ${amountSats ?? '?'} sats ao provedor DA SUA CARTEIRA.\n\n'
          'O invoice será buscado do evento COMPLETE no Nostr.\n\n'
          'Confirmar?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF6B6B)),
            child: const Text('Pagar'),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    setState(() => _isAdminPaying = true);

    try {
      // 1. Buscar providerInvoice do evento COMPLETE no Nostr
      final nostrService = NostrOrderService();
      String? providerInvoice;

      broLog('🔍 [AdminPay] Buscando invoice do provedor para ordem ${orderId.substring(0, 8)}...');
      final completeData = await nostrService.fetchOrderCompleteEvent(orderId);
      if (!mounted) return;
      if (completeData != null) {
        providerInvoice = completeData['providerInvoice'] as String?;
      }

      if (providerInvoice == null || providerInvoice.isEmpty) {
        broLog('❌ [AdminPay] providerInvoice não encontrado no Nostr!');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('❌ Invoice do provedor não encontrado no Nostr. O provedor precisa gerar um novo invoice.'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 5),
            ),
          );
          setState(() => _isAdminPaying = false);
        }
        return;
      }

      broLog('✅ [AdminPay] Invoice encontrado: ${providerInvoice.substring(0, 30)}...');

      // 2. Pagar via Breez Spark ou Liquid (carteira do admin)
      final breezProvider = context.read<BreezProvider>();
      final liquidProvider = context.read<BreezLiquidProvider>();
      bool paymentSuccess = false;
      String paymentError = '';

      if (!breezProvider.isInitialized && !liquidProvider.isInitialized) {
        paymentError = 'Carteira não inicializada. Abra sua carteira primeiro.';
      } else {
        for (int attempt = 1; attempt <= 3; attempt++) {
          try {
            Map<String, dynamic>? payResult;
            String usedBackend = 'none';

            if (breezProvider.isInitialized) {
              broLog('⚡ [AdminPay] Tentativa $attempt/3: Pagando via Spark...');
              payResult = await breezProvider.payInvoice(providerInvoice).timeout(
                const Duration(seconds: 30),
                onTimeout: () => {'success': false, 'error': 'timeout'},
              );
              usedBackend = 'Spark';
            } else if (liquidProvider.isInitialized) {
              broLog('⚡ [AdminPay] Tentativa $attempt/3: Pagando via Liquid...');
              payResult = await liquidProvider.payInvoice(providerInvoice).timeout(
                const Duration(seconds: 30),
                onTimeout: () => {'success': false, 'error': 'timeout'},
              );
              usedBackend = 'Liquid';
            }

            if (payResult != null && payResult['success'] == true) {
              broLog('✅ [AdminPay] Pago com sucesso via $usedBackend na tentativa $attempt!');
              paymentSuccess = true;
              break;
            } else {
              paymentError = payResult?['error']?.toString() ?? 'Falha desconhecida';
              broLog('⚠️ [AdminPay] Tentativa $attempt falhou: $paymentError');
            }
          } catch (e) {
            paymentError = e.toString();
            broLog('⚠️ [AdminPay] Tentativa $attempt erro: $paymentError');
          }
          if (attempt < 3) await Future.delayed(const Duration(seconds: 2));
        }
      }

      if (!mounted) return;
      if (!paymentSuccess) {
        broLog('❌ [AdminPay] Pagamento FALHOU: $paymentError');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('❌ Pagamento falhou: $paymentError'),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 6),
            ),
          );
        }
      } else {
        // 3. Gerar invoice de reembolso para o admin receber do usuário
        String? adminReimbursementInvoice;
        final satsAmount = int.tryParse(amountSats?.toString() ?? '') ?? 0;
        
        if (satsAmount > 0) {
          broLog('🧾 [AdminPay] Gerando invoice de reembolso ($satsAmount sats)...');
          try {
            Map<String, dynamic>? invoiceResult;
            if (breezProvider.isInitialized) {
              invoiceResult = await breezProvider.createInvoice(
                amountSats: satsAmount,
                description: 'Bro reembolso admin - ordem ${orderId.substring(0, 8)}',
              );
            } else if (liquidProvider.isInitialized) {
              invoiceResult = await liquidProvider.createInvoice(
                amountSats: satsAmount,
                description: 'Bro reembolso admin - ordem ${orderId.substring(0, 8)}',
              );
            }
            
            if (invoiceResult != null && invoiceResult['success'] == true) {
              adminReimbursementInvoice = (invoiceResult['bolt11'] ?? invoiceResult['invoice']) as String?;
              if (adminReimbursementInvoice != null) {
                broLog('✅ [AdminPay] Invoice de reembolso gerado: ${adminReimbursementInvoice.substring(0, 30)}...');
                
                // Publicar no Nostr para o usuário encontrar
                final orderProvider = context.read<OrderProvider>();
                final privateKey = orderProvider.nostrPrivateKey;
                if (privateKey != null) {
                  final published = await nostrService.publishAdminReimbursementInvoice(
                    privateKey: privateKey,
                    orderId: orderId,
                    adminInvoice: adminReimbursementInvoice,
                    amountSats: satsAmount,
                    userPubkey: userPubkey,
                  );
                  if (published) {
                    broLog('✅ [AdminPay] Invoice de reembolso publicado no Nostr');
                  } else {
                    broLog('⚠️ [AdminPay] Falha ao publicar invoice de reembolso');
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('⚠️ Invoice de reembolso não publicado. Tente novamente.'),
                          backgroundColor: Colors.orange,
                          duration: Duration(seconds: 5),
                        ),
                      );
                    }
                  }
                }
              }
            }
          } catch (e) {
            broLog('⚠️ [AdminPay] Erro ao gerar invoice de reembolso: $e');
          }
        }

        // 4. Marcar pagamento no metadata local da ordem
        final orderProvider = context.read<OrderProvider>();
        final order = orderProvider.getOrderById(orderId);
        if (order != null) {
          orderProvider.updateOrderMetadataLocal(orderId, {
            ...?order.metadata,
            'disputeProviderPaid': true,
            'disputeProviderPaidAt': DateTime.now().toIso8601String(),
            'disputeProviderPaidBy': 'admin',
            if (adminReimbursementInvoice != null)
              'adminReimbursementInvoice': adminReimbursementInvoice,
          });
        }

        setState(() => _adminPaidProvider = true);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(adminReimbursementInvoice != null
                ? '✅ Provedor pago! Invoice de reembolso publicado — o usuário pagará automaticamente.'
                : '✅ Provedor pago com sucesso!'),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 5),
            ),
          );
        }
      }
    } catch (e) {
      broLog('❌ [AdminPay] Erro geral: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro: $e'), backgroundColor: Colors.red),
        );
      }
    }

    if (mounted) setState(() => _isAdminPaying = false);
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
      //    Timeout de 20s para não travar a tela
      bool published = false;
      broLog('🔄 _executeResolution: orderId=$orderId resolution=$resolution userPubkey=${userPubkey.isNotEmpty ? userPubkey.substring(0, 8) : "EMPTY"} providerId=${providerId.isNotEmpty ? providerId.substring(0, 8) : "EMPTY"}');
      try {
        published = await nostrService.publishDisputeResolution(
          privateKey: privateKey,
          orderId: orderId,
          resolution: resolution,
          notes: message,
          userPubkey: userPubkey,
          providerId: providerId,
        ).timeout(const Duration(seconds: 20), onTimeout: () => false);
      } catch (e) {
        broLog('⚠️ publishDisputeResolution timeout/erro: $e');
      }
      
      // 2. Atualizar status da ordem localmente E publicar no Nostr
      final newStatus = resolution == 'resolved_user' ? 'cancelled' : 'completed';
      try {
        // Primeiro: atualizar local
        orderProvider.updateOrderStatusLocalOnly(orderId: orderId, status: newStatus);
        broLog('✅ Status local da ordem atualizado para $newStatus');
        
        // Segundo: publicar status update no Nostr (kind 30080) para a outra parte receber
        try {
          final nostrPublished = await nostrService.updateOrderStatus(
            privateKey: privateKey,
            orderId: orderId,
            newStatus: newStatus,
            providerId: providerId.isNotEmpty ? providerId : null,
            orderUserPubkey: userPubkey.isNotEmpty ? userPubkey : null,
          ).timeout(const Duration(seconds: 15), onTimeout: () => false);
          if (nostrPublished) {
            broLog('✅ Status $newStatus publicado no Nostr para ${orderId.substring(0, 8)}');
            published = published || true; // Se ao menos o status update publicou, contar como sucesso
          } else {
            broLog('⚠️ Falha ao publicar status $newStatus no Nostr');
          }
        } catch (e2) {
          broLog('⚠️ Erro ao publicar status no Nostr: $e2');
        }
      } catch (e) {
        broLog('⚠️ Erro ao atualizar status local: $e');
      }
      
      // 3. Persistir resolução localmente (não depende do relay)
      await StorageService().markDisputeResolved(orderId, resolution);
      
      // 4. Atualizar UI IMEDIATAMENTE — não esperar notificações
      if (mounted) {
        setState(() {
          _isResolved = true;
          _resolvedDirection = resolution;
          _isLoading = false;
        });
        
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
      
      // 5. Enviar notificações em background (fire-and-forget, não trava a UI)
      final resolutionMsg = '⚖️ RESOLUÇÃO DA DISPUTA\n\n'
        'Ordem: ${orderId.length > 8 ? orderId.substring(0, 8) : orderId}...\n'
        'Decisão: ${resolution == 'resolved_user' ? 'A favor do USUÁRIO' : 'A favor do PROVEDOR'}\n\n'
        '$message\n\n'
        'Status atualizado para: ${newStatus == 'cancelled' ? 'Cancelada' : 'Concluída'}';
      
      // Fire-and-forget: mensagens e DMs com timeout individual
      _sendResolutionNotifications(nostrService, privateKey, resolutionMsg);
      
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted && _isLoading) {
        setState(() => _isLoading = false);
      }
    }
  }
  
  /// Envia notificações de resolução em background (não trava a UI)
  Future<void> _sendResolutionNotifications(
    NostrOrderService nostrService, String privateKey, String resolutionMsg,
  ) async {
    try {
      await nostrService.publishMediatorMessage(
        privateKey: privateKey,
        orderId: orderId,
        message: resolutionMsg,
        target: 'both',
        userPubkey: userPubkey,
        providerId: providerId,
      ).timeout(const Duration(seconds: 15), onTimeout: () => false);
    } catch (e) {
      broLog('⚠️ Erro ao enviar mensagem de resolução: $e');
    }
    
    // DMs NIP-04 para as partes
    try {
      if (userPubkey.isNotEmpty) {
        await nostrService.sendAdminNip04DM(
          adminPrivateKey: privateKey,
          recipientPubkey: userPubkey,
          message: '⚖️ [Bro Mediação] $resolutionMsg',
        ).timeout(const Duration(seconds: 15), onTimeout: () => false);
      }
    } catch (e) {
      broLog('⚠️ DM para usuário falhou: $e');
    }
    
    try {
      if (providerId.isNotEmpty) {
        await nostrService.sendAdminNip04DM(
          adminPrivateKey: privateKey,
          recipientPubkey: providerId,
          message: '⚖️ [Bro Mediação] $resolutionMsg',
        ).timeout(const Duration(seconds: 15), onTimeout: () => false);
      }
    } catch (e) {
      broLog('⚠️ DM para provedor falhou: $e');
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
