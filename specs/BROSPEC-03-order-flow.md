# BROSPEC-03: Fluxo de Ordens

`draft` `mandatory`

## Resumo

Esta especificação define o fluxo completo de uma ordem no Protocolo Bro, desde a criação até a conclusão.

## Diagrama de Sequência

```
┌────────┐          ┌─────────┐          ┌──────────┐          ┌─────────┐
│ USUÁRIO│          │  RELAYS │          │ PROVEDOR │          │LIGHTNING│
└───┬────┘          └────┬────┘          └────┬─────┘          └────┬────┘
    │                    │                    │                     │
    │ 1. Criar Ordem     │                    │                     │
    │ (kind 30078)       │                    │                     │
    ├───────────────────►│                    │                     │
    │                    │                    │                     │
    │                    │ 2. Broadcast       │                     │
    │                    ├───────────────────►│                     │
    │                    │                    │                     │
    │                    │ 3. Aceitar Ordem   │                     │
    │                    │ (kind 30079)       │                     │
    │                    │◄───────────────────┤                     │
    │                    │                    │                     │
    │ 4. Recebe Aceite   │                    │                     │
    │◄───────────────────┤                    │                     │
    │                    │                    │                     │
    │ 5. Gera Invoice    │                    │                     │
    ├────────────────────┼───────────────────►│                     │
    │                    │                    │                     │
    │ 6. Paga Invoice    │                    │                     │
    ├────────────────────┼────────────────────┼────────────────────►│
    │                    │                    │                     │
    │                    │                    │ 7. Recebe Pagamento │
    │                    │                    │◄────────────────────┤
    │                    │                    │                     │
    │                    │                    │ 8. Executa PIX/     │
    │                    │                    │    Boleto           │
    │                    │                    ├─────────────────────┤
    │                    │                    │                     │
    │                    │ 9. Envia Comprovante                     │
    │                    │ (kind 30081)       │                     │
    │                    │◄───────────────────┤                     │
    │                    │                    │                     │
    │ 10. Recebe Prova   │                    │                     │
    │◄───────────────────┤                    │                     │
    │                    │                    │                     │
    │ 11. Confirma       │                    │                     │
    │ (via DM ou rating) │                    │                     │
    ├───────────────────►│                    │                     │
    │                    │                    │                     │
    ▼                    ▼                    ▼                     ▼
```

## Estados da Ordem

```
                    ┌─────────────┐
                    │   pending   │ ◄── Ordem criada
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
              ▼            ▼            ▼
       ┌──────────┐  ┌──────────┐  ┌─────────┐
       │ accepted │  │ expired  │  │cancelled│
       └────┬─────┘  └──────────┘  └─────────┘
            │
            ▼
       ┌─────────┐
       │  paid   │ ◄── Invoice Lightning paga
       └────┬────┘
            │
            ▼
    ┌───────────────┐
    │  in_progress  │ ◄── Provedor executando pagamento
    └───────┬───────┘
            │
            ▼
┌────────────────────────┐
│  awaiting_confirmation │ ◄── Comprovante enviado
└───────────┬────────────┘
            │
     ┌──────┴──────┐
     │             │
     ▼             ▼
┌──────────┐  ┌──────────┐
│completed │  │ disputed │
└──────────┘  └──────────┘
```

## Transições de Estado

| De | Para | Gatilho | Quem |
|----|------|---------|------|
| - | `pending` | Criar ordem | Usuário |
| `pending` | `accepted` | Provedor aceita | Provedor |
| `pending` | `expired` | Timeout (30min) | Sistema |
| `pending` | `cancelled` | Cancelamento | Usuário |
| `accepted` | `paid` | Invoice paga | Lightning |
| `paid` | `in_progress` | Provedor inicia | Provedor |
| `in_progress` | `awaiting_confirmation` | Comprovante enviado | Provedor |
| `awaiting_confirmation` | `completed` | Usuário confirma | Usuário |
| `awaiting_confirmation` | `disputed` | Abre disputa | Ambos |
| `disputed` | `completed` | Resolução | Mediador |

## Detalhamento das Etapas

### 1. Criação da Ordem (Usuário)

O usuário cria uma ordem especificando:

```javascript
// Dados necessários
{
  billType: "pix" | "boleto" | "ted",
  billCode: "<codigo_pix_ou_boleto>",
  amount: 100.00,  // BRL
}

// Sistema calcula automaticamente
{
  btcPrice: 800000.00,  // Cotação atual
  btcAmount: 0.000125,  // amount / btcPrice
  providerFee: 3.00,    // % do provedor
  platformFee: 0.50,    // % da plataforma (opcional)
  total: 103.50,        // BRL total
}
```

