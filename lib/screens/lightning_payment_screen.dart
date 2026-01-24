import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:confetti/confetti.dart';
import 'dart:async';
import '../providers/breez_provider_export.dart';
import '../providers/order_provider.dart';
import '../services/platform_fee_service.dart';

class LightningPaymentScreen extends StatefulWidget {
  final String invoice;
  final int amountSats;
  final double totalBrl;
  final String orderId; // Pode ser vazio se ordem ainda não foi criada
  final String paymentHash;
  final String? receiver;
  
  // 🔥 NOVOS CAMPOS: Dados para criar ordem APÓS pagamento
  final String? billType;
  final String? billCode;
  final double? billAmount;
  final double? btcAmount;
  final double? btcPrice;

  const LightningPaymentScreen({
    Key? key,
    required this.invoice,
    required this.amountSats,
    required this.totalBrl,
    required this.orderId,
    required this.paymentHash,
    this.receiver,
    this.billType,
    this.billCode,
    this.billAmount,
    this.btcAmount,
    this.btcPrice,
  }) : super(key: key);

  @override
  State<LightningPaymentScreen> createState() => _LightningPaymentScreenState();
}

class _LightningPaymentScreenState extends State<LightningPaymentScreen> {
  late ConfettiController _confettiController;
  Timer? _checkPaymentTimer;
  StreamSubscription? _eventSubscription;
  bool _isPaid = false;
  bool _isChecking = false;
  String? _createdOrderId; // ID da ordem criada após pagamento

  @override
  void initState() {
    super.initState();
    _confettiController = ConfettiController(duration: const Duration(seconds: 3));
    _startPaymentCheck();
    _startEventListener();
    debugPrint('Configurando deteccao automatica de pagamento...');
    debugPrint('PaymentHash: ${widget.paymentHash}');
    debugPrint('Amount: ${widget.amountSats} sats');
  }

  @override
  void dispose() {
    _checkPaymentTimer?.cancel();
    _eventSubscription?.cancel();
    _confettiController.dispose();
    super.dispose();
  }

  /// Escuta eventos do SDK em tempo real (mais rápido que polling)
  void _startEventListener() {
    final breezProvider = context.read<BreezProvider>();
    _eventSubscription = breezProvider.sdk?.addEventListener().listen((event) {
      if (_isPaid) return;
      
      debugPrint('📡 Evento SDK: ${event.runtimeType}');
      
      // Detectar pagamento recebido instantaneamente
      if (event.toString().contains('PaymentSucceeded') || 
          event.toString().contains('InvoicePaid')) {
        debugPrint('⚡ Evento de pagamento detectado!');
        _checkPayment(); // Verificar imediatamente
      }
    });
    debugPrint('🎧 Escutando eventos do SDK em tempo real');
  }

