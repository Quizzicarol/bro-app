import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import '../providers/breez_provider_export.dart';
import '../providers/order_provider.dart';
import '../services/payment_monitor_service.dart';

class OnchainPaymentScreen extends StatefulWidget {
  final String address;
  final double btcAmount;
  final double totalBrl;
  final int amountSats;
  final String orderId; // Pode ser vazio se ordem ainda n�o foi criada
  
  // ?? NOVOS CAMPOS: Dados para criar ordem AP�S pagamento
  final String? billType;
  final String? billCode;
  final double? billAmount;
  final double? btcPrice;

  const OnchainPaymentScreen({
    Key? key,
    required this.address,
    required this.btcAmount,
    required this.totalBrl,
    required this.amountSats,
    required this.orderId,
    this.billType,
    this.billCode,
    this.billAmount,
    this.btcPrice,
  }) : super(key: key);

  @override
  State<OnchainPaymentScreen> createState() => _OnchainPaymentScreenState();
}

class _OnchainPaymentScreenState extends State<OnchainPaymentScreen> {
  PaymentMonitorService? _monitor;
  bool _isPaid = false;
  int _confirmations = 0;
  int _secondsElapsed = 0;
  Timer? _timerForDisplay;
  String? _createdOrderId; // ID da ordem criada ap�s pagamento

