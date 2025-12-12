import 'dart:math';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:breez_sdk_spark_flutter/breez_sdk_spark.dart' as spark;
import 'package:intl/intl.dart';
import '../providers/order_provider.dart';
import '../providers/breez_provider_export.dart';
import '../widgets/fee_breakdown_card.dart';
import '../services/payment_monitor_service.dart';
import '../services/storage_service.dart';
import '../services/order_service.dart';
import 'onchain_payment_screen.dart';

class PaymentScreen extends StatefulWidget {
  const PaymentScreen({Key? key}) : super(key: key);

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> {
  final _codeController = TextEditingController();
  bool _isScanning = false;
  bool _isProcessing = false;
  Map<String, dynamic>? _billData;
  Map<String, dynamic>? _conversionData;
  bool _autoDetectionEnabled = true;

  @override
  void initState() {
    super.initState();
    // Listener para detecção automática de código colado
    _codeController.addListener(_onCodeChanged);
    debugPrint('💳 PaymentScreen inicializado - _isProcessing: $_isProcessing');
  }

  // Método para forçar reset do estado de processamento
  void _forceResetProcessing() {
    debugPrint('🔄 Forçando reset de _isProcessing');
    if (mounted) {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  void _onCodeChanged() {
    if (!_autoDetectionEnabled || _isProcessing) return;
    
    final code = _codeController.text.trim();
    
    // Detectar PIX (começa com 00020126) ou Boleto (linha digitável de 47 dígitos)
    if (code.length >= 30) {
      if (code.startsWith('00020126') || _isValidBoletoCode(code)) {
        // Aguardar 500ms após última digitação antes de processar
        Future.delayed(const Duration(milliseconds: 500), () {
          if (_codeController.text.trim() == code && !_isProcessing) {
            _processBill(code);
          }
        });
      }
    }
  }

  bool _isValidBoletoCode(String code) {
    // Linha digitável do boleto tem 47 ou 48 dígitos
    final cleanCode = code.replaceAll(RegExp(r'[^\d]'), '');
    return cleanCode.length == 47 || cleanCode.length == 48;
  }

  @override
  void dispose() {
    _codeController.removeListener(_onCodeChanged);
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _processBill(String code) async {
    debugPrint('📝 _processBill iniciado - _isProcessing antes: $_isProcessing');
    setState(() {
      _isProcessing = true;
      _billData = null;
      _conversionData = null;
    });
    debugPrint('🔒 _isProcessing setado para TRUE');

    final orderProvider = context.read<OrderProvider>();

    try {
      Map<String, dynamic>? result;
      String billType;

      // Detectar tipo de código
      final cleanCode = code.replaceAll(RegExp(r'[^\d]'), '');
      final isPix = code.contains('00020126') || code.contains('pix.') || code.contains('br.gov.bcb');
      
      debugPrint('🔍 Processando código: ${code.substring(0, min(50, code.length))}');
      debugPrint('📊 Tipo detectado: ${isPix ? "PIX" : "Boleto"}');

      if (isPix) {
        result = await orderProvider.decodePix(code);
        billType = 'pix';
      } else if (cleanCode.length >= 47) {
        result = await orderProvider.validateBoleto(cleanCode);
        billType = result != null ? (result['type'] as String? ?? 'boleto') : 'boleto';
      } else {
        _showError('Código inválido. Use um código PIX ou linha digitável de boleto.');
        return;
      }

      debugPrint('📨 Resposta da API: $result');

      if (result != null && result['success'] == true) {
        debugPrint('✅ Decodificação bem-sucedida: $result');
        
        final Map<String, dynamic> billDataMap = {};
        result.forEach((key, value) {
          billDataMap[key] = value;
        });
        billDataMap['billType'] = billType;
        
        setState(() {
          _billData = billDataMap;
        });

        final dynamic valueData = result['value'];
        final double amount = (valueData is num) ? valueData.toDouble() : 0.0;
        
        debugPrint('💰 Chamando convertPrice com amount: $amount');
        final conversion = await orderProvider.convertPrice(amount);
        debugPrint('📊 Resposta do convertPrice: $conversion');

        if (conversion != null && conversion['success'] == true) {
          setState(() {
            _conversionData = conversion;
          });
          debugPrint('✅ Conversão calculada - Breakdown de taxas e botão "Criar Ordem" serão exibidos');
          debugPrint('💎 Conversion data: $conversion');
        } else {
          debugPrint('❌ Falha na conversão: ${conversion?['error']}');
          _showError('Erro ao calcular conversão: ${conversion?['error'] ?? 'Desconhecido'}');
        }
      } else {
        debugPrint('❌ Resultado inválido: $result');
        _showError('Código inválido ou não reconhecido');
      }
    } catch (e) {
      _showError('Erro ao processar: $e');
    } finally {
      debugPrint('🔓 _processBill finally - resetando _isProcessing');
      setState(() {
        _isProcessing = false;
      });
      debugPrint('✅ _isProcessing setado para FALSE');
    }
  }

    Future<void> _showLightningInvoiceDialog({
      required String invoice,
      required String paymentHash,
      required int amountSats,
      required double totalBrl,
      required String orderId,
      String? receiver,
    }) async {
      final orderProvider = context.read<OrderProvider>();
      final breezProvider = context.read<BreezProvider>();

      bool isPaid = false;
      bool dialogClosed = false; // Flag para saber se dialog foi fechado
      StreamSubscription<spark.SdkEvent>? eventSub;
      
      // Listen to SDK events for payment confirmation
      debugPrint('💡 Escutando eventos do Breez SDK para pagamento $paymentHash');
      eventSub = breezProvider.sdk?.addEventListener().listen((event) {
        debugPrint('📡 Evento recebido: ${event.runtimeType}');
        
        // IMPORTANTE: Não processar se dialog já foi fechado
        if (dialogClosed) {
          debugPrint('⚠️ Dialog já fechado, ignorando evento');
          return;
        }
        
        if (event is spark.SdkEvent_PaymentSucceeded && !isPaid) {
          final payment = event.payment;
          debugPrint('✅ PaymentSucceeded recebido! Payment ID: ${payment.id}');
          
          // Verificar se é o pagamento correto através do payment hash E valor
          if (payment.details is spark.PaymentDetails_Lightning) {
            final details = payment.details as spark.PaymentDetails_Lightning;
            final receivedAmount = payment.amount.toInt();
            
            // Validações: payment hash deve bater E valor deve ser >= 95% do esperado
            final isCorrectHash = details.paymentHash == paymentHash;
            final isCorrectAmount = receivedAmount >= (amountSats * 0.95).round();
            
            if (isCorrectHash && isCorrectAmount) {
              isPaid = true;
              debugPrint('🎉 É o nosso pagamento! Hash: ✅ Valor: $receivedAmount sats ✅');
              
              orderProvider.updateOrderStatus(orderId: orderId, status: 'confirmed');
              
              // Fechar o dialog atual e mostrar tela de sucesso
              try {
                // Tentar fechar o dialog de QR code
                Navigator.of(context, rootNavigator: true).pop();
                debugPrint('✅ Dialog de QR code fechado');
                // Aguardar um frame para garantir que o dialog anterior foi fechado
                Future.delayed(const Duration(milliseconds: 100), () {
                  showDialog(
                    context: context,
                    barrierDismissible: false,
                    builder: (context) => AlertDialog(
                      backgroundColor: const Color(0xFF121212),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      title: Row(
                        children: [
                          const Icon(Icons.check_circle, color: Colors.green, size: 32),
                          const SizedBox(width: 12),
                          const Text('Pagamento Confirmado!', style: TextStyle(color: Colors.white)),
                        ],
                      ),
                      content: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '✅ Seu pagamento Lightning foi recebido com sucesso!',
                            style: TextStyle(color: Colors.white, fontSize: 16),
                          ),
                          const SizedBox(height: 16),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.green,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.green),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Valor: $amountSats sats',
                                  style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold),
                                ),
                                Text(
                                  'R\$ ${totalBrl.toStringAsFixed(2)}',
                                  style: const TextStyle(color: Colors.white70),
                                ),
                                if (receiver != null) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    'Recebedor: $receiver',
                                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                                  ),
                                ],
                                const SizedBox(height: 8),
                                Text(
                                  'ID: ${payment.id.substring(0, 16)}...',
                                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      actions: [
                        TextButton(
                          onPressed: () {
                            debugPrint('📋 Botão "Ver Minhas Ordens" clicado');
                            eventSub?.cancel();
                            debugPrint('🔌 EventSub cancelado');
                            // Navegar para Minhas Ordens
                            Navigator.of(context, rootNavigator: true).pushNamedAndRemoveUntil(
                              '/user-orders',
                              (route) => route.isFirst,
                              arguments: {'userId': 'user_test_001'},
                            );
                            debugPrint('✅ Navegou para Minhas Ordens');
                          },
                          style: TextButton.styleFrom(
                            backgroundColor: Colors.green,
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                          ),
                          child: const Text(
                            'Ver Minhas Ordens',
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                  );
                });
              } catch (e) {
                debugPrint('❌ Erro ao mostrar dialog de confirmação: $e');
              }
            }
          }
        }
      });

      final result = await showDialog(
        context: context,
        barrierDismissible: true,
        builder: (ctx) {
          return WillPopScope(
            onWillPop: () async {
              // Cancelar listener ao fechar o dialog
              debugPrint('⚠️ Dialog fechado pelo usuário');
              dialogClosed = true; // Marcar como fechado ANTES de cancelar
              eventSub?.cancel();
              return true;
            },
            child: AlertDialog(
              backgroundColor: const Color(0xFF121212),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Text('Pagar via Lightning', style: TextStyle(color: Colors.white)),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                      child: QrImageView(
                        data: invoice,
                        version: QrVersions.auto,
                        size: 220,
                        backgroundColor: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text('$amountSats sats', style: const TextStyle(color: Colors.orange, fontSize: 18, fontWeight: FontWeight.bold)),
                    Text('R\$ ${totalBrl.toStringAsFixed(2)}', style: const TextStyle(color: Colors.white70)),
                    if (receiver != null) ...[
                      const SizedBox(height: 8),
                      Text('Recebedor: $receiver', style: const TextStyle(color: Colors.white60, fontSize: 12))
                    ],
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: invoice));
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Invoice copiada')),
                          );
                        }
                      },
                      icon: const Icon(Icons.copy, size: 16, color: Colors.orange),
                      label: const Text('Copiar invoice'),
                    ),
                    const SizedBox(height: 8),
                    isPaid
                        ? const Icon(Icons.check_circle, color: Colors.green, size: 32)
                        : const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange),
                          ),
                    const SizedBox(height: 4),
                    Text(isPaid ? 'Pago' : 'Aguardando pagamento...', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  ],
                ),
              ),
              actions: [
              TextButton(
                onPressed: () {
                  debugPrint('🔴 Botão Fechar clicado');
                  eventSub?.cancel();
                  debugPrint('🔌 EventSub cancelado');
                  Navigator.of(ctx).pop();
                  debugPrint('✅ Dialog fechado');
                },
                child: const Text('Fechar'),
              ),
            ],
          ),
        );
      },
      ).whenComplete(() {
        // Cleanup: cancelar subscription de eventos
        debugPrint('🧹 whenComplete executado');
        dialogClosed = true; // Marcar como fechado
        eventSub?.cancel();
        debugPrint('🔌 Event subscription cancelada no whenComplete');
      });
      
      // Se o result for null, significa que o usuário fechou o dialog
      debugPrint('📍 Após showDialog - result: $result');
      if (result == null && mounted) {
        debugPrint('⚠️ Dialog fechado sem resultado - garantindo cleanup');
        dialogClosed = true;
        eventSub?.cancel();
      }
    }
 

  void _showBitcoinPaymentOptions(double totalBrl, String sats) {
    debugPrint('🔵 _showBitcoinPaymentOptions chamado: totalBrl=$totalBrl, sats=$sats');
    // sats já está em formato correto (satoshis), só converter para BTC quando necessário
    final btcAmount = int.parse(sats) / 100000000; // Convert sats to BTC for display
    debugPrint('🔵 BTC amount: $btcAmount, abrindo bottom sheet...');
    
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      isScrollControlled: true,
      isDismissible: true,
      enableDrag: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) => Padding(
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            controller: scrollController,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const Text(
                  'Escolha o método de pagamento',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'R\$ ${totalBrl.toStringAsFixed(2)} ≈ $sats sats',
                  style: const TextStyle(
                    fontSize: 16,
                    color: Color(0x99FFFFFF),
                  ),
                ),
                const SizedBox(height: 24),
                
                // Lightning Network
                ListTile(
                  onTap: () {
                    Navigator.pop(context);
                    _createPayment(paymentType: 'lightning', totalBrl: totalBrl, sats: sats, btcAmount: btcAmount);
                  },
                  leading: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF6B35),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.bolt, color: Colors.white, size: 28),
                  ),
                  title: const Text(
                    'Lightning Network',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  subtitle: const Text(
                    'Instantâneo • Taxas baixas • Recomendado',
                    style: TextStyle(color: Color(0x99FFFFFF), fontSize: 13),
                  ),
                  trailing: const Icon(Icons.arrow_forward_ios, color: Colors.white, size: 16),
                ),
                const SizedBox(height: 16),
                
                // On-chain
                ListTile(
                  onTap: () {
                    Navigator.pop(context);
                    _createPayment(paymentType: 'onchain', totalBrl: totalBrl, sats: sats, btcAmount: btcAmount);
                  },
                  leading: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF4CAF50),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.link, color: Colors.white, size: 28),
                  ),
                  title: const Text(
                    'Bitcoin On-chain',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  subtitle: const Text(
                    'Rede principal • Mais seguro • Pode demorar',
                    style: TextStyle(color: Color(0x99FFFFFF), fontSize: 13),
                  ),
                  trailing: const Icon(Icons.arrow_forward_ios, color: Colors.white, size: 16),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _createPayment({
    required String paymentType,
    required double totalBrl,
    required String sats,
    required double btcAmount,
  }) async {
    debugPrint('🚀 _createPayment iniciado: $paymentType');
    
    if (_billData == null || _conversionData == null) {
      debugPrint('❌ Dados da conta ausentes');
      _showError('Dados da conta não encontrados');
      return;
    }

    final orderProvider = context.read<OrderProvider>();
    final breezProvider = context.read<BreezProvider>();

    debugPrint('💳 _createPayment iniciado - _isProcessing antes: $_isProcessing');
    setState(() {
      _isProcessing = true;
    });
    debugPrint('🔒 _isProcessing setado para TRUE em _createPayment');

    try {
      final dynamic valueData = _billData!['value'];
      final double billAmount = (valueData is num) ? valueData.toDouble() : 0.0;
      
      final dynamic priceData = _conversionData!['bitcoinPrice'];
      final double btcPrice = (priceData is num) ? priceData.toDouble() : 0.0;

      debugPrint('💰 Criando ordem: R\$ $billAmount @ R\$ $btcPrice/BTC');

      final order = await orderProvider.createOrder(
        billType: _billData!['billType'] as String,
        billCode: _codeController.text.trim(),
        amount: billAmount,
        btcAmount: btcAmount,
        btcPrice: btcPrice,
      );

      if (order == null) {
        debugPrint('❌ Falha ao criar ordem');
        _showError('Erro ao criar ordem');
        return;
      }

      debugPrint('✅ Ordem criada: ${order.id}');

      if (!mounted) {
        debugPrint('⚠️ Widget desmontado');
        return;
      }

      final amountSats = int.parse(sats);
      
      if (paymentType == 'lightning') {
        debugPrint('⚡ Criando invoice Lightning...');
        
        // Create Lightning invoice and navigate to Lightning payment screen with timeout
        final invoiceData = await breezProvider.createInvoice(
          amountSats: amountSats,
          description: 'Paga Conta ${order.id}',
        ).timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            debugPrint('⏰ Timeout ao criar invoice Lightning');
            return {'success': false, 'error': 'Timeout ao criar invoice'};
          },
        );

        debugPrint('📨 Invoice data: $invoiceData');

        if (invoiceData != null && (invoiceData['success'] == true)) {
          final inv = (invoiceData['invoice'] ?? '') as String;
          if (inv.isEmpty || !(inv.startsWith('lnbc') || inv.startsWith('lntb') || inv.startsWith('lnbcrt'))) {
            debugPrint('❌ Invoice inválida: $inv');
            _showError('Invoice inválida recebida');
            return;
          }
          debugPrint('✅ Invoice válida, abrindo dialog...');
          
          if (!mounted) return;
          
          // Reset processing flag before showing dialog
          setState(() {
            _isProcessing = false;
          });
          
          // Show inline Lightning payment dialog with polling
          await _showLightningInvoiceDialog(
            invoice: inv,
            paymentHash: (invoiceData['paymentHash'] ?? '') as String,
            amountSats: amountSats,
            totalBrl: totalBrl,
            orderId: order.id,
            receiver: invoiceData['receiver'] as String?,
          );
        } else {
          debugPrint('❌ Erro ao criar invoice');
          _showError('Erro ao criar Lightning invoice: ${invoiceData?['error'] ?? 'desconhecido'}');
        }
      } else {
        debugPrint('🔗 Criando endereço onchain...');
        
        // Create on-chain address and navigate to On-chain payment screen
        final addressData = await breezProvider.createOnchainAddress();

        debugPrint('📨 Address data: $addressData');

        if (addressData != null && addressData['success'] == true && mounted) {
          final address = addressData['swap']?['bitcoinAddress'] ?? '';
          
          if (address.isEmpty) {
            debugPrint('❌ Endereço vazio');
            _showError('Erro ao criar endereço Bitcoin');
            return;
          }
          
          debugPrint('✅ Endereço criado: $address, navegando...');
          
          // Navigate to On-chain payment screen
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => OnchainPaymentScreen(
                address: address,
                btcAmount: btcAmount,
                totalBrl: totalBrl,
                amountSats: amountSats,
                orderId: order.id,
              ),
            ),
          );
        } else {
          debugPrint('❌ Erro ao criar endereço onchain');
          _showError('Erro ao criar endereço Bitcoin: ${addressData?['error'] ?? 'desconhecido'}');
        }
      }
    } catch (e) {
      debugPrint('❌ Exception em _createPayment: $e');
      _showError('Erro ao criar pagamento: $e');
    } finally {
      debugPrint('🔓 _createPayment finally - mounted: $mounted');
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
        debugPrint('✅ _isProcessing setado para FALSE em _createPayment');
      } else {
        debugPrint('⚠️ Widget não montado, não pode resetar _isProcessing');
      }
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    debugPrint('🔄 PaymentScreen build - _isProcessing: $_isProcessing');
    return Scaffold(
      appBar: AppBar(
        title: const Text('Novo Pagamento'),
        actions: [
          // Botão de debug para resetar estado
          if (_isProcessing)
            IconButton(
              icon: const Icon(Icons.refresh, color: Colors.orange),
              tooltip: 'Reset (Debug)',
              onPressed: _forceResetProcessing,
            ),
        ],
      ),
      body: _isScanning ? _buildScanner() : _buildForm(),
    );
  }

  Widget _buildScanner() {
    return Stack(
      children: [
        MobileScanner(
          onDetect: (capture) {
            final List<Barcode> barcodes = capture.barcodes;
            for (final barcode in barcodes) {
              final rawValue = barcode.rawValue;
              if (rawValue != null) {
                setState(() {
                  _isScanning = false;
                  _codeController.text = rawValue;
                });
                _processBill(rawValue);
                break;
              }
            }
          },
        ),
        Positioned(
          top: 16,
          right: 16,
          child: FloatingActionButton(
            mini: true,
            onPressed: () {
              setState(() {
                _isScanning = false;
              });
            },
            child: const Icon(Icons.close),
          ),
        ),
        const Positioned(
          bottom: 32,
          left: 0,
          right: 0,
          child: Text(
            'Aponte para o código de barras ou QR Code',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              backgroundColor: Colors.black54,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _codeController,
                  decoration: const InputDecoration(
                    labelText: 'Código PIX ou Boleto',
                    hintText: 'Cole ou escaneie o código',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 3,
                ),
              ),
              const SizedBox(width: 8),
              FloatingActionButton(
                mini: true,
                onPressed: () {
                  setState(() {
                    _isScanning = true;
                  });
                },
                child: const Icon(Icons.qr_code_scanner),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _isProcessing || _codeController.text.trim().isEmpty
                ? null
                : () => _processBill(_codeController.text.trim()),
            icon: _isProcessing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.search),
            label: const Text('Processar Código'),
          ),
          const SizedBox(height: 24),
          if (_billData != null) ..._buildBillInfo(),
          if (_conversionData != null) ..._buildConversionInfo(),
        ],
      ),
    );
  }

  List<Widget> _buildBillInfo() {
    final billType = _billData!['billType'] as String? ?? 'pix';
    final value = _billData!['value'];
    final valueStr = (value is num) ? value.toStringAsFixed(2) : '0.00';
    
    return [
      // Alert de sucesso na detecção
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0x1A4CAF50), // rgba(76, 175, 80, 0.1)
          border: Border.all(
            color: const Color(0xFF4CAF50),
            width: 1,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: const [
            Icon(Icons.check_circle, color: Color(0xFF4CAF50), size: 20),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                '✅ Valor detectado automaticamente',
                style: TextStyle(
                  color: Color(0xFF4CAF50),
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      Card(
        color: const Color(0x0DFFFFFF), // rgba(255, 255, 255, 0.05)
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(
            color: Color(0x33FF6B35), // rgba(255, 107, 53, 0.2)
            width: 1,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    billType == 'pix' ? Icons.pix : Icons.receipt,
                    color: const Color(0xFFFF6B35),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    billType == 'pix' ? 'PIX' : 'Boleto',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
              const Divider(height: 24, color: Color(0x33FF6B35)),
              _InfoRow(label: 'Valor', value: 'R\$ $valueStr'),
              if (_billData!['merchantName'] != null)
                _InfoRow(label: 'Beneficiário', value: _billData!['merchantName'] as String),
              if (_billData!['type'] != null)
                _InfoRow(label: 'Tipo', value: _billData!['type'] as String),
            ],
          ),
        ),
      ),
      const SizedBox(height: 16),
    ];
  }

  List<Widget> _buildConversionInfo() {
    final btcAmount = _conversionData!['bitcoinAmount'];
    final btcAmountSats = (btcAmount is num) ? (btcAmount.toDouble() * 100000000).toStringAsFixed(0) : '0';
    
    final btcPrice = _conversionData!['bitcoinPrice'];
    final btcPriceStr = (btcPrice is num) ? btcPrice.toStringAsFixed(2) : '0.00';
    
    final billValue = _billData!['value'];
    final billValueStr = (billValue is num) ? billValue.toStringAsFixed(2) : '0.00';
    
    // Calculate fees (provider 5%, platform 2% - igual web)
    final accountValue = (billValue is num) ? billValue.toDouble() : 0.0;
    final providerFeePercent = 5.0;
    final platformFeePercent = 2.0;
    final providerFee = accountValue * (providerFeePercent / 100.0);
    final platformFee = accountValue * (platformFeePercent / 100.0);
    final totalBrl = accountValue + providerFee + platformFee;
    
    // Calcular sats totais baseado no valor total com taxas
    // btcAmount é o valor em BTC para pagar APENAS a conta
    // Precisamos calcular o BTC total (conta + taxas)
    final btcPriceNum = (btcPrice is num) ? btcPrice.toDouble() : 0.0;
    final totalBtc = btcPriceNum > 0 ? totalBrl / btcPriceNum : 0.0;
    final totalSats = (totalBtc * 100000000).round();
    
    // Calcular taxa de conversão BRL → Sats
    final brlToSatsRate = totalSats > 0 ? totalSats / totalBrl : 0.0;

    return [
      const SizedBox(height: 8),
      // Info sobre taxas
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0x1A1E88E5), // rgba(30, 136, 229, 0.1)
          border: Border.all(color: const Color(0xFF1E88E5)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: const [
            Icon(Icons.info_outline, color: Color(0xFF64B5F6), size: 18),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                '💡 Confira abaixo o detalhamento completo das taxas',
                style: TextStyle(
                  color: Color(0xFF64B5F6),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      FeeBreakdownCard(
        accountValue: accountValue,
        providerFee: providerFee,
        providerFeePercent: providerFeePercent,
        platformFee: platformFee,
        platformFeePercent: platformFeePercent,
        totalBrl: totalBrl,
        totalSats: totalSats,
        brlToSatsRate: brlToSatsRate.isFinite ? brlToSatsRate : 0.0,
        networkFee: null,
      ),
      const SizedBox(height: 16),
      Card(
        color: Colors.orange.shade50,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.currency_bitcoin, color: Colors.orange.shade900),
                  const SizedBox(width: 8),
                  Text(
                    'Pagamento em Bitcoin',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.orange.shade900,
                    ),
                  ),
                ],
              ),
              Divider(height: 24, color: Colors.orange.shade300),
              _InfoRow(
                label: 'Valor em Bitcoin',
                value: '$totalSats sats',
                valueColor: Colors.orange.shade900,
              ),
              _InfoRow(
                label: 'Cotação BTC',
                value: '${NumberFormat.currency(locale: 'pt_BR', symbol: 'R\$').format(btcPrice)}/BTC',
              ),
              _InfoRow(
                label: 'Total a Pagar',
                value: 'R\$ ${totalBrl.toStringAsFixed(2)}',
                valueColor: Colors.orange.shade900,
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 24),
      ElevatedButton.icon(
        onPressed: _isProcessing ? null : () => _showBitcoinPaymentOptions(totalBrl, totalSats.toString()),
        icon: const Icon(Icons.currency_bitcoin),
        label: const Text('Pagar com Bitcoin', style: TextStyle(fontSize: 16)),
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 16),
          backgroundColor: const Color(0xFFFF6B35),
        ),
      ),
    ];
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _InfoRow({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: Colors.grey.shade800, fontSize: 14)),
          Text(value, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: valueColor ?? Colors.grey.shade900)),
        ],
      ),
    );
  }
}
