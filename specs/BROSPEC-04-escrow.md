# BROSPEC-04: Sistema de Escrow e Garantias

`draft` `optional`

## Resumo

Esta especificação define os mecanismos de escrow e garantias para proteger usuários e provedores no Protocolo Bro.

## Motivação

Em trocas P2P, existe o risco de:
- Provedor não executar o pagamento após receber Bitcoin
- Usuário alegar não recebimento após pagamento executado
- Disputas sem resolução

O sistema de escrow mitiga esses riscos.

## Opções de Implementação

### Opção 1: Hold Invoices (Recomendado)

Lightning Hold Invoices permitem travar fundos até condição ser satisfeita.

```
┌─────────┐          ┌──────────┐          ┌─────────┐
│ USUÁRIO │          │   LSP    │          │PROVEDOR │
└────┬────┘          └────┬─────┘          └────┬────┘
     │                    │                     │
     │ 1. Paga Hold       │                     │
     │    Invoice         │                     │
     ├───────────────────►│                     │
     │                    │ (fundos travados)   │
     │                    │                     │
     │                    │ 2. Notifica         │
     │                    ├────────────────────►│
     │                    │                     │
     │                    │                     │ 3. Executa
     │                    │                     │    pagamento
     │                    │                     │    fiat
     │                    │                     │
     │ 4. Confirma        │                     │
     ├───────────────────►│                     │
     │                    │                     │
     │                    │ 5. Libera fundos    │
     │                    ├────────────────────►│
     │                    │ (settle invoice)    │
     │                    │                     │
```

**Vantagens:**
- Nativo do Lightning
- Sem custódia de terceiros
- Reversível se provedor não executar

**Desvantagens:**
- Requer LSP compatível
- Timeout limitado (~24h)

### Opção 2: Garantia do Provedor (Colateral)

Provedor deposita garantia que é perdida em caso de fraude.

```
┌──────────┐                              ┌──────────┐
│ PROVEDOR │                              │ SISTEMA  │
└────┬─────┘                              └────┬─────┘
     │                                         │
     │ 1. Deposita 500k sats como garantia     │
     ├────────────────────────────────────────►│
     │                                         │
     │        (Garantia travada)               │
     │                                         │
     │ 2. Aceita ordem de 100k sats            │
     ├────────────────────────────────────────►│
     │                                         │
     │        (100k sats da garantia travados  │
     │         para esta ordem)                │
     │                                         │
     │ 3. Completa ordem com sucesso           │
     ├────────────────────────────────────────►│
     │                                         │
     │ 4. Garantia destravada                  │
     │◄────────────────────────────────────────┤
     │                                         │
```

#### Tiers de Provedor

| Tier | Garantia | Limite/Ordem | Ordens Simultâneas |
|------|----------|--------------|-------------------|
| Bronze | 100k sats | R$ 500 | 2 |
| Prata | 500k sats | R$ 2.000 | 5 |
| Ouro | 2M sats | R$ 10.000 | 10 |
| Diamante | 10M sats | R$ 50.000 | 20 |

#### Evento de Tier (kind 30082)

```json
{
  "kind": 30082,
  "pubkey": "<provider_pubkey>",
  "tags": [
    ["d", "provider_tier"],
    ["t", "bro-provider"],
    ["tier", "gold"],
    ["collateral", "2000000"],
    ["max_order", "10000.00"],
    ["max_concurrent", "10"]
  ],
  "content": "{...}"
}
```

### Opção 3: Escrow Multisig

Para valores altos, usar escrow Bitcoin on-chain com multisig 2-de-3.

```
Participantes:
- Usuário (1 chave)
- Provedor (1 chave)  
- Mediador (1 chave)

Cenários:
- Sucesso: Usuário + Provedor assinam liberação
- Disputa pró-usuário: Usuário + Mediador
- Disputa pró-provedor: Provedor + Mediador
```

**Vantagens:**
- Trustless (sem custódia)
- Funciona para qualquer valor

**Desvantagens:**
- Lento (confirmações on-chain)
- Taxas de mineração
- Complexo de implementar

## Fluxo com Hold Invoice

### 1. Usuário Cria Ordem

```javascript
// Ordem inclui preferência de escrow
{
  "escrow": {
    "type": "hold_invoice",
    "timeoutMinutes": 60
  }
}
```

### 2. Provedor Aceita e Gera Hold Invoice

```javascript
// Provedor gera hold invoice via LSP
const holdInvoice = await lsp.createHoldInvoice({
  amountSats: order.totalSats,
  description: `Bro Order ${order.id}`,
  expiryMinutes: 60,
  preimageHash: generatePreimageHash()
});

// Guarda preimage em segredo até completar
const preimage = holdInvoice.preimage;
```

