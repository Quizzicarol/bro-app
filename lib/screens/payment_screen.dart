import 'dart:math';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:breez_sdk_spark_flutter/breez_sdk_spark.dart' as spark;
import 'package:bro_app/services/log_utils.dart';
import 'package:intl/intl.dart';
import '../providers/order_provider.dart';
import '../providers/breez_provider_export.dart';
import '../providers/lightning_provider.dart';
import '../services/local_collateral_service.dart';
import '../services/platform_fee_service.dart';
import '../l10n/app_localizations.dart';
import '../widgets/fee_breakdown_card.dart';
import 'onchain_payment_screen.dart';
import 'lightning_payment_screen.dart';

class PaymentScreen extends StatefulWidget {
  const PaymentScreen({Key? key}) : super(key: key);

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> {
  final _codeController = TextEditingController();
  final _scrollController = ScrollController();
  bool _isScanning = false;
  bool _isProcessing = false;
  Map<String, dynamic>? _billData;
  Map<String, dynamic>? _conversionData;
  String? _errorMessage;

  /// Mascara o nome do beneficiário para privacidade
  /// Mostra apenas o primeiro nome e hachurado o resto
  String _maskBeneficiaryName(String fullName) {
    if (fullName.isEmpty) return '';
    
    final parts = fullName.trim().split(' ');
    if (parts.isEmpty) return fullName;
    
    final firstName = parts[0];
    if (parts.length == 1) {
      // Se só tem um nome, mostra as 3 primeiras letras + ***
      if (firstName.length <= 3) return firstName;
      return '${firstName.substring(0, 3)}***';
    }
    
    // Mostra primeiro nome + resto hachurado
    final restMasked = parts.skip(1).map((p) => '***').join(' ');
    return '$firstName $restMasked';
  }
  bool _autoDetectionEnabled = true;

  @override
  void initState() {
    super.initState();
    // Listener para detecção automática de código colado
    _codeController.addListener(_onCodeChanged);
    broLog('💳 PaymentScreen inicializado - _isProcessing: $_isProcessing');
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
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _processBill(String code) async {
    broLog('📝 _processBill iniciado - _isProcessing antes: $_isProcessing');
    if (!mounted) return;
    setState(() {
      _isProcessing = true;
      _billData = null;
      _conversionData = null;
      _errorMessage = null;
    });
    broLog('🔒 _isProcessing setado para TRUE');

    final orderProvider = context.read<OrderProvider>();

    try {
      Map<String, dynamic>? result;
      String billType;

      // Detectar tipo de código
      final cleanCode = code.replaceAll(RegExp(r'[^\d]'), '');
      final isPix = code.contains('00020126') || code.contains('pix.') || code.contains('br.gov.bcb');
      
      broLog('🔍 Processando código: ${code.substring(0, min(50, code.length))}');
      broLog('📊 Tipo detectado: ${isPix ? "PIX" : "Boleto"}');

      if (isPix) {
        result = await orderProvider.decodePix(code);
        billType = 'pix';
      } else if (cleanCode.length >= 47) {
        result = await orderProvider.validateBoleto(cleanCode);
        billType = result != null ? (result['type'] as String? ?? 'boleto') : 'boleto';
      } else {
        if (!mounted) return;
        _showError(AppLocalizations.of(context).t('payment_invalid_code'));
        return;
      }

      broLog('📨 Resposta da API: $result');

      if (!mounted) return;
      
      if (result != null && result['success'] == true) {
        broLog('✅ Decodificação bem-sucedida: $result');
        
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
        
        // VALIDAÇÃO: Limites de valor para ordens
        const double minOrderBrl = 0.01;  // Mínimo R$ 0.01 para testes
        const double maxOrderBrl = 200.0; // TEMPORÁRIO: Máximo R$ 200 para fase de testes externos
        
        if (amount < minOrderBrl) {
          if (!mounted) return;
          _showError(AppLocalizations.of(context).tp('payment_value_too_low', {'min': minOrderBrl.toStringAsFixed(2)}));
          setState(() {
            _isProcessing = false;
          });
          return;
        }
        
        if (amount > maxOrderBrl) {
          if (!mounted) return;
          _showError(AppLocalizations.of(context).tp('payment_value_too_high', {'max': maxOrderBrl.toStringAsFixed(2)}));
          setState(() {
            _isProcessing = false;
          });
          return;
        }
        
        broLog('💰 Chamando convertPrice com amount: $amount');
        final conversion = await orderProvider.convertPrice(amount);
        broLog('📊 Resposta do convertPrice: $conversion');

        if (!mounted) return;
        
        if (conversion != null && conversion['success'] == true) {
          setState(() {
            _conversionData = conversion;
          });
          broLog('✅ Conversão calculada - Breakdown de taxas e botão "Criar Ordem" serão exibidos');
          broLog('💎 Conversion data: $conversion');
        } else {
          broLog('❌ Falha na conversão: ${conversion?['error']}');
          _showError(AppLocalizations.of(context).tp('payment_conversion_error', {'error': conversion?['error'] ?? 'Unknown'}));
        }
      } else {
        broLog('❌ Resultado inválido: $result');
        _showError(AppLocalizations.of(context).t('payment_invalid_or_unrecognized'));
      }
    } catch (e) {
      if (!mounted) return;
      _showError('Erro ao processar: $e');
    } finally {
      broLog('🔓 _processBill finally - resetando _isProcessing');
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
      broLog('✅ _isProcessing setado para FALSE');
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
      bool isProcessingPayment = false; // Lock para evitar processamento duplicado
      bool dialogClosed = false; // Flag para saber se dialog foi fechado
      StreamSubscription<spark.SdkEvent>? eventSub;
      
      // Listen to SDK events for payment confirmation
      broLog('💡 Escutando eventos do Breez SDK para pagamento $paymentHash');
      eventSub = breezProvider.sdk?.addEventListener().listen((event) {
        broLog('📡 Evento recebido: ${event.runtimeType}');
        
        // IMPORTANTE: Não processar se dialog já foi fechado ou já processando
        if (dialogClosed || isProcessingPayment) {
          broLog('⚠️ Dialog fechado ou já processando, ignorando evento');
          return;
        }
        
        if (event is spark.SdkEvent_PaymentSucceeded && !isPaid) {
          // Marcar como processando ANTES de qualquer operação
          isProcessingPayment = true;
          
          final payment = event.payment;
          broLog('✅ PaymentSucceeded recebido! Payment ID: ${payment.id}');
          
          // Verificar se é o pagamento correto através do payment hash E valor
          if (payment.details is spark.PaymentDetails_Lightning) {
            final details = payment.details as spark.PaymentDetails_Lightning;
            final receivedAmount = payment.amount.toInt();
            
            // Validações: payment hash deve bater E valor deve ser >= 95% do esperado
            final isCorrectHash = details.paymentHash == paymentHash;
            final isCorrectAmount = receivedAmount >= (amountSats * 0.95).round();
            
            if (isCorrectHash && isCorrectAmount) {
              isPaid = true;
              broLog('🎉 É o nosso pagamento! Hash: ✅ Valor: $receivedAmount sats ✅');
              
              orderProvider.updateOrderStatus(orderId: orderId, status: 'confirmed');
              
              // Fechar o dialog atual e mostrar tela de sucesso
              try {
                // Tentar fechar o dialog de QR code
                Navigator.of(context, rootNavigator: true).pop();
                broLog('✅ Dialog de QR code fechado');
                // Aguardar um frame para garantir que o dialog anterior foi fechado
                Future.delayed(const Duration(milliseconds: 100), () {
                  showDialog(
                    context: context,
                    barrierDismissible: false,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: const Color(0xFF121212),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      title: Row(
                        children: [
                          const Icon(Icons.check_circle, color: Colors.green, size: 32),
                          const SizedBox(width: 12),
                          Text(AppLocalizations.of(ctx).t('payment_confirmed'), style: const TextStyle(color: Colors.white)),
                        ],
                      ),
                      content: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            AppLocalizations.of(ctx).t('payment_lightning_received'),
                            style: const TextStyle(color: Colors.white, fontSize: 16),
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
                                  AppLocalizations.of(ctx).tp('payment_amount_sats', {'amount': amountSats}),
                                  style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold),
                                ),
                                Text(
                                  'R\$ ${totalBrl.toStringAsFixed(2)}',
                                  style: const TextStyle(color: Colors.white70),
                                ),
                                if (receiver != null) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    AppLocalizations.of(ctx).tp('payment_receiver', {'receiver': receiver}),
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
                            broLog('📋 Botão "Ver Detalhes" clicado');
                            eventSub?.cancel();
                            broLog('🔌 EventSub cancelado');
                            // Navegar para Detalhes da Ordem
                            Navigator.of(ctx, rootNavigator: true).pushNamedAndRemoveUntil(
                              '/order-status',
                              (route) => route.isFirst,
                              arguments: {
                                'orderId': orderId,
                                'amountBrl': totalBrl,
                                'amountSats': amountSats,
                              },
                            );
                            broLog('✅ Navegou para Detalhes da Ordem');
                          },
                          style: TextButton.styleFrom(
                            backgroundColor: Colors.green,
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                          ),
                          child: Text(
                            AppLocalizations.of(ctx).t('payment_view_order_details'),
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                  );
                });
              } catch (e) {
                broLog('❌ Erro ao mostrar dialog de confirmação: $e');
              }
            }
          }
        }
      });

      final result = await showDialog(
        context: context,
        barrierDismissible: true,
        builder: (ctx) {
          broLog('🎨 DIALOG BUILDER CHAMADO - invoice length: ${invoice.length}');
          return WillPopScope(
            onWillPop: () async {
              // Cancelar listener ao fechar o dialog
              broLog('⚠️ Dialog fechado pelo usuário');
              dialogClosed = true; // Marcar como fechado ANTES de cancelar
              eventSub?.cancel();
              return true;
            },
            child: AlertDialog(
              backgroundColor: const Color(0xFF121212),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Text(AppLocalizations.of(ctx).t('payment_pay_via_lightning'), style: const TextStyle(color: Colors.white)),
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
                    const SizedBox(height: 12),
                    Text('$amountSats sats', style: const TextStyle(color: Colors.orange, fontSize: 18, fontWeight: FontWeight.bold)),
                    Text('R\$ ${totalBrl.toStringAsFixed(2)}', style: const TextStyle(color: Colors.white70)),
                    if (receiver != null) ...[
                      const SizedBox(height: 8),
                      Text(AppLocalizations.of(ctx).tp('payment_receiver', {'receiver': receiver}), style: const TextStyle(color: Colors.white60, fontSize: 12))
                    ],
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: invoice));
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(AppLocalizations.of(context).t('payment_invoice_copied'))),
                          );
                        }
                      },
                      icon: const Icon(Icons.copy, size: 16, color: Colors.orange),
                      label: Text(AppLocalizations.of(ctx).t('payment_copy_invoice')),
                    ),
                    const SizedBox(height: 8),
                    isPaid
                        ? const Icon(Icons.check_circle, color: Colors.green, size: 32)
                        : const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFFF6B6B)),
                          ),
                    const SizedBox(height: 4),
                    Text(isPaid ? AppLocalizations.of(ctx).t('payment_paid') : AppLocalizations.of(ctx).t('payment_awaiting'), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  ],
                ),
              ),
              actions: [
              TextButton(
                onPressed: () {
                  broLog('🔴 Botão Fechar clicado');
                  eventSub?.cancel();
                  broLog('🔌 EventSub cancelado');
                  Navigator.of(ctx).pop();
                  broLog('✅ Dialog fechado');
                },
                child: Text(AppLocalizations.of(ctx).t('close')),
              ),
            ],
          ),
        );
      },
      ).whenComplete(() {
        // Cleanup: cancelar subscription de eventos
        broLog('🧹 whenComplete executado');
        dialogClosed = true; // Marcar como fechado
        eventSub?.cancel();
        broLog('🔌 Event subscription cancelada no whenComplete');
      });
      
      // Se o result for null, significa que o usuário fechou o dialog
      broLog('📍 Após showDialog - result: $result');
      if (result == null && mounted) {
        broLog('⚠️ Dialog fechado sem resultado - garantindo cleanup');
        dialogClosed = true;
        eventSub?.cancel();
      }
    }
 

  void _showBitcoinPaymentOptions(double totalBrl, String sats) {
    broLog('🔵 _showBitcoinPaymentOptions chamado: totalBrl=$totalBrl, sats=$sats');
    final btcAmount = int.parse(sats) / 100000000;
    final amountSats = int.parse(sats);

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppLocalizations.of(ctx).t('payment_how_to_pay'),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '$amountSats sats (~R\$ ${totalBrl.toStringAsFixed(2)})',
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 20),
              // Opção 1: Lightning Invoice
              _buildPaymentOptionTile(
                icon: Icons.flash_on,
                iconColor: const Color(0xFFFFD700),
                title: AppLocalizations.of(ctx).t('payment_lightning_invoice_title'),
                subtitle: AppLocalizations.of(ctx).t('payment_lightning_subtitle'),
                onTap: () {
                  Navigator.pop(ctx);
                  _createPayment(paymentType: 'lightning', totalBrl: totalBrl, sats: sats, btcAmount: btcAmount);
                },
              ),
              const SizedBox(height: 12),
              // Opção 2: Saldo da Carteira
              _buildPaymentOptionTile(
                icon: Icons.account_balance_wallet,
                iconColor: const Color(0xFF4CAF50),
                title: AppLocalizations.of(ctx).t('payment_wallet_balance_label'),
                subtitle: AppLocalizations.of(ctx).t('payment_wallet_subtitle'),
                onTap: () {
                  Navigator.pop(ctx);
                  _payWithWalletBalance(totalBrl: totalBrl, sats: sats, btcAmount: btcAmount);
                },
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPaymentOptionTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF2A2A2A),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 28),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 13)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white38),
          ],
        ),
      ),
    );
  }

  /// Pagar com saldo da carteira - sem invoice, débito direto
  Future<void> _payWithWalletBalance({
    required double totalBrl,
    required String sats,
    required double btcAmount,
  }) async {
    if (_isProcessing) return;
    final amountSats = int.parse(sats);
    final lightningProvider = context.read<LightningProvider>();
    final orderProvider = context.read<OrderProvider>();

    // 1. Verificar saldo DISPONÍVEL (descontando sats já travados em wallet payments)
    int walletBalance;
    try {
      walletBalance = await lightningProvider.getBalance();
    } catch (e) {
      _showError(AppLocalizations.of(context).tp('payment_error_check_balance', {'error': e.toString()}));
      return;
    }

    // v257: Descontar sats já travados em ordens wallet anteriores
    final lockedSats = orderProvider.committedSats;
    final availableBalance = walletBalance - lockedSats;

    if (availableBalance < amountSats) {
      final msg = lockedSats > 0 
          ? AppLocalizations.of(context).tp('payment_insufficient_balance_detailed', {'total': walletBalance.toString(), 'locked': lockedSats.toString(), 'available': availableBalance.toString(), 'needed': amountSats.toString()})
          : AppLocalizations.of(context).tp('payment_insufficient_balance_simple', {'available': walletBalance.toString(), 'needed': amountSats.toString()});
      _showError(msg);
      return;
    }

    // 2. Verificar se pagamento vai comprometer garantia de tier (Bro mode)
    final userPubkey = orderProvider.currentUserPubkey ?? '';
    if (userPubkey.isNotEmpty) {
      final collateralService = LocalCollateralService();
      final collateral = await collateralService.getCollateral(userPubkey: userPubkey);
      if (collateral != null && collateral.requiredSats > 0) {
        final remainingAfterPayment = walletBalance - amountSats;
        if (remainingAfterPayment < collateral.requiredSats) {
          // Mostrar aviso sobre tier
          final confirmed = await _showTierWarningDialog(
            tierName: collateral.tierName,
            requiredSats: collateral.requiredSats,
            currentBalance: walletBalance,
            afterPayment: remainingAfterPayment,
          );
          if (confirmed != true) return;
        }
      }
    }

    // 3. Criar invoice para si mesmo e pagar (garante registro na cadeia Lightning)
    setState(() => _isProcessing = true);

    // Mostrar loading
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => WillPopScope(
        onWillPop: () async => false,
        child: AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Color(0xFF4CAF50)),
              const SizedBox(height: 20),
              Text(
                AppLocalizations.of(ctx).t('payment_paying_with_wallet'),
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(AppLocalizations.of(ctx).t('payment_please_wait'), style: const TextStyle(color: Colors.white70, fontSize: 14)),
            ],
          ),
        ),
      ),
    );

    try {
      if (_billData == null || _conversionData == null) {
        if (mounted) Navigator.of(context).pop();
        _showError(AppLocalizations.of(context).t('payment_bill_data_not_found'));
        return;
      }

      final dynamic valueData = _billData!['value'];
      final double billAmount = (valueData is num) ? valueData.toDouble() : 0.0;
      final dynamic priceData = _conversionData!['bitcoinPrice'];
      final double btcPrice = (priceData is num) ? priceData.toDouble() : 0.0;

      // Gerar paymentHash local (sem auto-pagamento - débito direto)
      final walletPayId = DateTime.now().millisecondsSinceEpoch.toRadixString(16);
      final paymentHash = 'wallet_$walletPayId';
      final invoice = 'wallet_balance_payment_$walletPayId';

      broLog('💰 Pagamento com saldo da carteira: $amountSats sats (hash: $paymentHash)');

      // Criar ordem diretamente (sem auto-pagamento Lightning)
      final order = await orderProvider.createOrder(
        billType: _billData!['billType'] as String,
        billCode: _codeController.text.trim(),
        amount: billAmount,
        btcAmount: btcAmount,
        btcPrice: btcPrice,
      ).timeout(const Duration(seconds: 15), onTimeout: () {
        return null;
      });

      if (order == null) {
        if (mounted) Navigator.of(context).pop();
        _showError(AppLocalizations.of(context).t('payment_error_creating_order'));
        return;
      }

      broLog('✅ Ordem criada: ${order.id}');

      // Fechar loading e navegar IMEDIATAMENTE
      if (mounted) Navigator.of(context).pop();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).t('payment_wallet_success')),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 3),
          ),
        );
        
        Navigator.of(context).pushNamedAndRemoveUntil(
          '/order-status',
          (route) => route.isFirst,
          arguments: {
            'orderId': order.id,
            'amountBrl': totalBrl,
            'amountSats': amountSats,
          },
        );
      }

      // Fire-and-forget: atualizar Nostr em background (não bloqueia a UI)
      _completeWalletPaymentInBackground(
        orderProvider: orderProvider,
        orderId: order.id,
        paymentHash: paymentHash,
        invoice: invoice,
        totalBrl: totalBrl,
        amountSats: amountSats,
        userPubkey: userPubkey,
      );
    } catch (e) {
      broLog('❌ Erro em _payWithWalletBalance: $e');
      if (mounted) Navigator.of(context).pop();
      _showError(AppLocalizations.of(context).tp('payment_error_wallet_pay', {'error': e.toString()}));
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  /// Completa operações de Nostr em background após criar ordem com saldo da carteira
  Future<void> _completeWalletPaymentInBackground({
    required OrderProvider orderProvider,
    required String orderId,
    required String paymentHash,
    required String invoice,
    required double totalBrl,
    required int amountSats,
    required String userPubkey,
  }) async {
    try {
      // Salvar paymentHash (com timeout)
      if (paymentHash.isNotEmpty) {
        await orderProvider.setOrderPaymentHash(orderId, paymentHash, invoice)
            .timeout(const Duration(seconds: 15), onTimeout: () {
          broLog('⚠️ Timeout ao salvar paymentHash (15s) - continuando...');
        });
      }

      // v259: NÃO publicar payment_received no Nostr para wallet payments!
      // A ordem deve permanecer 'pending' nos relays para que provedores possam vê-la.
      // payment_received só faz sentido quando o provedor confirma recebimento Lightning.
      // Apenas salvar o status LOCALMENTE para a UI mostrar o progresso.
      orderProvider.updateOrderStatusLocalOnly(
        orderId: orderId,
        status: 'payment_received',
      );

      // Registrar taxa da plataforma (2%)
      try {
        await PlatformFeeService.recordFee(
          orderId: orderId,
          transactionBrl: totalBrl,
          transactionSats: amountSats,
          providerPubkey: 'unknown',
          clientPubkey: userPubkey,
        );
      } catch (e) {
        broLog('Erro ao registrar taxa: $e');
      }

      broLog('✅ Operações background do wallet payment concluídas para ordem $orderId');
    } catch (e) {
      broLog('⚠️ Erro em operações background do wallet payment: $e');
    }
  }

  /// Diálogo de aviso sobre comprometimento da garantia de tier
  Future<bool?> _showTierWarningDialog({
    required String tierName,
    required int requiredSats,
    required int currentBalance,
    required int afterPayment,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Color(0xFFFF9800), size: 28),
            const SizedBox(width: 10),
            Text(AppLocalizations.of(ctx).t('payment_tier_warning_title'), style: const TextStyle(color: Colors.white, fontSize: 18)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppLocalizations.of(ctx).tp('payment_tier_warning_body', {'tierName': tierName}),
              style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
            ),
            const SizedBox(height: 16),
            _buildTierInfoRow(AppLocalizations.of(ctx).t('payment_required_collateral'), '$requiredSats sats'),
            _buildTierInfoRow(AppLocalizations.of(ctx).t('payment_current_balance'), '$currentBalance sats'),
            _buildTierInfoRow(AppLocalizations.of(ctx).t('payment_balance_after'), '$afterPayment sats', isNegative: afterPayment < requiredSats),
            const SizedBox(height: 16),
            Text(
              AppLocalizations.of(ctx).t('payment_tier_warning_detail'),
              style: const TextStyle(color: Color(0xFFFF9800), fontSize: 13, fontStyle: FontStyle.italic),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppLocalizations.of(ctx).t('cancel'), style: const TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF6B6B),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppLocalizations.of(ctx).t('payment_pay_anyway'), style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _buildTierInfoRow(String label, String value, {bool isNegative = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 13)),
          Text(
            value,
            style: TextStyle(
              color: isNegative ? const Color(0xFFFF6B6B) : Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _createPayment({
    required String paymentType,
    required double totalBrl,
    required String sats,
    required double btcAmount,
  }) async {
    broLog('🚀 _createPayment iniciado: $paymentType');
    
    // Fechar teclado
    FocusScope.of(context).unfocus();
    
    if (_billData == null || _conversionData == null) {
      broLog('❌ Dados da conta ausentes');
      _showError(AppLocalizations.of(context).t('payment_bill_data_not_found'));
      return;
    }

    final orderProvider = context.read<OrderProvider>();
    final breezProvider = context.read<BreezProvider>();

    broLog('💳 _createPayment iniciado - _isProcessing antes: $_isProcessing');
    
    // Mostrar popup de loading "Criando invoice"
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => WillPopScope(
        onWillPop: () async => false,
        child: AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Color(0xFFFF6B6B)),
              const SizedBox(height: 20),
              Text(
                paymentType == 'lightning' ? AppLocalizations.of(ctx).t('payment_creating_lightning') : AppLocalizations.of(ctx).t('payment_generating_btc'),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                AppLocalizations.of(ctx).t('payment_please_wait'),
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
    
    setState(() {
      _isProcessing = true;
    });
    broLog('🔒 _isProcessing setado para TRUE em _createPayment');

    try {
      final dynamic valueData = _billData!['value'];
      final double billAmount = (valueData is num) ? valueData.toDouble() : 0.0;
      
      final dynamic priceData = _conversionData!['bitcoinPrice'];
      final double btcPrice = (priceData is num) ? priceData.toDouble() : 0.0;
      final amountSats = int.parse(sats);

      broLog('💰 Preparando pagamento: R\$ $billAmount @ R\$ $btcPrice/BTC');

      if (paymentType == 'lightning') {
        broLog('⚡ Criando invoice Lightning PRIMEIRO...');
        
        // 🔥 NOVO FLUXO: Criar invoice ANTES da ordem!
        // Isso evita criar ordem "fantasma" se usuário sair da tela
        // Usa LightningProvider com fallback Spark -> Liquid
        final lightningProvider = context.read<LightningProvider>();
        final invoiceData = await lightningProvider.createInvoice(
          amountSats: amountSats,
          description: 'Bro Payment',
        ).timeout(
          const Duration(seconds: 45), // Timeout maior para fallback
          onTimeout: () {
            broLog('⏰ Timeout ao criar invoice Lightning');
            return {'success': false, 'error': 'Timeout ao criar invoice'};
          },
        );

        broLog('📨 Invoice data: $invoiceData');
        
        // Log se usou Liquid
        if (invoiceData?['isLiquid'] == true) {
          broLog('💧 Invoice criada via LIQUID (fallback)');
        }

        if (invoiceData == null || invoiceData['success'] != true) {
          // Fechar popup de loading
          if (mounted) Navigator.of(context).pop();
          broLog('❌ Erro ao criar invoice');
          _showError(AppLocalizations.of(context).tp('payment_error_creating_invoice', {'error': invoiceData?['error'] ?? 'unknown'}));
          return;
        }
        
        final inv = (invoiceData['invoice'] ?? '') as String;
        if (inv.isEmpty || !(inv.startsWith('lnbc') || inv.startsWith('lntb') || inv.startsWith('lnbcrt'))) {
          if (mounted) Navigator.of(context).pop();
          broLog('❌ Invoice inválida: $inv');
          _showError(AppLocalizations.of(context).t('payment_invalid_invoice'));
          return;
        }
        
        final paymentHash = (invoiceData['paymentHash'] ?? '') as String;
        broLog('✅ Invoice criada! NÃO criando ordem ainda - só após pagamento!');
        
        // Fechar popup de loading
        if (mounted) Navigator.of(context).pop();
        
        if (!mounted) return;
        
        // Reset processing flag before navigating
        setState(() {
          _isProcessing = false;
        });
        
        // 🔥 NOVO FLUXO: NÃO criar ordem agora!
        // Ordem será criada SOMENTE quando pagamento for confirmado
        // Passar dados da conta para LightningPaymentScreen criar a ordem depois
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => LightningPaymentScreen(
              invoice: inv,
              paymentHash: paymentHash,
              amountSats: amountSats,
              totalBrl: totalBrl,
              orderId: '', // Ordem será criada após pagamento
              receiver: invoiceData['receiver'] as String?,
              // Dados para criar ordem após pagamento
              billType: _billData!['billType'] as String,
              billCode: _codeController.text.trim(),
              billAmount: billAmount,
              btcAmount: btcAmount,
              btcPrice: btcPrice,
            ),
          ),
        );
      } else {
        broLog('🔗 Criando endereço onchain PRIMEIRO...');
        
        // 🔥 NOVO FLUXO: Criar endereço ANTES da ordem!
        final addressData = await breezProvider.createOnchainAddress();

        broLog('📨 Address data: $addressData');

        if (addressData == null || addressData['success'] != true) {
          if (mounted) Navigator.of(context).pop();
          broLog('❌ Erro ao criar endereço onchain');
          _showError(AppLocalizations.of(context).tp('payment_error_btc_address', {'error': addressData?['error'] ?? 'unknown'}));
          return;
        }
        
        final address = addressData['swap']?['bitcoinAddress'] ?? '';
        
        if (address.isEmpty) {
          if (mounted) Navigator.of(context).pop();
          broLog('❌ Endereço vazio');
          _showError(AppLocalizations.of(context).t('payment_error_btc_address_generic'));
          return;
        }
        
        broLog('✅ Endereço criado! NÃO criando ordem ainda - só após pagamento!');
        
        // Fechar popup de loading
        if (mounted) Navigator.of(context).pop();
        
        if (!mounted) return;
        
        // 🔥 NOVO FLUXO: NÃO criar ordem agora!
        // Ordem será criada SOMENTE quando pagamento for confirmado
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => OnchainPaymentScreen(
              address: address,
              btcAmount: btcAmount,
              totalBrl: totalBrl,
              amountSats: amountSats,
              orderId: '', // Ordem será criada após pagamento
              // Dados para criar ordem após pagamento
              billType: _billData!['billType'] as String,
              billCode: _codeController.text.trim(),
              billAmount: billAmount,
              btcPrice: btcPrice,
            ),
          ),
        );
      }
    } catch (e) {
      broLog('❌ Exception em _createPayment: $e');
      // Fechar popup de loading em caso de erro
      if (mounted) Navigator.of(context).pop();
      _showError(AppLocalizations.of(context).tp('payment_error_creating_payment', {'error': e.toString()}));
    } finally {
      broLog('🔓 _createPayment finally - mounted: $mounted');
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
        broLog('✅ _isProcessing setado para FALSE em _createPayment');
      } else {
        broLog('⚠️ Widget não montado, não pode resetar _isProcessing');
      }
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() => _errorMessage = message);
  }

  void _clearError() {
    if (mounted && _errorMessage != null) {
      setState(() => _errorMessage = null);
    }
  }

  Widget _buildErrorCard() {
    if (_errorMessage == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _errorMessage!,
              style: const TextStyle(color: Colors.red, fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
          GestureDetector(
            onTap: _clearError,
            child: const Icon(Icons.close, color: Colors.red, size: 18),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        // Retrair teclado ao tocar no fundo da tela
        FocusScope.of(context).unfocus();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(AppLocalizations.of(context).t('payment_title')),

        ),
        body: _isScanning ? _buildScanner() : _buildForm(),
      ),
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
        Positioned(
          bottom: 32,
          left: 0,
          right: 0,
          child: Text(
            AppLocalizations.of(context).t('payment_point_to_barcode'),
            textAlign: TextAlign.center,
            style: const TextStyle(
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
      controller: _scrollController,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _codeController,
                  decoration: InputDecoration(
                    labelText: AppLocalizations.of(context).t('payment_code_label'),
                    hintText: AppLocalizations.of(context).t('payment_code_hint'),
                    border: const OutlineInputBorder(),
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
          
          // Instruções de como funciona
          if (_billData == null) ...[
            const SizedBox(height: 24),
            _buildInstructionsCard(),
          ],
          
          _buildErrorCard(),
          if (_billData != null) ..._buildBillInfo(),
          if (_conversionData != null) ..._buildConversionInfo(),
          
          // Extra space for navigation
          const SizedBox(height: 80),
        ],
      ),
    );
  }
  
  Widget _buildInstructionsCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x33FF6B6B)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.help_outline, color: Color(0xFFFF6B6B), size: 24),
              const SizedBox(width: 8),
              Text(
                AppLocalizations.of(context).t('payment_how_it_works'),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildInstructionStep('1', AppLocalizations.of(context).t('payment_step1')),
          const SizedBox(height: 12),
          _buildInstructionStep('2', AppLocalizations.of(context).t('payment_step2')),
          const SizedBox(height: 12),
          _buildInstructionStep('3', AppLocalizations.of(context).t('payment_step3')),
          const SizedBox(height: 12),
          _buildInstructionStep('4', AppLocalizations.of(context).t('payment_step4')),
          const SizedBox(height: 12),
          _buildInstructionStep('5', AppLocalizations.of(context).t('payment_step5')),
          const SizedBox(height: 12),
          _buildInstructionStep('6', AppLocalizations.of(context).t('payment_step6')),
          const SizedBox(height: 16),
          // v237: Aviso sobre vencimento de contas
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0x1AFF9800),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0x33FF9800)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.warning_amber_rounded, color: Color(0xFFFF9800), size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    AppLocalizations.of(context).t('payment_expiration_warning'),
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFFFF9800),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0x1A3DE98C),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.security, color: Color(0xFF3DE98C), size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        AppLocalizations.of(context).t('payment_escrow_explanation'),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF3DE98C),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  AppLocalizations.of(context).t('payment_auto_release_warning'),
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xB3FFFFFF),
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildInstructionStep(String number, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: const Color(0xFFFF6B6B),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Center(
            child: Text(
              number,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              color: Color(0xB3FFFFFF),
              fontSize: 14,
            ),
          ),
        ),
      ],
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
          children: [
            const Icon(Icons.check_circle, color: Color(0xFF4CAF50), size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                AppLocalizations.of(context).t('payment_value_auto_detected'),
                style: const TextStyle(
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
                    color: const Color(0xFFFF6B6B),
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
              _InfoRow(label: AppLocalizations.of(context).t('payment_value_label'), value: 'R\$ $valueStr', labelColor: const Color(0xB3FFFFFF), valueColor: Colors.white),
              if (_billData!['merchantName'] != null)
                _InfoRow(label: AppLocalizations.of(context).t('payment_beneficiary'), value: _maskBeneficiaryName(_billData!['merchantName'] as String), labelColor: const Color(0xB3FFFFFF), valueColor: Colors.white),
              if (_billData!['type'] != null)
                _InfoRow(label: AppLocalizations.of(context).t('payment_type'), value: _billData!['type'] as String, labelColor: const Color(0xB3FFFFFF), valueColor: Colors.white),
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
    
    // Calculate fees (provider 3%, platform 0% - não cobrando taxa de plataforma por enquanto)
    final accountValue = (billValue is num) ? billValue.toDouble() : 0.0;
    final providerFeePercent = 3.0;  // Taxa do Bro: 3%
    final platformFeePercent = 0.0; // Taxa de plataforma desativada
    final providerFee = accountValue * (providerFeePercent / 100.0);
    final platformFee = 0.0; // Não cobrando
    final totalBrl = accountValue + providerFee; // Apenas valor + taxa do Bro
    
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
          children: [
            const Icon(Icons.info_outline, color: Color(0xFF64B5F6), size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                AppLocalizations.of(context).t('payment_fee_breakdown_hint'),
                style: const TextStyle(
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
                    AppLocalizations.of(context).t('payment_bitcoin_payment'),
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
                label: AppLocalizations.of(context).t('payment_value_in_bitcoin'),
                value: '$totalSats sats',
                valueColor: Colors.orange.shade900,
              ),
              _InfoRow(
                label: AppLocalizations.of(context).t('payment_btc_quote'),
                value: '${NumberFormat.currency(locale: 'pt_BR', symbol: 'R\$').format(btcPrice)}/BTC',
              ),
              _InfoRow(
                label: AppLocalizations.of(context).t('payment_total_to_pay'),
                value: 'R\$ ${totalBrl.toStringAsFixed(2)}',
                valueColor: Colors.orange.shade900,
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 24),
      _isProcessing
          ? Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFFFF6B6B),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    AppLocalizations.of(context).t('payment_creating_invoice'),
                    style: const TextStyle(
                      fontSize: 16,
                      color: Color(0xFFFF6B6B),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            )
          : ElevatedButton.icon(
              onPressed: () => _showBitcoinPaymentOptions(totalBrl, totalSats.toString()),
              icon: const Icon(Icons.currency_bitcoin),
              label: Text(AppLocalizations.of(context).t('payment_pay_with_bitcoin'), style: const TextStyle(fontSize: 16)),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                backgroundColor: const Color(0xFFFF6B6B),
              ),
            ),
    ];
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  final Color? labelColor;

  const _InfoRow({required this.label, required this.value, this.valueColor, this.labelColor});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            flex: 2,
            child: Text(label, style: TextStyle(color: labelColor ?? Colors.grey.shade800, fontSize: 14)),
          ),
          const SizedBox(width: 8),
          Flexible(
            flex: 3,
            child: Text(
              value,
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: valueColor ?? Colors.grey.shade900),
              textAlign: TextAlign.end,
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
            ),
          ),
        ],
      ),
    );
  }
}
