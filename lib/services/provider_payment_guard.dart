import 'dart:convert';
import 'package:bro_app/services/log_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// GUARDA ANTI-GASTO-DUPLO do pagamento AO PROVEDOR.
///
/// O pagamento do invoice do provedor (o valor "grande" da conta) NÃO tinha
/// proteção persistente contra duplicidade — só o `_isConfirming` por instância
/// de tela e a detecção "already paid" do SDK (que só funciona se for o MESMO
/// bolt11 e o SDK reportar). Se a ordem voltasse para `awaiting_confirmation`
/// (ex.: `bro_republish_request` do provedor + sync), o botão Confirmar
/// reaparecia e o usuário pagava DE NOVO — gasto duplo real.
///
/// Este guarda registra, POR ORDEM e de forma PERSISTENTE (sobrevive a
/// restart/reinstalação parcial), que o provedor já foi pago. É consultado
/// ANTES de qualquer pagamento. Segue o mesmo padrão de lock síncrono do
/// [PlatformFeeService] para também cobrir concorrência na mesma sessão.
class ProviderPaymentGuard {
  static const String _paidKey = 'provider_paid_order_ids';
  static const String _attemptHashKey = 'provider_paid_attempt_hashes';

  /// Ordens cujo provedor JÁ foi pago (settled). Bloqueio absoluto.
  static final Set<String> _paidOrderIds = {};

  /// orderId -> último paymentHash TENTADO (mesmo se ficou pending/timeout).
  /// Permite re-checar o status daquele hash específico antes de pagar de novo.
  static final Map<String, String> _attemptHashes = {};

  /// Lock em memória para concorrência dentro da MESMA sessão (antes de await).
  static final Set<String> _paying = {};

  static Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final paid = prefs.getStringList(_paidKey) ?? [];
    _paidOrderIds
      ..clear()
      ..addAll(paid);
    // Nenhum pagamento está em andamento num boot fresco.
    _paying.clear();
    final raw = prefs.getString(_attemptHashKey);
    _attemptHashes.clear();
    if (raw != null && raw.isNotEmpty) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        map.forEach((k, v) => _attemptHashes[k] = v.toString());
      } catch (_) {}
    }
    broLog('🛡️ ProviderPaymentGuard: ${_paidOrderIds.length} ordens pagas, ${_attemptHashes.length} hashes tentados');
  }

  /// True se o provedor desta ordem JÁ foi pago (não pode pagar de novo).
  static bool isPaid(String orderId) => _paidOrderIds.contains(orderId);

  /// Último paymentHash tentado para a ordem (para re-checar status antes de pagar).
  static String? attemptHashFor(String orderId) => _attemptHashes[orderId];

  /// Tenta adquirir o lock de pagamento (síncrono, antes de qualquer await).
  /// Retorna false se já está pago OU se outro fluxo está pagando agora.
  static bool tryAcquire(String orderId) {
    if (_paidOrderIds.contains(orderId)) return false;
    if (_paying.contains(orderId)) return false;
    _paying.add(orderId);
    return true;
  }

  /// Libera o lock (em falha) para permitir nova tentativa legítima.
  static void release(String orderId) {
    _paying.remove(orderId);
  }

  /// Registra o paymentHash que está sendo tentado (persiste mesmo em pending).
  static Future<void> recordAttempt(String orderId, String? paymentHash) async {
    if (paymentHash == null || paymentHash.isEmpty) return;
    if (_attemptHashes[orderId] == paymentHash) return;
    _attemptHashes[orderId] = paymentHash;
    await _saveAttemptHashes();
  }

  /// Marca a ordem como PAGA (settled) — bloqueio absoluto e persistente.
  static Future<void> markPaid(String orderId, {String? paymentHash}) async {
    _paying.remove(orderId);
    final added = _paidOrderIds.add(orderId);
    if (paymentHash != null && paymentHash.isNotEmpty) {
      _attemptHashes[orderId] = paymentHash;
      await _saveAttemptHashes();
    }
    if (added) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_paidKey, _paidOrderIds.toList());
      broLog('🛡️ ProviderPaymentGuard: ordem ${_short(orderId)} marcada como PAGA (anti double-spend)');
    }
  }

  static Future<void> _saveAttemptHashes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_attemptHashKey, jsonEncode(_attemptHashes));
  }

  static String _short(String id) => id.length > 8 ? id.substring(0, 8) : id;
}
