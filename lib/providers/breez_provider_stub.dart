import 'package:flutter/material.dart';

/// Stub para web/Windows/Linux - Breez SDK n�o funciona nessas plataformas
class BreezProvider with ChangeNotifier {
  bool get isInitialized => false;
  bool get isLoading => false;
  String? get error => 'Lightning Network n�o dispon�vel nesta plataforma';
  String? get mnemonic => null;
  dynamic get sdk => null;
  bool get seedRecoveryNeeded => false;  // Para mostrar alerta de erro
  
  // Callback para notificar pagamentos recebidos
  Function(String paymentId, int amountSats, String? paymentHash)? onPaymentReceived;
  // Callback para notificar pagamentos enviados
  Function(String paymentId, int amountSats, String? paymentHash)? onPaymentSent;
  
  String? get lastPaymentId => null;
  int? get lastPaymentAmount => null;
  
  void clearLastPayment() {}
  
  /// Reset para novo usu�rio (stub)
  Future<void> resetForNewUser() async {
    debugPrint('?? resetForNewUser n�o dispon�vel nesta plataforma');
  }

  Future<bool> initialize({String? mnemonic}) async {
    debugPrint('?? Breez SDK n�o dispon�vel nesta plataforma');
    return false;
  }

  Future<Map<String, dynamic>?> createInvoice({
    required int amountSats,
    String? description,
  }) async {
    return {'success': false, 'error': 'Lightning n�o dispon�vel nesta plataforma'};
  }

  Future<Map<String, dynamic>> checkPaymentStatus(String paymentHash) async {
    return {'paid': false, 'error': 'Lightning n�o dispon�vel nesta plataforma'};
  }

  Future<Map<String, dynamic>> waitForPayment({
    required String paymentHash,
    int timeoutSeconds = 300,
  }) async {
    return {'paid': false, 'error': 'Lightning n�o dispon�vel nesta plataforma'};
  }

  Future<Map<String, dynamic>> getBalance() async {
    return {'balance': '0', 'pendingReceive': '0', 'pendingSend': '0'};
  }

  Future<Map<String, dynamic>?> createOnchainAddress() async {
    return {'success': false, 'error': 'Lightning n�o dispon�vel nesta plataforma'};
  }

  Future<Map<String, dynamic>?> payInvoice(String bolt11, {int? amountSats}) async {
    return {'success': false, 'error': 'Lightning n�o dispon�vel nesta plataforma'};
  }

  Future<Map<String, dynamic>?> decodeInvoice(String bolt11) async {
    return {'success': false, 'error': 'Lightning n�o dispon�vel nesta plataforma'};
  }

  Future<List<Map<String, dynamic>>> listPayments() async {
    return [];
  }

  /// Buscar todos os pagamentos (stub)
  Future<List<Map<String, dynamic>>> getAllPayments() async {
    return [];
  }

  Future<Map<String, dynamic>?> getNodeInfo() async {
    return null;
  }

  Future<void> refresh() async {}

  Future<void> refreshBalance() async {}

  Future<Map<String, dynamic>?> createBitcoinAddress({String? description}) async {
    return {'success': false, 'error': 'Lightning n�o dispon�vel nesta plataforma'};
  }

  Future<Map<String, dynamic>> checkAddressStatus(String address) async {
    return {'received': false, 'amount': 0};
  }

  /// Reinicializar SDK com nova seed (stub - n�o faz nada em plataformas n�o-suportadas)
  Future<bool> reinitializeWithNewSeed(String mnemonic) async {
    debugPrint('?? Breez SDK n�o dispon�vel nesta plataforma');
    return false;
  }

  Future<void> disconnect() async {}
  
  /// Force sync da carteira (stub)
  Future<void> forceSyncWallet() async {
    debugPrint('?? forceSyncWallet n�o dispon�vel nesta plataforma');
  }
  
  /// Recuperar dep�sitos n�o reclamados (stub)
  Future<Map<String, dynamic>> recoverUnclaimedDeposits() async {
    return {'success': false, 'claimed': 0, 'error': 'Lightning n�o dispon�vel nesta plataforma'};
  }
  
  /// Diagn�stico completo (stub)
  Future<Map<String, dynamic>> getFullDiagnostics() async {
    return {
      'isInitialized': false,
      'sdkAvailable': false,
      'isNewWallet': false,
      'error': 'Lightning n�o dispon�vel nesta plataforma',
    };
  }
  
  @override
  void dispose() {
    super.dispose();
  }
}
