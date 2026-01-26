# 🐛 Bugs Resolvidos - Guia de Referência

Este documento detalha cada bug encontrado, sua causa raiz e solução implementada.

---

## 🚨 CRÍTICO: Vazamento de Ordens ao Sair do Modo Bro - v1.0.43+57 (26/01/2026)

### Sintoma
Quando usuário saía do Modo Bro para "Minhas Trocas", ordens de OUTROS usuários apareciam na lista.

### Causa Raiz (múltiplas)
1. O `dispose()` do ProviderOrdersScreen NÃO chamava `exitProviderMode()`, apenas setava `SecureStorageService`
2. O `PopScope.onPopInvokedWithResult` pode falhar silenciosamente se o contexto estiver desmontado
3. Não havia verificação de segurança nas telas Home e UserOrders para resetar modo provedor

### Solução
```dart
// 1. Em ProviderOrdersScreen - Armazenar referência ao OrderProvider:
OrderProvider? _orderProviderRef;

@override
void didChangeDependencies() {
  super.didChangeDependencies();
  // SEGURANÇA: Capturar referência para uso no dispose
  _orderProviderRef = Provider.of<OrderProvider>(context, listen: false);
}

@override
void dispose() {
  // SEGURANÇA: Chamar exitProviderMode usando referência salva
  _orderProviderRef?.exitProviderMode();
  super.dispose();
}

// 2. Em HomeScreen._loadData() - Verificação de segurança:
if (orderProvider.isProviderMode) {
  debugPrint('⚠️ [HOME] Detectado modo provedor ativo! Forçando reset...');
  orderProvider.exitProviderMode();
}

// 3. Em UserOrdersScreen._loadOrdersWithAutoReconcile() - Mesma verificação
if (orderProvider.isProviderMode) {
  debugPrint('⚠️ [MINHAS TROCAS] Detectado modo provedor ativo! Forçando reset...');
  orderProvider.exitProviderMode();
}
```

### Arquivos
- `lib/screens/provider_orders_screen.dart` - Armazena referência e chama exitProviderMode no dispose
- `lib/screens/home_screen.dart` - Verificação de segurança em _loadData
- `lib/screens/user_orders_screen.dart` - Verificação de segurança em _loadOrdersWithAutoReconcile

---

## 🛡️ Status "Completed" Não Atualizado no Modo Bro - v1.0.42 (25/01/2026)

### Sintoma
Quando usuário confirmava pagamento (status = completed), o Bro continuava vendo "Aguardando confirmação do usuário" mesmo após sincronizar.

### Causa Raiz (múltiplas)
1. A função `fetchOrderUpdatesForProvider()` só executava a busca por `#orderId` quando `events.isEmpty`, ignorando quando já tinha eventos parciais
2. Faltava busca por tag `#e` (referência ao evento original)
3. O `providerId` poderia não ser encontrado por usar diferentes formatos (`providerId` vs `provider_id`)
4. Faltava logging para debugar quando os updates eram encontrados mas não aplicados

### Solução
```dart
// 1. SEMPRE executar busca por #orderId, não apenas quando events.isEmpty
// Em fetchOrderUpdatesForProvider():
if (orderIds != null && orderIds.isNotEmpty) {
  for (final orderId in orderIds.take(10)) { // Aumentado de 5 para 10
    // Buscar por tag #orderId
    final orderEvents = await _fetchFromRelay(relay, kinds: [30080], tags: {'#orderId': [orderId]});
    
    // NOVO: Buscar também por tag #e (referência ao evento)
    final eTagEvents = await _fetchFromRelay(relay, kinds: [30080], tags: {'#e': [orderId]});
  }
}

// 2. Fallback para múltiplos formatos de providerId em _handleConfirmPayment():
providerId = orderDetails?['providerId'] as String?;
providerId ??= orderDetails?['provider_id'] as String?;
providerId ??= order?.providerId;
providerId ??= order?.metadata?['providerId'];
providerId ??= order?.metadata?['provider_id'];

// 3. Logging detalhado para debug:
debugPrint('📥 [PROVEDOR] Updates encontrados: ${providerUpdates.length}');
debugPrint('🔍 Verificando: local=$existing.status vs nostr=$newStatus');
```

