# 🛠️ GUIA DE OPERAÇÃO DO BRO — para qualquer agente (local ou remoto)

> Lê isto ANTES de tocar em qualquer coisa. É o mapa de operação segura.
> Sem detalhes de incidentes com nomes/valores (regra de privacidade 15/11).

## O que é o Bro

App Flutter (Android/iOS) de pagamento de contas Pix com bitcoin via Lightning,
P2P sobre Nostr. Usuário deposita sats → provedor ("Bro") paga a conta Pix dele
→ usuário confirma → provedor recebe os sats. Taxa: 3% provedor + 2% plataforma.

## Arquitetura em 1 minuto

- **Nostr = a verdade e o dinheiro.** Ordens/aceites/comprovantes/completes vivem
  nos relays. Se não tá no relay, não aconteceu.
- **Servidor (bro-api, Fly.io) = cache + acelerador + watchtower.** Nunca detém
  verdade nem custódia de fluxo de ordem. Caiu = app fica lento, não quebrado.
- **BRIX (brix.brostr.app, Fly separado) = LNURL/carteira servidor** (Spark SDK
  server-side) pra pagamentos com app offline. NUNCA LNbits (proibido).
- **Watchtower** (backend/services/nostrWatchtowerService.js) vigia os relays,
  decide o canônico de corridas (/canonical/:orderId) e dispara pushes FCM.

## Kinds Nostr (o protocolo da casa)

| Kind | O quê | Tag chave |
|---|---|---|
| 30078 | ordem (replaceable) | #d=orderId |
| 30079 | aceite | #d={orderId}_accept |
| 30080 | updates + billcode NIP-44 | #d={orderId}_{autor8}_update / _billcode |
| 30081 | complete + invoice_refresh | #d={orderId}_complete / _invoice_refresh |
| 1 | disputas/mediação | #r=orderId, #t=bro-disputa/bro-resolucao |

⚠️ Eventos 30080/30081 são **substituíveis** — o relay guarda só a ÚLTIMA
escrita por #d. "Não achei no relay" ≠ "nunca existiu" — entregas antigas somem.
⚠️ Eventos podem sair com **#p vazio** quando a ordem veio do snapshot da API
(userPubkey omitido por privacidade) → TODA leitura usa #d, nunca só #p.

## Regras de OURO (ordem de prioridade)

1. **Dinheiro 100% Nostr, e prova antes de pagar.** Nenhum pagamento sem prova
   decodificável no relay (guard v727). Na dúvida, NÃO paga.
2. **Evidência primeiro:** qualquer afirmação sobre dinheiro/estado precisa de
   evento+timestamp de relay ou log de produção. Nunca "deve ter".
3. **Privacidade:** nunca nomes de pessoas (nem a fundadora) em código/commits/
   docs. Incidente = orderId + data + papel.
4. **Sem botões novos** sem autorização explícita da dona do produto.
5. **Edição cirúrgica** com âncoras; nunca rewrite de arquivo inteiro.
6. **Revisão dupla:** quem escreve não aprova sozinho.

## Branches e publicação

- `main` = produção. **Nada entra sem a dona mandar.**
- `test/*` = builds internos (Codemagic dispara no push, canal interno).
- `feature/*` = PROIBIDO push (Codemagic dispara; HODL Vault mora local).
- Remotes: origin=Quizzicarol/Bro, brostr=Brostr/bro, bro-app=Quizzicarol/bro-app.
  Push sempre nos 3 + verificar com `git ls-remote` (PowerShell engole saída).
- Versão de marketing congelada: **1.0.134** — só build number (+NNN) sobe.

## Comandos de operação

```powershell
# Build Android release + instalar no USB
flutter build apk --release --dart-define-from-file=env.json
& "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" install -r build\app\outputs\flutter-apk\app-release.apk

# Testes (gate obrigatório antes de qualquer push)
flutter test test/race test/integration

# Logs do aparelho USB
& "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" logcat -d -s flutter

# Backend bro-api (deploy manual; do dir backend/)
cmd /c "flyctl deploy -a bro-api > %TEMP%\dep.txt 2>&1"   # via cmd, NÃO PowerShell puro

# Backend BRIX (dir do repo brix clonado à parte)
flyctl deploy -a brix
```

## Probe de relay (forense de ordens)

Padrão: Python + websockets, filtro por #d-prefixo do orderId, kinds
30078/30079/30080/30081, janela de dias, relays bro-relay2.fly.dev +
apexcord.duckdns.org + relay.primal.net. Relays morrem **por rede** (um morto
pra ti pode estar vivo pra outro) — nunca concluir "relay morto" de 1 máquina.
Fuso: relay = UTC; BRT = UTC-3.

## O que NUNCA fazer

- LNbits (proibido explicitamente, tentado e falhou 5×)
- Push de feature/* 
- Mudar versão de marketing
- Re-publicar resolução de disputa velha (dispara autopay retroativo!)
- Confiar em probe de uma máquina pra cortar relay da lista
- Commitar google-services.json / env.json / chaves
- Reescrever histórico público do git

## Referências vivas

- Roadmap: docs/internal/ROADMAP_NOV2026.md
- Handoffs: docs/internal/HANDOFF_COMPLEMENTO_16NOV.md (+ o do outro agente)
- Mapa do dinheiro: docs/internal/MAPA_FLUXO_DINHEIRO.md
- Skills operacionais: .github/skills/ (nostr, nostr-relay-sync, fcm-push,
  dispute-resolution, app-performance)
