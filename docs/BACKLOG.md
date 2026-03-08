# 📋 BACKLOG - Tarefas Futuras do Bro App

**Última Atualização:** 5 de Março de 2026

---

## 🔒 Prioridade Alta

### ~~1. Implementar NIP-44 para Comprovantes~~ ✅ CONCLUÍDO
**Versão:** 1.0.131+274  
**Concluído em:** Fevereiro 2026  
**Resultado:** Implementado NIP-44v2 (XChaCha20-Poly1305) para encriptar comprovantes entre user↔provider e admin mediador. Inclui fallback para plaintext com warning.

---

### ~~2. Auto-liquidação em Background~~ ✅ CONCLUÍDO
**Versão:** 1.0.131+274  
**Concluído em:** Fevereiro 2026  
**Resultado:** WorkManager com task periódica de 15min. Verifica ordens em `awaiting_confirmation` > 36h. Race condition lock (2min TTL) entre foreground/background. Event signature verification no background.

---

## 🟡 Prioridade Média

### ~~3. Indicador de Status de Conexão com Relays~~ ✅ CONCLUÍDO → REMOVIDO
**Versão:** 1.0.131+337 (adicionado) → 1.0.131+340 (removido)  
**Concluído em:** Março 2026  
**Resultado:** Implementado e depois removido por poluir a interface. RelayService continua funcional internamente.

---

### ~~4. Timeout Mais Curto para Criar Invoice~~ ✅ CONCLUÍDO
**Versão:** 1.0.131+337  
**Concluído em:** Março 2026  
**Resultado:** Dialog de criação de invoice agora mostra feedback progressivo: "Conectando ao Spark... (Xs)" → "Aguardando resposta... (Xs)" → "Tentando via Liquid... (Xs)". Atualiza a cada 5s.

---

### 5. Localização de Moeda
**Versão Target:** 1.2.0  
**Estimativa:** 1 dia  
**Descrição:**  
Formato de moeda hardcoded como `R$`. Usar `Intl` package para detectar locale.

---

## 🟢 Prioridade Baixa

### ~~6. Reduzir Logs em Produção~~ ✅ CONCLUÍDO
**Versão:** 1.0.131+336  
**Concluído em:** Março 2026  
**Resultado:** Criado `broLog()` wrapper em `lib/services/log_utils.dart`. Substituídos 1579 `debugPrint()` em 74 arquivos. Zero logs em release builds.

---

### 7. Feedback Tátil (Haptic)
**Versão Target:** 1.2.0  
**Estimativa:** 0.5 dia  
**Descrição:**  
Adicionar `HapticFeedback.mediumImpact()` em ações críticas como "Aceitar Ordem" e "Confirmar Pagamento".

---

### ~~8. Limitar Tamanho de Imagem de Comprovante~~ ✅ CONCLUÍDO
**Versão:** 1.0.131+337  
**Concluído em:** Março 2026  
**Resultado:** Validação de 500KB máximo em `completeOrderOnNostr` antes da criptografia NIP-44. Imagens de evidência reduzidas de 1024x1024/q70 para 600x600/q50. `order_details_modal` também atualizado para 600x600/q50.

---

## 📊 Histórico de Versões

| Versão | Data | Principais Mudanças |
|--------|------|---------------------|
| 1.0.131+339 | 2026-03-05 | Fix disputa: auto-pay, reembolso admin, regenerar invoice, admin pay provider |
| 1.0.131+336 | 2026-03-05 | Open source docs, Breez cert limpo do histórico, bump build |
| 1.0.131+274 | 2026-02 | Security audit (18 vulns), NIP-44 proofs, auto-liquidação background, broLog |
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
