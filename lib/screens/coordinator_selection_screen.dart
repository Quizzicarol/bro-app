import 'package:flutter/material.dart';
import 'package:bro_app/services/log_utils.dart';
import '../services/coordinator_service.dart';

/// Tela de escolha de coordinator (Configurações → Coordinator).
///
/// ETAPA 1: lista os coordinators descobertos via Nostr (kind 30082) e permite
/// escolher. A escolha fica salva local. O roteamento da taxa (Etapa 2) usa a
/// seleção — mas só passa a valer quando ligarmos o fluxo de pagamento.
///
/// Ordem da lista (decisão da dona do projeto):
///   1) Automático (Coordinator Bro original) — padrão
///   2) coordinators descobertos, por ordem de criação (+reputação futura)
class CoordinatorSelectionScreen extends StatefulWidget {
  const CoordinatorSelectionScreen({Key? key}) : super(key: key);

  @override
  State<CoordinatorSelectionScreen> createState() => _CoordinatorSelectionScreenState();
}

class _CoordinatorSelectionScreenState extends State<CoordinatorSelectionScreen> {
  final _service = CoordinatorService();
  List<CoordinatorCard> _cards = [];
  String _selected = '';
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _service.loadSelection();
    // Mostra o cache primeiro (rápido), depois atualiza dos relays.
    final cached = await _service.loadCachedCards();
    if (mounted) {
      setState(() {
        _cards = cached;
        _selected = _service.selectedPubkey;
      });
    }
    try {
      final fresh = await _service.fetchCoordinatorCards();
      if (mounted) {
        setState(() {
          _cards = fresh;
          _loading = false;
          _error = fresh.isEmpty ? 'Nenhum coordinator encontrado ainda.' : null;
        });
      }
    } catch (e) {
      broLog('⚠️ CoordinatorSelection._load: $e');
      if (mounted) {
        setState(() {
          _loading = false;
          _error = _cards.isEmpty ? 'Não foi possível carregar a lista agora.' : null;
        });
      }
    }
  }

  Future<void> _choose(String pubkey) async {
    await _service.setSelection(pubkey);
    if (mounted) setState(() => _selected = pubkey);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('Coordinator', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              'Por padrão suas ordens usam o Coordinator Bro original. Você pode, se quiser, escolher outro coordinator. Isso é opcional.',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),

          // Aviso: o coordinator escolhido é quem resolve disputas
          Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.orange.withOpacity(0.35)),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.gavel, color: Colors.orange, size: 20),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'O coordinator que você escolher é quem vai acompanhar suas ordens e resolver disputas (além de receber a taxa da ordem). Escolha um coordinator em quem você confia. Se não souber, deixe em Automático.',
                    style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.35),
                  ),
                ),
              ],
            ),
          ),

          // Opção 1: Automático (padrão)
          _optionTile(
            pubkey: '',
            title: 'Automático (Coordinator Bro original)',
            subtitle: 'Recomendado. Usa a configuração atual.',
            selected: _selected.isEmpty,
            onTap: () => _choose(''),
          ),

          const SizedBox(height: 16),
          const Text('Outros coordinators', style: TextStyle(color: Colors.orange, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),

          if (_loading && _cards.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator(color: Colors.orange)),
            ),

          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(_error!, style: const TextStyle(color: Colors.white54, fontSize: 13)),
            ),

          // Opções descobertas (ex.: PC antigo)
          ..._cards.map((c) => _optionTile(
                pubkey: c.pubkey,
                title: c.name,
                subtitle: c.lnAddress.isNotEmpty
                    ? 'Taxa ${c.fee.isNotEmpty ? "${(double.tryParse(c.fee) ?? 0) * 100}%" : ""} • ${c.lnAddress}'
                    : 'Sem endereço Lightning anunciado',
                selected: _selected == c.pubkey,
                enabled: c.lnAddress.isNotEmpty, // Etapa 2: só escolhe se puder receber taxa
                onTap: () => _choose(c.pubkey),
              )),
        ],
      ),
    );
  }

  Widget _optionTile({
    required String pubkey,
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    return Card(
      elevation: 0,
      color: const Color(0xFF1A1A1A),
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected ? Colors.orange : Colors.orange.withOpacity(0.15),
          width: selected ? 2 : 1,
        ),
      ),
      child: ListTile(
        enabled: enabled,
        leading: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_off,
          color: selected ? Colors.orange : Colors.white38,
        ),
        title: Text(
          title,
          style: TextStyle(color: enabled ? Colors.white : Colors.white38),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(color: enabled ? Colors.white54 : Colors.white24, fontSize: 12),
        ),
        onTap: enabled ? onTap : null,
      ),
    );
  }
}
