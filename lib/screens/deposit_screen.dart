import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'dart:async';
import '../config.dart';
import '../providers/breez_provider_export.dart';
import '../providers/lightning_provider.dart';
import '../widgets/fee_breakdown_card.dart';

class DepositScreen extends StatefulWidget {
  const DepositScreen({Key? key}) : super(key: key);

  @override
  State<DepositScreen> createState() => _DepositScreenState();
}

class _DepositScreenState extends State<DepositScreen> {
  final TextEditingController _amountController = TextEditingController();
  
  // Lightning state
  String? _lightningInvoice;
  String? _lightningQrData;
  Timer? _lightningPollingTimer;
  bool _isGeneratingLightning = false;
  
  // Fees - centralizados no AppConfig
  // Taxa Bro: 3% (vai para o provedor)
  // Taxa Plataforma: 2% (manutenção)
  // Total: 5%
  final double _providerFeePercent = AppConfig.providerFeePercent * 100; // 3%
  final double _platformFeePercent = AppConfig.platformFeePercent * 100; // 2%
  
  // BRL to Sats conversion rate (mock - should come from API)
  double _brlToSatsRate = 100.0; // 1 BRL = 100 sats (example)
  
  @override
  void initState() {
    super.initState();
    _fetchBtcPrice();
  }
  
  @override
  void dispose() {
    _amountController.dispose();
    _lightningPollingTimer?.cancel();
    super.dispose();
  }
  
  Future<void> _fetchBtcPrice() async {
    // TODO: Fetch real BTC/BRL rate from API
    // For now using mock data
    setState(() {
      _brlToSatsRate = 100.0; // Example rate
    });
  }
  
  double get _amountBrl {
    return double.tryParse(_amountController.text) ?? 0.0;
  }
  
  int get _amountSats {
    return (_amountBrl * _brlToSatsRate).round();
  }
  
  double get _providerFee {
    return _amountBrl * (_providerFeePercent / 100);
  }
  
  double get _platformFee {
    return _amountBrl * (_platformFeePercent / 100);
  }
  
  double get _totalBrl {
    return _amountBrl + _providerFee + _platformFee;
  }
  
  int get _totalSats {
    return (_totalBrl * _brlToSatsRate).round();
  }
  
  Future<void> _generateLightningInvoice() async {
    if (_amountBrl <= 0) {
      _showError('Por favor, insira um valor válido');
      return;
    }
    
    setState(() {
      _isGeneratingLightning = true;
      _lightningInvoice = null;
      _lightningQrData = null;
    });
    
    try {
      // Usar LightningProvider com fallback automático Spark -> Liquid
      final lightningProvider = context.read<LightningProvider>();
      
      // Create invoice via LightningProvider (tenta Spark, depois Liquid)
      final response = await lightningProvider.createInvoice(
        amountSats: _totalSats,
        description: 'Depósito Bro - R\$ ${_totalBrl.toStringAsFixed(2)}',
      );

      if (response == null) {
        setState(() {
          _isGeneratingLightning = false;
        });
        _showError('Erro ao criar invoice');
        return;
      }

      // Log se usou Liquid
      if (response['isLiquid'] == true) {
        debugPrint('💧 Invoice de depósito criada via LIQUID (fallback)');
      }

      if (response['invoice'] is String) {
        final invoice = response['invoice'] as String;
        final paymentHash = response['paymentHash'] as String? ?? '';

        setState(() {
          _lightningInvoice = invoice;
          _lightningQrData = invoice;
          _isGeneratingLightning = false;
        });

        // Start polling for payment
        if (paymentHash.isNotEmpty) {
          _startLightningPolling(paymentHash);
        }
      }
      
    } catch (e) {
      setState(() {
        _isGeneratingLightning = false;
      });
      _showError('Erro ao gerar invoice: $e');
    }
  }
  
  void _startLightningPolling(String paymentHash) {
    _lightningPollingTimer?.cancel();
    _lightningPollingTimer = Timer.periodic(
      const Duration(seconds: 3),
      (timer) async {
        try {
          final breezProvider = context.read<BreezProvider>();
          final status = await breezProvider.checkPaymentStatus(paymentHash);
          
          if (status != null && status['paid'] == true) {
            timer.cancel();
            _onLightningPaymentReceived();
          }
        } catch (e) {
          // Continue polling on error
          debugPrint('Polling error: $e');
        }
      },
    );
  }
  
