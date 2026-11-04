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
  // v596: ISO-4217 da moeda. BRL renderiza 'R$', outras o código.
  final String currency;

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
    this.currency = 'BRL',
  }) : super(key: key);

  String _fmt(double v) {
    final c = currency.toUpperCase();
    if (c == 'BRL') return 'R\$ ${v.toStringAsFixed(2)}';
    return '$c ${v.toStringAsFixed(2)}';
  }

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
            
            // v695: taxas CONSOLIDADAS numa linha só (Bro 3% + coordenação 2%),
            // igual ao status da ordem. Antes mostrava só "Taxa Bro" e a de
            // coordenação ficava escondida num TODO — o total não batia com a
            // soma das linhas visíveis (pedido da Carol, 04/11).
            _buildFeeRow(
              label: 'Taxas (${(providerFeePercent + platformFeePercent).toStringAsFixed(0)}%)',
              valueBrl: providerFee + platformFee,
              valueSats: ((providerFee + platformFee) * brlToSatsRate).round(),
              isTotal: false,
              color: const Color(0xFFFFB74D), // orange 300
            ),
            
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
              _fmt(valueBrl),
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