  @override
  void initState() {
    super.initState();
    
    // Iniciar monitoramento autom�tico
    final breezProvider = context.read<BreezProvider>();
    final orderProvider = context.read<OrderProvider>();
    
    _monitor = PaymentMonitorService(breezProvider);
    _monitor!.monitorOnchainAddress(
      paymentId: widget.orderId.isNotEmpty ? widget.orderId : 'pending_${DateTime.now().millisecondsSinceEpoch}',
      address: widget.address,
      expectedSats: widget.amountSats,
      checkInterval: const Duration(seconds: 30), // On-chain � mais lento
      onStatusChange: (status, data) async {
        if (status == PaymentStatus.confirmed && !_isPaid) {
          setState(() {
            _isPaid = true;
            _confirmations = 1;
          });
          
          // ?? NOVO FLUXO: Criar ordem SOMENTE AGORA que o pagamento foi confirmado!
          String orderId = widget.orderId;
          
          if (orderId.isEmpty && widget.billType != null) {
            debugPrint('?? Pagamento on-chain confirmado! CRIANDO ORDEM AGORA...');
            
            final order = await orderProvider.createOrder(
              billType: widget.billType!,
              billCode: widget.billCode ?? '',
              amount: widget.billAmount ?? 0,
              btcAmount: widget.btcAmount,
              btcPrice: widget.btcPrice ?? 0,
            );
            
            if (order != null) {
              orderId = order.id;
              _createdOrderId = orderId;
              debugPrint('? Ordem CRIADA ap�s pagamento on-chain: $orderId');
            } else {
              debugPrint('? Falha ao criar ordem ap�s pagamento on-chain!');
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Erro ao criar ordem. Pagamento recebido mas ordem n�o foi criada.'),
                    backgroundColor: Colors.orange,
                    duration: Duration(seconds: 5),
                  ),
                );
              }
              return;
            }
          } else {
            // Ordem j� existe (fluxo antigo) - apenas publicar
            debugPrint('?? Pagamento on-chain confirmado! Publicando ordem existente...');
            final published = await orderProvider.publishOrderAfterPayment(orderId);
            if (published) {
              debugPrint('? Ordem publicada no Nostr - Bros agora podem v�-la!');
            } else {
              debugPrint('?? Falha ao publicar ordem no Nostr');
            }
          }
          
          // Atualizar status da ordem
          await orderProvider.updateOrderStatus(
            orderId: orderId,
            status: 'confirmed',
          );
          
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('? Pagamento on-chain confirmado!'),
                backgroundColor: Colors.green,
                duration: Duration(seconds: 5),
              ),
            );
          }
        }
      },
    );
    
    // Timer apenas para UI (contagem de tempo)
    _timerForDisplay = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (mounted) {
        setState(() {
          _secondsElapsed += 30;
        });
      }
    });
  }

  @override
  void dispose() {
    _monitor?.stopAll();
    _timerForDisplay?.cancel();
    super.dispose();
  }

  Future<void> _checkPaymentStatus() async {
    // N�o � mais necess�rio - o PaymentMonitorService cuida disso
  }

  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label copiado!'),
        backgroundColor: const Color(0xFF4CAF50),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String get bitcoinUri {
    // BIP21 format: bitcoin:address?amount=btc
    return 'bitcoin:${widget.address}?amount=${widget.btcAmount.toStringAsFixed(8)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Pagamento On-chain'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: _isPaid ? _buildSuccessView() : _buildPaymentView(),
    );
  }

  Widget _buildSuccessView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF4CAF50),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.check,
              size: 80,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 32),
          const Text(
            'Pagamento Detectado!',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '$_confirmations confirma��es',
            style: const TextStyle(
              fontSize: 18,
              color: Color(0x99FFFFFF),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Status card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF4CAF50), width: 1),
            ),
            child: Row(
              children: [
                const Icon(Icons.link, color: Color(0xFF4CAF50), size: 32),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Bitcoin On-chain',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Aguardando pagamento... (${(_secondsElapsed / 60).floor()} min)',
                        style: const TextStyle(
                          color: Color(0x99FFFFFF),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF4CAF50)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Amount display
          Card(
            color: const Color(0xFF1A1A1A),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  const Text(
                    'Valor a Pagar',
                    style: TextStyle(
                      color: Color(0x99FFFFFF),
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '? ${widget.btcAmount.toStringAsFixed(8)}',
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF4CAF50),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${widget.amountSats} sats',
                    style: const TextStyle(
                      fontSize: 16,
                      color: Color(0xFFFF6B6B),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'R\$ ${widget.totalBrl.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontSize: 18,
                      color: Color(0x99FFFFFF),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // QR Code
          const Text(
            'Escaneie o QR Code',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: QrImageView(
                data: bitcoinUri,
                version: QrVersions.auto,
                size: 250,
                backgroundColor: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Address field
          const Text(
            'Endere�o Bitcoin',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0x33FFFFFF)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.address,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontFamily: 'monospace',
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, color: Color(0xFF4CAF50)),
                  onPressed: () => _copyToClipboard(widget.address, 'Endere�o'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // BTC Amount field
          const Text(
            'Valor em Bitcoin',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0x33FFFFFF)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${widget.btcAmount.toStringAsFixed(8)} BTC',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'monospace',
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, color: Color(0xFF4CAF50)),
                  onPressed: () => _copyToClipboard(
                    widget.btcAmount.toStringAsFixed(8),
                    'Valor',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Warning
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0x1AFFB74D),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFFFB74D)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.warning_amber, color: Color(0xFFFFB74D), size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Aten��o',
                        style: TextStyle(
                          color: Color(0xFFFFB74D),
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Envie EXATAMENTE ${widget.btcAmount.toStringAsFixed(8)} BTC para o endere�o acima. Valores diferentes podem n�o ser processados.',
                        style: const TextStyle(
                          color: Color(0xFFFFB74D),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Instructions
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0x1A1E88E5),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF1E88E5)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.info_outline, color: Color(0xFF64B5F6), size: 20),
                    SizedBox(width: 8),
                    Text(
                      'Como pagar',
                      style: TextStyle(
                        color: Color(0xFF64B5F6),
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _buildInstructionItem('1. Abra sua carteira Bitcoin'),
                _buildInstructionItem('2. Envie o valor EXATO para o endere�o'),
                _buildInstructionItem('3. Aguarde 1-3 confirma��es (~10-30 min)'),
                _buildInstructionItem('4. O pagamento ser� processado automaticamente'),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Fee info
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0x1A666666),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              '?? Taxas de rede: Ser�o deduzidas do valor enviado pela sua carteira',
              style: TextStyle(
                color: Color(0x99FFFFFF),
                fontSize: 12,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 16),

          // Order ID
          Center(
            child: Text(
              'Ordem: ${widget.orderId}',
              style: const TextStyle(
                color: Color(0x66FFFFFF),
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInstructionItem(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '.  ',
            style: TextStyle(color: Color(0xFF64B5F6), fontSize: 14),
          ),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Color(0xFF64B5F6), fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}
