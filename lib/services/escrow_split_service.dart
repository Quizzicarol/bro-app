import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';
import 'platform_wallet_service.dart';
import 'platform_fee_service.dart';

/// Servi�o de Escrow com Split Autom�tico
/// 
/// Fluxo completo:
/// 1. Cliente solicita pagamento ? Gera invoice na carteira MASTER
/// 2. Cliente paga a invoice ? Dinheiro vai para carteira MASTER
/// 3. Sistema detecta pagamento ? Executa SPLIT autom�tico:
///    - 2% fica na carteira master (taxa plataforma)
///    - 98% � enviado para o provedor
/// 4. Registra transa��o para auditoria
class EscrowSplitService {
  static const String _pendingEscrowsKey = 'pending_escrows';
  static const String _completedEscrowsKey = 'completed_escrows';
  
  // Armazenamento seguro para mnemonic
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );
  
  static final EscrowSplitService _instance = EscrowSplitService._();
  static EscrowSplitService get instance => _instance;
  
  EscrowSplitService._();
  
  Timer? _checkTimer;
  bool _isProcessing = false;

  /// Inicia o servi�o de escrow
  /// Deve ser chamado ao iniciar o app (no main.dart)
  Future<void> startService() async {
    debugPrint('?? Iniciando servi�o de Escrow Split...');
    
    // Iniciar verifica��o peri�dica de pagamentos pendentes
    _checkTimer?.cancel();
    _checkTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _processPendingEscrows(),
    );
    
    // Processar escrows pendentes imediatamente
    await _processPendingEscrows();
  }

  /// Para o servi�o
  void stopService() {
    _checkTimer?.cancel();
    _checkTimer = null;
  }

  /// Cria um novo escrow para uma ordem
  /// Retorna a invoice que o cliente deve pagar
  Future<Map<String, dynamic>> createEscrow({
    required String orderId,
    required int totalSats,
    required double totalBrl,
    required String providerLightningAddress,
    required String providerPubkey,
    required String clientPubkey,
  }) async {
    debugPrint('?? Criando escrow para ordem $orderId');
    debugPrint('   Total: $totalSats sats (R\$ $totalBrl)');
    debugPrint('   Provedor: $providerLightningAddress');
    
    // Garantir que a carteira master est� inicializada
    final wallet = PlatformWalletService.instance;
    if (!wallet.isInitialized) {
      // Tentar inicializar com mnemonic salvo
      final savedMnemonic = await _getSavedPlatformMnemonic();
      final success = await wallet.initialize(mnemonic: savedMnemonic);
      if (!success) {
        return {
          'success': false,
          'error': 'Falha ao inicializar carteira master: ${wallet.error}',
        };
      }
      // Salvar mnemonic se novo
      if (savedMnemonic == null && wallet.mnemonic != null) {
        await _savePlatformMnemonic(wallet.mnemonic!);
      }
    }
    
    // Criar invoice na carteira master
    final result = await wallet.createEscrowInvoice(
      amountSats: totalSats,
      orderId: orderId,
      providerLightningAddress: providerLightningAddress,
      description: 'Bro - Pagamento de conta #${orderId.substring(0, 8)}',
    );
    
    if (result?['success'] != true) {
      return {
        'success': false,
        'error': result?['error'] ?? 'Falha ao criar invoice',
      };
    }
    
    // Salvar escrow pendente
    final escrow = {
      'orderId': orderId,
      'totalSats': totalSats,
      'totalBrl': totalBrl,
      'providerAddress': providerLightningAddress,
      'providerPubkey': providerPubkey,
      'clientPubkey': clientPubkey,
      'invoice': result!['invoice'],
      'paymentHash': result['paymentHash'],
      'status': 'pending_payment', // pending_payment ? paid ? split_completed
      'createdAt': DateTime.now().toIso8601String(),
    };
    
    await _savePendingEscrow(escrow);
    
    debugPrint('? Escrow criado com sucesso');
    
    return {
      'success': true,
      'invoice': result['invoice'],
      'paymentHash': result['paymentHash'],
      'escrow': escrow,
    };
  }

  /// Processa escrows pendentes
  Future<void> _processPendingEscrows() async {
    if (_isProcessing) return;
    _isProcessing = true;
    
    try {
      final pendingEscrows = await _getPendingEscrows();
      
      for (final escrow in pendingEscrows) {
        final status = escrow['status'] as String?;
        
        if (status == 'pending_payment') {
          // Verificar se pagamento foi recebido
          await _checkPaymentReceived(escrow);
        } else if (status == 'paid') {
          // Executar split
          await _executeSplit(escrow);
        }
      }
    } catch (e) {
      debugPrint('? Erro processando escrows: $e');
    } finally {
      _isProcessing = false;
    }
  }

  /// Verifica se um pagamento foi recebido
  Future<void> _checkPaymentReceived(Map<String, dynamic> escrow) async {
    final paymentHash = escrow['paymentHash'] as String?;
    if (paymentHash == null) return;
    
    final wallet = PlatformWalletService.instance;
    if (!wallet.isInitialized) return;
    
    final result = await wallet.checkPaymentReceived(paymentHash);
    
    if (result['received'] == true) {
      debugPrint('?? Pagamento recebido para escrow ${escrow['orderId']}');
      
      // Atualizar status
      escrow['status'] = 'paid';
      escrow['paidAt'] = DateTime.now().toIso8601String();
      escrow['receivedAmount'] = result['amount'];
      
      await _updatePendingEscrow(escrow);
      
      // Executar split imediatamente
      await _executeSplit(escrow);
    }
  }

  /// Executa o split autom�tico
  Future<void> _executeSplit(Map<String, dynamic> escrow) async {
    debugPrint('?? Executando split para ${escrow['orderId']}...');
    
    final wallet = PlatformWalletService.instance;
    if (!wallet.isInitialized) return;
    
    final totalSats = escrow['totalSats'] as int? ?? 0;
    final providerAddress = escrow['providerAddress'] as String?;
    
    if (providerAddress == null || providerAddress.isEmpty) {
      debugPrint('? Endere�o do provedor n�o encontrado');
      return;
    }
    
    // Executar split
    final result = await wallet.processSplit(
      totalSats: totalSats,
      providerInvoice: providerAddress,
    );
    
    if (result['success'] == true) {
      debugPrint('? Split executado com sucesso!');
      debugPrint('   Taxa plataforma: ${result['platformFee']} sats');
      debugPrint('   Enviado ao provedor: ${result['providerAmount']} sats');
      
      // Atualizar escrow
      escrow['status'] = 'split_completed';
      escrow['splitAt'] = DateTime.now().toIso8601String();
      escrow['platformFee'] = result['platformFee'];
      escrow['providerAmount'] = result['providerAmount'];
      
      // Mover para completados
      await _moveToCompleted(escrow);
      
      // Registrar taxa no PlatformFeeService para tracking
      await PlatformFeeService.recordFee(
        orderId: escrow['orderId'] ?? '',
        transactionBrl: (escrow['totalBrl'] as num?)?.toDouble() ?? 0,
        transactionSats: totalSats,
        providerPubkey: escrow['providerPubkey'] ?? '',
        clientPubkey: escrow['clientPubkey'] ?? '',
      );
      
      // Marcar como coletada (j� foi retida automaticamente)
      await PlatformFeeService.markAsCollected([escrow['orderId'] ?? '']);
      
    } else {
      debugPrint('? Falha no split: ${result['error']}');
      escrow['lastSplitError'] = result['error'];
      escrow['lastSplitAttempt'] = DateTime.now().toIso8601String();
      await _updatePendingEscrow(escrow);
    }
  }

  /// For�a o processamento de um escrow espec�fico
  Future<Map<String, dynamic>> forceProcessEscrow(String orderId) async {
    final escrows = await _getPendingEscrows();
    final escrow = escrows.firstWhere(
      (e) => e['orderId'] == orderId,
      orElse: () => {},
    );
    
    if (escrow.isEmpty) {
      return {'success': false, 'error': 'Escrow n�o encontrado'};
    }
    
    if (escrow['status'] == 'pending_payment') {
      await _checkPaymentReceived(escrow);
    }
    
    if (escrow['status'] == 'paid') {
      await _executeSplit(escrow);
    }
    
    return {'success': true, 'escrow': escrow};
  }

  // === Storage Methods ===
  
  Future<List<Map<String, dynamic>>> _getPendingEscrows() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_pendingEscrowsKey);
    if (json == null) return [];
    return List<Map<String, dynamic>>.from(jsonDecode(json));
  }
  
  Future<void> _savePendingEscrow(Map<String, dynamic> escrow) async {
    final escrows = await _getPendingEscrows();
    escrows.add(escrow);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingEscrowsKey, jsonEncode(escrows));
  }
  
  Future<void> _updatePendingEscrow(Map<String, dynamic> escrow) async {
    final escrows = await _getPendingEscrows();
    final index = escrows.indexWhere((e) => e['orderId'] == escrow['orderId']);
    if (index >= 0) {
      escrows[index] = escrow;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_pendingEscrowsKey, jsonEncode(escrows));
    }
  }
  
  Future<void> _moveToCompleted(Map<String, dynamic> escrow) async {
    // Remover dos pendentes
    final pending = await _getPendingEscrows();
    pending.removeWhere((e) => e['orderId'] == escrow['orderId']);
    
    // Adicionar aos completados
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingEscrowsKey, jsonEncode(pending));
    
    final completedJson = prefs.getString(_completedEscrowsKey);
    List<Map<String, dynamic>> completed = [];
    if (completedJson != null) {
      completed = List<Map<String, dynamic>>.from(jsonDecode(completedJson));
    }
    completed.add(escrow);
    await prefs.setString(_completedEscrowsKey, jsonEncode(completed));
  }
  
  Future<List<Map<String, dynamic>>> getCompletedEscrows() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_completedEscrowsKey);
    if (json == null) return [];
    return List<Map<String, dynamic>>.from(jsonDecode(json));
  }
  
  Future<List<Map<String, dynamic>>> getPendingEscrows() async {
    return _getPendingEscrows();
  }

  // === Platform Mnemonic Storage (ARMAZENAMENTO SEGURO) ===
  
  static const String _platformMnemonicKey = 'platform_wallet_mnemonic';
  
  Future<String?> _getSavedPlatformMnemonic() async {
    // Primeiro tentar armazenamento seguro
    final secureMnemonic = await _secureStorage.read(key: _platformMnemonicKey);
    if (secureMnemonic != null) return secureMnemonic;
    
    // Fallback: migrar de SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    final oldMnemonic = prefs.getString(_platformMnemonicKey);
    if (oldMnemonic != null && oldMnemonic.isNotEmpty) {
      // Migrar para armazenamento seguro
      await _secureStorage.write(key: _platformMnemonicKey, value: oldMnemonic);
      await prefs.remove(_platformMnemonicKey);
      debugPrint('?? Mnemonic da plataforma migrado para armazenamento seguro');
      return oldMnemonic;
    }
    return null;
  }
  
  Future<void> _savePlatformMnemonic(String mnemonic) async {
    await _secureStorage.write(key: _platformMnemonicKey, value: mnemonic);
    debugPrint('?? Mnemonic da carteira master salvo com seguran�a');
  }
  
  /// Exporta o mnemonic da carteira master (para backup seguro)
  Future<String?> exportPlatformMnemonic() async {
    return _getSavedPlatformMnemonic();
  }
  
  /// Importa um mnemonic existente
  Future<bool> importPlatformMnemonic(String mnemonic) async {
    try {
      await _savePlatformMnemonic(mnemonic);
      // Reinicializar wallet com novo mnemonic
      final wallet = PlatformWalletService.instance;
      await wallet.disconnect();
      return await wallet.initialize(mnemonic: mnemonic);
    } catch (e) {
      debugPrint('? Erro importando mnemonic: $e');
      return false;
    }
  }
}
