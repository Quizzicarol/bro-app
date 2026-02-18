import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Modal de pagamento Bitcoin replicando o design do web
/// Lightning + On-chain side-by-side com QR codes
class BitcoinPaymentModal extends StatelessWidget {
  final String btcAddress;
  final String lightningInvoice;
  final double billAmount;
  final double providerFee;
  final double platformFee;
  final double btcTotal;

  const BitcoinPaymentModal({
    Key? key,
    required this.btcAddress,
    required this.lightningInvoice,
    required this.billAmount,
    required this.providerFee,
    required this.platformFee,
    required this.btcTotal,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(16),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 800),
        decoration: BoxDecoration(
          color: const Color(0xF70A0A0A), // rgba(10, 10, 10, 0.98)
          border: Border.all(
            color: const Color(0x33FF6B35),
            width: 1,
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(context),
            _buildContent(),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFFFF6B6B), Color(0xFFFF8A8A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.currency_bitcoin, color: Colors.white),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Escolha a Forma de Pagamento',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          // Payment Methods Side-by-Side
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth > 600) {
                // Desktop/Tablet: lado a lado
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _buildOnChainCard()),
                    const SizedBox(width: 16),
                    Expanded(child: _buildLightningCard()),
                  ],
                );
              } else {
                // Mobile: empilhado
                return Column(
                  children: [
                    _buildLightningCard(),
                    const SizedBox(height: 16),
                    _buildOnChainCard(),
                  ],
                );
              }
            },
          ),
          const SizedBox(height: 20),
          
          // Payment Summary
          _buildPaymentSummary(),
        ],
      ),
    );
  }

  Widget _buildOnChainCard() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0x0DFFFFFF),
        border: Border.all(color: const Color(0x33FF6B35)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFFFF6B6B), Color(0xFFFF8A8A)],
              ),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
              ),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.currency_bitcoin, color: Colors.white, size: 20),
                SizedBox(width: 8),
                Text(
                  'Bitcoin On-chain',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
          
          // Body
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                // QR Code
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: QrImageView(
                    data: btcAddress,
                    version: QrVersions.auto,
                    size: 180,
                    backgroundColor: Colors.white,
                    eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: Colors.black,
                    ),
                    dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: Colors.black,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                
                // Address
                const Text(
                  'Endereço Bitcoin:',
                  style: TextStyle(
                    fontSize: 12,
                    color: Color(0x99FFFFFF),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0x1AFFFFFF),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0x33FF6B35)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          btcAddress,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white,
                            fontFamily: 'monospace',
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy, size: 18),
                        color: const Color(0xFFFF6B6B),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: btcAddress));
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                
                // Info
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0x1A2196F3),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: const [
                      Icon(Icons.info_outline, size: 16, color: Color(0xFF2196F3)),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Confirmação em ~10 minutos',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF2196F3),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLightningCard() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0x0DFFFFFF),
        border: Border.all(color: const Color(0x33FF6B35)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF9C27B0), Color(0xFFE040FB)],
              ),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
              ),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.flash_on, color: Colors.white, size: 20),
                SizedBox(width: 8),
                Text(
                  'Lightning Network',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
          
          // Body
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                // QR Code
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: QrImageView(
                    data: lightningInvoice,
                    version: QrVersions.auto,
                    size: 180,
                    backgroundColor: Colors.white,
                    eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: Colors.black,
                    ),
                    dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: Colors.black,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                
                // Invoice
                const Text(
                  'Invoice Lightning:',
                  style: TextStyle(
                    fontSize: 12,
                    color: Color(0x99FFFFFF),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0x1AFFFFFF),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0x33FF6B35)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          lightningInvoice,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white,
                            fontFamily: 'monospace',
                          ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy, size: 18),
                        color: const Color(0xFFE040FB),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: lightningInvoice));
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                
                // Info
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0x1A4CAF50),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: const [
                      Icon(Icons.flash_on, size: 16, color: Color(0xFF4CAF50)),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Pagamento instantâneo!',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF4CAF50),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentSummary() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0x0DFFFFFF),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Resumo do Pagamento',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 16),
          
          Row(
            children: [
              Expanded(
                child: _buildSummaryItem(
                  'Valor da Conta:',
                  'R\$ ${billAmount.toStringAsFixed(2)}',
                ),
              ),
              Expanded(
                child: _buildSummaryItem(
                  'Taxa Provedor (5%):',
                  'R\$ ${providerFee.toStringAsFixed(2)}',
                ),
              ),
              Expanded(
                child: _buildSummaryItem(
                  'Taxa Plataforma (2%):',
                  'R\$ ${platformFee.toStringAsFixed(2)}',
                ),
              ),
            ],
          ),
          
          const Divider(color: Color(0x33FFFFFF), height: 32),
          
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Total em Bitcoin:',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              Text(
                '₿ ${btcTotal.toStringAsFixed(8)}',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFFFC107),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryItem(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
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
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
      ],
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.all(20),
      child: const Text(
        'Aguardando pagamento...',
        style: TextStyle(
          fontSize: 14,
          color: Color(0x99FFFFFF),
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}
