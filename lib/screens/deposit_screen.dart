import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'dart:async';
import '../providers/breez_provider_export.dart';
import '../widgets/fee_breakdown_card.dart';

class DepositScreen extends StatefulWidget {
  const DepositScreen({Key? key}) : super(key: key);

  @override
  State<DepositScreen> createState() => _DepositScreenState();
}

class _DepositScreenState extends State<DepositScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _amountController = TextEditingController();
  
  // Lightning state
  String? _lightningInvoice;
  String? _lightningQrData;
  Timer? _lightningPollingTimer;
  bool _isGeneratingLightning = false;
  
  // On-chain state
  String? _bitcoinAddress;
  String? _bitcoinQrData;
  Timer? _onchainPollingTimer;
  bool _isGeneratingOnchain = false;
  double _estimatedNetworkFee = 0.0;
  
  // Fees
  final double _providerFeePercent = 7.0;
  final double _platformFeePercent = 2.0;
  
  // BRL to Sats conversion rate (mock - should come from API)
  double _brlToSatsRate = 100.0; // 1 BRL = 100 sats (example)
  
  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _fetchBtcPrice();
    _estimateNetworkFee();
  }
  
  @override
  void dispose() {
    _tabController.dispose();
    _amountController.dispose();
    _lightningPollingTimer?.cancel();
    _onchainPollingTimer?.cancel();
    super.dispose();
  }
  
  Future<void> _fetchBtcPrice() async {
    // TODO: Fetch real BTC/BRL rate from API
    // For now using mock data
    setState(() {
      _brlToSatsRate = 100.0; // Example rate
    });
  }
  
  Future<void> _estimateNetworkFee() async {
    // TODO: Fetch real network fee estimate from API
    setState(() {
      _estimatedNetworkFee = 0.00001; // Example: 0.00001 BTC
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
      final breezProvider = context.read<BreezProvider>();
      
      // Call backend API to create invoice
      final response = await breezProvider.createInvoice(
        amountSats: _totalSats,
        description: 'Depósito Paga Conta - R\$ ${_totalBrl.toStringAsFixed(2)}',
      );

      if (response == null) {
        setState(() {
          _isGeneratingLightning = false;
        });
        _showError('Erro ao criar invoice');
        return;
      }

      if (response['invoice'] is String && response['paymentHash'] is String) {
        final invoice = response['invoice'] as String;
        final paymentHash = response['paymentHash'] as String;

        setState(() {
          _lightningInvoice = invoice;
          _lightningQrData = invoice;
          _isGeneratingLightning = false;
        });

        // Start polling for payment (paymentHash is guaranteed to be a String here)
        _startLightningPolling(paymentHash);
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
  
  Future<void> _generateBitcoinAddress() async {
    if (_amountBrl <= 0) {
      _showError('Por favor, insira um valor válido');
      return;
    }
    
    setState(() {
      _isGeneratingOnchain = true;
      _bitcoinAddress = null;
      _bitcoinQrData = null;
    });
    
    try {
      final breezProvider = context.read<BreezProvider>();
      
      // Call backend API to create address
      final response = await breezProvider.createBitcoinAddress();
      
      if (response != null && response['address'] is String) {
        final address = response['address'] as String;
        setState(() {
          _bitcoinAddress = address;
          _bitcoinQrData = 'bitcoin:$address?amount=${(_totalSats / 100000000).toStringAsFixed(8)}';
          _isGeneratingOnchain = false;
        });

        // Start polling for confirmations using the validated address
        _startOnchainPolling(address);
      } else {
        setState(() {
          _isGeneratingOnchain = false;
        });
        _showError('Endereço Bitcoin inválido');
      }
      
    } catch (e) {
      setState(() {
        _isGeneratingOnchain = false;
      });
      _showError('Erro ao gerar endereço: $e');
    }
  }
  
  void _startOnchainPolling(String address) {
    _onchainPollingTimer?.cancel();
    _onchainPollingTimer = Timer.periodic(
      const Duration(seconds: 30),
      (timer) async {
        try {
          final breezProvider = context.read<BreezProvider>();
          final status = await breezProvider.checkAddressStatus(address);
          
          if (status != null && 
              status['confirmations'] is int && 
              status['confirmations'] > 0) {
            timer.cancel();
            _onBitcoinReceived(status['confirmations'] as int);
          }
        } catch (e) {
          debugPrint('Polling error: $e');
        }
      },
    );
  }
  
  void _onBitcoinReceived(int confirmations) {
    _showSuccess('Pagamento Bitcoin recebido! Confirmações: $confirmations');
    setState(() {
      _bitcoinAddress = null;
      _bitcoinQrData = null;
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
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(
              icon: Icon(Icons.flash_on),
              text: 'Lightning',
            ),
            Tab(
              icon: Icon(Icons.link),
              text: 'On-chain',
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildLightningTab(),
          _buildOnchainTab(),
        ],
      ),
    );
  }
  
  Widget _buildLightningTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Amount input
          Card(
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
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _amountController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Valor em BRL',
                      prefixText: 'R\$ ',
                      border: OutlineInputBorder(),
                      hintText: '0.00',
                    ),
                    onChanged: (value) {
                      setState(() {}); // Update sats conversion
                    },
                  ),
                  const SizedBox(height: 8),
                  if (_amountBrl > 0)
                    Text(
                      '≈ ${_amountSats.toStringAsFixed(0)} sats',
                      style: TextStyle(
                        color: Colors.grey[600],
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
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.flash_on),
              label: Text(
                _isGeneratingLightning
                    ? 'Gerando...'
                    : 'Gerar Invoice Lightning',
              ),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.all(16),
              ),
            ),
          
          // Invoice display
          if (_lightningInvoice != null) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    const Text(
                      'Escaneie o QR Code ou copie a invoice',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
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
                        color: Colors.grey[100],
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
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.copy),
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
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Theme.of(context).primaryColor,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Text('Aguardando pagamento...'),
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
                      child: const Text('Cancelar'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
  
  Widget _buildOnchainTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Amount input
          Card(
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
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _amountController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Valor em BRL',
                      prefixText: 'R\$ ',
                      border: OutlineInputBorder(),
                      hintText: '0.00',
                    ),
                    onChanged: (value) {
                      setState(() {});
                    },
                  ),
                  const SizedBox(height: 8),
                  if (_amountBrl > 0)
                    Text(
                      '≈ ${_amountSats.toStringAsFixed(0)} sats',
                      style: TextStyle(
                        color: Colors.grey[600],
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
              networkFee: _estimatedNetworkFee,
            ),
          
          const SizedBox(height: 16),
          
          // Network fee info
          Card(
            color: Colors.blue[50],
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.blue[700]),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Taxa de Rede Estimada',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.blue[900],
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '≈ ${_estimatedNetworkFee.toStringAsFixed(8)} BTC',
                          style: TextStyle(color: Colors.blue[700]),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Depósitos on-chain requerem 1 confirmação',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.blue[600],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          
          const SizedBox(height: 16),
          
          // Generate address button
          if (_bitcoinAddress == null)
            ElevatedButton.icon(
              onPressed: _isGeneratingOnchain ? null : _generateBitcoinAddress,
              icon: _isGeneratingOnchain
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.link),
              label: Text(
                _isGeneratingOnchain
                    ? 'Gerando...'
                    : 'Gerar Endereço Bitcoin',
              ),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.all(16),
              ),
            ),
          
          // Address display
          if (_bitcoinAddress != null) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    const Text(
                      'Escaneie o QR Code ou copie o endereço',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
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
                      child: _bitcoinQrData != null ? QrImageView(
                        data: _bitcoinQrData!,
                        version: QrVersions.auto,
                        size: 250.0,
                        backgroundColor: Colors.white,
                      ) : const SizedBox.shrink(),
                    ),
                    const SizedBox(height: 16),
                    
                    // Address string
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.grey[100],
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _bitcoinAddress!,
                              style: const TextStyle(
                                fontSize: 12,
                                fontFamily: 'monospace',
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.copy),
                            onPressed: () => _copyToClipboard(
                              _bitcoinAddress!,
                              'Endereço',
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
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Theme.of(context).primaryColor,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Text('Aguardando confirmações...'),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _bitcoinAddress = null;
                          _bitcoinQrData = null;
                        });
                        _onchainPollingTimer?.cancel();
                      },
                      child: const Text('Cancelar'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
