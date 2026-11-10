/// Mock do watchtower (bro-api) para testes de corrida.
/// Criado na revisão pós-entrega (09/11): republish_zombie_test o referenciava
/// e ele não existia (teste não compilava).
///
/// Modela o mínimo do comportamento real: ordens terminais conhecidas em
/// memória + persistência (state file) simulada pelo construtor — o boot
/// (backfillTerminalOrders) re-popula a memória a partir dela (v765/v758b).
library;

class MockWatchtower {
  /// Memória "viva" do watchtower (o que o processo sabe agora).
  final Set<String> _terminalInMemory = {};

  /// Simula o /data/watchtower_state.json — sobrevive a deploy/restart.
  final Set<String> persistedTerminal;

  MockWatchtower({Set<String>? persisted})
      : persistedTerminal = persisted ?? {'order_legacy_terminal_seed'};

  /// Marca ordem como terminal (o que o watchtower faz ao ver completed).
  void markTerminal(String orderId) => _terminalInMemory.add(orderId);

  /// O que o /canonical e os gates de broadcast consultam.
  List<String> getTerminalOrdersList() => _terminalInMemory.toList();

  /// Boot/restart: re-popula a memória a partir do estado persistido.
  Future<void> backfillTerminalOrders() async {
    _terminalInMemory.addAll(persistedTerminal);
  }

  void reset() => _terminalInMemory.clear();

  // v-fix (09/11): stub do vault HODL — o vault_expiry_during_dispute_test
  // precisa. O vault real mora no backend /hodl/* (branch feature/hodl-collateral).
  final Map<String, Map<String, String>> vaults = {};
  Future<MockVaultResult> createVault({required String pubkey, required String tierId}) async {
    vaults[pubkey] = {'tierId': tierId, 'status': 'active'};
    return MockVaultResult(true);
  }
}

class MockVaultResult {
  final bool success;
  MockVaultResult(this.success);
}