### 3. Usuário Paga Hold Invoice

```javascript
// Fundos ficam travados no LSP
await wallet.payInvoice(holdInvoice.bolt11);
// Status: HELD (não SETTLED)
```

### 4. Provedor Executa Pagamento Fiat

```javascript
// Provedor paga PIX/Boleto
// Obtém comprovante
```

### 5. Provedor Revela Preimage (Settle)

```javascript
// Ao revelar preimage, fundos são liberados
await lsp.settleHoldInvoice(orderId, preimage);
// Provedor recebe os sats
```

### 6. Timeout/Cancelamento

```javascript
// Se provedor não completar a tempo
await lsp.cancelHoldInvoice(orderId);
// Fundos voltam para usuário
```

## Fluxo com Colateral

### 1. Provedor Deposita Garantia

```javascript
// Gerar invoice de depósito
const depositInvoice = await escrow.createDepositInvoice({
  tierId: 'gold',
  amountSats: 2000000
});

// Provedor paga
await wallet.payInvoice(depositInvoice);

// Publicar tier no Nostr
await publishProviderTier({
  tier: 'gold',
  collateral: 2000000
});
```

### 2. Travamento para Ordem

```javascript
// Ao aceitar ordem, parte da garantia é travada
await escrow.lockCollateral({
  providerId: provider.pubkey,
  orderId: order.id,
  lockedSats: order.totalSats * 1.5 // 150% do valor
});
```

### 3. Liberação após Sucesso

```javascript
// Ordem completada com sucesso
await escrow.unlockCollateral({
  providerId: provider.pubkey,
  orderId: order.id
});
```

### 4. Slashing em Caso de Fraude

```javascript
// Disputa resolvida contra provedor
await escrow.slashCollateral({
  providerId: provider.pubkey,
  orderId: order.id,
  slashedSats: order.totalSats,
  recipientPubkey: user.pubkey,
  reason: 'Pagamento não executado'
});
```

## API de Escrow

### Interface

```typescript
interface EscrowService {
  // Hold Invoices
  createHoldInvoice(params: HoldInvoiceParams): Promise<HoldInvoice>;
  settleHoldInvoice(orderId: string, preimage: string): Promise<void>;
  cancelHoldInvoice(orderId: string): Promise<void>;
  
  // Colateral
  depositCollateral(tierId: string, amountSats: number): Promise<Invoice>;
  withdrawCollateral(amountSats: number): Promise<void>;
  lockCollateral(params: LockParams): Promise<void>;
  unlockCollateral(params: UnlockParams): Promise<void>;
  slashCollateral(params: SlashParams): Promise<void>;
  
  // Consultas
  getCollateralBalance(providerId: string): Promise<number>;
  getLockedAmount(providerId: string): Promise<number>;
  getAvailableAmount(providerId: string): Promise<number>;
}

interface HoldInvoiceParams {
  amountSats: number;
  description: string;
  expiryMinutes: number;
}

interface LockParams {
  providerId: string;
  orderId: string;
  lockedSats: number;
}
```

## Considerações de Segurança

### Riscos e Mitigações

| Risco | Mitigação |
|-------|-----------|
| Provedor some com fundos | Hold invoice ou colateral |
| Usuário nega recebimento | Comprovante + mediação |
| LSP malicioso | Usar LSPs confiáveis |
| Timeout muito curto | Mínimo 60min para fiat |
| Colateral insuficiente | Tiers proporcionais |

### Melhores Práticas

1. **Para Usuários:**
   - Preferir provedores com alto colateral
   - Verificar reputação antes de criar ordem
   - Não confirmar sem verificar pagamento

2. **Para Provedores:**
   - Manter colateral adequado ao volume
   - Responder rapidamente a ordens
   - Guardar comprovantes por 30 dias

## Integração com LSPs

### LSPs Compatíveis com Hold Invoices

| LSP | Hold Invoice | Notas |
|-----|--------------|-------|
| Breez SDK | ✅ | Via Greenlight |
| LND | ✅ | Nativo |
| CLN | ✅ | Via plugin |
| Phoenix | ❌ | Não suportado |

### Exemplo com Breez SDK

```dart
// Criar hold invoice
final invoice = await breezSdk.receivePayment(
  amountMsat: order.totalSats * 1000,
  description: 'Bro Order ${order.id}',
  preimage: null, // LSP gera
  useDescriptionHash: true,
);

// Hold é gerenciado pelo LSP
// Settle automático quando preimage é revelado
```

---

*Versão: 0.1-draft*
*Data: Janeiro 2026*
