# Guia de Teste: Auto-Detecção PIX/Boleto

## 🎯 O que foi corrigido

O problema estava no **modo de teste** (`AppConfig.testMode = true`). Quando você colava um código PIX:

1. O listener `_onCodeChanged` detectava o código ✅
2. Chamava `orderProvider.decodePix(code)` ✅
3. O método tentava chamar `/api/decode-pix` no backend ❌
4. Como o backend não estava rodando, a chamada falhava ❌
5. Não tinha resposta mock configurada ❌

**Solução implementada:** Adicionei respostas mock para `/api/decode-pix`, `/api/validate-boleto` e `/api/bitcoin/convert-price` no `api_service.dart`.

---

## 📱 Como testar

### 1. Abra o app no emulador
- O app já está instalado: **Paga Conta Clean**
- Faça login (qualquer chave funciona em modo teste)

### 2. Vá para "Novo Pagamento"
- Clique no botão de criar nova ordem/pagamento
- Você verá uma tela com campo de texto "Código PIX ou Boleto"

### 3. Teste com códigos PIX de exemplo

**Código PIX válido (formato EMV):**
```
00020126580014br.gov.bcb.pix0136teste@email.com5204000053039865802BR5913Teste Merchant6009SAO PAULO62070503***63041D3D
```

**Como colar no emulador:**
1. Copie o código acima
2. No emulador Android, pressione `Ctrl` + `V` (ou use o botão "..." → "Extended controls" → "Virtual sensors" → "Clipboard")
3. Cole no campo de texto

### 4. Observe o comportamento esperado

**Auto-detecção ativa (500ms de delay):**
- Após colar, aguarde 500ms
- O app deve automaticamente detectar que é PIX
- Deve aparecer um card verde: "✅ Valor detectado automaticamente"
- Dados simulados exibidos:
  - **Tipo:** PIX
  - **Valor:** R$ 150,75
  - **Beneficiário:** Comerciante Teste Ltda
  - **Chave PIX:** teste@email.com

**Conversão Bitcoin:**
- Preço BTC mock: R$ 350.000,00
- Taxas:
  - Provider: 5% (R$ 7,54)
  - Plataforma: 2% (R$ 3,02)
  - Total BRL: R$ 161,31
  - Total sats: ~46.089 sats

### 5. Teste com Boleto

**Linha digitável de boleto (47 dígitos):**
```
23793381286000012800371000063306789560000001234
```

**Comportamento esperado:**
- Auto-detecção em 500ms
- Card verde: "✅ Valor detectado automaticamente"
- Dados mock:
  - **Tipo:** Boleto
  - **Valor:** R$ 250,50
  - **Beneficiário:** Banco Teste S.A.
  - **Vencimento:** 5 dias a partir de hoje

---

## 🔍 Debug no console

Se quiser ver os logs, rode com:
```bash
cd C:\Users\produ\Documents\GitHub\paga_conta_clean
flutter run
```

Logs esperados:
```
🧪 TEST MODE: Mock response para /api/decode-pix
🔍 Mock: Decodificando PIX: 00020126580014br.gov.bcb.pix0136teste@email.com...
📨 Resposta da API: {success: true, billType: pix, value: 150.75, ...}
✅ Decodificação bem-sucedida
```

---

## 📊 Diferenças vs versão web

A lógica de detecção é **idêntica** à versão web:

| Feature | Web | Mobile |
|---------|-----|--------|
| Auto-detecção PIX (00020126) | ✅ | ✅ |
| Auto-detecção Boleto (47/48 dígitos) | ✅ | ✅ |
| Delay de 500ms | ✅ | ✅ |
| Cálculo de taxas (5% + 2%) | ✅ | ✅ |
| Mock em modo teste | ✅ | ✅ |

---

## 🧪 Próximos passos

### Para testar com backend real:

1. **Desative o modo teste:**
   ```dart
   // lib/config.dart
   static const bool testMode = false; // Altere para false
   ```

2. **Inicie o backend:**
   ```bash
   cd C:\path\to\backend
   npm start
   ```

3. **Configure o IP correto:**
   ```dart
   // lib/config.dart
   static const String defaultBackendUrl = 'http://10.0.2.2:3002'; // Android emulador
   // ou
   static const String defaultBackendUrl = 'http://<SEU_IP>:3002'; // Dispositivo físico
   ```

4. **Rebuild o app:**
   ```bash
   flutter build apk
   ```

### Testando Lightning real:

O app já está configurado com Breez SDK Spark. Para testar:

1. Faça login com Nostr
2. Crie uma ordem
3. Escolha "Lightning Network"
4. Escaneie a invoice em uma carteira testnet (Phoenix, Breez, etc.)
5. Pague e observe o polling de confirmação (a cada 3s)

---

## ⚠️ Observações importantes

1. **Modo Teste está ATIVO** por padrão (`testMode = true`)
2. **Backend não é necessário** em modo teste
3. **Lightning funciona normalmente** (Breez SDK não é mockado)
4. **Dados PIX/Boleto são mockados** com valores fixos
5. **Auto-detecção funciona** mesmo sem backend

---

## 🐛 Solução de problemas

**"Código não é detectado automaticamente":**
- Verifique se o código começa com `00020126` (PIX) ou tem 47/48 dígitos (Boleto)
- Aguarde 500ms após colar
- Veja os logs no console com `flutter run`

**"Erro ao decodificar PIX":**
- Se testMode = false, verifique se backend está rodando
- Se testMode = true, veja os logs do mock

**"App não abre":**
- Limpe cache: `flutter clean`
- Rebuild: `flutter build apk`
- Reinstale

---

## 📝 Resumo técnico

**Arquivos modificados:**
- `lib/services/api_service.dart`: Adicionado mock responses para PIX/Boleto
- `lib/config.dart`: `testMode = true` por padrão

**Fluxo da auto-detecção:**
```
TextField onChange
  → _onCodeChanged (listener)
  → Detecta formato (PIX ou Boleto)
  → Delay 500ms
  → _processBill(code)
  → orderProvider.decodePix(code) ou validateBoleto(code)
  → ApiService.post('/api/decode-pix', ...)
  → testMode? _getMockResponse() : Dio.post()
  → Retorna dados mockados
  → Atualiza UI com card verde + dados
```

---

✅ **Auto-detecção PIX/Boleto está funcionando!**

Cole um código PIX e aguarde 500ms para ver a mágica acontecer! 🎉
