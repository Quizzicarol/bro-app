import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

class BitcoinPaymentDialog extends StatelessWidget {
  final String? lightningInvoice;
  final String? onchainAddress;
  final double? btcAmount;
  final String orderId;

  const BitcoinPaymentDialog({
    Key? key,
    this.lightningInvoice,
    this.onchainAddress,
    this.btcAmount,
    required this.orderId,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 500),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFFF6B6B).withOpacity(0.3)),
        ),
        child: DefaultTabController(
          length: lightningInvoice != null && onchainAddress != null ? 2 : 1,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFFF6B6B), Color(0xFFFF8A8A)],
                  ),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(16),
                    topRight: Radius.circular(16),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.currency_bitcoin, color: Colors.white, size: 28),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Pagar com Bitcoin',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),

              // Tabs (se tiver ambos Lightning e On-chain)
              if (lightningInvoice != null && onchainAddress != null)
                Container(
                  color: const Color(0xFF0A0A0A),
                  child: TabBar(
                    indicatorColor: const Color(0xFFFF6B6B),
                    labelColor: const Color(0xFFFF6B6B),
                    unselectedLabelColor: Colors.white60,
                    tabs: const [
                      Tab(icon: Icon(Icons.flash_on), text: 'Lightning'),
                      Tab(icon: Icon(Icons.link), text: 'On-chain'),
                    ],
                  ),
                ),

              // Content
              Flexible(
                child: lightningInvoice != null && onchainAddress != null
                    ? TabBarView(
                        children: [
                          _buildLightningTab(context),
                          _buildOnchainTab(context),
                        ],
                      )
                    : SingleChildScrollView(
                        child: lightningInvoice != null
                            ? _buildLightningTab(context)
                            : _buildOnchainTab(context),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLightningTab(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Info
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFFFEB3B).withOpacity(0.1),
              border: Border.all(color: const Color(0xFFFFEB3B)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: const [
                Icon(Icons.flash_on, color: Color(0xFFFFEB3B), size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '⚡ Lightning Network - Rápido e com taxas baixas',
                    style: TextStyle(
                      color: Color(0xFFFFEB3B),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // QR Code
          if (lightningInvoice != null)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: QrImageView(
                data: lightningInvoice!,
                version: QrVersions.auto,
                size: 220,
                eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: Colors.black,
                ),
              ),
            ),
          const SizedBox(height: 20),

          // Amount
          if (btcAmount != null)
            Text(
              '${btcAmount!.toStringAsFixed(8)} BTC',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          const SizedBox(height: 12),

          // Invoice
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF0A0A0A),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFFF6B6B).withOpacity(0.2)),
            ),
            child: SelectableText(
              lightningInvoice ?? '',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
              maxLines: 3,
            ),
          ),
          const SizedBox(height: 16),

          // Copy Button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: lightningInvoice ?? ''));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Invoice copiada!'),
                    backgroundColor: Color(0xFF4CAF50),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copiar Invoice'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF6B6B),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOnchainTab(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Info
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF1E88E5).withOpacity(0.1),
              border: Border.all(color: const Color(0xFF1E88E5)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: const [
                Icon(Icons.link, color: Color(0xFF1E88E5), size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '⛓️ Bitcoin On-chain - Mais seguro para valores altos',
                    style: TextStyle(
                      color: Color(0xFF1E88E5),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // QR Code
          if (onchainAddress != null)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: QrImageView(
                data: onchainAddress!,
                version: QrVersions.auto,
                size: 220,
                eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: Colors.black,
                ),
              ),
            ),
          const SizedBox(height: 20),

          // Amount
          if (btcAmount != null)
            Text(
              '${btcAmount!.toStringAsFixed(8)} BTC',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          const SizedBox(height: 12),

          // Address
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF0A0A0A),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFFF6B6B).withOpacity(0.2)),
            ),
            child: SelectableText(
              onchainAddress ?? '',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
              maxLines: 3,
            ),
          ),
          const SizedBox(height: 16),

          // Copy Button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: onchainAddress ?? ''));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Endereço copiado!'),
                    backgroundColor: Color(0xFF4CAF50),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copiar Endereço'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF6B6B),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Helper function para mostrar o diálogo
void showBitcoinPaymentDialog(
  BuildContext context, {
  String? lightningInvoice,
  String? onchainAddress,
  double? btcAmount,
  required String orderId,
}) {
  showDialog(
    context: context,
    builder: (context) => BitcoinPaymentDialog(
      lightningInvoice: lightningInvoice,
      onchainAddress: onchainAddress,
      btcAmount: btcAmount,
      orderId: orderId,
    ),
  );
}
