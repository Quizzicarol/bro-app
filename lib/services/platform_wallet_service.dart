import 'dart:async';
import 'package:flutter/material.dart';
import 'package:breez_sdk_spark_flutter/breez_sdk_spark.dart' as spark;
import 'package:path_provider/path_provider.dart';
import 'package:bip39/bip39.dart' as bip39;
import '../config/breez_config.dart';
import '../extensions/breez_extensions.dart';

/// Carteira Master da Plataforma para Escrow e Split de Taxas
/// 
/// Esta carteira é controlada APENAS pelo administrador da plataforma.
/// Fluxo:
/// 1. Cliente paga para esta carteira (via invoice gerada aqui)
/// 2. Plataforma retém 2% de taxa
/// 3. Plataforma envia 98% para o provedor automaticamente
class PlatformWalletService {
  static PlatformWalletService? _instance;
  static bool _rustLibInitialized = false;
  
  spark.BreezSdk? _sdk;
  bool _isInitialized = false;
  bool _isLoading = false;
  String? _error;
  String? _mnemonic;
  
  static const double platformFeePercent = 0.02;
  
  static PlatformWalletService get instance {
    _instance ??= PlatformWalletService._();
    return _instance!;
  }
  
  PlatformWalletService._();
  
  bool get isInitialized => _isInitialized;
  bool get isLoading => _isLoading;
  String? get error => _error;
  String? get mnemonic => _mnemonic;
  spark.BreezSdk? get sdk => _sdk;

  /// Inicializa a carteira master da plataforma
  Future<bool> initialize({String? mnemonic}) async {
    if (_isInitialized) return true;
    if (_isLoading) return false;
    
    _isLoading = true;
    _error = null;
    
    debugPrint('🏦 Inicializando Carteira Master da Plataforma...');
    
    try {
      if (!_rustLibInitialized) {
        await spark.BreezSdkSparkLib.init();
        _rustLibInitialized = true;
      }
      
      if (mnemonic != null && mnemonic.isNotEmpty) {
        _mnemonic = mnemonic;
        debugPrint('🔑 Usando mnemonic existente');
      } else {
        _mnemonic = bip39.generateMnemonic();
        debugPrint('🆕 Nova carteira master gerada');
        // SEGURANÇA: NUNCA imprimir mnemonic em logs!
        // O mnemonic deve ser mostrado apenas na UI para backup
      }
      
      final seed = spark.Seed.mnemonic(mnemonic: _mnemonic!);
      final appDir = await getApplicationDocumentsDirectory();
      final storageDir = '${appDir.path}/platform_wallet';
      
      final network = BreezConfig.useMainnet ? spark.Network.mainnet : spark.Network.regtest;
      final config = spark.defaultConfig(network: network).copyWith(
        apiKey: BreezConfig.apiKey,
      );
      
      debugPrint('🔗 Conectando carteira master ($network)...');
      
      _sdk = await spark.connect(
        request: spark.ConnectRequest(
          config: config,
          seed: seed,
          storageDir: storageDir,
        ),
      );
      
      _isInitialized = true;
      debugPrint('✅ Carteira Master inicializada!');
      
      _syncInBackground();
      
      return true;
    } catch (e) {
      _error = 'Erro ao inicializar carteira master: $e';
      debugPrint('❌ $_error');
      return false;
    } finally {
      _isLoading = false;
    }
  }

  Future<void> _syncInBackground() async {
    if (_sdk == null) return;
    try {
      await _sdk!.syncWallet(request: spark.SyncWalletRequest());
      final info = await _sdk!.getInfo(request: spark.GetInfoRequest());
      debugPrint('🏦 Saldo Master: ${info.balanceSats} sats');
    } catch (e) {
      debugPrint('⚠️ Erro sync: $e');
    }
  }

