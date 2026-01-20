# 📋 Bro Protocol Specification

> **Status**: Draft v0.1  
> **Data**: Janeiro 2026

## 🎯 Objetivo

Formalizar o **Bro** como um protocolo aberto de escambo P2P (Bitcoin ↔ Fiat), permitindo que qualquer desenvolvedor implemente clientes compatíveis.

---

## 📚 Especificações

| Spec | Título | Status |
|------|--------|--------|
| [BROSPEC-01](specs/BROSPEC-01-overview.md) | Visão Geral | ✅ Draft |
| [BROSPEC-02](specs/BROSPEC-02-events.md) | Eventos e Mensagens | ✅ Draft |
| [BROSPEC-03](specs/BROSPEC-03-order-flow.md) | Fluxo de Ordens | ✅ Draft |
| [BROSPEC-04](specs/BROSPEC-04-escrow.md) | Sistema de Escrow | ✅ Draft |
| [BROSPEC-05](specs/BROSPEC-05-reputation.md) | Sistema de Reputação | ✅ Draft |
| [BROSPEC-06](specs/BROSPEC-06-discovery.md) | Descoberta de Provedores | ✅ Draft |

---

## 🗺️ Mapeamento do Código Atual

### Event Kinds Implementados

| Kind | Descrição | Arquivo | Status |
|------|-----------|---------|--------|
| `30078` | Ordem de Pagamento | `nostr_order_service.dart` | ✅ Implementado |
| `30079` | Aceitação de Ordem | `nostr_order_service.dart` | ✅ Implementado |
| `30080` | Atualização de Status | `nostr_order_service.dart` | ✅ Implementado |
| `30081` | Conclusão com Comprovante | `nostr_order_service.dart` | ✅ Implementado |
| `30082` | Perfil de Provedor | `nostr_order_service.dart` | ⚠️ Parcial |
| `4` | DM Criptografada (NIP-04) | `chat_service.dart` | ✅ Implementado |
| `0` | Perfil Nostr (NIP-01) | `nostr_profile_service.dart` | ✅ Implementado |

### Serviços Principais

| Serviço | Arquivo | Responsabilidade |
|---------|---------|------------------|
| `NostrService` | `nostr_service.dart` | Gerenciamento de chaves, assinatura |
| `NostrOrderService` | `nostr_order_service.dart` | Publicar/buscar ordens |
| `ChatService` | `chat_service.dart` | DMs criptografadas (NIP-04) |
| `EscrowService` | `escrow_service.dart` | Garantias e colateral |
| `DisputeService` | `dispute_service.dart` | Gerenciamento de disputas |
| `RelayService` | `relay_service.dart` | Conexão com relays |
| `NostrProfileService` | `nostr_profile_service.dart` | Perfis Nostr |

### Relays Utilizados

```dart
// Definidos em nostr_order_service.dart
final List<String> _relays = [
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://relay.nostr.band',
  'wss://nostr.wine',
  'wss://relay.primal.net',
];
```

---

## 📅 Fases do Projeto

### Fase 1: Documentação da Arquitetura Atual ✅ CONCLUÍDA

- [x] **Mapear fluxos existentes**
  - Fluxo de criação de ordem (usuário)
  - Fluxo de aceitação de ordem (provedor)
  - Fluxo de confirmação de pagamento
  - Fluxo de disputa/cancelamento

- [x] **Documentar eventos Nostr utilizados**
  - Tipos de eventos (kinds) usados
  - Estrutura das mensagens JSON
  - Tags utilizadas (p, e, t, etc.)

- [x] **Documentar integração Lightning**
  - Formato de invoices
  - Hold invoices para escrow
  - Timeouts e expirações

---

### Fase 2: Especificação Formal ✅ CONCLUÍDA

#### 2.1 BroSpecs Criadas

```
specs/
├── BROSPEC-01-overview.md      ✅ Visão geral do protocolo
├── BROSPEC-02-events.md        ✅ Eventos Nostr específicos
├── BROSPEC-03-order-flow.md    ✅ Fluxo de ordens
├── BROSPEC-04-escrow.md        ✅ Sistema de garantia
├── BROSPEC-05-reputation.md    ✅ Sistema de reputação
└── BROSPEC-06-discovery.md     ✅ Descoberta de provedores
```

#### 2.2 Event Kinds Definidos

