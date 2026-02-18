import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/provider_balance_provider.dart';
import '../providers/breez_provider_export.dart';
import '../models/provider_balance.dart';
import '../services/nostr_service.dart';

/// Tela para visualizar saldo e hist�rico do provedor
class ProviderBalanceScreen extends StatefulWidget {
  const ProviderBalanceScreen({Key? key}) : super(key: key);

  @override
  State<ProviderBalanceScreen> createState() => _ProviderBalanceScreenState();
}

class _ProviderBalanceScreenState extends State<ProviderBalanceScreen> {
  int _breezBalanceSats = 0;
  bool _loadingBreez = true;
  
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Usar pubkey real do NostrService
      final nostrService = NostrService();
      final providerId = nostrService.publicKey ?? 'unknown';
      context.read<ProviderBalanceProvider>().initialize(providerId);
      _loadBreezBalance();
    });
  }
  
  Future<void> _loadBreezBalance() async {
    try {
      final breezProvider = context.read<BreezProvider>();
      if (breezProvider.isInitialized) {
        final balance = await breezProvider.getBalance();
        if (mounted) {
          setState(() {
            _breezBalanceSats = int.tryParse(balance?['balance']?.toString() ?? '0') ?? 0;
            _loadingBreez = false;
          });
        }
      } else {
        setState(() => _loadingBreez = false);
      }
    } catch (e) {
      debugPrint('? Erro ao carregar saldo Breez: $e');
      if (mounted) setState(() => _loadingBreez = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Meu Saldo (Provedor)'),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
      ),
      body: Consumer<ProviderBalanceProvider>(
        builder: (context, balanceProvider, child) {
          final balance = balanceProvider.balance;

          if (balance == null) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          return RefreshIndicator(
            onRefresh: () async {
              final nostrService = NostrService();
              final providerId = nostrService.publicKey ?? 'unknown';
              await balanceProvider.initialize(providerId);
              await _loadBreezBalance();
            },
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Card do saldo REAL (Breez Lightning)
                  _buildRealBalanceCard(),
                  const SizedBox(height: 16),
                  // Card do saldo cont�bil do provedor
                  _buildBalanceCard(balance),
                  const SizedBox(height: 16),
                  _buildStatsCard(balance),
                  const SizedBox(height: 16),
                  _buildWithdrawButtons(context, balance.availableBalanceSats),
                  const SizedBox(height: 24),
                  _buildTransactionHistory(balance.transactions),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Card com o saldo REAL da carteira Lightning (Breez)
  Widget _buildRealBalanceCard() {
    return Card(
      color: Colors.orange.shade800,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.flash_on, color: Colors.yellow, size: 24),
                const SizedBox(width: 8),
                const Text(
                  'Carteira Lightning (Real)',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_loadingBreez)
              const CircularProgressIndicator(color: Colors.white)
            else
              Column(
                children: [
                  Text(
                    '${_formatSats(_breezBalanceSats.toDouble())} sats',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '? ${_satsToReais(_breezBalanceSats.toDouble())}',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 12),
            const Text(
              '? Saldo real na rede Lightning',
              style: TextStyle(
                color: Colors.white60,
                fontSize: 12,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBalanceCard(ProviderBalance balance) {
    return Card(
      color: Colors.deepPurple,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const Text(
              'Ganhos como Bro (Cont�bil)',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.volunteer_activism,
                  color: Colors.white,
                  size: 32,
                ),
                const SizedBox(width: 12),
                Text(
                  '${_formatSats(balance.availableBalanceSats)} sats',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '? ${_satsToReais(balance.availableBalanceSats)}',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '?? Ganhos das ordens completadas',
              style: TextStyle(
                color: Colors.white60,
                fontSize: 12,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsCard(ProviderBalance balance) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _buildStatRow(
              'Total Ganho',
              '${_formatSats(balance.totalEarnedSats)} sats',
              Icons.trending_up,
              Colors.green,
            ),
            const Divider(),
            _buildStatRow(
              'Transa��es',
              balance.transactions.length.toString(),
              Icons.receipt_long,
              Colors.blue,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatRow(String label, String value, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 16),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWithdrawButtons(BuildContext context, double availableBalance) {
    final hasBalance = availableBalance > 0;

    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed: hasBalance ? () => _showWithdrawLightningDialog(context) : null,
            icon: const Icon(Icons.flash_on),
            label: const Text('Sacar Lightning'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: ElevatedButton.icon(
            onPressed: hasBalance ? () => _showWithdrawOnchainDialog(context) : null,
            icon: const Icon(Icons.currency_bitcoin),
            label: const Text('Sacar Onchain'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.deepOrange,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTransactionHistory(List<BalanceTransaction> transactions) {
    if (transactions.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            children: [
              Icon(
                Icons.history,
                size: 64,
                color: Colors.grey[400],
              ),
              const SizedBox(height: 16),
              Text(
                'Nenhuma transa��o ainda',
                style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Hist�rico',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        ...transactions.map((tx) => _buildTransactionCard(tx)),
      ],
    );
  }

  Widget _buildTransactionCard(BalanceTransaction tx) {
    final isEarning = tx.type == 'earning';
    final isWithdrawal = tx.type.startsWith('withdrawal_');
    
    IconData icon;
    Color color;
    String typeLabel;
    
    if (isEarning) {
      icon = Icons.add_circle;
      color = Colors.green;
      typeLabel = 'Ganho';
    } else if (tx.type == 'withdrawal_lightning') {
      icon = Icons.flash_on;
      color = Colors.orange;
      typeLabel = 'Saque Lightning';
    } else if (tx.type == 'withdrawal_onchain') {
      icon = Icons.currency_bitcoin;
      color = Colors.deepOrange;
      typeLabel = 'Saque Onchain';
    } else {
      icon = Icons.remove_circle;
      color = Colors.red;
      typeLabel = tx.type;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon, color: color, size: 32),
        title: Text(
          typeLabel,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (tx.orderDescription != null) ...[
              const SizedBox(height: 4),
              Text(tx.orderDescription!),
            ],
            if (tx.txHash != null) ...[
              const SizedBox(height: 4),
              Text(
                'TX: ${tx.txHash!.substring(0, 16)}...',
                style: const TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
            ],
            const SizedBox(height: 4),
            Text(
              _formatDate(tx.createdAt),
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
        trailing: Text(
          '${isEarning ? '+' : '-'}${_formatSats(tx.amountSats)}',
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        onTap: () {
          if (tx.txHash != null) {
            _showTransactionDetails(tx);
          }
        },
      ),
    );
  }

  void _showTransactionDetails(BalanceTransaction tx) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Detalhes da Transa��o'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildDetailRow('Tipo', tx.type),
            _buildDetailRow('Valor', '${tx.amountSats} sats'),
            _buildDetailRow('Data/Hora', _formatDateTimeFull(tx.createdAt)),
            if (tx.orderDescription != null)
              _buildDetailRow('Descri��o', tx.orderDescription!),
            if (tx.txHash != null) ...[
              const SizedBox(height: 8),
              const Text(
                'Transaction Hash:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              SelectableText(
                tx.txHash!,
                style: const TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
            ],
            if (tx.invoice != null) ...[
              const SizedBox(height: 8),
              const Text(
                'Lightning Invoice:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              SelectableText(
                tx.invoice!,
                style: const TextStyle(
                  fontSize: 10,
                  fontFamily: 'monospace',
                ),
                maxLines: 3,
              ),
            ],
          ],
        ),
        actions: [
          if (tx.txHash != null)
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: tx.txHash!));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Hash copiado!')),
                );
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copiar Hash'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: Text(value),
          ),
        ],
      ),
    );
  }

  void _showWithdrawLightningDialog(BuildContext context) {
    final balanceProvider = context.read<ProviderBalanceProvider>();
    final availableBalance = balanceProvider.balance?.availableBalanceSats ?? 0;
    final amountController = TextEditingController();
    final invoiceController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.flash_on, color: Colors.orange),
            SizedBox(width: 8),
            Text('Saque Lightning'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Saldo dispon�vel: ${_formatSats(availableBalance)} sats'),
            const SizedBox(height: 16),
            TextField(
              controller: amountController,
              decoration: InputDecoration(
                labelText: 'Valor (sats)',
                hintText: 'Ex: ${availableBalance ~/ 2}',
                border: const OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: invoiceController,
              decoration: const InputDecoration(
                labelText: 'Lightning Invoice',
                hintText: 'lnbc...',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () async {
              final amount = int.tryParse(amountController.text);
              final invoice = invoiceController.text.trim();

              if (amount == null || amount <= 0) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Valor inv�lido')),
                );
                return;
              }

              if (amount > availableBalance) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Saldo insuficiente')),
                );
                return;
              }

              if (invoice.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Informe a invoice')),
                );
                return;
              }

              Navigator.pop(context);

              try {
                await balanceProvider.withdrawLightning(
                  amountSats: amount.toDouble(),
                  invoice: invoice,
                );

                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('? Saque realizado!'),
                      backgroundColor: Colors.green,
                    ),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Erro: $e'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
            ),
            child: const Text('Sacar'),
          ),
        ],
      ),
    );
  }

  void _showWithdrawOnchainDialog(BuildContext context) {
    final balanceProvider = context.read<ProviderBalanceProvider>();
    final availableBalance = balanceProvider.balance?.availableBalanceSats ?? 0;
    final amountController = TextEditingController();
    final addressController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.currency_bitcoin, color: Colors.deepOrange),
            SizedBox(width: 8),
            Text('Saque Onchain'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Saldo dispon�vel: ${_formatSats(availableBalance)} sats'),
            const SizedBox(height: 16),
            TextField(
              controller: amountController,
              decoration: InputDecoration(
                labelText: 'Valor (sats)',
                hintText: 'Ex: ${availableBalance ~/ 2}',
                border: const OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: addressController,
              decoration: const InputDecoration(
                labelText: 'Endere�o Bitcoin',
                hintText: 'bc1...',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 8),
            const Text(
              'Taxa de rede: ~1000 sats',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () async {
              final amount = int.tryParse(amountController.text);
              final address = addressController.text.trim();

              if (amount == null || amount <= 0) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Valor inv�lido')),
                );
                return;
              }

              if (amount > availableBalance) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Saldo insuficiente')),
                );
                return;
              }

              if (address.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Informe o endere�o')),
                );
                return;
              }

              Navigator.pop(context);

              try {
                await balanceProvider.withdrawOnchain(
                  amountSats: amount.toDouble(),
                  address: address,
                );

                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('? Saque enviado!'),
                      backgroundColor: Colors.green,
                    ),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Erro: $e'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.deepOrange,
            ),
            child: const Text('Sacar'),
          ),
        ],
      ),
    );
  }

  String _formatSats(double sats) {
    final satsInt = sats.round();
    if (satsInt >= 100000000) {
      return '${(satsInt / 100000000).toStringAsFixed(2)} BTC';
    } else if (satsInt >= 1000) {
      return '${(satsInt / 1000).toStringAsFixed(1)}k';
    }
    return satsInt.toString();
  }

  String _satsToReais(double sats) {
    // Cota��o exemplo: 1 BTC = R$ 300.000
    final btc = sats / 100000000;
    final reais = btc * 300000;
    return 'R\$ ${reais.toStringAsFixed(2)}';
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inDays == 0) {
      return 'Hoje �s ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    } else if (difference.inDays == 1) {
      return 'Ontem';
    } else if (difference.inDays < 7) {
      return '${difference.inDays} dias atr�s';
    } else {
      return '${date.day}/${date.month}/${date.year}';
    }
  }

  String _formatDateTimeFull(DateTime date) {
    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');
    final year = date.year;
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    final second = date.second.toString().padLeft(2, '0');
    
    return '$day/$month/$year �s $hour:$minute:$second';
  }
}
