# Sistema de Ordens - Fluxo Completo

## ✅ Implementações Finalizadas

### 1. **Tela de Status da Ordem (OrderStatusScreen)**
Após o usuário pagar a Lightning invoice:
- ✅ Mostra status visual (pendente/aceito/em validação/concluído)
- ✅ Polling automático a cada 10 segundos
- ✅ Timeline com 3 etapas do processo
- ✅ Contador de tempo restante (24 horas)
- ✅ Botão de cancelamento para ordens pendentes
- ✅ Informações sobre o processo
- ✅ Dialog automático quando expira

### 2. **Tela de Minhas Ordens (UserOrdersScreen)**
- ✅ Lista todas as ordens do usuário
- ✅ Badges de status coloridos
- ✅ Filtros automáticos por status
- ✅ Botão de cancelamento em ordens pendentes
- ✅ Pull-to-refresh
- ✅ Navegação para detalhes

### 3. **Serviço de Ordens (OrderService)**
- ✅ `createOrder()` - Criar ordem de pagamento
- ✅ `getOrder()` - Obter detalhes
- ✅ `getUserOrders()` - Listar ordens do usuário
- ✅ `cancelOrder()` - Cancelar ordem pendente
- ✅ `checkOrderStatus()` - Verificar status
- ✅ Timeout de 24 horas configurado
- ✅ Formatação de tempo restante

### 4. **Integração no App**
- ✅ Rotas adicionadas ao main.dart
- ✅ Botão "Minhas Ordens" na Home (azul)
- ✅ Botão "Modo Provedor" na Home (laranja)
- ✅ StorageService com getUserId()
- ✅ EscrowService atualizado
- ✅ OrderProvider com métodos auxiliares

---

## 🔄 Fluxo Completo: Usuário → Provedor

### **PASSO 1: Usuário Cria Ordem**

1. Usuário vai em "Pagar Conta"
2. Escaneia/digita PIX ou Boleto
3. Sistema calcula valor + taxas (5%)
4. Sistema gera Lightning Invoice
5. Usuário paga invoice (Bitcoin vai para escrow)
6. **✅ NOVO:** Sistema redireciona para `OrderStatusScreen`
   - Mostra: "Aguardando Provedor"
   - Timer: 24 horas
   - Status: PENDENTE

### **PASSO 2: Ordem Fica Disponível para Provedores**

**⚠️ IMPORTANTE - FALTA IMPLEMENTAR:**

Para as ordens aparecerem na sessão do provedor, você precisa:

#### **No Backend:**
```javascript
// Quando ordem é criada (após pagamento da invoice)
POST /orders/create
{
  user_id: "xxx",
  payment_type: "pix" | "boleto",
  payment_data: {
    pix_key: "xxx", // ou
    barcode: "xxx"
  },
  amount_brl: 100.00,
  amount_sats: 20000,
  status: "pending",
  expires_at: Date.now() + (24 * 60 * 60 * 1000) // +24h
}

// Endpoint para listar ordens disponíveis
GET /orders/available?provider_id=xxx

Retorna:
{
  orders: [
    {
      id: "order_123",
      amount_brl: 100.00,
      amount_sats: 20000,
      payment_type: "pix",
      status: "pending",
      created_at: "2025-11-11T10:00:00Z",
      expires_at: "2025-11-12T10:00:00Z",
      user_id: "user_456"
      // NÃO incluir payment_data aqui (segurança)
    }
  ]
}
```

#### **No Frontend (já implementado):**
- `ProviderOrdersScreen` chama `getAvailableOrdersForProvider()`
- Filtra ordens por tier do provedor
- Mostra lista de ordens disponíveis

### **PASSO 3: Provedor Aceita Ordem**

1. Provedor vê ordem em "Ordens Disponíveis"
2. Clica na ordem → `ProviderOrderDetailScreen`
3. **AGORA** vê os dados da conta (PIX/Boleto)
4. Clica "Aceitar Ordem"
5. Sistema bloqueia garantia do provedor
6. Status muda: `pending` → `accepted`

### **PASSO 4: Provedor Paga a Conta**

1. Provedor copia dados PIX/Boleto
2. Vai no banco e paga
3. Tira foto do comprovante
4. Faz upload na tela
5. Status muda: `accepted` → `payment_submitted`

### **PASSO 5: Validação e Conclusão**

1. **Sistema valida comprovante** (OCR/Manual)
2. Se válido:
   - Libera Bitcoin para provedor + taxa 3%
   - Plataforma recebe taxa 2%
   - Desbloqueia garantia do provedor
   - Status: `payment_submitted` → `completed`
3. **Usuário recebe notificação:** "Sua conta foi paga!"

---

## 📱 Como Testar Agora

### **Teste 1: Criar Ordem como Usuário**

1. Abra o app (já instalado)
2. Vá em "Pagar Conta"
3. Escaneie/digite PIX ou Boleto
4. Pague a Lightning Invoice
5. **✅ NOVO:** Você será redirecionado para tela de status
   - Deve mostrar "Aguardando Provedor"
   - Timer de 24h
   - Botão "Cancelar Ordem"

