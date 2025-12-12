import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../providers/breez_provider_export.dart';

/// Tela de teste para funcionalidades Lightning (enviar/receber pagamentos)
class LightningTestScreen extends StatefulWidget {
  const LightningTestScreen({Key? key}) : super(key: key);

  @override
  State<LightningTestScreen> createState() => _LightningTestScreenState();
}

class _LightningTestScreenState extends State<LightningTestScreen> {
  final _amountController = TextEditingController(text: '1000');
  final _invoiceController = TextEditingController();
  String? _generatedInvoice;
  String? _paymentResult;
  Map<String, dynamic>? _balance;
  List<Map<String, dynamic>> _payments = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final breez = context.read<BreezProvider>();
    
    // Inicializar SDK se necessário
    if (!breez.isInitialized) {
      await breez.initialize();
    }

    // Carregar saldo e histórico
    final balance = await breez.getBalance();
    final payments = await breez.listPayments();

    if (mounted) {
      setState(() {
        _balance = balance;
        _payments = payments;
      });
    }
  }

  Future<void> _createInvoice() async {
    final breez = context.read<BreezProvider>();
    final amountSats = int.tryParse(_amountController.text) ?? 1000;

    final result = await breez.createInvoice(
      amountSats: amountSats,
      description: 'Teste Paga Conta',
    );

    if (result?['success'] == true) {
      setState(() {
        _generatedInvoice = result!['invoice'];
        _paymentResult = null;
      });
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ Invoice criada! Copie ou mostre o QR code')),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ Erro: ${result?['error']}')),
        );
      }
    }
  }

  Future<void> _payInvoice() async {
    final breez = context.read<BreezProvider>();
    final bolt11 = _invoiceController.text.trim();

    if (bolt11.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cole uma invoice BOLT11 primeiro')),
      );
      return;
    }

    // Decodificar invoice primeiro
    final decoded = await breez.decodeInvoice(bolt11);
    if (decoded?['success'] != true) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ Invoice inválida: ${decoded?['error']}')),
        );
      }
      return;
    }

    // Confirmar pagamento
    final invoice = decoded!['invoice'];
    final amountSats = invoice['amountSats'] ?? 'desconhecido';
    final description = invoice['description'] ?? '';

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirmar Pagamento'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Valor: $amountSats sats'),
            const SizedBox(height: 8),
            Text('Descrição: $description'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Pagar'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    // Pagar invoice
    final result = await breez.payInvoice(bolt11);

    if (result?['success'] == true) {
      setState(() {
        _paymentResult = 'Pagamento enviado com sucesso!';
        _invoiceController.clear();
      });
      
      _loadData(); // Atualizar saldo e histórico
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ Pagamento enviado!')),
        );
      }
    } else {
      setState(() {
        _paymentResult = 'Erro: ${result?['error']}';
      });
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ ${result?['error']}')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final breez = context.watch<BreezProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('⚡ Lightning Test'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadData,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status do SDK
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Status',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text('SDK: ${breez.isInitialized ? '✅ Conectado' : '❌ Desconectado'}'),
                    if (_balance != null) ...[
                      const SizedBox(height: 4),
                      Text('Saldo: ${_balance!['balance']} sats'),
                    ],
                  ],
                ),
              ),
            ),
            
            const SizedBox(height: 16),

            // Receber pagamento (criar invoice)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '📥 Receber Pagamento',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _amountController,
                      decoration: const InputDecoration(
                        labelText: 'Valor (sats)',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: breez.isLoading ? null : _createInvoice,
                      icon: const Icon(Icons.qr_code),
                      label: const Text('Criar Invoice'),
                    ),
                    if (_generatedInvoice != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          children: [
                            QrImageView(
                              data: _generatedInvoice!,
                              version: QrVersions.auto,
                              size: 200,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _generatedInvoice!.length > 40
                                  ? '${_generatedInvoice!.substring(0, 40)}...'
                                  : _generatedInvoice!,
                              style: const TextStyle(fontSize: 10, color: Colors.black),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 8),
                            ElevatedButton.icon(
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: _generatedInvoice!));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Invoice copiada!')),
                                );
                              },
                              icon: const Icon(Icons.copy),
                              label: const Text('Copiar Invoice'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Enviar pagamento
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '📤 Enviar Pagamento',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _invoiceController,
                      decoration: const InputDecoration(
                        labelText: 'Invoice BOLT11',
                        border: OutlineInputBorder(),
                        hintText: 'lnbc...',
                      ),
                      maxLines: 3,
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: breez.isLoading ? null : _payInvoice,
                            icon: const Icon(Icons.send),
                            label: const Text('Pagar Invoice'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.paste),
                          onPressed: () async {
                            final data = await Clipboard.getData('text/plain');
                            if (data?.text != null) {
                              setState(() {
                                _invoiceController.text = data!.text!;
                              });
                            }
                          },
                        ),
                      ],
                    ),
                    if (_paymentResult != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _paymentResult!,
                        style: TextStyle(
                          color: _paymentResult!.contains('sucesso')
                              ? Colors.green
                              : Colors.red,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Histórico de pagamentos
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '📜 Histórico',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 16),
                    if (_payments.isEmpty)
                      const Text('Nenhum pagamento ainda')
                    else
                      ..._payments.take(10).map((payment) {
                        final isReceived = payment['paymentType'].toString().contains('Received');
                        return ListTile(
                          leading: Icon(
                            isReceived ? Icons.arrow_downward : Icons.arrow_upward,
                            color: isReceived ? Colors.green : Colors.orange,
                          ),
                          title: Text('${payment['amount']} sats'),
                          subtitle: Text(payment['description'] ?? 'Sem descrição'),
                          trailing: Text(
                            payment['status'].toString().split('.').last,
                            style: const TextStyle(fontSize: 12),
                          ),
                        );
                      }),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Instruções
            Card(
              color: Colors.blue.shade900.withOpacity(0.3),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '💡 Como Testar',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '1. Criar Invoice: Gera uma invoice para você receber pagamento\n'
                      '2. Pagar Invoice: Cole uma invoice de outra carteira Lightning\n'
                      '3. Teste com Testnet: Use https://htlc.me para criar invoices de teste\n'
                      '4. Ou use outra wallet Lightning (Phoenix, Muun, etc.)',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _amountController.dispose();
    _invoiceController.dispose();
    super.dispose();
  }
}