  /// Cria invoice para receber pagamento (cliente paga aqui)
  Future<Map<String, dynamic>?> createEscrowInvoice({
    required int amountSats,
    required String orderId,
    required String providerLightningAddress,
    String? description,
  }) async {
    if (!_isInitialized || _sdk == null) {
      return {'success': false, 'error': 'Carteira master não inicializada'};
    }
    
    debugPrint('📥 Criando invoice escrow de $amountSats sats...');
    
    try {
      final resp = await _sdk!.receivePayment(
        request: spark.ReceivePaymentRequest(
          paymentMethod: spark.ReceivePaymentMethod.bolt11Invoice(
            description: description ?? 'Bro Escrow - Order $orderId',
            amountSats: BigInt.from(amountSats),
          ),
        ),
      );
      
      final invoice = resp.paymentRequest;
      
      String? paymentHash;
      try {
        final parsed = await _sdk!.parse(input: invoice);
        if (parsed is spark.InputType_Bolt11Invoice) {
          paymentHash = parsed.field0.paymentHash;
        }
      } catch (_) {}
      
      debugPrint('✅ Invoice escrow criada');
      
      return {
        'success': true,
        'invoice': invoice,
        'paymentHash': paymentHash,
        'amountSats': amountSats,
        'orderId': orderId,
        'providerAddress': providerLightningAddress,
      };
    } catch (e) {
      debugPrint('❌ Erro criando invoice escrow: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Processa o split - envia para provedor
  Future<Map<String, dynamic>> processSplit({
    required int totalSats,
    required String providerInvoice, // BOLT11 invoice do provedor
  }) async {
    if (!_isInitialized || _sdk == null) {
      return {'success': false, 'error': 'Carteira master não inicializada'};
    }
    
    final platformFeeSats = (totalSats * platformFeePercent).round();
    final providerAmountSats = totalSats - platformFeeSats;
    
    debugPrint('💰 Processando split:');
    debugPrint('   Total recebido: $totalSats sats');
    debugPrint('   Taxa plataforma (2%): $platformFeeSats sats');
    debugPrint('   Para provedor: $providerAmountSats sats');
    
    try {
      // Preparar pagamento
      final prepareResp = await _sdk!.prepareSendPayment(
        request: spark.PrepareSendPaymentRequest(
          paymentRequest: providerInvoice,
          amount: null,
          tokenIdentifier: null,
        ),
      );
      
      // Enviar pagamento
      final sendResp = await _sdk!.sendPayment(
        request: spark.SendPaymentRequest(
          prepareResponse: prepareResp,
          options: null,
        ),
      );
      
      debugPrint('✅ Pagamento enviado para provedor');
      return {
        'success': true,
        'providerAmount': providerAmountSats,
        'platformFee': platformFeeSats,
        'payment': {
          'id': sendResp.payment.id,
          'amount': sendResp.payment.amount.toInt(),
          'status': sendResp.payment.status.toString(),
        },
      };
    } catch (e) {
      debugPrint('❌ Erro no split: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Verifica se um pagamento foi recebido
  Future<Map<String, dynamic>> checkPaymentReceived(String paymentHash) async {
    if (!_isInitialized || _sdk == null) {
      return {'received': false, 'error': 'Não inicializado'};
    }
    
    try {
      await _sdk!.syncWallet(request: spark.SyncWalletRequest());
      
      final resp = await _sdk!.listPayments(
        request: spark.ListPaymentsRequest(),
      );
      
      for (final payment in resp.payments) {
        if (payment.details is spark.PaymentDetails_Lightning) {
          final details = payment.details as spark.PaymentDetails_Lightning;
          if (details.paymentHash == paymentHash &&
              payment.status == spark.PaymentStatus.completed) {
            return {
              'received': true,
              'amount': payment.amount.toInt(),
            };
          }
        }
      }
      
      return {'received': false};
    } catch (e) {
      return {'received': false, 'error': e.toString()};
    }
  }

  /// Obtém saldo da carteira master
  Future<Map<String, dynamic>> getBalance() async {
    if (!_isInitialized || _sdk == null) {
      return {'balance': 0, 'error': 'Não inicializado'};
    }
    
    try {
      final info = await _sdk!.getInfo(request: spark.GetInfoRequest());
      return {
        'balance': info.balanceSats.toInt(),
        'success': true,
      };
    } catch (e) {
      return {'balance': 0, 'error': e.toString()};
    }
  }

  /// Lista pagamentos
  Future<List<Map<String, dynamic>>> listPayments() async {
    if (!_isInitialized || _sdk == null) return [];
    
    try {
      final resp = await _sdk!.listPayments(
        request: spark.ListPaymentsRequest(),
      );
      
      return resp.payments.map((p) => {
        'id': p.id,
        'amount': p.amount.toInt(),
        'status': p.status.toString(),
        'type': p.paymentType.toString(),
      }).toList();
    } catch (e) {
      debugPrint('Erro listando pagamentos: $e');
      return [];
    }
  }

  /// Gera endereço Bitcoin on-chain
  Future<String?> generateBitcoinAddress() async {
    if (!_isInitialized || _sdk == null) return null;
    
    try {
      final resp = await _sdk!.receivePayment(
        request: spark.ReceivePaymentRequest(
          paymentMethod: const spark.ReceivePaymentMethod.bitcoinAddress(),
        ),
      );
      return resp.paymentRequest;
    } catch (e) {
      debugPrint('Erro gerando endereço: $e');
      return null;
    }
  }

  Future<void> disconnect() async {
    if (_sdk != null) {
      try {
        await _sdk!.disconnect();
      } catch (_) {}
    }
    _sdk = null;
    _isInitialized = false;
  }
}