### **Teste 2: Ver Suas Ordens**

1. Na Home, clique em "Minhas Ordens" (botão azul)
2. Deve listar todas suas ordens
3. Ordens pendentes têm botão "Cancelar"
4. Clique em uma ordem para ver detalhes

### **Teste 3: Cancelar Ordem**

1. Em "Minhas Ordens", clique em ordem pendente
2. Clique "Cancelar Ordem"
3. Confirme
4. ✅ Ordem deve mudar para status "Cancelado"
5. ✅ Bitcoin deve ser devolvido (backend precisa implementar)

### **⚠️ Teste 4: Ordem Aparecer no Modo Provedor (PENDENTE BACKEND)**

**O que deveria acontecer:**
1. Crie ordem como usuário (Teste 1)
2. Clique em "Modo Provedor" na Home
3. Clique "Começar Agora"
4. Deposite garantia
5. Vá em "Ver Ordens Disponíveis"
6. **✅ A ordem que você criou DEVERIA aparecer aqui**

**Por que não aparece:**
- ❌ Backend ainda não implementado
- ❌ Endpoint `/orders/available` não existe
- ❌ Endpoint `/orders/create` não existe

---

## 🔧 O Que Falta Implementar no Backend

### **Endpoints Necessários:**

```javascript
// 1. Criar ordem (após pagamento Lightning invoice)
POST /orders/create
Body: { user_id, payment_type, payment_data, amount_brl, amount_sats, payment_hash }
Retorna: { order_id, status: "pending", expires_at }

// 2. Listar ordens do usuário
GET /orders/user/:userId
Retorna: { orders: [...] }

// 3. Obter detalhes da ordem
GET /orders/:orderId
Retorna: { id, status, amount, payment_data, ... }

// 4. Cancelar ordem
POST /orders/:orderId/cancel
Body: { user_id, reason }
Validar: status === "pending"
Ação: Devolver Bitcoin, status = "cancelled"

// 5. Listar ordens disponíveis para provedor
GET /orders/available?provider_id=xxx
Retorna: { orders: [...] } // Apenas pending e não expiradas

// 6. Aceitar ordem (provedor)
POST /orders/:orderId/accept
Body: { provider_id }
Ação: Bloquear garantia, status = "accepted"

// 7. Submeter comprovante
POST /orders/:orderId/submit-proof
Body: { provider_id, receipt_url }
Ação: status = "payment_submitted"

// 8. Aprovar/Rejeitar pagamento
POST /orders/:orderId/validate
Body: { approved: true/false, reason }
Ação: Se aprovado → liberar fundos, status = "completed"
```

### **Lógica de Expiração:**

```javascript
// Job que roda a cada 5 minutos
async function checkExpiredOrders() {
  const expiredOrders = await db.orders.find({
    status: "pending",
    expires_at: { $lt: new Date() }
  });

  for (const order of expiredOrders) {
    // Devolver Bitcoin ao usuário
    await refundOrder(order.id, "Expirou - nenhum provedor aceitou");
    
    // Atualizar status
    await db.orders.update(order.id, { 
      status: "expired",
      refunded: true 
    });
  }
}
```

---

## 🎯 Próximos Passos

### **Para Você (Backend):**
1. Implementar endpoints listados acima
2. Adicionar job de expiração de ordens
3. Implementar lógica de devolução de Bitcoin
4. Adicionar validação de comprovantes (OCR ou manual)

### **Para Testar o Fluxo Completo:**
1. Backend pronto
2. Crie ordem como usuário
3. Veja ordem aparecer no modo provedor
4. Aceite ordem como provedor
5. Pague e submeta comprovante
6. Sistema valida e libera fundos
7. Usuário vê "Pagamento Concluído"

---

## 📊 Estados da Ordem

| Status | Descrição | Quem Vê |
|--------|-----------|---------|
| `pending` | Aguardando provedor aceitar | Usuário + Provedores |
| `accepted` | Provedor aceitou, vai pagar | Usuário + Provedor específico |
| `payment_submitted` | Comprovante enviado, aguardando validação | Usuário + Provedor |
| `completed` | Pagamento validado, fundos liberados | Usuário + Provedor |
| `cancelled` | Cancelado pelo usuário | Usuário |
| `expired` | Expirou (24h sem provedor) | Usuário |
| `disputed` | Em disputa | Usuário + Provedor + Admin |

---

## ✅ Resumo do Que Foi Entregue

**Frontend completo:**
- ✅ Tela de status pós-pagamento
- ✅ Tela de minhas ordens
- ✅ Serviço de ordens
- ✅ Integração na Home
- ✅ Cancelamento de ordens
- ✅ Polling de status
- ✅ Timer de expiração
- ✅ App compilado e instalado

**Falta:**
- ❌ Backend implementar endpoints
- ❌ Lógica de expiração
- ❌ Devolução de fundos
- ❌ Validação de comprovantes

**Teste no dispositivo para ver as novas telas funcionando!** 🚀