**Ações:**
1. Gerar UUID para `orderId`
2. Buscar cotação BTC/BRL
3. Calcular taxas
4. Criar evento kind 30078
5. Publicar nos relays

### 2. Aceitação (Provedor)

Provedor vê ordens pendentes e escolhe aceitar.

**Validações do Provedor:**
- [ ] Valor dentro dos limites
- [ ] Tipo de pagamento suportado
- [ ] Tem liquidez para executar
- [ ] Tem garantia suficiente (opcional)

**Ações:**
1. Verificar ordem válida
2. Travar garantia (se usar escrow)
3. Criar evento kind 30079
4. Publicar nos relays

### 3. Pagamento Lightning (Usuário)

Após aceite, usuário paga invoice.

**Opções de Invoice:**
- **Hold Invoice**: Fundos travados até confirmação
- **Invoice Normal**: Pagamento direto ao provedor

**Ações:**
1. Provedor gera invoice (valor em sats)
2. Usuário paga com wallet Lightning
3. Provedor confirma recebimento

### 4. Execução do Pagamento (Provedor)

Provedor executa o pagamento fiat.

**Para PIX:**
1. Acessar app bancário
2. Colar código PIX
3. Confirmar pagamento
4. Salvar comprovante

**Para Boleto:**
1. Acessar app bancário
2. Digitar código de barras
3. Confirmar pagamento
4. Salvar comprovante

### 5. Envio de Comprovante (Provedor)

Provedor envia prova de pagamento.

**Formatos aceitos:**
- Imagem (PNG, JPG) em base64
- PDF em base64
- Link para imagem (menos seguro)

**Ações:**
1. Capturar comprovante
2. Converter para base64
3. Criar evento kind 30081
4. Publicar nos relays

### 6. Confirmação (Usuário)

Usuário verifica e confirma.

**Validações:**
- [ ] Valor correto no comprovante
- [ ] Destinatário correto
- [ ] Data/hora recente
- [ ] Comprovante parece autêntico

**Ações:**
1. Verificar comprovante
2. Confirmar no app bancário (opcional)
3. Marcar ordem como `completed`
4. Deixar avaliação (opcional)

## Timeouts

| Estado | Timeout | Ação |
|--------|---------|------|
| `pending` | 30 min | Expira automaticamente |
| `accepted` | 15 min | Pode cancelar |
| `paid` | 60 min | Pode abrir disputa |
| `awaiting_confirmation` | 24h | Auto-confirmação* |

> *Auto-confirmação: Se usuário não responder em 24h e não abrir disputa, ordem é marcada como `completed`.

## Casos Especiais

### Ordem Direta (para provedor específico)

Usuário pode criar ordem direcionada a um provedor:

```json
{
  "tags": [
    ["d", "order-123"],
    ["t", "bro-order"],
    ["p", "<provider_pubkey>"],  // Provedor específico
    ...
  ]
}
```

### Cancelamento

Usuário pode cancelar ordem em `pending`:

```json
{
  "kind": 30080,
  "tags": [
    ["d", "order-123_cancel"],
    ["e", "<order_event_id>"],
    ["status", "cancelled"]
  ],
  "content": "{\"type\":\"bro_cancel\",\"reason\":\"Desisti\"}"
}
```

### Múltiplos Provedores

Se múltiplos provedores aceitarem, vale o primeiro evento.

**Regra**: Primeiro evento `kind 30079` com timestamp mais antigo é o aceite válido.

## Chat Durante Ordem

Comunicação via DMs Nostr (NIP-04/NIP-44):

```json
{
  "kind": 4,
  "pubkey": "<sender>",
  "tags": [
    ["p", "<receiver>"],
    ["e", "<order_event_id>"]  // Referência à ordem
  ],
  "content": "<encrypted_message>"
}
```

## Exemplo de Código (Dart)

```dart
// Criar ordem
final order = await broProtocol.createOrder(
  billType: 'pix',
  billCode: 'chavepix@email.com',
  amount: 100.00,
);

// Escutar atualizações
broProtocol.orderUpdates(order.id).listen((update) {
  switch (update.status) {
    case 'accepted':
      // Mostrar invoice para pagar
      showInvoice(update.invoice);
      break;
    case 'awaiting_confirmation':
      // Mostrar comprovante
      showProof(update.proofImage);
      break;
    case 'completed':
      // Sucesso!
      showSuccess();
      break;
  }
});

// Confirmar ordem
await broProtocol.confirmOrder(order.id);
```

---

*Versão: 0.1-draft*
*Data: Janeiro 2026*
