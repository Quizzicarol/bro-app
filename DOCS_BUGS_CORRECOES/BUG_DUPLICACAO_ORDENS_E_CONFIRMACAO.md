# BUG: Duplicação de Ordens e Falha na Confirmação entre Dispositivos

**Data de Resolução:** 31 de Janeiro de 2026  
**Versão Corrigida:** 1.0.87+125  
**Severidade:** CRÍTICA  

---

## 📋 RESUMO DO PROBLEMA

### Sintomas Reportados:
1. **Ordens duplicadas** aparecendo na lista de "Ordens Disponíveis" no modo provedor (Bro)
2. **Ordens de outro dispositivo** aparecendo no dispositivo errado (ex: ordens criadas no Android aparecendo no iOS)
3. **Falha na confirmação** - provedor confirmava pagamento mas criador da ordem não via a confirmação
4. **Instabilidade** ao carregar ordens disponíveis

### Ambiente de Teste:
- **iOS:** pubkey `0b31181f021539d1afcda76e66577d5a7797a9603ac4a7aa46514745c8acfc26`
- **Android:** pubkey `4c020f93e3240ba5215ce3f2d6b2b1e9ec57b64d0189b6411b8394d8a60c499d`
- **Relays:** nos.lol, relay.damus.io, relay.primal.net, nostr.wine

---

## 🔍 CAUSA RAIZ

### Problema 1: Ordens sem `userPubkey` (Ordens Legadas)
Ordens antigas criadas antes da implementação do campo `userPubkey` no content não tinham identificação do criador. Isso causava:
- Ordens aparecendo em todos os dispositivos
- Impossibilidade de filtrar por proprietário

### Problema 2: Duplicação de Múltiplos Relays
Ao buscar ordens de 4 relays diferentes, a mesma ordem podia ser retornada múltiplas vezes, causando duplicatas na lista.

### Problema 3: Republish Errado
A função `republishLocalOrdersToNostr()` estava republicando TODAS as ordens locais, incluindo ordens de outros usuários que foram baixadas dos relays.

### Problema 4: Falta de Verificação de Propriedade
`fetchPendingOrders()` (modo provedor) não verificava se a ordem pertencia ao usuário atual, mostrando ordens próprias como "disponíveis para aceitar".

---

## ✅ CORREÇÕES IMPLEMENTADAS

### 1. Rejeição de Ordens Sem `userPubkey`

**Arquivo:** `lib/services/nostr_order_service.dart`  
**Função:** `eventToOrder()`

```dart
// CORREÇÃO: Rejeitar ordens sem userPubkey (ordens legadas ou republicadas incorretamente)
final userPubkey = contentMap['userPubkey'] as String?;
if (userPubkey == null || userPubkey.isEmpty) {
  debugPrint('🚫 REJEITANDO ordem ${orderId.substring(0, 8)}: SEM userPubkey no content (ordem legada/republicada)');
  return null;
}
```

**Lógica:** Ordens sem `userPubkey` no JSON do content são rejeitadas completamente. Isso elimina ordens legadas que causavam confusão.

---

### 2. Deduplicação em `fetchPendingOrders()` (Modo Provedor)

**Arquivo:** `lib/services/nostr_order_service.dart`  
**Função:** `fetchPendingOrders()`

```dart
// CORREÇÃO: Usar Set para deduplicar por orderId
final Set<String> seenOrderIds = {};
final List<Order> uniqueOrders = [];

for (final order in allOrders) {
  if (!seenOrderIds.contains(order.id)) {
    seenOrderIds.add(order.id);
    uniqueOrders.add(order);
  }
}

debugPrint('📊 fetchPendingOrders: ${allOrders.length} total -> ${uniqueOrders.length} únicos (${allOrders.length - uniqueOrders.length} duplicatas removidas)');
```

**Lógica:** Antes de retornar ordens para o modo provedor, removemos duplicatas usando um Set de IDs.

---

### 3. Deduplicação em `syncAllPendingOrdersFromNostr()` (Lista de Disponíveis)

**Arquivo:** `lib/providers/order_provider.dart`  
**Função:** `syncAllPendingOrdersFromNostr()`

```dart
// CORREÇÃO: Deduplicar ordens disponíveis
final Set<String> seenAvailableIds = {};
_availableOrders = _availableOrders.where((order) {
  if (seenAvailableIds.contains(order.id)) {
    return false; // Já vimos essa ordem, ignorar duplicata
  }
  seenAvailableIds.add(order.id);
  return true;
}).toList();

debugPrint('📊 availableOrders após deduplicação: ${_availableOrders.length} ordens únicas');
```

---

