# 🐛 DEBUG: Ordens não aparecem no modo provedor

## Problema
Ordem criada como usuário não aparece na lista de ordens disponíveis do provedor.

## Logs Adicionados

### 1. OrderProvider (_saveOrders)
```
💾 X ordens salvas no SharedPreferences
   - abc12345: status="pending", R$ 100.00
```

### 2. OrderProvider (initialize)
```
📦 Carregadas X ordens salvas
   - abc12345: R$ 100.00 (pending)
```

### 3. ProviderOrdersScreen (_loadOrders)
```
🧪 Modo teste ativo, buscando OrderProvider...
🧪 OrderProvider obtido, total de ordens: X
   [0] Ordem abc12345: status="pending", amount=100.0
```

### 4. EscrowService (getAvailableOrdersForProvider)
```
🔍 getAvailableOrdersForProvider - Total de ordens: X
  Ordem abc12345: status=pending, isPending=true
📦 Ordens filtradas para provedor: X
```

---

## 🧪 Passo a Passo de Teste

### **Preparação:**
1. Build terminada? Execute o script:
   ```bash
   cd C:\Users\produ\Documents\GitHub\paga_conta_clean
   .\debug-ordens.bat
   ```

2. O script vai:
   - Instalar o APK atualizado
   - Reiniciar o app
   - Mostrar logs filtrados em tempo real

### **Teste 1: Criar Ordem**
1. Abra o app
2. Login como usuário (ou skip)
3. Crie uma ordem (ex: R$ 50,00)
4. **AGUARDE** aparecer os logs:
   ```
   💾 1 ordens salvas no SharedPreferences
      - abc12345: status="pending", R$ 50.00
   ```

5. **Se NÃO aparecer esse log:**
   - O problema é na CRIAÇÃO da ordem
   - Verifique se `AppConfig.testMode = true`

### **Teste 2: Entrar no Modo Provedor**
1. Volte para tela inicial
2. Clique em "Modo Teste" (ícone de provedor)
3. Entre na tela de ordens disponíveis
4. **AGUARDE** aparecer os logs:
   ```
   🧪 OrderProvider obtido, total de ordens: 1
      [0] Ordem abc12345: status="pending", amount=50.0
   🔍 getAvailableOrdersForProvider - Total de ordens: 1
     Ordem abc12345: status=pending, isPending=true
   📦 Ordens filtradas para provedor: 1
   ```

5. **Se aparecer `total de ordens: 0`:**
   - O OrderProvider não tem a ordem
   - A ordem não foi salva ou não foi carregada

6. **Se aparecer `Ordens filtradas: 0` mas `Total: 1`:**
   - O status da ordem não é 'pending'
   - Verifique o log detalhado do status

### **Teste 3: Verificar Persistência**
1. Force stop do app:
   ```bash
   .\adb.exe shell am force-stop com.pagaconta.paga_conta_clean
   ```

2. Reabra o app:
   ```bash
   .\adb.exe shell am start -n com.pagaconta.paga_conta_clean/.MainActivity
   ```

3. Entre direto no modo provedor
4. **AGUARDE** o log de carregamento:
   ```
   📦 Carregadas 1 ordens salvas
      - abc12345: R$ 50.00 (pending)
   ```

5. **Se aparecer `Carregadas 0 ordens`:**
   - SharedPreferences não persistiu
   - Problema de permissões ou storage

---

## 🔍 Cenários e Soluções

### Cenário 1: "💾 0 ordens salvas"
**Causa:** Ordem não foi criada
**Solução:** 
- Verifique se o fluxo de criação completou
- Verifique se `AppConfig.testMode = true`
- Verifique se o payment foi confirmado

### Cenário 2: "📦 Carregadas 0 ordens" (após reabrir)
**Causa:** SharedPreferences não funcionou
**Solução:**
- Limpar dados do app:
  ```bash
  .\adb.exe shell pm clear com.pagaconta.paga_conta_clean
  ```
- Reinstalar e testar novamente

### Cenário 3: "Total: 1, Filtradas: 0"
**Causa:** Status da ordem não é 'pending'
**Solução:**
- Verificar o log: `status="XXX"`
- Se for outro status, investigar por que mudou

### Cenário 4: Ordens aparecem mas lista vazia na UI
**Causa:** Problema de rendering
**Solução:**
- Verificar se `_availableOrders.length` no log
- Verificar console por erros de UI

---

## 📊 Checklist de Debug

- [ ] Build finalizada
- [ ] Script `debug-ordens.bat` rodando
- [ ] Ordem criada com sucesso (viu o log "💾")
- [ ] Entrou no modo provedor
- [ ] Viu log "🧪 OrderProvider obtido"
- [ ] Viu log "🔍 getAvailableOrdersForProvider"
- [ ] Viu log "📦 Ordens filtradas"
- [ ] Ordem apareceu na lista (UI)
- [ ] Testou persistência (fechar/reabrir)

---

## 🆘 Se Nada Funcionar

Envie os logs completos:
```bash
.\adb.exe logcat > logs.txt
```

Procure por:
- `❌` (erros)
- `💾` (salvamento)
- `📦` (carregamento)
- `🔍` (filtragem)
- `status=` (status das ordens)