| Kind | Descrição | Status |
|------|-----------|--------|
| `30078` | Ordem de pagamento (PIX/Boleto) | ✅ Implementado |
| `30079` | Aceitação de ordem | ✅ Implementado |
| `30080` | Atualização de status | ✅ Implementado |
| `30081` | Conclusão com comprovante | ✅ Implementado |
| `30082` | Perfil de provedor | ⚠️ Parcial |

---

### Fase 3: Definição de Mensagens ✅ DOCUMENTADA

Veja [BROSPEC-02-events.md](specs/BROSPEC-02-events.md) para estrutura completa.

#### 3.1 Estrutura de Ordem de Pagamento (kind 30078)

```json
{
  "kind": 30078,
  "tags": [
    ["d", "<order_id>"],
    ["t", "bro-order"],
    ["t", "bro-app"],
    ["t", "<bill_type>"],
    ["amount", "<amount_brl>"],
    ["status", "pending"]
  ],
  "content": "<json_com_detalhes>"
}
```

#### 3.2 Conteúdo da Ordem

```json
{
  "type": "bro_order",
  "version": "1.0",
  "orderId": "<uuid>",
  "billType": "pix",
  "billCode": "00020126580014br.gov.bcb.pix...",
  "amount": 100.00,
  "btcAmount": 0.000125,
  "btcPrice": 800000.00,
  "providerFee": 3.00,
  "platformFee": 0.50,
  "total": 103.50,
  "status": "pending",
  "createdAt": "2026-01-20T10:30:00Z"
}
```

#### 3.3 Aceitação de Ordem (kind 30079)

```json
{
  "kind": 30079,
  "tags": [
    ["d", "<order_id>_accept"],
    ["e", "<order_event_id>"],
    ["p", "<user_pubkey>"],
    ["t", "bro-order"],
    ["t", "bro-accept"]
  ],
  "content": "{\"type\":\"bro_accept\",\"orderId\":\"...\",\"providerId\":\"...\"}"
}
```

---

### Fase 4: Sistema de Escrow ✅ DOCUMENTADO

Veja [BROSPEC-04-escrow.md](specs/BROSPEC-04-escrow.md) para detalhes.

#### 4.1 Opções de Implementação

| Método | Status | Prós | Contras |
|--------|--------|------|---------|
| **Hold Invoices** | Recomendado | Simples, nativo LN | Requer LSP |
| **Colateral** | ✅ Implementado | Flexível | Requer confiança |
| **DLCs** | Futuro | Trustless | Complexo |
| **Fedimint** | Futuro | Privacy | Requer federação |

#### 4.2 Fluxo de Escrow com Colateral (Atual)

```
1. Provedor deposita garantia (colateral)
2. Provedor aceita ordem → parte do colateral é travada
3. Provedor executa pagamento PIX/Boleto
4. Provedor envia comprovante
5. Usuário confirma → colateral destravado
   OU
5. Disputa → colateral pode ser slashed
```

---

### Fase 5: Sistema de Reputação ✅ DOCUMENTADO

Veja [BROSPEC-05-reputation.md](specs/BROSPEC-05-reputation.md) para detalhes.

#### 5.1 Métricas de Reputação Implementadas

```json
{
  "totalOrders": 150,
  "successRate": 98.5,
  "avgTimeSeconds": 180,
  "totalVolume": 5000000,
  "disputeRate": 1.0,
  "activeSince": "2025-06-01T00:00:00Z",
  "collateral": 500000
}
```

#### 5.2 Reviews (NIP-32 Labels)

```json
{
  "kind": 1985,
  "tags": [
    ["L", "bro/review"],
    ["l", "positive", "bro/review"],
    ["e", "<order_event_id>"],
    ["p", "<provider_pubkey>"],
    ["rating", "5"]
  ],
  "content": "Rápido e confiável!"
}
```

---

### Fase 6: Descoberta de Provedores ✅ DOCUMENTADA

Veja [BROSPEC-06-discovery.md](specs/BROSPEC-06-discovery.md) para detalhes.

#### 6.1 Métodos de Descoberta

- **Busca em Relays**: Filtrar `kind 30082` com `#t: bro-provider`
- **Hashtags**: `#bro-provider`, `#bro-brasil`, `#bro-order`
- **NIP-05**: Verificação via domínio (ex: `provider@brostr.app`)
- **Web of Trust**: Provedores seguidos por contatos

---

### Fase 7: SDK de Referência 🚧 EM ANDAMENTO

O código atual em `lib/services/` serve como implementação de referência.

#### 7.1 Estrutura Atual (bro_app/lib/)

