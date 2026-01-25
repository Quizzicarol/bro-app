# 🐛 Bugs Resolvidos - Guia de Referência

Este documento detalha cada bug encontrado, sua causa raiz e solução implementada.

---

## 🚨 CRÍTICO: Vazamento de Ordens Entre Usuários

### Sintoma
Ordens criadas por um usuário apareciam em outro dispositivo com conta diferente.

### Causa Raiz
1. `createOrder()` salvava ordens diretamente no SharedPreferences sem usar `_saveOrders()` que tem filtro de segurança
2. `fetchOrder()` inseria ordens na lista sem verificar se pertenciam ao usuário atual
3. `clearOrders()` não resetava `_isProviderMode`, permitindo que ordens do modo provedor vazassem

### Solução
```dart
// Em createOrder() - ANTES (errado):
final prefs = await SharedPreferences.getInstance();
final ordersJson = json.encode(_orders.map((o) => o.toJson()).toList());
await prefs.setString(_ordersKey, ordersJson);

// DEPOIS (correto):
await _saveOrders(); // Usa filtro de segurança

// Em fetchOrder() - Adicionar verificação:
final isUserOrder = order.userPubkey == _currentUserPubkey;
final isProviderOrder = order.providerId == _currentUserPubkey;
if (!_isProviderMode && !isUserOrder && !isProviderOrder) {
  debugPrint('🚫 Bloqueando ordem de outro usuário');
  return null;
}

// Em clearOrders():
_isProviderMode = false; // Reset modo provedor
```

### Arquivos
- `lib/providers/order_provider.dart`

---

## 🐛 Sincronização de Status Entre Usuário e Bro

### Sintoma
Usuário via ordem como "Concluída", Bro via como "Aguardando Usuário".

### Causa Raiz
Quando usuário confirmava pagamento, o evento Nostr era publicado SEM a tag `['p', providerId]`. O Bro buscava updates por `#p: [providerPubkey]` mas não encontrava.

### Solução
```dart
// Em _handleConfirmPayment() - Passar providerId:
final providerId = orderDetails?['providerId'] as String?;
await orderProvider.updateOrderStatus(
  orderId: widget.orderId,
  status: 'completed',
  providerId: providerId,  // CRÍTICO!
);

// Criar nova função para buscar updates do provedor:
Future<Map<String, Map<String, dynamic>>> fetchOrderUpdatesForProvider(
  String providerPubkey, 
  {List<String>? orderIds}
) async {
  // Busca eventos kind 30080 com tag #p = providerPubkey
}

// Em syncAllPendingOrdersFromNostr() - Buscar updates:
final providerUpdates = await _nostrOrderService.fetchOrderUpdatesForProvider(
  _currentUserPubkey!,
  orderIds: myOrderIds,
);
```

### Arquivos
- `lib/screens/order_status_screen.dart`
- `lib/services/nostr_order_service.dart`
- `lib/providers/order_provider.dart`

---

## 🐛 Comprovante do Bro Não Aparecia para Usuário

### Sintoma
Usuário não conseguia ver a imagem do comprovante enviado pelo Bro.

### Causa Raiz
O `paymentProof` era truncado ao salvar:
```dart
// ERRADO:
'paymentProof': proof.length > 100 ? 'image_base64_stored' : proof,
```

### Solução
```dart
// CORRETO:
'paymentProof': proof,  // Salvar completo
'proofSentAt': DateTime.now().toIso8601String(),
```

### Arquivos
- `lib/providers/order_provider.dart`

---

## 🐛 Sats "Pendentes" Incorretos

### Sintoma
Tela mostrava "37445 sats em Ordens Pendentes" mesmo com apenas 13 sats na carteira.

### Causa Raiz
O getter `committedSats` contava ordens com status `pending`, `payment_received`, etc. Mas essas ordens já tiveram a invoice Lightning paga - os sats JÁ SAÍRAM da carteira!

### Solução
```dart
int get committedSats {
  // RETORNAR 0: Nenhum sat está "comprometido" na carteira
  // Os sats já saíram quando o usuário pagou a invoice Lightning
  return 0;
}
```

### Arquivos
- `lib/providers/order_provider.dart`

---

## 🐛 Badge "Tier Ativo" Inconsistente

### Sintoma
Badge mostrava "Tier Ativo" (verde) mas as ordens mostravam "BLOQUEADA" (vermelho).

### Causa Raiz
Variável de estado `_tierAtRisk` local que não estava sincronizada com `CollateralProvider.isTierAtRisk`.

### Solução
Remover a variável local e usar diretamente o CollateralProvider:
```dart
// ANTES:
bool _tierAtRisk = false;
if (_tierAtRisk) { ... }

// DEPOIS:
final collateralProvider = context.read<CollateralProvider>();
if (collateralProvider.isTierAtRisk) { ... }
```

### Arquivos
- `lib/screens/provider_orders_screen.dart`

---

## 🐛 Ordens Fantasma

### Sintoma
Ordens apareciam na lista mesmo sem o usuário ter pago.

### Causa Raiz
A ordem era criada e publicada no Nostr ANTES da invoice ser paga. Se o usuário cancelasse ou fechasse o app, a ordem "fantasma" já existia.

### Solução
Inverter o fluxo:
1. Criar invoice PRIMEIRO
2. Só criar a ordem APÓS pagamento confirmado

```dart
// Fluxo correto:
1. Usuário preenche dados
2. Gerar invoice Lightning
3. Aguardar pagamento da invoice
4. APENAS APÓS confirmação: createOrder()
5. Publicar no Nostr
```

### Arquivos
- `lib/screens/marketplace_screen.dart`
- `lib/screens/payment_screen.dart`

---

## 🐛 Erro "order is not a subtype of Map"

### Sintoma
App crashava ao entrar no modo Bro.

### Causa Raiz
Código esperava `Map<String, dynamic>` mas recebia objeto `Order`.

### Solução
```dart
// ANTES:
final order = ...; // Order object
order['status'] // ERRO!

// DEPOIS:
final orderMap = order.toJson();
orderMap['status'] // OK
```

### Arquivos
- `lib/screens/provider_orders_screen.dart`

---

## 📌 Padrões de Debug Úteis

### Verificar pubkey atual
```dart
debugPrint('👤 Pubkey: ${_currentUserPubkey?.substring(0, 8) ?? "null"}');
```

### Verificar ordens na memória
```dart
for (final o in _orders) {
  debugPrint('📋 ${o.id.substring(0, 8)}: status=${o.status}, userPubkey=${o.userPubkey?.substring(0, 8)}');
}
```

### Verificar eventos Nostr
```dart
debugPrint('📤 Publicando evento kind=$kind com tags: $tags');
debugPrint('📥 Recebido evento: $event');
```

---

*Última atualização: 25 de Janeiro de 2026*
