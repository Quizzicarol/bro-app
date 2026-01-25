# 🏗️ Arquitetura do Bro App

## Visão Geral

O Bro é um app P2P para pagamento de contas usando Bitcoin via Lightning Network.
Usa o protocolo Nostr para comunicação descentralizada entre usuários e provedores (Bros).

```
┌─────────────────────────────────────────────────────────────┐
│                        BRO APP                               │
├─────────────────────────────────────────────────────────────┤
│  SCREENS (UI)                                                │
│  ├── marketplace_screen.dart    # Criar ordens              │
│  ├── order_status_screen.dart   # Status da ordem           │
│  ├── provider_orders_screen.dart # Tela do Bro              │
│  ├── deposit_screen.dart        # Depósito BTC              │
│  └── ...                                                     │
├─────────────────────────────────────────────────────────────┤
│  PROVIDERS (Estado)                                          │
│  ├── order_provider.dart        # Ordens (CRUD + Nostr)     │
│  ├── breez_provider.dart        # Carteira Lightning        │
│  ├── collateral_provider.dart   # Tier/Garantia             │
│  └── ...                                                     │
├─────────────────────────────────────────────────────────────┤
│  SERVICES (Lógica de Negócio)                               │
│  ├── nostr_service.dart         # Chaves Nostr              │
│  ├── nostr_order_service.dart   # Eventos de ordens         │
│  ├── breez_sdk (externo)        # SDK Lightning             │
│  └── ...                                                     │
├─────────────────────────────────────────────────────────────┤
│  MODELS (Dados)                                              │
│  ├── order.dart                 # Modelo de ordem           │
│  └── ...                                                     │
└─────────────────────────────────────────────────────────────┘
```

---

## 📁 Estrutura de Pastas

```
lib/
├── main.dart                 # Entry point
├── config.dart               # Configurações (testMode, etc)
├── models/
│   └── order.dart            # Modelo Order
├── providers/
│   ├── order_provider.dart   # ⭐ CRÍTICO - gerencia ordens
│   ├── breez_provider.dart   # Carteira Lightning
│   ├── collateral_provider.dart # Tier/Garantia
│   ├── provider_balance_provider.dart
│   └── platform_balance_provider.dart
├── services/
│   ├── nostr_service.dart    # Chaves e assinatura Nostr
│   ├── nostr_order_service.dart # ⭐ CRÍTICO - eventos Nostr
│   ├── secure_storage_service.dart
│   └── ...
├── screens/
│   ├── marketplace_screen.dart
│   ├── order_status_screen.dart
│   ├── provider_orders_screen.dart
│   ├── deposit_screen.dart
│   └── ...
└── widgets/
    └── ...
```

---

## 🔑 Componentes Críticos

### 1. OrderProvider (`lib/providers/order_provider.dart`)

Gerencia TODAS as ordens do usuário. Responsável por:
- CRUD de ordens
- Sincronização com Nostr
- Filtro de segurança por pubkey
- Salvar/Carregar do SharedPreferences

**Variáveis importantes:**
```dart
List<Order> _orders = [];           // Todas as ordens em memória
String? _currentUserPubkey;         // Pubkey do usuário logado
bool _isProviderMode = false;       // Se está no modo Bro
```

**Métodos críticos:**
```dart
initialize()           // Inicializa com pubkey
loadOrdersForUser()    // Carrega ordens de um usuário
createOrder()          // Cria nova ordem
updateOrderStatus()    // Atualiza status (publica no Nostr)
syncOrdersFromNostr()  // Sincroniza ordens do usuário
syncAllPendingOrdersFromNostr() // Sincroniza TODAS (modo Bro)
_saveOrders()          // Salva COM filtro de segurança
```

### 2. NostrOrderService (`lib/services/nostr_order_service.dart`)

Gerencia eventos Nostr para ordens. Kinds usados:
```dart
kindBroOrder = 30078;       // Ordem criada
kindBroAccept = 30079;      // Bro aceita ordem
kindBroPaymentProof = 30080; // Update de status
kindBroComplete = 30081;    // Ordem completada
kindBroProviderData = 30082; // Dados do provedor (tier)
```

**Métodos críticos:**
```dart
publishOrder()                    // Publica ordem no Nostr
updateOrderStatus()               // Publica update de status
completeOrderOnNostr()            // Bro envia comprovante
fetchUserOrders()                 // Busca ordens do usuário
fetchPendingOrders()              // Busca ordens pendentes
fetchOrderUpdatesForUser()        // Busca updates para usuário
fetchOrderUpdatesForProvider()    // Busca updates para Bro
```

### 3. BreezProvider (`lib/providers/breez_provider.dart`)

Gerencia a carteira Lightning via Breez SDK Spark.

**Métodos críticos:**
```dart
initialize()          // Inicializa SDK
getBalance()          // Saldo da carteira
receivePayment()      // Gerar invoice para receber
payInvoice()          // Pagar invoice
getAllPayments()      // Histórico de pagamentos
```

---

## 💾 Persistência de Dados

### SharedPreferences
- `orders_{pubkey}` - Ordens do usuário (JSON)
- `collateral_{pubkey}` - Dados do tier

### Secure Storage
- `nostr_private_key` - Chave privada Nostr
- `is_provider_mode_{pubkey}` - Flag modo Bro

### Nostr (Relays)
- Eventos de ordens (persistência descentralizada)
- Eventos de tier (para recuperação)

---

## 🔐 Segurança

### Filtro de Ordens por Pubkey

TODA operação que adiciona ordem à lista `_orders` DEVE verificar:
```dart
final isOwner = order.userPubkey == _currentUserPubkey;
final isProvider = order.providerId == _currentUserPubkey;
if (!isOwner && !isProvider) {
  // REJEITAR - ordem de outro usuário
}
```

### Salvar apenas ordens do usuário
```dart
Future<void> _saveOrders() async {
  // Filtrar ANTES de salvar
  final userOrders = _orders.where((o) => 
    o.userPubkey == _currentUserPubkey || 
    o.providerId == _currentUserPubkey
  ).toList();
  // Salvar userOrders
}
```

---

## 📡 Comunicação Nostr

### Relays Usados
```dart
final _relays = [
  'wss://relay.damus.io',
  'wss://relay.primal.net',
  'wss://nos.lol',
  'wss://relay.snort.social',
];
```

### Fluxo de Eventos

```
USUÁRIO                          NOSTR                           BRO
   |                               |                               |
   |---(1) Publica kind 30078----->|                               |
   |       (nova ordem)            |                               |
   |                               |<----(2) Busca pendentes-------|
   |                               |                               |
   |                               |---(3) Retorna ordem---------->|
   |                               |                               |
   |                               |<----(4) Publica kind 30079----|
   |                               |       (aceita ordem)          |
   |<----(5) Busca updates---------|                               |
   |                               |                               |
   |                               |<----(6) Publica kind 30081----|
   |                               |       (envia comprovante)     |
   |<----(7) Busca updates---------|                               |
   |                               |                               |
   |---(8) Publica kind 30080----->|                               |
   |       (confirma, completed)   |                               |
   |                               |<----(9) Busca updates---------|
```

---

*Última atualização: 25 de Janeiro de 2026*
