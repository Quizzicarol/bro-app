import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'dart:convert';
import '../services/platform_fee_service.dart';
import '../services/dispute_service.dart';
import '../services/nostr_order_service.dart';
import '../providers/order_provider.dart';
import '../config.dart';
import 'dispute_detail_screen.dart';

/// Tela de administração MASTER - Taxas da Plataforma + Disputas
/// ACESSO RESTRITO - Protegida por senha de administrador
/// 
/// Para acessar: Na tela de Settings, toque no logo "Versão" e digite a senha
/// 
/// Esta tela mostra:
/// - Total de taxas coletadas (2% de cada transação)
/// - Histórico de transações
/// - Disputas abertas com arbitragem
/// - Opção para exportar dados
class PlatformAdminScreen extends StatefulWidget {
  const PlatformAdminScreen({Key? key}) : super(key: key);

  @override
  State<PlatformAdminScreen> createState() => _PlatformAdminScreenState();
}

class _PlatformAdminScreenState extends State<PlatformAdminScreen> {
  Map<String, dynamic>? _totals;
  List<Map<String, dynamic>> _pendingRecords = [];
  bool _isLoading = true;
  bool _isTesting = false;
  
  // Disputas
  final DisputeService _disputeService = DisputeService();
  List<Dispute> _openDisputes = [];
  List<Dispute> _allDisputes = [];
  