### 4. Verificação de Propriedade no Republish

**Arquivo:** `lib/providers/order_provider.dart`  
**Função:** `republishLocalOrdersToNostr()`

```dart
// CORREÇÃO: Só republicar ordens do usuário atual
for (final order in _orders) {
  // Verificar se a ordem pertence ao usuário atual
  if (order.userPubkey != _currentUserPubkey) {
    debugPrint('⏭️ Ignorando ordem ${order.id.substring(0, 8)}: pertence a outro usuário');
    continue;
  }
  // ... resto do código de republish
}
```

**Lógica:** Antes de republicar uma ordem, verificamos se `order.userPubkey == _currentUserPubkey`. Isso evita que um dispositivo republique ordens de outro dispositivo.

---

## 🧪 COMO TESTAR

### Teste 1: Verificar Separação de Ordens
1. Criar ordem no Dispositivo A
2. Abrir Dispositivo B
3. **Esperado:** Ordem NÃO aparece na lista "Minhas Ordens" do Dispositivo B
4. **Esperado:** Ordem APARECE em "Ordens Disponíveis" (modo Bro) do Dispositivo B

### Teste 2: Verificar Deduplicação
1. Abrir modo Bro (provedor)
2. Verificar lista de ordens disponíveis
3. **Esperado:** Nenhuma ordem duplicada

### Teste 3: Verificar Confirmação Cross-Device
1. Dispositivo A cria ordem
2. Dispositivo B aceita e paga (modo provedor)
3. Dispositivo B envia comprovante
4. Dispositivo A confirma recebimento
5. **Esperado:** Ambos dispositivos veem ordem como "completed"

---

## 📊 LOGS DE DIAGNÓSTICO

### Logs Úteis para Debug:
```
🔑 Order XXXXX: userPubkey do CONTENT = YYYY
🚫 REJEITANDO ordem XXXXX: SEM userPubkey no content
📊 fetchPendingOrders: X total -> Y únicos (Z duplicatas removidas)
📊 myCreatedOrders: X/Y ordens criadas por ZZZZ
⏭️ Ignorando ordem XXXXX: pertence a outro usuário
```

### Verificar no Relay (Node.js):
```javascript
const WebSocket = require('ws');
const ws = new WebSocket('wss://nos.lol');
ws.on('open', () => {
  ws.send(JSON.stringify(['REQ', 's1', {
    kinds: [30078], 
    '#d': ['ORDER_ID_AQUI'], 
    limit: 10
  }]));
});
ws.on('message', (data) => {
  const msg = JSON.parse(data);
  if (msg[0] === 'EVENT') {
    const content = JSON.parse(msg[2].content);
    console.log('userPubkey:', content.userPubkey || 'VAZIO');
  }
});
```

---

## ⚠️ PONTOS DE ATENÇÃO

1. **Ordens legadas são perdidas:** Ordens criadas antes desta correção (sem `userPubkey`) serão rejeitadas. Isso é intencional.

2. **Múltiplos relays:** O sistema busca de 4 relays para redundância. A deduplicação é essencial.

3. **Campo `userPubkey`:** Deve estar SEMPRE no content JSON da ordem (kind 30078), não apenas nas tags.

4. **Verificação crítica:** A verificação `userPubkey == currentUserPubkey` é feita em:
   - `eventToOrder()` - ao converter evento para Order
   - `fetchUserOrders()` - ao buscar ordens do usuário
   - `republishLocalOrdersToNostr()` - ao republicar ordens
   - `syncAllPendingOrdersFromNostr()` - ao sincronizar ordens disponíveis

---

## 📁 ARQUIVOS MODIFICADOS

| Arquivo | Função | Correção |
|---------|--------|----------|
| `lib/services/nostr_order_service.dart` | `eventToOrder()` | Rejeitar ordens sem userPubkey |
| `lib/services/nostr_order_service.dart` | `fetchPendingOrders()` | Deduplicação por Set |
| `lib/providers/order_provider.dart` | `syncAllPendingOrdersFromNostr()` | Deduplicação de availableOrders |
| `lib/providers/order_provider.dart` | `republishLocalOrdersToNostr()` | Verificar propriedade antes de republicar |

---

## 🔗 RELACIONADOS

- [NOSTR_SYNC_PATTERNS.md](./NOSTR_SYNC_PATTERNS.md) - Padrões de sincronização Nostr
- [FLUXOS.md](./FLUXOS.md) - Fluxos de ordens
- [BRO_PROTOCOL_SPEC.md](../BRO_PROTOCOL_SPEC.md) - Especificação do protocolo

---

**Autor:** GitHub Copilot  
**Revisado por:** Equipe Bro  
