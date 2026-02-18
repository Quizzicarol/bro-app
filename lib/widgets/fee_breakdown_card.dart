import 'package:flutter/material.dart';

class FeeBreakdownCard extends StatelessWidget {
  final double accountValue;
  final double providerFee;
  final double providerFeePercent;
  final double platformFee;
  final double platformFeePercent;
  final double totalBrl;
  final int totalSats;
  final double brlToSatsRate;
  final double? networkFee;

  const FeeBreakdownCard({
    Key? key,
    required this.accountValue,
    required this.providerFee,
    required this.providerFeePercent,
    required this.platformFee,
    required this.platformFeePercent,
    required this.totalBrl,
    required this.totalSats,
    required this.brlToSatsRate,
    this.networkFee,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0x0DFFFFFF), // rgba(255, 255, 255, 0.05)
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(
          color: Color(0x33FF6B35), // rgba(255, 107, 53, 0.2)
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: const [
                Icon(
                  Icons.receipt_long,
                  color: Color(0xFFFF6B6B),
                  size: 20,
                ),
                SizedBox(width: 8),
                Text(
                  'Detalhamento de Taxas',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            
            // Account value
            _buildFeeRow(
              label: 'Valor da Conta',
              valueBrl: accountValue,
              valueSats: (accountValue * brlToSatsRate).round(),
              isTotal: false,
              color: Colors.white,
            ),
            
            const Divider(height: 24),
            
            // Provider fee (Bro)
            _buildFeeRow(
              label: 'Taxa Bro (${providerFeePercent.toStringAsFixed(0)}%)',
              valueBrl: providerFee,
              valueSats: (providerFee * brlToSatsRate).round(),
              isTotal: false,
              color: const Color(0xFFFFB74D), // orange 300
            ),
            
            // Platform fee - escondido por enquanto (não estamos cobrando)
            // TODO: Descomentar quando ativar taxa de plataforma
            
            // Network fee (only for on-chain)
            if (networkFee != null) ...[
              const SizedBox(height: 8),
              _buildNetworkFeeRow(
                label: 'Taxa de Rede (estimada)',
                valueBtc: networkFee!,
                color: Colors.grey[700],
              ),
            ],
            
            const Divider(height: 24),
            
            // Total
            _buildFeeRow(
              label: 'Total a Depositar',
              valueBrl: totalBrl,
              valueSats: totalSats,
              isTotal: true,
              color: const Color(0xFF4CAF50), // green
            ),
            
            // Info sobre cotação atual
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0x1A4CAF50), // verde sutil
                border: Border.all(color: const Color(0xFF4CAF50), width: 1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: Color(0xFF81C784),
                  ),
                  SizedBox(width: 6),
                  Text(
                    'Cotação atualizada em tempo real',
                    style: TextStyle(
                      fontSize: 12,
                      color: Color(0xFF81C784),
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

  Widget _buildFeeRow({
    required String label,
    required double valueBrl,
    required int valueSats,
    required bool isTotal,
    Color? color,
  }) {
    final textStyle = TextStyle(
      fontSize: isTotal ? 16 : 14,
      fontWeight: isTotal ? FontWeight.bold : FontWeight.normal,
      color: color ?? Colors.white70,
    );

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(
            label,
            style: textStyle,
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              'R\$ ${valueBrl.toStringAsFixed(2)}',
              style: textStyle,
            ),
            const SizedBox(height: 2),
            Text(
              '${valueSats.toStringAsFixed(0)} sats',
              style: TextStyle(
                fontSize: isTotal ? 13 : 12,
                color: color?.withOpacity(0.7) ?? Colors.white54,
                fontWeight: isTotal ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildNetworkFeeRow({
    required String label,
    required double valueBtc,
    Color? color,
  }) {
    final textStyle = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.normal,
      color: color ?? Colors.black87,
    );

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(
            label,
            style: textStyle,
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '${valueBtc.toStringAsFixed(8)} BTC',
              style: textStyle,
            ),
            const SizedBox(height: 2),
            Text(
              '≈ ${(valueBtc * 100000000).toStringAsFixed(0)} sats',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[600],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