  // Disputas do Nostr (visíveis de qualquer dispositivo)
  List<Map<String, dynamic>> _nostrDisputes = [];      // Abertas
  List<Map<String, dynamic>> _resolvedNostrDisputes = []; // Resolvidas
  bool _showResolved = false; // Toggle: false = abertas, true = resolvidas

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    
    try {
      final totals = await PlatformFeeService.getHistoricalTotals();
      final pending = await PlatformFeeService.getPendingFees();
      
      // Carregar disputas locais
      await _disputeService.initialize();
      final openDisputes = _disputeService.getOpenDisputes();
      final allDisputes = _disputeService.getAllDisputes();
      
      // Carregar disputas do Nostr (de qualquer dispositivo)
      List<Map<String, dynamic>> nostrDisputes = [];
      try {
        final nostrOrderService = NostrOrderService();
        final rawEvents = await nostrOrderService.fetchDisputeNotifications()
            .timeout(const Duration(seconds: 10), onTimeout: () => <Map<String, dynamic>>[]);
        
        // Deduplicar por orderId (manter o mais completo/recente)
        final disputesByOrderId = <String, Map<String, dynamic>>{};
        
        for (final event in rawEvents) {
          try {
            final content = event['parsedContent'] ?? jsonDecode(event['content']);
            final eventKind = event['kind'] as int?;
            String orderId;
            Map<String, dynamic> disputeData;
            
            if (eventKind == 1 && content['type'] == 'bro_dispute') {
              // Kind 1: notificação explícita de disputa (tem dados completos)
              orderId = content['orderId'] as String? ?? '';
              disputeData = {
                'orderId': orderId,
                'reason': content['reason'] ?? 'Não informado',
                'description': content['description'] ?? '',
                'openedBy': content['openedBy'] ?? 'user',
                'userPubkey': content['userPubkey'] ?? event['pubkey'] ?? '',
                'amount_brl': content['amount_brl'],
                'amount_sats': content['amount_sats'],
                'payment_type': content['payment_type'],
                'pix_key': content['pix_key'],
                'provider_id': content['provider_id'],
                'previous_status': content['previous_status'],
                'createdAt': content['createdAt'] ?? DateTime.fromMillisecondsSinceEpoch(
                  ((event['created_at'] ?? 0) as int) * 1000,
                ).toIso8601String(),
                'eventId': event['id'],
                'source': 'kind1',
              };
            } else if (content['status'] == 'disputed') {
              // Kind 30080: status update de disputa (pode não ter razão/descrição)
              orderId = content['orderId'] as String? ?? '';
              disputeData = {
                'orderId': orderId,
                'reason': content['reason'] ?? 'Disputa via status update',
                'description': content['description'] ?? '',
                'openedBy': content['userPubkey'] != null ? 'user' : 'provider',
                'userPubkey': content['userPubkey'] ?? event['pubkey'] ?? '',
                'amount_brl': content['amount_brl'],
                'amount_sats': content['amount_sats'],
                'payment_type': content['payment_type'],
                'pix_key': content['pix_key'],
                'provider_id': content['providerId'] ?? content['provider_id'],
                'previous_status': null,
                'createdAt': content['updatedAt'] ?? DateTime.fromMillisecondsSinceEpoch(
                  ((event['created_at'] ?? 0) as int) * 1000,
                ).toIso8601String(),
                'eventId': event['id'],
                'source': 'kind30080',
              };
            } else {
              continue;
            }
            
            if (orderId.isEmpty) continue;
            
            // Verificar se já existe como disputa local
            final existsLocally = allDisputes.any((d) => d.orderId == orderId);
            disputeData['existsLocally'] = existsLocally;
            
            // Priorizar kind 1 (dados mais completos) sobre kind 30080
            final existing = disputesByOrderId[orderId];
            if (existing == null || (existing['source'] == 'kind30080' && disputeData['source'] == 'kind1')) {
              disputesByOrderId[orderId] = disputeData;
            }
          } catch (_) {}
        }
        
        nostrDisputes = disputesByOrderId.values.toList();
        
        // CORREÇÃO build 218: Buscar disputas abertas e resoluções EM PARALELO
        // Problema: após resolução, o relay pode não retornar mais o evento original de disputa.
        // Solução: buscar resoluções diretamente (bro-resolucao) para popular aba "Resolvidas"
        // mesmo quando o evento original sumiu.
        final openNostr = <Map<String, dynamic>>[];
        final resolvedNostr = <Map<String, dynamic>>[];
        final resolvedOrderIds = <String>{};
        
        // 1. Buscar TODAS as resoluções diretamente do Nostr
        List<Map<String, dynamic>> allResolutions = [];
        try {
          allResolutions = await nostrOrderService.fetchAllDisputeResolutions()
              .timeout(const Duration(seconds: 10), onTimeout: () => <Map<String, dynamic>>[]);
        } catch (_) {}
        
        // 2. Indexar resoluções por orderId
        final resolutionsByOrderId = <String, Map<String, dynamic>>{};
        for (final res in allResolutions) {
          final orderId = res['orderId'] as String? ?? '';
          if (orderId.isNotEmpty) {
            resolutionsByOrderId[orderId] = res;
          }
        }
        
        // 3. Classificar disputas do fetch em abertas/resolvidas
        for (final dispute in nostrDisputes) {
          final dOrderId = dispute['orderId'] as String? ?? '';
          final resolution = resolutionsByOrderId[dOrderId];
          if (resolution != null) {
            dispute['resolution'] = resolution;
            dispute['resolved'] = true;
            resolvedNostr.add(dispute);
            resolvedOrderIds.add(dOrderId);
          } else {
            dispute['resolved'] = false;
            openNostr.add(dispute);
          }
        }
        
        // 4. CRÍTICO: Adicionar resoluções cujo evento original de disputa NÃO foi retornado
        // Isso garante que disputas resolvidas apareçam mesmo quando o relay limpa o evento original
        for (final res in allResolutions) {
          final orderId = res['orderId'] as String? ?? '';
          if (orderId.isEmpty || resolvedOrderIds.contains(orderId)) continue;
          
          // Reconstruir entrada de disputa a partir dos dados da resolução
          resolvedNostr.add({
            'orderId': orderId,
            'userPubkey': res['userPubkey'] ?? '',
            'providerId': res['providerId'] ?? '',
            'reason': res['notes'] ?? '',
            'createdAt': res['resolvedAt'] ?? '',
            'resolution': res,
            'resolved': true,
            'source': 'resolution_only',
          });
          resolvedOrderIds.add(orderId);
        }
        
        // Ordenar por data (mais recentes primeiro)
        openNostr.sort((a, b) => (b['createdAt'] ?? '').compareTo(a['createdAt'] ?? ''));
        resolvedNostr.sort((a, b) => (b['createdAt'] ?? '').compareTo(a['createdAt'] ?? ''));
        
        nostrDisputes = openNostr;
        
        debugPrint('📋 Admin: ${openNostr.length} abertas, ${resolvedNostr.length} resolvidas (Nostr), ${allDisputes.length} locais');
      
        setState(() {
          _totals = totals;
          _pendingRecords = pending;
          _openDisputes = openDisputes;
          _allDisputes = allDisputes;
          _nostrDisputes = openNostr;
          _resolvedNostrDisputes = resolvedNostr;
        });
      } catch (e) {
        debugPrint('⚠️ Erro ao buscar disputas do Nostr: $e');
        setState(() {
          _totals = totals;
          _pendingRecords = pending;
          _openDisputes = openDisputes;
          _allDisputes = allDisputes;
        });
      }
    } catch (e) {
      debugPrint('Erro ao carregar dados: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label copiado!'),
        backgroundColor: Colors.green,
      ),
    );
  }

  Future<void> _exportData() async {
    try {
      final json = await PlatformFeeService.exportToJson();
      _copyToClipboard(json, 'Dados exportados');
      
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Dados Exportados'),
            content: SingleChildScrollView(
              child: SelectableText(
                json,
                style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Fechar'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erro: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _markAllCollected() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirmar'),
        content: Text(
          'Marcar ${_pendingRecords.length} taxas como coletadas?\n\n'
          'Faça isso APENAS após transferir os fundos para sua carteira.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            child: const Text('Confirmar'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      final count = await PlatformFeeService.markAllAsCollected();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$count taxas marcadas como coletadas'),
          backgroundColor: Colors.green,
        ),
      );
      _loadData();
    }
  }

  Future<void> _testPlatformFee() async {
    setState(() => _isTesting = true);
    
    try {
      debugPrint('🧪 Testando envio de taxa da plataforma...');
      debugPrint('📍 Destino: ${AppConfig.platformLightningAddress}');
      
      final result = await PlatformFeeService.sendPlatformFee(
        orderId: 'test_${DateTime.now().millisecondsSinceEpoch}',
        totalSats: 50, // 2% de 50 = 1 sat
      );
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result ? '✅ Taxa enviada com sucesso para ${AppConfig.platformLightningAddress}!' : '❌ Falha - verifique logs'),
            backgroundColor: result ? Colors.green : Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
        
        // Recarregar para mostrar novos dados
        await _loadData();
      }
    } catch (e) {
      debugPrint('❌ Erro no teste: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ Erro: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isTesting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Row(
          children: [
            Icon(Icons.admin_panel_settings, color: Colors.amber),
            SizedBox(width: 8),
            Text('Platform Admin', style: TextStyle(color: Colors.white)),
          ],
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: _loadData,
          ),
          IconButton(
            icon: const Icon(Icons.download, color: Colors.white),
            onPressed: _exportData,
            tooltip: 'Exportar dados',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(Colors.amber),
              ),
            )
          : RefreshIndicator(
              onRefresh: _loadData,
              color: Colors.amber,
              child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Aviso de segurança
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.red.withOpacity(0.3)),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.security, color: Colors.red, size: 20),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'ÁREA RESTRITA - Dados sensíveis da plataforma',
                            style: TextStyle(color: Colors.red, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Card de Totais
                  _buildTotalsCard(),
                  const SizedBox(height: 24),

                  // DISPUTAS ABERTAS
                  _buildDisputesSection(),
                  const SizedBox(height: 24),

                  // Endereços para receber
                  _buildReceiveAddressesCard(),
                  const SizedBox(height: 24),

                  // Taxas pendentes
                  _buildPendingFeesCard(),
                  const SizedBox(height: 24),
                  
                  // Recalcular taxas
                  _buildRecalculateFeesCard(),
                  const SizedBox(height: 24),

                  // Histórico
                  _buildHistorySection(),
                ],
              ),
            ),
          ),
    );
  }

  Widget _buildTotalsCard() {
    final totalSats = _totals?['totalSats'] ?? 0;
    final pendingSats = _totals?['pendingSats'] ?? 0;
    final collectedSats = _totals?['collectedSats'] ?? 0;
    final totalBrl = _totals?['totalBrl'] ?? 0.0;
    final pendingBrl = _totals?['pendingBrl'] ?? 0.0;
    final totalTx = _totals?['totalTransactions'] ?? 0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1A1A2E), Color(0xFF16213E)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.amber.withOpacity(0.3)),
      ),
      child: Column(
        children: [
          // Status do modo
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.green.withOpacity(0.2),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.green.withOpacity(0.5)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle, color: Colors.green, size: 16),
                SizedBox(width: 6),
                Text(
                  'COLETA AUTOMÁTICA ATIVA',
                  style: TextStyle(color: Colors.green, fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${(AppConfig.platformFeePercent * 100).toStringAsFixed(0)}% de cada transação é enviado automaticamente\npara ${AppConfig.platformLightningAddress}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white38, fontSize: 10),
          ),
          const SizedBox(height: 16),
          Text(
            '💰 TAXAS DA PLATAFORMA (${(AppConfig.platformFeePercent * 100).toStringAsFixed(0)}%)',
            style: const TextStyle(
              color: Colors.amber,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 20),
          
          // Total Histórico
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Total Histórico:', style: TextStyle(color: Colors.white70)),
              Text(
                '$totalSats sats',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(
                'R\$ ${totalBrl.toStringAsFixed(2)}',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
          const Divider(color: Colors.white24, height: 24),
          
          // Pendente
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('⏳ Pendente:', style: TextStyle(color: Colors.orange)),
              Text(
                '$pendingSats sats',
                style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold, fontSize: 18),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(
                'R\$ ${pendingBrl.toStringAsFixed(2)}',
                style: const TextStyle(color: Colors.orange, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 8),
          
          // Coletado
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('✅ Coletado:', style: TextStyle(color: Colors.green)),
              Text(
                '$collectedSats sats',
                style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 16),
          
          // Total de transações
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'Total de $totalTx transações processadas',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReceiveAddressesCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF333333)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '📥 Endereços para Receber Taxas',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 16),
          
          // Lightning Address
          const Text('⚡ Lightning Address:', style: TextStyle(color: Colors.white70, fontSize: 12)),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A0A0A),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    AppConfig.platformLightningAddress.isNotEmpty ? AppConfig.platformLightningAddress : 'Não configurado',
                    style: const TextStyle(color: Colors.white, fontFamily: 'monospace'),
                  ),
                ),
              ),
              if (AppConfig.platformLightningAddress.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.copy, color: Colors.amber),
                  onPressed: () => _copyToClipboard(AppConfig.platformLightningAddress, 'Lightning Address'),
                ),
            ],
          ),
          const SizedBox(height: 16),
          
          // Botão de teste
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isTesting ? null : _testPlatformFee,
              icon: _isTesting 
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.send, size: 16),
              label: Text(_isTesting ? 'Enviando...' : 'Testar Envio (1 sat)'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.purple,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPendingFeesCard() {
    final pendingSats = _totals?['pendingSats'] ?? 0;
    
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '⏳ Taxas Pendentes',
                style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold, fontSize: 16),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${_pendingRecords.length}',
                  style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          
          if (_pendingRecords.isEmpty)
            const Center(
              child: Text(
                'Nenhuma taxa pendente 🎉',
                style: TextStyle(color: Colors.white54),
              ),
            )
          else ...[
            // Lista das últimas 5 pendentes
            ...(_pendingRecords.take(5).map((record) => Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF0A0A0A),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Order: ${(record['orderId'] as String).substring(0, 8)}...',
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                      Text(
                        _formatDate(record['timestamp']),
                        style: const TextStyle(color: Colors.white38, fontSize: 10),
                      ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '${record['feeSats']} sats',
                        style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        'R\$ ${(record['feeBrl'] as num).toStringAsFixed(2)}',
                        style: const TextStyle(color: Colors.white54, fontSize: 10),
                      ),
                    ],
                  ),
                ],
              ),
            ))),
            
            if (_pendingRecords.length > 5)
              Center(
                child: Text(
                  '+ ${_pendingRecords.length - 5} mais...',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ),
            
            const SizedBox(height: 16),
            
            // Botão para marcar como coletado
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: pendingSats > 0 ? _markAllCollected : null,
                icon: const Icon(Icons.check_circle, color: Colors.white),
                label: Text(
                  'Marcar $pendingSats sats como coletados',
                  style: const TextStyle(color: Colors.white),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHistorySection() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '📊 Estatísticas',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 16),
          
          _buildStatRow('Total de Transações', '${_totals?['totalTransactions'] ?? 0}'),
          _buildStatRow('Taxa por Transação', '${(AppConfig.platformFeePercent * 100).toStringAsFixed(0)}%'),
          _buildStatRow('Taxa Média', _calculateAverageFee()),
          
          const SizedBox(height: 16),
          
          // Botão de exportar
          OutlinedButton.icon(
            onPressed: _exportData,
            icon: const Icon(Icons.download, color: Colors.amber),
            label: const Text('Exportar Dados Completos', style: TextStyle(color: Colors.amber)),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Colors.amber),
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.white70)),
          Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  String _formatDate(String? timestamp) {
    if (timestamp == null) return '';
    try {
      final date = DateTime.parse(timestamp);
      return '${date.day}/${date.month}/${date.year} ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return timestamp;
    }
  }

  String _calculateAverageFee() {
    final totalTx = _totals?['totalTransactions'] ?? 0;
    final totalSats = _totals?['totalSats'] ?? 0;
    if (totalTx == 0) return '0 sats';
    return '${(totalSats / totalTx).round()} sats';
  }

  // ========== SEÇÃO DE DISPUTAS ==========

  Widget _buildDisputesSection() {
    final openCount = _openDisputes.length + _nostrDisputes.length;
    final resolvedCount = _resolvedNostrDisputes.length + 
        _allDisputes.where((d) => d.status.startsWith('resolved') || d.status == 'cancelled').length;
    final hasAny = openCount > 0 || resolvedCount > 0;
    
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: (!_showResolved && openCount > 0) 
            ? Colors.red.withOpacity(0.5) 
            : const Color(0xFF333333),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Icon(
                Icons.gavel, 
                color: openCount > 0 ? Colors.red : Colors.white54,
                size: 24,
              ),
              const SizedBox(width: 8),
              Text(
                'Disputas',
                style: TextStyle(
                  color: openCount > 0 ? Colors.red : Colors.white,
                  fontWeight: FontWeight.bold, 
                  fontSize: 16,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          
          // Toggle: Abertas / Resolvidas
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _showResolved = false),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: !_showResolved ? Colors.red.withOpacity(0.2) : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: !_showResolved ? Colors.red.withOpacity(0.6) : Colors.white24,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.error_outline, 
                          color: !_showResolved ? Colors.red : Colors.white38, size: 18),
                        const SizedBox(width: 6),
                        Text(
                          'Abertas ($openCount)',
                          style: TextStyle(
                            color: !_showResolved ? Colors.red : Colors.white38,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _showResolved = true),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: _showResolved ? Colors.green.withOpacity(0.2) : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _showResolved ? Colors.green.withOpacity(0.6) : Colors.white24,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.check_circle_outline, 
                          color: _showResolved ? Colors.green : Colors.white38, size: 18),
                        const SizedBox(width: 6),
                        Text(
                          'Resolvidas ($resolvedCount)',
                          style: TextStyle(
                            color: _showResolved ? Colors.green : Colors.white38,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          
          if (!hasAny)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: Column(
                  children: [
                    Icon(Icons.check_circle, color: Colors.green, size: 48),
                    SizedBox(height: 12),
                    Text(
                      'Nenhuma disputa registrada',
                      style: TextStyle(color: Colors.white54),
                    ),
                  ],
                ),
              ),
            )
          else if (!_showResolved) ...[
            // === ABA ABERTAS ===
            if (_nostrDisputes.isEmpty && _openDisputes.isEmpty)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Column(
                    children: [
                      Icon(Icons.check_circle, color: Colors.green, size: 40),
                      SizedBox(height: 8),
                      Text('Nenhuma disputa aberta', style: TextStyle(color: Colors.white54)),
                    ],
                  ),
                ),
              )
            else ...[
              if (_nostrDisputes.isNotEmpty) ...[
                ..._nostrDisputes.map((d) => _buildNostrDisputeCard(d)),
              ],
              if (_openDisputes.isNotEmpty) ...[
                ..._openDisputes.map((d) => _buildDisputeCard(d, isOpen: true)),
              ],
            ],
          ] else ...[
            // === ABA RESOLVIDAS (HISTÓRICO) ===
            if (_resolvedNostrDisputes.isEmpty && _allDisputes.where((d) => d.status.startsWith('resolved') || d.status == 'cancelled').isEmpty)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Column(
                    children: [
                      Icon(Icons.history, color: Colors.white38, size: 40),
                      SizedBox(height: 8),
                      Text('Nenhuma disputa resolvida ainda', style: TextStyle(color: Colors.white54)),
                    ],
                  ),
                ),
              )
            else ...[
              if (_resolvedNostrDisputes.isNotEmpty) ...[
                ..._resolvedNostrDisputes.map((d) => _buildResolvedNostrDisputeCard(d)),
              ],
              if (_allDisputes.where((d) => d.status.startsWith('resolved') || d.status == 'cancelled').isNotEmpty) ...[
                const SizedBox(height: 8),
                ..._allDisputes
                  .where((d) => d.status.startsWith('resolved') || d.status == 'cancelled')
                  .map((d) => _buildDisputeCard(d, isOpen: false)),
              ],
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildDisputeCard(Dispute dispute, {required bool isOpen}) {
    Color statusColor;
    String statusLabel;
    IconData statusIcon;
    
    switch (dispute.status) {
      case 'open':
        statusColor = Colors.red;
        statusLabel = 'Aberta';
        statusIcon = Icons.error;
        break;
      case 'in_review':
        statusColor = Colors.orange;
        statusLabel = 'Em Análise';
        statusIcon = Icons.hourglass_bottom;
        break;
      case 'resolved_user':
        statusColor = Colors.green;
        statusLabel = 'Resolvida (Usuário)';
        statusIcon = Icons.check_circle;
        break;
      case 'resolved_provider':
        statusColor = Colors.green;
        statusLabel = 'Resolvida (Provedor)';
        statusIcon = Icons.check_circle;
        break;
      case 'cancelled':
        statusColor = Colors.grey;
        statusLabel = 'Cancelada';
        statusIcon = Icons.cancel;
        break;
      default:
        statusColor = Colors.white54;
        statusLabel = dispute.status;
        statusIcon = Icons.help;
    }
    
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isOpen ? Colors.red.withOpacity(0.05) : const Color(0xFF0A0A0A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isOpen ? statusColor.withOpacity(0.3) : const Color(0xFF222222),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header com status
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(statusIcon, color: statusColor, size: 18),
                  const SizedBox(width: 6),
                  Text(
                    statusLabel,
                    style: TextStyle(color: statusColor, fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                ],
              ),
              Text(
                _formatDisputeDate(dispute.createdAt),
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 10),
          
          // ID da disputa e ordem
          Row(
            children: [
              const Text('Disputa: ', style: TextStyle(color: Colors.white54, fontSize: 12)),
              Text(
                dispute.id.length > 12 ? '${dispute.id.substring(0, 12)}...' : dispute.id,
                style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              const Text('Ordem: ', style: TextStyle(color: Colors.white54, fontSize: 12)),
              Text(
                dispute.orderId.length > 16 ? '${dispute.orderId.substring(0, 16)}...' : dispute.orderId,
                style: const TextStyle(color: Colors.amber, fontFamily: 'monospace', fontSize: 12),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => _copyToClipboard(dispute.orderId, 'Order ID'),
                child: const Icon(Icons.copy, size: 14, color: Colors.white38),
              ),
            ],
          ),
          const SizedBox(height: 8),
          
          // Aberta por
          Row(
            children: [
              const Text('Aberta por: ', style: TextStyle(color: Colors.white54, fontSize: 12)),
              Icon(
                dispute.openedBy == 'user' ? Icons.person : Icons.storefront,
                color: Colors.white70, size: 16,
              ),
              const SizedBox(width: 4),
              Text(
                dispute.openedBy == 'user' ? 'Usuário' : 'Provedor',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 6),
          
          // Motivo
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.black26,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '📌 ${dispute.reason}',
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                ),
                if (dispute.description.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    dispute.description,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          
          // Resolução (se já resolvida)
          if (dispute.resolution != null) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('✅ Resolução:', style: TextStyle(color: Colors.green, fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(dispute.resolution!, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  if (dispute.mediatorNotes != null) ...[
                    const SizedBox(height: 4),
                    Text('Notas: ${dispute.mediatorNotes}', style: const TextStyle(color: Colors.white54, fontSize: 11, fontStyle: FontStyle.italic)),
                  ],
                ],
              ),
            ),
          ],
          
          // Botões de ação (apenas para disputas abertas)
          if (isOpen) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                // Marcar em análise
                if (dispute.status == 'open')
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: OutlinedButton.icon(
                        onPressed: () => _updateDisputeStatus(dispute, 'in_review'),
                        icon: const Icon(Icons.hourglass_bottom, size: 16),
                        label: const Text('Analisar', style: TextStyle(fontSize: 12)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.orange,
                          side: const BorderSide(color: Colors.orange),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                        ),
                      ),
                    ),
                  ),
                
                // Resolver a favor do usuário
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ElevatedButton.icon(
                      onPressed: () => _showResolveDialog(dispute, 'resolved_user'),
                      icon: const Icon(Icons.person, size: 16, color: Colors.white),
                      label: const FittedBox(
                        child: Text('Usuário', style: TextStyle(fontSize: 12, color: Colors.white)),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue.shade700,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                    ),
                  ),
                ),
                
                // Resolver a favor do provedor
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: ElevatedButton.icon(
                      onPressed: () => _showResolveDialog(dispute, 'resolved_provider'),
                      icon: const Icon(Icons.storefront, size: 16, color: Colors.white),
                      label: const FittedBox(
                        child: Text('Provedor', style: TextStyle(fontSize: 12, color: Colors.white)),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green.shade700,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // Cancelar disputa
            SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: () => _showCancelDisputeDialog(dispute),
                icon: const Icon(Icons.cancel, size: 16),
                label: const Text('Cancelar Disputa', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(foregroundColor: Colors.white38),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _formatDisputeDate(DateTime dt) {
    final day = dt.day.toString().padLeft(2, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final year = dt.year;
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$day/$month/$year $hour:$minute';
  }

  /// Card de disputa recebida via Nostr (de qualquer dispositivo)
  Widget _buildNostrDisputeCard(Map<String, dynamic> dispute) {
    final orderId = dispute['orderId'] as String? ?? '';
    final reason = dispute['reason'] as String? ?? 'Não informado';
    final openedBy = dispute['openedBy'] as String? ?? 'user';
    final amountBrl = dispute['amount_brl'];
    final amountSats = dispute['amount_sats'];
    final createdAtStr = dispute['createdAt'] as String? ?? '';
    final existsLocally = dispute['existsLocally'] as bool? ?? false;
    
    String dateStr = '';
    try {
      final dt = DateTime.parse(createdAtStr);
      dateStr = _formatDisputeDate(dt);
    } catch (_) {
      dateStr = createdAtStr;
    }
    
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => DisputeDetailScreen(dispute: dispute)),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.orange.withOpacity(0.05),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.orange.withOpacity(0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Icon(Icons.gavel, color: Colors.orange, size: 18),
                    const SizedBox(width: 6),
                    Text(
                      existsLocally ? 'Disputa (Nostr + Local)' : 'Disputa (Nostr)',
                      style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                  ],
                ),
                Text(dateStr, style: const TextStyle(color: Colors.white38, fontSize: 11)),
              ],
            ),
            const SizedBox(height: 10),
            
            // Ordem ID
            Row(
              children: [
                const Text('🆔 Ordem: ', style: TextStyle(color: Colors.white54, fontSize: 12)),
                Expanded(
                  child: Text(
                    orderId.length > 20 ? '${orderId.substring(0, 20)}...' : orderId,
                    style: const TextStyle(color: Colors.amber, fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            
            // Aberta por + Valores
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      openedBy == 'user' ? Icons.person : Icons.storefront,
                      color: Colors.white70, size: 16,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      openedBy == 'user' ? 'Usuário' : 'Provedor',
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
                if (amountBrl != null)
                  Text(
                    'R\$ ${amountBrl is num ? amountBrl.toStringAsFixed(2) : amountBrl}',
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            
            // Motivo resumido
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '📌 $reason',
                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            
            // Indicador de toque
            const SizedBox(height: 8),
            const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.touch_app, color: Colors.orange, size: 14),
                SizedBox(width: 4),
                Text('Toque para ver detalhes e mediar', style: TextStyle(color: Colors.orange, fontSize: 11)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Card de disputa resolvida do Nostr (para aba de histórico)
  Widget _buildResolvedNostrDisputeCard(Map<String, dynamic> dispute) {
    final orderId = dispute['orderId'] as String? ?? '';
    final reason = dispute['reason'] as String? ?? 'Não informado';
    final openedBy = dispute['openedBy'] as String? ?? 'user';
    final amountBrl = dispute['amount_brl'];
    final createdAtStr = dispute['createdAt'] as String? ?? '';
    final resolution = dispute['resolution'] as Map<String, dynamic>?;
    
    final resolutionType = resolution?['resolution'] as String? ?? '';
    final resolutionNotes = resolution?['notes'] as String? ?? '';
    final resolvedAtStr = resolution?['resolvedAt'] as String? ?? '';
    
    final isUser = resolutionType == 'resolved_user';
    final resolutionLabel = isUser ? 'Favor do Usuário' : 'Favor do Provedor';
    
    String dateStr = '';
    try {
      final dt = DateTime.parse(createdAtStr);
      dateStr = _formatDisputeDate(dt);
    } catch (_) {
      dateStr = createdAtStr;
    }
    
    String resolvedDateStr = '';
    try {
      if (resolvedAtStr.isNotEmpty) {
        final dt = DateTime.parse(resolvedAtStr);
        resolvedDateStr = _formatDisputeDate(dt);
      }
    } catch (_) {}
    
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => DisputeDetailScreen(dispute: dispute)),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.green.withOpacity(0.05),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.green.withOpacity(0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header com resolução
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Icon(Icons.check_circle, color: Colors.green, size: 18),
                    const SizedBox(width: 6),
                    Text(
                      resolutionLabel,
                      style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                  ],
                ),
                Text(dateStr, style: const TextStyle(color: Colors.white38, fontSize: 11)),
              ],
            ),
            const SizedBox(height: 10),
            
            // Ordem ID
            Row(
              children: [
                const Text('🆔 Ordem: ', style: TextStyle(color: Colors.white54, fontSize: 12)),
                Expanded(
                  child: Text(
                    orderId.length > 20 ? '${orderId.substring(0, 20)}...' : orderId,
                    style: const TextStyle(color: Colors.amber, fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            
            // Aberta por + Valores
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      openedBy == 'user' ? Icons.person : Icons.storefront,
                      color: Colors.white70, size: 16,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      openedBy == 'user' ? 'Usuário' : 'Provedor',
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
                if (amountBrl != null)
                  Text(
                    'R\$ ${amountBrl is num ? amountBrl.toStringAsFixed(2) : amountBrl}',
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            
            // Motivo original
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '📌 $reason',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            
            // Resolução
            if (resolutionNotes.isNotEmpty || resolvedDateStr.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.green.withOpacity(0.2)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.gavel, color: Colors.green, size: 14),
                        const SizedBox(width: 6),
                        Text(
                          'Resolução${resolvedDateStr.isNotEmpty ? ' • $resolvedDateStr' : ''}',
                          style: const TextStyle(color: Colors.green, fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    if (resolutionNotes.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        resolutionNotes,
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ],
            
            // Indicador de toque
            const SizedBox(height: 8),
            const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.touch_app, color: Colors.green, size: 14),
                SizedBox(width: 4),
                Text('Toque para ver detalhes', style: TextStyle(color: Colors.green, fontSize: 11)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Dialog de resolução para disputas vindas do Nostr
  void _showNostrResolveDialog(Map<String, dynamic> dispute, String resolveFor) {
    final notesController = TextEditingController();
    final isUser = resolveFor == 'resolved_user';
    final orderId = dispute['orderId'] as String? ?? '';
    final reason = dispute['reason'] as String? ?? '';
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: Row(
          children: [
            Icon(
              isUser ? Icons.person : Icons.storefront,
              color: isUser ? Colors.blue : Colors.green,
              size: 28,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Resolver a favor do ${isUser ? 'Usuário' : 'Provedor'}',
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Ordem: ${orderId.length > 20 ? '${orderId.substring(0, 20)}...' : orderId}',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              if (reason.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  'Motivo: $reason',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
              const SizedBox(height: 16),
              Text(
                isUser
                  ? '⚠️ Ao resolver a favor do USUÁRIO:\n• O status da ordem será atualizado\n• Os sats podem ser devolvidos ao usuário\n• A resolução será publicada no Nostr'
                  : '⚠️ Ao resolver a favor do PROVEDOR:\n• O status da ordem será atualizado\n• Os sats permanecem com o provedor\n• A resolução será publicada no Nostr',
                style: TextStyle(
                  color: isUser ? Colors.blue.shade200 : Colors.green.shade200,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: notesController,
                maxLines: 3,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Notas do mediador (obrigatório)...',
                  hintStyle: const TextStyle(color: Colors.white38),
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
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () {
              if (notesController.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Adicione notas do mediador'), backgroundColor: Colors.orange),
                );
                return;
              }
              Navigator.pop(context);
              _resolveNostrDispute(dispute, resolveFor, notesController.text.trim());
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: isUser ? Colors.blue : Colors.green,
            ),
            child: const Text('Confirmar Resolução', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  /// Resolve uma disputa vinda do Nostr:
  /// 1. Publica resolução no Nostr (kind 1, tag bro-resolucao)
  /// 2. Atualiza status da ordem local para 'completed'
  /// 3. Recarrega dados
  Future<void> _resolveNostrDispute(Map<String, dynamic> dispute, String resolution, String notes) async {
    try {
      final orderId = dispute['orderId'] as String? ?? '';
      final userPubkey = dispute['userPubkey'] as String? ?? '';
      final providerId = dispute['provider_id'] as String? ?? '';
      
      // Obter chave privada do admin
      final orderProvider = context.read<OrderProvider>();
      final privateKey = orderProvider.nostrPrivateKey;
      
      if (privateKey == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('❌ Chave privada não disponível'), backgroundColor: Colors.red),
          );
        }
        return;
      }
      
      // 1. Publicar resolução no Nostr
      final nostrOrderService = NostrOrderService();
      final published = await nostrOrderService.publishDisputeResolution(
        privateKey: privateKey,
        orderId: orderId,
        resolution: resolution,
        notes: notes,
        userPubkey: userPubkey,
        providerId: providerId,
      );
      
      // 2. Atualizar status da ordem local
      // Se favor do usuário: marcar como 'completed' (usuário tem razão, recebe de volta)
      // Se favor do provedor: marcar como 'completed' (provedor completou o serviço)
      final newOrderStatus = resolution == 'resolved_user' ? 'cancelled' : 'completed';
      try {
        await orderProvider.updateOrderStatus(
          orderId: orderId,
          status: newOrderStatus,
        );
        
        // Publicar o novo status no Nostr
        await nostrOrderService.updateOrderStatus(
          privateKey: privateKey,
          orderId: orderId,
          newStatus: newOrderStatus,
          providerId: providerId.isNotEmpty ? providerId : null,
        );
      } catch (e) {
        debugPrint('⚠️ Erro ao atualizar status da ordem: $e');
      }
      
      // 3. Recarregar dados
      await _loadData();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(published 
              ? '⚖️ Disputa ${orderId.substring(0, 8)} resolvida e publicada no Nostr!'
              : '⚠️ Disputa resolvida localmente mas falhou ao publicar no Nostr'),
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
    }
  }

  Future<void> _updateDisputeStatus(Dispute dispute, String newStatus, {String? resolution, String? notes}) async {
    try {
      await _disputeService.updateDisputeStatus(
        dispute.id, 
        newStatus,
        resolution: resolution,
        mediatorNotes: notes,
      );
      
      // Se resolver, atualizar status da ordem via Nostr
      if (newStatus.startsWith('resolved')) {
        try {
          final orderProvider = context.read<OrderProvider>();
          // Marcar ordem como completada ou cancelada baseado no resultado
          final orderStatus = newStatus == 'resolved_user' ? 'cancelled' : 'completed';
          await orderProvider.updateOrderStatus(
            orderId: dispute.orderId,
            status: orderStatus,
          );
        } catch (e) {
          debugPrint('⚠️ Erro ao atualizar status da ordem: $e');
        }
      }
      
      // Recarregar dados
      await _loadData();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('⚖️ Disputa ${dispute.id.substring(0, 8)} atualizada: $newStatus'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _showResolveDialog(Dispute dispute, String resolveFor) {
    final notesController = TextEditingController();
    final isUser = resolveFor == 'resolved_user';
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: Row(
          children: [
            Icon(
              isUser ? Icons.person : Icons.storefront,
              color: isUser ? Colors.blue : Colors.green,
              size: 28,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Resolver a favor do ${isUser ? 'Usuário' : 'Provedor'}',
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Ordem: ${dispute.orderId.length > 20 ? '${dispute.orderId.substring(0, 20)}...' : dispute.orderId}',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 4),
              Text(
                'Motivo: ${dispute.reason}',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 16),
              Text(
                isUser
                  ? '⚠️ Ao resolver a favor do USUÁRIO:\n• O provedor pode perder garantia colateral\n• Fundos serão liberados ao usuário'
                  : '⚠️ Ao resolver a favor do PROVEDOR:\n• A reclamação do usuário será negada\n• Fundos permanecem com o provedor',
                style: TextStyle(
                  color: isUser ? Colors.blue.shade200 : Colors.green.shade200,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: notesController,
                maxLines: 3,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Notas do mediador (opcional)...',
                  hintStyle: const TextStyle(color: Colors.white38),
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
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              final resolution = isUser
                ? 'Resolvida a favor do usuário pelo administrador'
                : 'Resolvida a favor do provedor pelo administrador';
              _updateDisputeStatus(
                dispute, 
                resolveFor,
                resolution: resolution,
                notes: notesController.text.isNotEmpty ? notesController.text : null,
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: isUser ? Colors.blue : Colors.green,
            ),
            child: Text(
              'Confirmar',
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  void _showCancelDisputeDialog(Dispute dispute) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('Cancelar Disputa', style: TextStyle(color: Colors.white)),
        content: Text(
          'Cancelar a disputa ${dispute.id.substring(0, 8)}...?\n\nIsso marca a disputa como cancelada sem resolução.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Não', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _updateDisputeStatus(dispute, 'cancelled', resolution: 'Cancelada pelo administrador');
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Cancelar Disputa', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  // ========== RECALCULAR TAXAS ==========
  
  Widget _buildRecalculateFeesCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF333333)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.calculate, color: Colors.cyan, size: 24),
              SizedBox(width: 8),
              Text(
                'Recalcular Taxas',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'Recalcula o total de taxas com base em todas as ordens completadas registradas no dispositivo.',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _recalculateFeesFromOrders,
              icon: const Icon(Icons.refresh, size: 18, color: Colors.white),
              label: const Text('Recalcular a partir das Ordens', style: TextStyle(color: Colors.white)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.cyan.shade700,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  Future<void> _recalculateFeesFromOrders() async {
    setState(() => _isLoading = true);
    
    try {
      final orderProvider = context.read<OrderProvider>();
      final allOrders = orderProvider.orders;
      
      // Filtrar ordens completadas
      final completedOrders = allOrders.where((o) => 
        o.status == 'completed' || o.status == 'liquidated'
      ).toList();
      
      int recordedCount = 0;
      
      for (final order in completedOrders) {
        try {
          // Verificar se já foi registrada
          final existingRecords = await PlatformFeeService.getAllFeeRecords();
          final alreadyRecorded = existingRecords.any((r) => r['orderId'] == order.id);
          
          final amountSats = (order.btcAmount * 100000000).round();
          
          if (!alreadyRecorded && amountSats > 0) {
            await PlatformFeeService.recordFee(
              orderId: order.id,
              transactionBrl: order.amount,
              transactionSats: amountSats,
              providerPubkey: order.providerId ?? 'unknown',
              clientPubkey: order.userPubkey ?? 'unknown',
            );
            recordedCount++;
          }
        } catch (e) {
          debugPrint('Erro ao registrar taxa para ordem ${order.id}: $e');
        }
      }
      
      // Recarregar dados
      await _loadData();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Recalculado! $recordedCount novas taxas registradas de ${completedOrders.length} ordens completadas.'),
            backgroundColor: Colors.green,
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
}
