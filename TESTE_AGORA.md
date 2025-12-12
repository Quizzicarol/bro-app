# 🚀 TESTE AGORA - Guia Rápido

## ▶️ Passo 1: Iniciar Backend (OBRIGATÓRIO)

Abra um terminal PowerShell e rode:

```powershell
cd C:\Users\produ\Documents\GitHub\paga_conta_clean\backend
npm start
```

**Deve aparecer:**
```
🚀 Servidor rodando na porta 3002
📡 Health check: http://localhost:3002/health
⏰ Job de expiração de ordens ativo (a cada 5 minutos)
```

**DEIXE ESTE TERMINAL ABERTO!** Se fechar, o backend para.

---

## 📱 Passo 2: Abrir o App

O app já está instalado no seu dispositivo/emulador:
```powershell
adb shell am start -n com.pagaconta.paga_conta_clean/.MainActivity
```

Ou simplesmente abra o app "Paga Conta" no emulador.

---

## ✅ Passo 3: Testar Fluxo Completo

### 1️⃣ Criar Ordem (Como Usuário)

1. Na tela inicial, clique em **"Pagar Conta"**
2. Escolha o tipo (ex: Luz/Energia)
3. Digite:
   - Número da conta: `123456`
   - Valor: `100`
4. Clique em **"Gerar Invoice"**
5. **Copie e pague o invoice Lightning** (ou use uma carteira de teste)
6. Após pagar, você será redirecionado para **tela de status da ordem**

**O que você DEVE ver:**
- ✅ Status: "Aguardando Provedor"
- ✅ Contador de 24 horas
- ✅ Timeline com 3 passos
- ✅ Botão "Cancelar Ordem"
- ✅ Detalhes da ordem (ID, valor, tipo)

### 2️⃣ Ver em "Minhas Ordens"

1. Volte para a tela inicial (botão voltar)
2. Clique em **"Minhas Ordens"** (botão azul)

**O que você DEVE ver:**
- ✅ Lista com a ordem que você criou
- ✅ Status colorido (laranja = pendente)
- ✅ Valor e tipo da conta
- ✅ Data de criação

### 3️⃣ Aceitar Ordem (Como Provedor)

1. Na tela inicial, clique em **"Modo Provedor"** (botão verde)
2. Clique em **"Ordens Disponíveis"**

**O que você DEVE ver:**
- ✅ A ordem que você criou aparece na lista!
- ✅ Valor, tipo, tempo restante

3. Clique na ordem
4. Você verá os **dados de pagamento** (conta, valor, código de barras)
5. Clique em **"Aceitar Ordem"**

### 4️⃣ Enviar Comprovante

1. Após aceitar, clique em **"Upload de Comprovante"**
2. Escolha uma foto (galeria ou câmera) - pode ser qualquer imagem
3. Clique em **"Enviar Comprovante"**

### 5️⃣ Verificar Conclusão

1. Volte para o modo usuário
2. Entre em **"Minhas Ordens"**
3. Veja que o status mudou para **"Aguardando Validação"** ou **"Concluído"**

---

## 🔍 Ver Logs do Backend

No terminal onde o backend está rodando, você verá em tempo real:

```
[2024-11-11T10:15:23.456Z] POST /orders/create
✅ Ordem criada: f9a8b7c6-... | Usuário: bc6452... | Valor: R$ 100

[2024-11-11T10:16:45.789Z] GET /orders/available
📋 Listando 1 ordens disponíveis para provedor any

[2024-11-11T10:17:30.123Z] POST /orders/f9a8b7c6-.../accept
✅ Ordem aceita: f9a8b7c6-... | Provedor: provider-xyz

[2024-11-11T10:18:12.456Z] POST /orders/f9a8b7c6-.../submit-proof
📸 Comprovante enviado: f9a8b7c6-...
```

---

## 🐛 Se Algo Não Funcionar

### Backend não inicia:
```powershell
cd C:\Users\produ\Documents\GitHub\paga_conta_clean\backend
npm install  # Reinstalar dependências
npm start
```

### App dá erro de conexão:
- ✅ Verifique se o backend está rodando (terminal aberto)
- ✅ Veja se aparece "🚀 Servidor rodando na porta 3002"
- ✅ Se não aparecer ordens, pode ser que o backend parou

### Ver logs do app:
```powershell
adb logcat | Select-String "flutter"
```

### Ordens não aparecem:
- ✅ Backend DEVE estar rodando ANTES de criar a ordem
- ✅ Aguarde 10 segundos (polling automático)
- ✅ Puxe para atualizar (swipe down)

---

## 📊 Endpoints para Testar Manualmente

Se quiser testar os endpoints diretamente:

**Health check:**
```
http://localhost:3002/health
```

**Criar ordem via curl/Postman:**
```bash
POST http://localhost:3002/orders/create
Content-Type: application/json

{
  "userId": "bc6452e5323df686865e0a166d52eb2cb7e15ffa8d2af71015d989160de86836",
  "paymentHash": "abc123",
  "paymentType": "electricity",
  "accountNumber": "123456",
  "billValue": 100,
  "btcAmount": 0.00018
}
```

**Listar ordens disponíveis:**
```
GET http://localhost:3002/orders/available
```

---

## ✅ Checklist de Teste

- [ ] Backend iniciou (porta 3002)
- [ ] App abriu sem crash
- [ ] Consegui criar uma ordem
- [ ] Tela de status apareceu
- [ ] "Minhas Ordens" mostra a ordem
- [ ] Modo provedor ativado
- [ ] Ordem aparece em "Ordens Disponíveis"
- [ ] Consegui aceitar a ordem
- [ ] Dados de pagamento apareceram
- [ ] Upload de comprovante funcionou
- [ ] Status mudou para concluído

---

## 🎯 Resultado Esperado

Ao final do teste, você terá:

1. ✅ Uma ordem criada pelo usuário
2. ✅ Ordem aceita por um provedor
3. ✅ Comprovante enviado
4. ✅ Status atualizado em tempo real
5. ✅ Logs do backend mostrando todas as operações

**Isso comprova que TODO o fluxo está funcionando!** 🎉

---

## 💡 Dica Final

Deixe o backend rodando em um terminal separado e use outro terminal para logs do app:

**Terminal 1 (Backend):**
```powershell
cd C:\Users\produ\Documents\GitHub\paga_conta_clean\backend
npm start
```

**Terminal 2 (Logs do App):**
```powershell
adb logcat | Select-String "flutter|pagaconta"
```

Assim você vê tudo acontecendo em tempo real! 🔥