  void _startPaymentCheck() {
    debugPrint('Iniciando polling a cada 3 segundos (backup)...');
    _checkPaymentTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (_isPaid) return;
      await _checkPayment();
    });
    debugPrint('Polling configurado - verificando a cada 3s');
  }

  Future<void> _checkPayment() async {
    if (_isChecking || _isPaid) return;
    setState(() => _isChecking = true);

    try {
      final breezProvider = context.read<BreezProvider>();
      final status = await breezProvider.checkPaymentStatus(widget.paymentHash);
      
      if (status['paid'] == true) {
        await _handlePaymentSuccess();
      }
    } catch (e) {
      debugPrint('Erro ao verificar pagamento: $e');
    } finally {
      if (mounted) {
        setState(() => _isChecking = false);
      }
    }
  }

  Future<void> _handlePaymentSuccess() async {
    if (_isPaid) return;
    setState(() => _isPaid = true);
    _checkPaymentTimer?.cancel();
    _confettiController.play();

    if (mounted) {
      final orderProvider = context.read<OrderProvider>();
      
      // 🔥 NOVO FLUXO: Criar ordem SOMENTE AGORA que o pagamento foi confirmado!
      // Isso evita criar ordens "fantasma" que não foram pagas
      String orderId = widget.orderId;
      
      if (orderId.isEmpty && widget.billType != null) {
        debugPrint('🚀 Pagamento confirmado! CRIANDO ORDEM AGORA...');
        
        final order = await orderProvider.createOrder(
          billType: widget.billType!,
          billCode: widget.billCode ?? '',
          amount: widget.billAmount ?? 0,
          btcAmount: widget.btcAmount ?? 0,
          btcPrice: widget.btcPrice ?? 0,
        );
        
        if (order != null) {
          orderId = order.id;
          _createdOrderId = orderId;
          debugPrint('✅ Ordem CRIADA após pagamento: $orderId');
          
          // Salvar paymentHash na ordem
          if (widget.paymentHash.isNotEmpty) {
            await orderProvider.setOrderPaymentHash(orderId, widget.paymentHash, widget.invoice);
            debugPrint('✅ PaymentHash salvo na ordem: ${widget.paymentHash}');
          }
        } else {
          debugPrint('❌ Falha ao criar ordem após pagamento!');
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Erro ao criar ordem. Pagamento recebido mas ordem não foi criada.'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 5),
            ),
          );
          return;
        }
      } else {
        // Ordem já existe (fluxo antigo) - apenas publicar
        debugPrint('🚀 Pagamento confirmado! Publicando ordem existente...');
        final published = await orderProvider.publishOrderAfterPayment(orderId);
        if (published) {
          debugPrint('✅ Ordem publicada no Nostr - Bros agora podem vê-la!');
        } else {
          debugPrint('⚠️ Falha ao publicar ordem no Nostr');
        }
      }
      
      // Status payment_received = usuário pagou via Lightning, aguardando Bro aceitar
      await orderProvider.updateOrderStatus(
        orderId: orderId,
        status: 'payment_received',
      );
      debugPrint('✅ Ordem $orderId atualizada para payment_received');

      // Registrar taxa da plataforma (2%)
      try {
        await PlatformFeeService.recordFee(
          orderId: orderId,
          transactionBrl: widget.totalBrl,
          transactionSats: widget.amountSats,
          providerPubkey: widget.receiver ?? 'unknown',
          clientPubkey: 'client',
        );
        debugPrint('Taxa da plataforma registrada');
      } catch (e) {
        debugPrint('Erro ao registrar taxa: $e');
      }

      // Mostrar mensagem e navegar para Minhas Ordens após 2 segundos
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Pagamento recebido! Agora aguarde um Bro aceitar sua ordem.'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 3),
        ),
      );

      // Aguardar 2 segundos e navegar para Detalhes da Ordem
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) {
        Navigator.of(context).pushNamedAndRemoveUntil(
          '/order-status',
          (route) => route.isFirst,
          arguments: {
            'orderId': orderId,
            'amountBrl': widget.totalBrl,
            'amountSats': widget.amountSats,
          },
        );
      }
    }
  }

  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label copiado!'),
        backgroundColor: const Color(0xFFFF6B6B),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        elevation: 0,
        title: const Text('Pagamento Lightning', style: TextStyle(color: Colors.white)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                if (_isPaid) ...[
                  const Icon(Icons.check_circle, color: Colors.green, size: 64),
                  const SizedBox(height: 16),
                  const Text(
                    'Pagamento Confirmado!',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.green),
                  ),
                  const SizedBox(height: 32),
                ] else ...[
                  const CircularProgressIndicator(valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFFF6B6B))),
                  const SizedBox(height: 16),
                  const Text('Aguardando pagamento...', style: TextStyle(fontSize: 16, color: Colors.white70)),
                  const SizedBox(height: 24),
                ],

                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: QrImageView(
                    data: widget.invoice,
                    size: 220,
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
                const SizedBox(height: 24),

                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A1A),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      Text(
                        'R\$ ${widget.totalBrl.toStringAsFixed(2)}',
                        style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Color(0xFFFF6B6B)),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${widget.amountSats} sats',
                        style: const TextStyle(fontSize: 16, color: Colors.white70),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // Mensagem de status
                if (_isPaid) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.green.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.green),
                    ),
                    child: const Column(
                      children: [
                        Icon(Icons.check_circle, color: Colors.green, size: 32),
                        SizedBox(height: 8),
                        Text(
                          'Pagamento confirmado!',
                          style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Agora é só aguardar um Bro aceitar sua ordem.',
                          style: TextStyle(color: Colors.white70, fontSize: 13),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),

                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A1A),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    children: [
                      const Text('Invoice Lightning', style: TextStyle(color: Colors.white70, fontSize: 12)),
                      const SizedBox(height: 8),
                      Text(
                        '${widget.invoice.substring(0, 30)}...',
                        style: const TextStyle(color: Colors.white, fontSize: 12, fontFamily: 'monospace'),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () => _copyToClipboard(widget.invoice, 'Invoice'),
                    icon: const Icon(Icons.copy, color: Colors.white),
                    label: const Text('Copiar Invoice', style: TextStyle(color: Colors.white)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF6B6B),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A1A),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF333333)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Como pagar:', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 12),
                      _buildInstructionItem('1. Abra sua carteira Lightning'),
                      _buildInstructionItem('2. Escaneie o QR code ou cole a invoice'),
                      _buildInstructionItem('3. Confirme o pagamento'),
                      _buildInstructionItem('4. Aguarde a confirmacao'),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                Center(
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancelar', style: TextStyle(color: Colors.white70)),
                  ),
                ),
              ],
            ),
          ),
          Align(
            alignment: Alignment.topCenter,
            child: ConfettiWidget(
              confettiController: _confettiController,
              blastDirectionality: BlastDirectionality.explosive,
              particleDrag: 0.05,
              emissionFrequency: 0.05,
              numberOfParticles: 50,
              gravity: 0.1,
              colors: const [Colors.green, Colors.blue, Colors.orange, Colors.pink],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInstructionItem(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const Icon(Icons.arrow_right, color: Color(0xFFFF6B6B), size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}