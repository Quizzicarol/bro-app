# 🧪 COMO TESTAR PAGAMENTOS LIGHTNING NO APP

## ✅ O que está pronto para testar

O app **Paga Conta Clean** já está buildando e você pode testar **pagamentos Lightning reais** usando o Breez SDK Spark!

---

## 🚀 Como acessar a tela de testes

1. Abra o app no emulador
2. Faça login (qualquer seed/mnemonic funciona para testes)
3. Na tela Home, clique no botão flutuante **"⚡ Lightning Test"**
4. Você verá a tela de testes Lightning com:
   - Status do SDK (conectado/desconectado)
   - Saldo da sua carteira
   - Criar invoice para receber
   - Pagar invoice de outra wallet
   - Histórico de pagamentos

---

## 📥 TESTE 1: Receber Pagamento

### Opção A: Testnet (Recomendado para começar)
1. Na tela Lightning Test, digite um valor (ex: `1000` sats)
2. Clique em **"Criar Invoice"**
3. Um QR code será gerado
4. Copie a invoice (botão "Copiar Invoice")
5. Vá em **https://htlc.me** (faucet de testnet)
6. Cole a invoice e clique em "Pay"
7. Volte no app e veja o saldo aumentar!

### Opção B: Mainnet (Pagamentos reais)
1. Configure `useMainnet = false` em `lib/config/breez_config.dart` primeiro (para não gastar Bitcoin real)
2. Ou, se quiser testar com Bitcoin real:
   - Use outra wallet Lightning (Phoenix, Muun, BlueWallet, etc.)
   - Crie invoice no Paga Conta
   - Pague com a outra wallet

---

## 📤 TESTE 2: Enviar Pagamento

### Com Testnet
1. Use outra wallet testnet (Phoenix testnet, etc.) para criar uma invoice
2. Ou use https://htlc.me para gerar invoice de teste
3. Cole a invoice no campo "Invoice BOLT11"
4. Clique em **"Pagar Invoice"**
5. Confirme o pagamento
6. Pronto! Pagamento enviado

### Com Mainnet
1. Abra outra wallet Lightning (Phoenix, Muun, etc.)
2. Crie uma invoice de recebimento
3. Cole no app Paga Conta
4. Pague (vai usar seu saldo Lightning real)

---

## ⚙️ Configurações importantes

### 1. Test Mode (sem backend)
- **Arquivo**: `lib/config.dart`
- **Config**: `testMode = true`
- Quando ativado, as chamadas de API (escrow, etc.) retornam dados mockados
- Os pagamentos Lightning **funcionam normalmente** (não precisam de backend)

### 2. Testnet vs Mainnet
- **Arquivo**: `lib/config/breez_config.dart`
- **Config**: `useTestnet = true` (use testnet para testes sem gastar Bitcoin real)
- Testnet: usa Bitcoin de teste (sem valor real)
- Mainnet: usa Bitcoin real (tenha cuidado!)

### 3. Backend URL
- **Arquivo**: `lib/config.dart`
- **Config**: `defaultBackendUrl = 'http://10.0.2.2:3002'`
- Para testar escrow e funcionalidades completas, você precisará de um backend rodando
- Por enquanto, `testMode = true` permite testar o app sem backend

---

## 🔧 Como buildar e rodar

### No terminal (VS Code)
```powershell
# Mudar para a pasta correta
cd C:\Users\produ\Documents\GitHub\paga_conta_clean

# Instalar dependências
flutter pub get

# Buildar APK
flutter build apk --debug

# Instalar no emulador
C:\Users\produ\AppData\Local\Android\Sdk\platform-tools\adb.exe -s emulator-5554 install -r build\app\outputs\flutter-apk\app-debug.apk

# Iniciar app
C:\Users\produ\AppData\Local\Android\Sdk\platform-tools\adb.exe -s emulator-5554 shell am start -n com.pagaconta.paga_conta_mobile/.MainActivity
```

### Ou via Flutter Run (mais rápido para desenvolvimento)
```powershell
cd C:\Users\produ\Documents\GitHub\paga_conta_clean
flutter run
```

---

## 📱 Fluxo completo de teste