### Arquivos
- `lib/services/nostr_order_service.dart` - Melhorias em fetchOrderUpdatesForProvider()
- `lib/providers/order_provider.dart` - Logging detalhado na sincronização
- `lib/screens/order_status_screen.dart` - Fallbacks para providerId

---

## �🚨 CRÍTICO: Vazamento de Ordens Entre Usuários

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

## 🐛 Comprovante Não Exibido ao Usuário (Sincronização Nostr) - v1.0.40

### Sintoma
Usuário abria a tela de status da ordem, o card "Comprovante do Bro" aparecia mas SEM a imagem do comprovante, mesmo o Bro tendo enviado.

### Causa Raiz (3 problemas)
1. `_fetchAllOrderStatusUpdates()` não salvava o `proofImage` do evento `kindBroComplete`
2. `_applyStatusUpdate()` criava nova Order mas NÃO passava `metadata` com o comprovante
3. `syncOrdersFromNostr()` não mesclava `metadata` ao atualizar ordens existentes

### Solução
```dart
// Em _fetchAllOrderStatusUpdates() - INCLUIR proofImage:
updates[orderId] = {
  'orderId': orderId,
  'status': status,
  'providerId': content['providerId'],
  'proofImage': content['proofImage'], // NOVO!
  'completedAt': content['completedAt'],
  'created_at': createdAt,
};

// Em _applyStatusUpdate() - INCLUIR metadata:
final proofImage = update['proofImage'] as String?;
final updatedMetadata = Map<String, dynamic>.from(order.metadata ?? {});
if (proofImage != null && proofImage.isNotEmpty) {
  updatedMetadata['proofImage'] = proofImage;
  updatedMetadata['paymentProof'] = proofImage; // Compatibilidade
}
return Order(
  // ... outros campos ...
  metadata: updatedMetadata, // NOVO!
);

// Em syncOrdersFromNostr() - MESCLAR metadata:
final mergedMetadata = <String, dynamic>{
  ...?existing.metadata,
  ...?nostrOrder.metadata,
};
_orders[existingIndex] = existing.copyWith(
  // ... outros campos ...
  metadata: mergedMetadata.isNotEmpty ? mergedMetadata : null,
);
```

### Arquivos
- `lib/services/nostr_order_service.dart`
- `lib/providers/order_provider.dart`

---

## 🐛 Status "Completed" Não Propagado para o Bro - v1.0.41

### Sintoma
Usuário confirmava recebimento do pagamento (marca como "completed"), mas o Bro continuava vendo "Aguardando Confirmação" mesmo após sincronizar.

### Causa Raiz
O `providerId` poderia ser `null` quando o usuário confirmava, fazendo com que o evento Nostr fosse publicado SEM a tag `['p', providerId]`. O Bro busca updates por `#p: [providerPubkey]` então não encontrava.

### Solução
```dart
// Em _handleConfirmPayment() - Garantir providerId:
String? providerId = orderDetails?['providerId'] as String?;

// Fallback: buscar diretamente da ordem no provider
if (providerId == null || providerId.isEmpty) {
  final order = orderProvider.getOrderById(widget.orderId);
  providerId = order?.providerId;
}

if (providerId == null || providerId.isEmpty) {
  debugPrint('⚠️ AVISO: providerId é null - Bro pode não receber!');
}

// Passar providerId ao atualizar status
await orderProvider.updateOrderStatus(
  orderId: widget.orderId,
  status: 'completed',
  providerId: providerId,  // CRÍTICO!
);
```

### Arquivos
- `lib/screens/order_status_screen.dart`
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
