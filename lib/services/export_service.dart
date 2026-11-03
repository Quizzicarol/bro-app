import 'dart:io';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/order.dart';
import '../services/log_utils.dart';

/// Exportação de dados do PRÓPRIO usuário (pedido do Roberto, out/2026):
/// relatório de operações para preço médio e controle pessoal.
///
/// PRIVACIDADE: o CSV é gerado 100% no aparelho e compartilhado pelo sheet
/// nativo do sistema — nenhum dado passa por servidor. O arquivo vai para o
/// diretório temporário e some sozinho.
class ExportService {
  static String _cell(Object? v) => '"${(v ?? '').toString().replaceAll('"', '""')}"';

  static Future<File> _write(String name, List<String> header, List<List<Object?>> rows) async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/$name');
    // BOM + ponto-e-vírgula: abre certinho no Excel pt-BR
    final b = StringBuffer('﻿');
    b.writeln(header.map(_cell).join(';'));
    for (final r in rows) {
      b.writeln(r.map(_cell).join(';'));
    }
    await f.writeAsString(b.toString());
    broLog('📤 [Export] CSV gerado: ${f.path} (${rows.length} linhas)');
    return f;
  }

  static String _dt(int? tsSeconds) {
    if (tsSeconds == null || tsSeconds <= 0) return '';
    return DateFormat('yyyy-MM-dd HH:mm')
        .format(DateTime.fromMillisecondsSinceEpoch(tsSeconds * 1000));
  }

  /// Movimentações da carteira (envios + recebimentos, Lightning/on-chain/Spark).
  /// [btcUsd]: cotação BTC/USD de HOJE, só para a coluna aproximada em USD —
  /// o app não guarda cotação histórica de cada movimentação.
  static Future<File> buildWalletCsv(List<Map<String, dynamic>> payments, {double? btcUsd}) async {
    final sorted = [...payments]
      ..sort((a, b) => ((a['timestamp'] as int?) ?? 0).compareTo((b['timestamp'] as int?) ?? 0));
    final rows = <List<Object?>>[];
    for (final p in sorted) {
      final sats = (p['amountSats'] as int?) ?? 0;
      final usd = btcUsd != null ? sats / 1e8 * btcUsd : null;
      rows.add([
        _dt(p['timestamp'] as int?),
        p['direction'],
        p['method'],
        sats,
        usd != null ? usd.toStringAsFixed(2) : 'n/d',
        p['feeSats'],
        p['status'],
        p['description'],
        p['paymentHash'],
        p['id'],
      ]);
    }
    return _write(
      'bro_movimentacoes.csv',
      ['data_hora_local', 'tipo', 'metodo', 'valor_sats', 'valor_usd_aprox_cotacao_de_hoje', 'taxa_sats', 'status', 'descricao', 'payment_hash', 'id_interno'],
      rows,
    );
  }

  /// Ordens concluídas como PROVEDOR: data, valor fiat (BRL etc.), preço do BTC
  /// na ordem (histórico real), sats e USD aproximado com cotação de hoje.
  static Future<File> buildProviderOrdersCsv(List<Order> orders, {double? btcUsd}) async {
    final sorted = [...orders]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final rows = <List<Object?>>[];
    for (final o in sorted) {
      final sats = (o.btcAmount * 1e8).round();
      final usd = btcUsd != null ? o.btcAmount * btcUsd : null;
      rows.add([
        DateFormat('yyyy-MM-dd HH:mm').format(o.completedAt ?? o.createdAt),
        o.id,
        o.currency,
        o.amount.toStringAsFixed(2),
        o.btcPrice.toStringAsFixed(2),
        sats,
        usd != null ? usd.toStringAsFixed(2) : 'n/d',
        o.providerFee.toStringAsFixed(2),
        o.status,
      ]);
    }
    return _write(
      'bro_ordens_provedor.csv',
      ['data_conclusao_local', 'ordem_id', 'moeda', 'valor_fiat', 'preco_btc_brl_na_ordem', 'sats', 'valor_usd_aprox_cotacao_de_hoje', 'taxa_provedor_fiat', 'status'],
      rows,
    );
  }

  static Future<void> share(File f, String subject) async {
    await Share.shareXFiles([XFile(f.path)], subject: subject);
  }
}