```
lib/
├── services/
│   ├── nostr_service.dart          # Chaves e assinatura
│   ├── nostr_order_service.dart    # Publicar/buscar ordens
│   ├── chat_service.dart           # DMs NIP-04
│   ├── escrow_service.dart         # Garantias
│   ├── dispute_service.dart        # Disputas
│   └── relay_service.dart          # Conexão relays
├── models/
│   ├── order.dart                  # Modelo de ordem
│   └── nostr_message.dart          # Modelo de mensagem
└── ...
```

#### 7.2 Futuro: SDK Extraído

```
bro-protocol-sdk/
├── dart/          # Flutter (extraído do bro_app)
├── typescript/    # Web/Node
├── rust/          # Performance/Core
└── python/        # Bots/Automação
```

#### 7.3 API Proposta do SDK

```dart
// Inicialização
final bro = BroProtocol(
  privateKey: nsec,
  relays: ['wss://relay.damus.io', 'wss://nos.lol'],
);

// Usuário: Criar ordem
final order = await bro.createOrder(
  billType: 'pix',
  billCode: 'chavepix@email.com',
  amount: 100.00,
);

// Provedor: Buscar e aceitar ordens
final pendingOrders = await bro.fetchPendingOrders();
await bro.acceptOrder(order.id);

// Provedor: Enviar comprovante
await bro.completeOrder(order.id, proofImage: base64Image);

// Usuário: Confirmar recebimento
await bro.confirmOrder(order.id);
```

---

## 📊 Timeline Atualizada

```
Fase 1:   [██████████] Documentação      ✅ CONCLUÍDA
Fase 2:   [██████████] Especificação     ✅ CONCLUÍDA
Fase 3:   [██████████] Mensagens         ✅ CONCLUÍDA
Fase 4:   [██████████] Escrow            ✅ CONCLUÍDA
Fase 5:   [██████████] Reputação         ✅ CONCLUÍDA
Fase 6:   [██████████] Descoberta        ✅ CONCLUÍDA
Fase 7:   [████░░░░░░] SDK               🚧 EM ANDAMENTO
───────────────────────────────────────────────────────
Próximo: Extrair SDK do código atual
```

---

## 🎯 Entregáveis

### Concluídos ✅

1. **Especificação Bro Protocol v0.1**
   - 6 BROSPECs documentando todo o protocolo
   - Diagramas de sequência
   - Exemplos de implementação

### Em Andamento 🚧

2. **SDK de Referência**
   - [x] Código Dart no bro_app (implementação atual)
   - [ ] Extrair para pacote separado
   - [ ] Testes automatizados
   - [ ] Documentação de API

### Futuro 📋

3. **Relay de Referência**
   - Relay Nostr otimizado para Bro
   - Filtros especializados
   - Endpoint: `wss://relay.brostr.app`

4. **Proposta de NIP**
   - Submeter ao repositório de NIPs
   - Discussão com comunidade Nostr
   - Padronização oficial

---

## 🤝 Próximos Passos

1. **[x] Revisar código atual** - Mapear todos os eventos Nostr usados no bro_app
2. **[x] Criar pasta `specs/`** - Documentação formal criada
3. **[x] Definir kinds oficiais** - Usando 30078-30082 (parametrized replaceable)
4. **[ ] Extrair SDK** - Separar lógica de protocolo do app
5. **[ ] Testes** - Criar suite de testes para o protocolo
6. **[ ] Proposta NIP** - Submeter especificação para comunidade Nostr

---

## 📚 Referências

- [NIPs - Nostr Implementation Possibilities](https://github.com/nostr-protocol/nips)
- [BOLTs - Lightning Network Specs](https://github.com/lightning/bolts)
- [NIP-04 - Encrypted Direct Messages](https://github.com/nostr-protocol/nips/blob/master/04.md)
- [NIP-44 - Versioned Encryption](https://github.com/nostr-protocol/nips/blob/master/44.md)
- [NIP-32 - Labeling](https://github.com/nostr-protocol/nips/blob/master/32.md)

---

## 💡 Visão de Futuro

> "O Bro Protocol permite que qualquer pessoa no mundo troque valor de forma P2P, 
> usando Bitcoin como ponte universal entre moedas fiduciárias, sem intermediários 
> centralizados ou permissão de terceiros."

**Casos de uso expandidos:**
- 🌎 Remessas internacionais P2P
- 🏪 Pagamentos a comerciantes
- 💱 Exchange descentralizada
- 🤝 Rede de confiança (Web of Trust)

---

*Documento criado em: Janeiro 2026*
*Versão: 0.1-draft*
