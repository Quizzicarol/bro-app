# 🚀 Checklist de Pré-Release para Testers Externos

**Versão:** 1.0.87+126  
**Data:** 31 de Janeiro de 2026  

---

## ✅ Bugs Corrigidos nesta Versão

### Críticos Resolvidos:
- [x] **Duplicação de ordens** no modo provedor - RESOLVIDO
- [x] **Ordens aparecendo em dispositivo errado** - RESOLVIDO (filtro por userPubkey)
- [x] **Falha na confirmação cross-device** - RESOLVIDO
- [x] **Auto-liquidação não funcionava** - RESOLVIDO (campo `receipt_submitted_at` corrigido)

### Melhorias de UX:
- [x] Botão de confirmação mostra loading visual
- [x] Validação de valores mínimo/máximo para ordens (R$ 0.01 - R$ 5.000)
- [x] Aviso ao aceitar ordem antiga (> 12h) - PIX pode ter expirado

---

## 🧪 Cenários de Teste Recomendados

### Fluxo Básico (Usuário)
1. [ ] Escanear código PIX válido
2. [ ] Verificar se valores e taxas estão corretos
3. [ ] Criar ordem e pagar invoice Lightning
4. [ ] Aguardar provedor aceitar
5. [ ] Ver comprovante enviado pelo provedor
6. [ ] Confirmar recebimento do pagamento

### Fluxo Básico (Provedor/Bro)
1. [ ] Ativar modo Bro
2. [ ] Ver lista de ordens disponíveis (sem duplicatas!)
3. [ ] Aceitar ordem
4. [ ] Realizar pagamento PIX
5. [ ] Enviar comprovante
6. [ ] Aguardar confirmação do usuário
7. [ ] Verificar ganhos após conclusão

### Cenários de Borda
1. [ ] Criar ordem com valor muito baixo (< R$ 0.01) - deve rejeitar
2. [ ] Criar ordem com valor muito alto (> R$ 5.000) - deve rejeitar
3. [ ] Aceitar ordem antiga (> 12h) - deve mostrar aviso
4. [ ] Fechar app durante operação - deve recuperar estado
5. [ ] Sem conexão com internet - deve mostrar erro amigável

### Multi-dispositivo
1. [ ] Ordem criada no Android NÃO aparece em "Minhas Ordens" do iOS
2. [ ] Ordem criada no Android APARECE em "Ordens Disponíveis" do iOS (modo Bro)
3. [ ] Confirmação no Android é recebida no iOS corretamente

---

## ⚠️ Limitações Conhecidas

### Comportamento Esperado:
1. **Ordens antigas sem userPubkey** são rejeitadas - isso é intencional
2. **Timeout de 24h** para auto-liquidação só funciona se o provedor enviou comprovante
3. **Comprovantes** são armazenados em texto claro no Nostr (limitação temporária)

### Problemas Conhecidos (não críticos):
1. Relay `nostr.wine` pode retornar HTTP 429 (rate limiting) - app tenta outros relays
2. Logs verbosos em produção - não afeta funcionalidade
3. Formato de moeda hardcoded como R$ - futuras versões terão localização

---

## 📱 Versões Mínimas

- **Android:** 5.0+ (API 21)
- **iOS:** 12.0+
- **Flutter:** 3.22.0

---

## 🔧 Configurações de Teste

### Modo Provedor (Bro):
- Em `lib/config.dart`: `providerTestMode = true` permite testar sem garantia
- Carteira deve ter saldo mínimo para receber Lightning

### Relays Usados:
- `wss://nos.lol` (principal)
- `wss://relay.damus.io`
- `wss://relay.primal.net`
- `wss://nostr.wine`

---

## 📝 Feedback para Testers

Ao reportar bugs, inclua:
1. Versão do app (Settings > Sobre)
2. Dispositivo e OS
3. Passos para reproduzir
4. Screenshots/vídeos se possível
5. Logs do console (se disponível)

**Canal de Feedback:** [Definir canal - Discord/Telegram/Email]

---

## 🔐 Segurança

- Nunca compartilhe sua seed phrase
- Use apenas satoshis de teste (valores pequenos)
- Não use dados bancários reais em testes públicos
- Reporte qualquer comportamento suspeito imediatamente
