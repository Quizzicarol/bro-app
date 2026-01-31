# 📋 BACKLOG - Tarefas Futuras do Bro App

**Última Atualização:** 31 de Janeiro de 2026

---

## 🔒 Prioridade Alta

### 1. Implementar NIP-17 (Gift Wraps) para Comprovantes
**Versão Target:** 1.1.0  
**Estimativa:** 2-3 dias  
**Descrição:**  
Atualmente os comprovantes de pagamento (imagens de PIX) são enviados em texto claro nos eventos Nostr. Isso expõe dados sensíveis como:
- Nome do pagador/recebedor
- CPF parcial
- Banco
- Valor

**Solução:**  
Implementar NIP-17 (Private Direct Messages via Gift Wraps) para encriptar o comprovante de forma que apenas o criador da ordem possa ver.

**Passos:**
1. [ ] Adicionar biblioteca de criptografia (NIP-04 ou NIP-44)
2. [ ] Modificar `completeOrderOnNostr()` para encriptar proof com pubkey do usuário
3. [ ] Modificar `fetchStatusUpdates()` para descriptografar proof
4. [ ] Manter compatibilidade retroativa (detectar se está encriptado ou não)
5. [ ] Testes cross-device

**Referências:**
- [NIP-17 Spec](https://github.com/nostr-protocol/nips/blob/master/17.md)
- [NIP-44 Versioned Encryption](https://github.com/nostr-protocol/nips/blob/master/44.md)

---

### 2. Auto-liquidação em Background
**Versão Target:** 1.1.0  
**Estimativa:** 1-2 dias  
**Descrição:**  
Atualmente a auto-liquidação só executa quando o provedor está com o app aberto na tela da ordem. Isso é ruim porque:
- Provedor pode esquecer de abrir o app
- Ganhos ficam presos até abrir manualmente

**Solução:**  
Implementar WorkManager (Android) / BGTaskScheduler (iOS) para verificar periodicamente ordens expiradas.

**Passos:**
1. [ ] Adicionar `workmanager` package
2. [ ] Criar task de verificação a cada 1h
3. [ ] Task verifica ordens locais em `awaiting_confirmation` > 24h
4. [ ] Executar auto-liquidação para cada uma
5. [ ] Enviar notificação local informando

---

## 🟡 Prioridade Média

### 3. Indicador de Status de Conexão com Relays
**Versão Target:** 1.1.0  
**Estimativa:** 0.5 dia  
**Descrição:**  
Usuário não sabe se está conectado aos relays Nostr. Operações podem parecer "travadas".

**Solução:**  
Adicionar indicador visual no AppBar ou Drawer mostrando status de conexão.

---

### 4. Timeout Mais Curto para Criar Invoice
**Versão Target:** 1.0.88  
**Estimativa:** 0.5 dia  
**Descrição:**  
Timeout de 30s para criar invoice é muito longo. Adicionar feedback intermediário.

---

### 5. Localização de Moeda
**Versão Target:** 1.2.0  
**Estimativa:** 1 dia  
**Descrição:**  
Formato de moeda hardcoded como `R$`. Usar `Intl` package para detectar locale.

---

## 🟢 Prioridade Baixa

### 6. Reduzir Logs em Produção
**Versão Target:** 1.1.0  
**Estimativa:** 0.5 dia  
**Descrição:**  
Logs verbosos (`debugPrint`) em produção afetam performance levemente.

**Solução:**  
Criar wrapper que só loga em `kDebugMode`.

---

### 7. Feedback Tátil (Haptic)
**Versão Target:** 1.2.0  
**Estimativa:** 0.5 dia  
**Descrição:**  
Adicionar `HapticFeedback.mediumImpact()` em ações críticas como "Aceitar Ordem" e "Confirmar Pagamento".

---

### 8. Limitar Tamanho de Imagem de Comprovante
**Versão Target:** 1.0.88  
**Estimativa:** 0.5 dia  
**Descrição:**  
Imagens de comprovante podem ser muito grandes (vários MB em base64). Relays podem rejeitar.

**Solução:**  
Adicionar `imageQuality: 50` e limitar tamanho final a 500KB.

---

## 📊 Histórico de Versões

| Versão | Data | Principais Mudanças |
|--------|------|---------------------|
| 1.0.87+126 | 2026-01-31 | Correções de duplicação, auto-liquidação, aviso privacidade |
| 1.0.87+125 | 2026-01-31 | Filtro userPubkey, deduplicação |
| 1.0.87+124 | 2026-01-31 | Bump de versão |

---

## 📝 Como Adicionar Tarefas

1. Identificar categoria (Alta/Média/Baixa)
2. Definir versão target
3. Estimar tempo
4. Descrever problema e solução
5. Listar passos de implementação
6. Adicionar referências se aplicável
