import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../providers/order_provider.dart';
import '../services/api_service.dart';
import '../widgets/gradient_button.dart';
import 'payment_success_screen.dart';

/// Tela de pagamento PIX com detecção automática via QR Code
class PixPaymentScreen extends StatefulWidget {
  final String? orderId;
  final double? amount;

  const PixPaymentScreen({
    Key? key,
    this.orderId,
    this.amount,
  }) : super(key: key);

  @override
  State<PixPaymentScreen> createState() => _PixPaymentScreenState();
}

class _PixPaymentScreenState extends State<PixPaymentScreen> {
  final MobileScannerController _scannerController = MobileScannerController();
  final ApiService _apiService = ApiService();
  
  bool _isProcessing = false;
  bool _paymentSuccess = false;
  Map<String, dynamic>? _pixData;
  String? _pixCode;

  @override
  void dispose() {
    _scannerController.dispose();
    super.dispose();
  }

  /// Detecta e processa código PIX automaticamente
  void _onQRDetected(BarcodeCapture barcodeCapture) async {
    if (_isProcessing || _paymentSuccess) return;

    final barcode = barcodeCapture.barcodes.firstOrNull;
    if (barcode == null || barcode.rawValue == null) return;

    final code = barcode.rawValue!;
    
    // Valida se é código PIX
    if (!code.startsWith('00020126')) return;

    setState(() {
      _isProcessing = true;
      _pixCode = code;
    });

    broLog('🔍 Processando código: ${code.substring(0, 50)}');
    broLog('📊 Tipo detectado: PIX');

    try {
      // Decodifica PIX via backend
      final pixInfo = await _apiService.decodePixCode(code);
      
      if (pixInfo == null) {
        throw Exception(AppLocalizations.of(context).t('pix_decode_error'));
      }

      setState(() {
        _pixData = pixInfo;
      });

      // Mostra confirmação antes de pagar
      final confirm = await _showPaymentConfirmation(pixInfo);
      
      if (!confirm) {
        setState(() {
          _isProcessing = false;
          _pixCode = null;
          _pixData = null;
        });
        return;
      }

      // Processa pagamento
      await _processPayment(code, pixInfo);

    } catch (e) {
      broLog('❌ Erro ao processar PIX: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).tp('pix_processing_error', {'error': e.toString()})),
            backgroundColor: Colors.red,
          ),
        );
      }
      setState(() {
        _isProcessing = false;
        _pixCode = null;
        _pixData = null;
      });
    }
  }

  Future<bool> _showPaymentConfirmation(Map<String, dynamic> pixInfo) async {
    final amount = widget.amount ?? (pixInfo['amount'] as num?)?.toDouble() ?? 0.0;
    
    return await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        final t = AppLocalizations.of(context).t;
        final tp = AppLocalizations.of(context).tp;
        return AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text(t('pix_confirm_title'), style: const TextStyle(color: Colors.orange)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tp('pix_recipient', {'name': pixInfo['recipient'] ?? 'N/A'}), style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 8),
            if (amount > 0)
              Text(tp('pix_value', {'value': amount.toStringAsFixed(2)}), style: const TextStyle(color: Colors.white)),
            const SizedBox(height: 8),
            if (pixInfo['description'] != null)
              Text(tp('pix_description', {'desc': pixInfo['description']}), style: const TextStyle(color: Colors.white70)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t('cancel'), style: const TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            child: Text(t('confirm')),
          ),
        ],
      );
      },
    ) ?? false;
  }

  Future<void> _processPayment(String pixCode, Map<String, dynamic> pixInfo) async {
    try {
      final amount = widget.amount ?? (pixInfo['amount'] as num?)?.toDouble() ?? 0.0;
      final orderId = widget.orderId ?? 'pix_${DateTime.now().millisecondsSinceEpoch}';
      
      // Chama API para processar pagamento PIX
      final result = await _apiService.processPixPayment(
        orderId,
        pixCode,
        amount,
      );

      if (result['success'] == true) {
        setState(() {
          _paymentSuccess = true;
        });

        // Atualiza ordem
        final orderProvider = Provider.of<OrderProvider>(context, listen: false);
        await orderProvider.fetchOrders();

        // Navega para tela de sucesso
        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => PaymentSuccessScreen(
                orderId: widget.orderId ?? 'pix_temp',
                amountSats: 0, // PIX não usa sats
                totalBrl: amount,
                paymentType: 'pix',
              ),
            ),
          );
        }
      } else {
        throw Exception(result['error'] ?? AppLocalizations.of(context).t('pix_payment_not_authorized'));
      }
    } catch (e) {
      broLog('❌ Erro ao processar pagamento: $e');
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: Text(AppLocalizations.of(context).t('pix_title')),
        backgroundColor: const Color(0xFF1A1A1A),
        foregroundColor: Colors.orange,
      ),
      body: _paymentSuccess
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.green.withOpacity(0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.check_circle, color: Colors.green, size: 64),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    AppLocalizations.of(context).t('pix_payment_done'),
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.white),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                // Instruções
                Container(
                  padding: const EdgeInsets.all(16),
                  color: const Color(0xFF1A1A1A),
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.orange.withOpacity(0.15),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.qr_code_scanner, size: 32, color: Colors.orange),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        AppLocalizations.of(context).t('pix_scan_qr'),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 4),
                      if (widget.amount != null)
                        Text(
                          'Valor: R\$ ${widget.amount!.toStringAsFixed(2)}',
                          style: const TextStyle(
                            fontSize: 14,
                            color: Colors.orange,
                          ),
                        ),
                    ],
                  ),
                ),

                // Scanner
                Expanded(
                  child: Stack(
                    children: [
                      MobileScanner(
                        controller: _scannerController,
                        onDetect: _onQRDetected,
                      ),
                      
                      // Overlay
                      if (_isProcessing)
                        Container(
                          color: Colors.black54,
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const CircularProgressIndicator(color: Colors.white),
                                const SizedBox(height: 16),
                                Text(
                                  AppLocalizations.of(context).t('pix_processing'),
                                  style: const TextStyle(color: Colors.white, fontSize: 16),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),

                // Informações adicionais
                Container(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      if (_pixData != null) ...[
                        Card(
                          color: const Color(0xFF1A1A1A),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(color: Colors.orange.withOpacity(0.2)),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  AppLocalizations.of(context).t('pix_data'),
                                  style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.orange),
                                ),
                                const SizedBox(height: 8),
                                Text(AppLocalizations.of(context).tp('pix_recipient', {'name': _pixData!['recipient'] ?? 'N/A'}), style: const TextStyle(color: Colors.white70)),
                                if (_pixData!['description'] != null)
                                  Text(AppLocalizations.of(context).tp('pix_description', {'desc': _pixData!['description']}), style: const TextStyle(color: Colors.white70)),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      GradientButton(
                        onPressed: () => Navigator.pop(context),
                        text: 'Cancelar',
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