### Cenário: Testar enviar + receber
1. **Instale duas wallets testnet** (ou use 2 emuladores):
   - App 1: Paga Conta (este app)
   - App 2: Phoenix Testnet, BlueWallet Testnet, ou htlc.me

2. **Receber no Paga Conta**:
   - Crie invoice de 1000 sats
   - Pague com App 2
   - Veja saldo aumentar

3. **Enviar do Paga Conta**:
   - App 2 cria invoice
   - Cole no Paga Conta
   - Pague
   - Veja saldo diminuir no Paga Conta e aumentar no App 2

---

## ⚡ O que funciona AGORA (sem backend)

### ✅ Pagamentos Lightning
- ✅ Criar invoices (receber)
- ✅ Pagar invoices (enviar)
- ✅ Verificar saldo
- ✅ Histórico de pagamentos
- ✅ Decodificar invoices
- ✅ Endereços on-chain (swap)

### ❌ O que precisa de backend
- ❌ Escrow (HODL invoices)
  - Criar depósito de garantia
  - Liberar fundos
  - Penalizar provider
- ❌ Orders/Pedidos
  - Criar pedido de pagamento de conta
  - Aceitar pedido (provider)
  - Marcar como pago
- ❌ Chat entre cliente/provider
- ❌ Nostr auth/messaging

**Solução**: Use `testMode = true` no `config.dart` para mockar as respostas de backend enquanto testa pagamentos Lightning.

---

## 🐛 Problemas comuns

### 1. "SDK não inicializado"
- Aguarde alguns segundos após o login
- O SDK demora ~5-10s para inicializar
- Veja logs no console: `🚀 Iniciando Breez SDK Spark...`

### 2. "Insufficient balance" ao pagar
- Você precisa ter saldo Lightning primeiro
- Crie invoice e peça para alguém pagar
- Ou use faucet de testnet (htlc.me)

### 3. "Invoice expirada"
- Invoices Lightning expiram (padrão: 1 hora)
- Crie nova invoice se a anterior expirou

### 4. App não abre no emulador
```powershell
# Verificar se emulador está rodando
adb devices

# Reinstalar app
adb -s emulator-5554 uninstall com.pagaconta.paga_conta_mobile
adb -s emulator-5554 install -r build\app\outputs\flutter-apk\app-debug.apk
```

---

## 📊 Próximos passos

### Para completar o app de escrow
1. **Implementar backend** (Node.js + LND/CLN)
   - Endpoint `/api/escrow/create` (criar HODL invoice)
   - Endpoint `/api/escrow/release` (reveal preimage)
   - Endpoint `/api/orders/*` (gerenciar pedidos)

2. **Integrar backend com Breez SDK**
   - Backend cria HODL invoice via LND
   - Provider paga invoice (fundos bloqueados)
   - Cliente paga provider via Lightning normal
   - Backend libera HODL invoice (provider recebe fundos de volta)

3. **Testar fluxo end-to-end**
   - Provider deposita garantia (R$ 500)
   - Cliente cria pedido de conta (R$ 100)
   - Provider aceita e paga conta
   - Cliente paga provider via Lightning
   - Escrow liberado automaticamente

---

## 🎯 Foco atual: TESTAR LIGHTNING

Por enquanto, **ignore o backend** e foque em testar:
- ✅ Criar invoices
- ✅ Pagar invoices
- ✅ Ver saldo
- ✅ Histórico

Depois de validar que Lightning funciona perfeitamente, aí sim implementamos o backend para escrow.

---

## 💡 Dicas

1. **Use testnet** para não gastar Bitcoin real
2. **Guarde sua seed** (mnemonic) se quiser manter os fundos entre reinstalações
3. **Logs úteis**: Veja o console do VS Code para debugar problemas
4. **htlc.me**: Ótimo site para testar invoices testnet
5. **Phoenix Testnet**: Melhor wallet testnet para testar com o app

---

## 📞 Suporte

Se tiver dúvidas ou problemas:
1. Veja os logs no console do VS Code
2. Verifique se `testMode = true` em `config.dart`
3. Confirme que `useTestnet = true` em `breez_config.dart`
4. Teste criar invoice primeiro (mais fácil que pagar)

---

**Boa sorte com os testes! ⚡🚀**
