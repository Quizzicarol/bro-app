import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/platform_fee_service.dart';

/// Tela de administração MASTER - Taxas da Plataforma
/// ACESSO RESTRITO - Apenas para o administrador da plataforma
/// 
/// Para acessar: Na tela de Settings, toque 7 vezes no logo "Versão"
/// 
/// Esta tela mostra:
/// - Total de taxas coletadas (2% de cada transação)
/// - Histórico de transações
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
  
  // Sua Lightning Address para receber as taxas
  // ALTERE PARA SUA LIGHTNING ADDRESS REAL
  static const String platformLightningAddress = 'carol@areabitcoin.com.br';
  
  // Seu endereço Bitcoin on-chain (opcional)
  static const String platformBitcoinAddress = ''; // Preencha se quiser

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
      
      setState(() {
        _totals = totals;
        _pendingRecords = pending;
      });
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
          : SingleChildScrollView(
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

                  // Endereços para receber
                  _buildReceiveAddressesCard(),
                  const SizedBox(height: 24),

                  // Taxas pendentes
                  _buildPendingFeesCard(),
                  const SizedBox(height: 24),

                  // Histórico
                  _buildHistorySection(),
                ],
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
          const Text(
            '💰 TAXAS DA PLATAFORMA (2%)',
            style: TextStyle(
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
                    platformLightningAddress.isNotEmpty ? platformLightningAddress : 'Não configurado',
                    style: const TextStyle(color: Colors.white, fontFamily: 'monospace'),
                  ),
                ),
              ),
              if (platformLightningAddress.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.copy, color: Colors.amber),
                  onPressed: () => _copyToClipboard(platformLightningAddress, 'Lightning Address'),
                ),
            ],
          ),
          const SizedBox(height: 16),
          
          // Instrução
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.blue.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Row(
              children: [
                Icon(Icons.info_outline, color: Colors.blue, size: 16),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Os provedores devem enviar 2% de cada transação para este endereço. '
                    'Configure cobranças automáticas ou colete manualmente.',
                    style: TextStyle(color: Colors.blue, fontSize: 11),
                  ),
                ),
              ],
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
          _buildStatRow('Taxa por Transação', '2%'),
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
}
