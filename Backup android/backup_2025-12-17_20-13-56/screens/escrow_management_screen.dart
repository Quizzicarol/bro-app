import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../services/escrow_service.dart';
import '../services/storage_service.dart';
import '../widgets/gradient_button.dart';

/// Tela de gestão do depósito de garantia (500 BRL)
/// TODO: Implementar integração com backend real de escrow
class EscrowManagementScreen extends StatefulWidget {
  const EscrowManagementScreen({Key? key}) : super(key: key);

  @override
  State<EscrowManagementScreen> createState() => _EscrowManagementScreenState();
}

class _EscrowManagementScreenState extends State<EscrowManagementScreen> {
  final _escrowService = EscrowService();
  final _storageService = StorageService();

  Map<String, dynamic>? _collateral;
  String? _providerId;
  bool _isLoading = true;
  String? _depositInvoice;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    _providerId = await _storageService.getProviderId();
    
    if (_providerId != null) {
      _collateral = await _escrowService.getProviderCollateral(_providerId!);
    }

    setState(() => _isLoading = false);
  }

  Future<void> _createDeposit() async {
    if (_providerId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('⚠️ Você precisa estar no modo provedor'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      // Por enquanto, usar o tier básico
      final result = await _escrowService.depositCollateral(
        tierId: 'basic',
        amountSats: 50000, // ~500 BRL em sats (estimado)
      );

      if (result['invoice'] != null) {
        setState(() {
          _depositInvoice = result['invoice'] as String;
        });
        _showInvoiceDialog();
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ Erro ao criar depósito: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }

    setState(() => _isLoading = false);
  }

  void _showInvoiceDialog() {
    if (_depositInvoice == null) return;
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Pagar Garantia'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Pague esta invoice para ativar o modo provedor:',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            QrImageView(
              data: _depositInvoice!,
              version: QrVersions.auto,
              size: 250,
              backgroundColor: Colors.white,
            ),
            const SizedBox(height: 16),
            const Text(
              '⚠️  Este valor ficará bloqueado como garantia.\n'
              'Você poderá resgatar quando não tiver ordens ativas ou disputas.',
              style: TextStyle(
                fontSize: 12,
                color: Color(0x99FFFFFF),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _loadData(); // Recarregar para verificar se foi pago
            },
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasCollateral = _collateral != null && 
        (_collateral!['available_sats'] as int? ?? 0) > 0;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Gestão de Garantia'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadData,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildStatusCard(hasCollateral),
                    const SizedBox(height: 24),
                    
                    if (!hasCollateral)
                      _buildCreateDepositCard()
                    else
                      _buildActiveDepositCard(),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildStatusCard(bool hasCollateral) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: hasCollateral
              ? [const Color(0xFF4CAF50), const Color(0xFF45A049)]
              : [const Color(0xFFFF6B6B), const Color(0xFFFF8A8A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: hasCollateral
                ? const Color(0xFF4CAF50).withAlpha(77)
                : const Color(0xFFFF6B6B).withAlpha(77),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Icon(
            hasCollateral ? Icons.check_circle : Icons.warning,
            size: 48,
            color: Colors.white,
          ),
          const SizedBox(height: 12),
          Text(
            hasCollateral ? 'Garantia Ativa' : 'Sem Garantia',
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            hasCollateral
                ? 'Você pode aceitar ordens'
                : 'Deposite garantia para começar',
            style: const TextStyle(
              color: Colors.white70,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildCreateDepositCard() {
    return Card(
      color: const Color(0x0DFFFFFF),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Depositar Garantia',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Para se tornar um provedor e aceitar ordens, você precisa '
              'depositar uma garantia em Bitcoin.',
              style: TextStyle(color: Color(0x99FFFFFF)),
            ),
            const SizedBox(height: 16),
            const Text(
              '✅ Você poderá resgatar quando:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            _buildCheckItem('Não tiver ordens ativas'),
            _buildCheckItem('Não tiver disputas em aberto'),
            const SizedBox(height: 16),
            const Text(
              '⚠️  Se houver problemas com pagamentos, a garantia pode ser '
              'usada para compensar o cliente.',
              style: TextStyle(
                color: Color(0xFFFF9800),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 24),
            GradientButton(
              text: 'Depositar Garantia',
              onPressed: _createDeposit,
              icon: Icons.lock,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActiveDepositCard() {
    final availableSats = _collateral?['available_sats'] ?? 0;
    final lockedSats = _collateral?['locked_sats'] ?? 0;

    return Card(
      color: const Color(0x0DFFFFFF),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Depósito Ativo',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF4CAF50),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    'ATIVO',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            
            _buildInfoRow('Disponível', '$availableSats sats'),
            _buildInfoRow('Bloqueado em ordens', '$lockedSats sats'),
            
            const SizedBox(height: 24),
            
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0x1A4CAF50),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF4CAF50)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, color: Color(0xFF4CAF50)),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Garantia ativa! Você pode aceitar ordens.',
                      style: TextStyle(color: Color(0xFF4CAF50)),
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

  Widget _buildCheckItem(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 4),
      child: Row(
        children: [
          const Icon(Icons.check, color: Color(0xFF4CAF50), size: 16),
          const SizedBox(width: 8),
          Text(text, style: const TextStyle(color: Color(0x99FFFFFF))),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(color: Color(0x99FFFFFF)),
          ),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}