  void _onLightningPaymentReceived() {
    _showSuccess('Pagamento Lightning recebido com sucesso!');
    setState(() {
      _lightningInvoice = null;
      _lightningQrData = null;
      _amountController.clear();
    });
    // Refresh balance
    context.read<BreezProvider>().refreshBalance();
  }
  
  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label copiado!'),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 2),
      ),
    );
  }
  
  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: 'OK',
          textColor: Colors.white,
          onPressed: () {},
        ),
      ),
    );
  }
  
  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 3),
      ),
    );
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Depositar'),
        backgroundColor: const Color(0xFF1E1E1E),
      ),
      backgroundColor: const Color(0xFF121212),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Lightning info banner
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange.withOpacity(0.3)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.flash_on, color: Colors.orange),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '⚡ Lightning Network',
                          style: TextStyle(
                            color: Colors.orange,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Pagamento instantâneo e taxas baixas',
                          style: TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            
            // Amount input
            Card(
              color: const Color(0xFF1E1E1E),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Valor do Depósito',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _amountController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Valor em BRL',
                        labelStyle: const TextStyle(color: Colors.white54),
                        prefixText: 'R\$ ',
                        prefixStyle: const TextStyle(color: Colors.white),
                        border: const OutlineInputBorder(),
                        enabledBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: Colors.white24),
                        ),
                        focusedBorder: const OutlineInputBorder(
                          borderSide: BorderSide(color: Colors.orange),
                        ),
                        hintText: '0.00',
                        hintStyle: const TextStyle(color: Colors.white24),
                      ),
                      onChanged: (value) {
                        setState(() {}); // Update sats conversion
                      },
                    ),
                    const SizedBox(height: 8),
                    if (_amountBrl > 0)
                      Text(
                        '≈ ${_amountSats.toStringAsFixed(0)} sats',
                        style: const TextStyle(
                          color: Colors.orange,
                          fontSize: 14,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            
            // Fee breakdown
            if (_amountBrl > 0)
              FeeBreakdownCard(
                accountValue: _amountBrl,
                providerFee: _providerFee,
                providerFeePercent: _providerFeePercent,
                platformFee: _platformFee,
                platformFeePercent: _platformFeePercent,
                totalBrl: _totalBrl,
                totalSats: _totalSats,
                brlToSatsRate: _brlToSatsRate,
              ),
            
            const SizedBox(height: 16),
            
            // Generate invoice button
            if (_lightningInvoice == null)
              ElevatedButton.icon(
                onPressed: _isGeneratingLightning ? null : _generateLightningInvoice,
                icon: _isGeneratingLightning
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.flash_on),
                label: Text(
                  _isGeneratingLightning
                      ? 'Gerando...'
                      : 'Gerar Invoice Lightning',
                  style: const TextStyle(fontSize: 16),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.all(16),
                ),
              ),
            
            // Invoice display
            if (_lightningInvoice != null) ...[
              Card(
                color: const Color(0xFF1E1E1E),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      const Text(
                        'Escaneie o QR Code ou copie a invoice',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 16),
                      
                      // QR Code
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: _lightningQrData != null ? QrImageView(
                          data: _lightningQrData!,
                          version: QrVersions.auto,
                          size: 250.0,
                          backgroundColor: Colors.white,
                        ) : const SizedBox.shrink(),
                      ),
                      const SizedBox(height: 16),
                      
                      // Invoice string
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2A2A2A),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _lightningInvoice!,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                  color: Colors.white70,
                                ),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.copy, color: Colors.orange),
                              onPressed: () => _copyToClipboard(
                                _lightningInvoice!,
                                'Invoice',
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      
                      // Polling indicator
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.orange),
                            ),
                          ),
                          const SizedBox(width: 12),
                          const Text(
                            'Aguardando pagamento...',
                            style: TextStyle(color: Colors.white70),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _lightningInvoice = null;
                            _lightningQrData = null;
                          });
                          _lightningPollingTimer?.cancel();
                        },
                        child: const Text('Cancelar', style: TextStyle(color: Colors.red)),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
