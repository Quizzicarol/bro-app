# Roadmap R3 + Performance + Certificação — novembro 2026

Data: 19/11/2026
Regras da casa (inalteradas): cada trilha em seu próprio branch `test/*`;
double review nos dois sentidos; `main` só depois de validação no aparelho
pela dona; nunca `feature/*` (o Codemagic builda); versão de marketing
congelada; rollback tag antes de cada merge.

## Estado dos branches

| Branch | Conteúdo | Estado |
|---|---|---|
| `main` | 822 = pacote v820 (bugfix puro) | produção/testers externos |
| `test/v816` | R3 (expiração de aceite) sobre base 822 + knob de teste | substituído pela integração abaixo |
| `test/v823` | certificação de entrega (preimage + recibo + verificador) | em teste no USB (825) |
| `test/perf-ui` | cache da Home e reconciliação única | publicado em `a985eb1` |
| `test/perf-sync` | sync coalescido, fases e proof-fetch limitado | publicado em `3252f16` |
| `test/r3-perf-integration` | R3 + PERF + expiração/republicação | `ca4ddbd` + reparo do limbo local em validação |

## Trilha 1 — Certificação de entrega (v823) — MAIS CURTA

1. Dona refaz o teste ponta-a-ponta no USB (825): ordem nova, fluxo completo.
2. `node scripts/verify_delivery.mjs <orderId>` tem que dar **DELIVERED**.
3. DELIVERED → merge pro main (só essa trilha) + build 826 + tag de rollback.
4. Sem DELIVERED → eu mergulho de novo antes de qualquer merge.

Responsável: eu (integrador/forense). Revisor: outro agente (já aprovou o
mecanismo; revisar só o follow-up das fendas).

## Trilha 2 — R3 (expiração de aceite 1h)

**Regra obrigatória:** produção e os próximos testes usam **60 minutos**. O
ciclo de 2 minutos foi rejeitado pela dona e não deve ser repetido.

Comportamento implementado na integração:

- Aviso ao provedor sobre o prazo de 1 hora e lembretes em 20/40 minutos,
  com deduplicação.
- Após `accept_expired`, o billcode é bloqueado. O provedor **não pode mais
  enviar comprovante nem abrir disputa**; comprovante tardio não recupera a
  ordem nem alimenta mediação.
- O comprador vê **Aceite expirado** e pode republicar ou cancelar/sacar,
  tanto na lista quanto nos detalhes da ordem.
- O aviso junto ao billcode informa os minutos restantes em vermelho; as
  telas educacionais explicam o prazo de 1 hora e a nova disponibilização.
- Lembretes ao provedor em 20/40 minutos e notificação de expiração para
  comprador e provedor, inclusive em background/watchtower.
- `completed` e `cancelled` permanecem terminais; eventos posteriores sem
  prova não podem apagar a prova, a invoice ou regredir o estado.

Evidências:

- Recuperação da ordem real `4e2c858a` e confirmação manual pela dona.
- Regressão da sequência completa em `r3_update_selection_test.dart`:
  `accept_expired` → complete canônico → `completed` sem prova →
  `awaiting_confirmation` sem prova, nas duas ordens de chegada.
- O teste detectou e a correção passou a preservar `providerInvoice` quando
  `completed` sem prova chega antes do complete canônico.
- Gate focado após a correção: **31/31 testes**.
- Revisão independente encontrou quatro problemas, todos corrigidos e cobertos:
  limpeza explícita de `providerId`/`acceptedAt` na nova rodada; aceite
  canônico por `acceptedAt` imutável com clamp de relógio e desempate;
  preservação do `completedAt` da prova; e `cancelled → disputed` somente
  quando mais recente.
- Gate focado após essas correções e o bloqueio de disputa antiga sobre
  cancelamento mais recente: **36/36 testes**; suíte `test/race` final:
  **121/121 testes**. Revisão independente final: sem novos achados.
- APK final com janela de 60 minutos instalado no USB com dados preservados
  em 22/11/2026, `1.0.134+827`.
- Revisão funcional da dona em 23/11/2026: aviso junto ao billcode corrigido;
  regra de expiração alterada para encerrar o aceite sem recuperação tardia.
  Gate focado **39/39** e suíte `test/race` **124/124**.

Reparo funcional solicitado em 23/11/2026 após inspeção do USB:

- A ordem `876115f4` tinha `accept_expired` no relay, mas o cache local ficou
  em `pending`; a tela mostrava **Aguardando Bro** e escondia as ações.
- Recuperar esse cache exige aceite antigo (>1h), mesmo provedor e nenhuma
  prova. O comprador passa a ver **Aguardando republicação**, com
  **Republicar ordem** acima de **Cancelar e sacar**.
- A republicação grava `republishedAt`, publica `pending` no kind 30080,
  limpa `providerId`/`acceptedAt`, remove a ordem da blocklist local e impede
  que a expiração/aceite antigos contaminem a nova rodada. Prova anterior à
  expiração continua protegida e não pode ser apagada pela republicação.
- O watchtower precisa aplicar a mesma rodada no snapshot: `accept_expired`
  fecha a rodada; `pending` com `republishedAt` abre outra e limpa o aceite
  canônico anterior. Não basta corrigir somente a UI.
- Em 23/11, o teste real confirmou que o aceite antigo era reutilizado pelo
  sync, snapshot, histórico, auto-repair e migração de billcode. Foram
  adicionados guards nesses caminhos e no ponto comum do Nostr. A Home passou
  a traduzir `accept_expired` como **Aguardando republicação**.
- **Deploy pendente:** `backend-deploy-flyio` só escuta `main`/`master`, não
  a branch de teste. O deploy manual autorizado foi tentado, mas o Fly
  respondeu `unauthorized` para `bro-api`. É necessário usar uma credencial
  autorizada ou publicar somente após a revisão/merge aprovado pela dona.
  Não declarar o watchtower como implantado antes disso.
- **Regressão 90800cdf contida na 838:** uma ordem nova de 4 minutos foi
  marcada como expirada e recebeu notificações contraditórias. A recuperação
  de instalações antigas agora exige `republishedAt` da mesma rodada, mesmo
  provedor, aceite >1h e ausência de prova. Ordem sem esse marco nunca entra
  na recuperação. O aviso visual ignora `acceptedAt` anterior à republicação;
  o novo aceite usa timestamp >= `republishedAt`, atualiza provedor/acceptedAt
  e limpa `lostRace`. Testes específicos incluídos; suíte race **136/136**.

Pendências antes de publicar/mergear:

1. Confirmação final da revisão independente e suíte completa. O smoke test
   `widget_test.dart` tem timeout preexistente também em `96c140a`, não
   introduzido por esta trilha.
2. Validar no aparelho a janela real de 60 minutos, lembretes, bloqueio do
   billcode, filtro de aceites antigos e republicação apenas sem prova.
3. Implantar o roteamento `accept_expired` do watchtower após revisão.
4. Não declarar recebimento Lightning de `4e2c858a` sem payment hash,
   preimage ou recibo correspondente. A confirmação manual e `proof=true`
   comprovam a recuperação do fluxo, não a liquidação.
5. BRIX claim/fee e a taxa de ordem seguem no pacote prioritário abaixo; não
   foram implementados neste reparo de expiração.

## Pacote prioritário seguinte — BRIX e taxa de ordem

Estes itens entram no roadmap dos agentes para implementação junto com as
correções priorizadas pela dona, com revisão independente e sem misturar
pagamentos ao teste de expiração:

1. **Transparência do resgate BRIX (app):** no momento do resgate, mostrar
   `bruto − taxa = líquido`, usando `gross_amount_sats`, `fee_sats` e o
   `amount_sats` líquido já entregues pelo endpoint. O valor exibido deve ser
   exatamente o valor esperado no claim.
2. **Histórico da carteira BRIX:** entrada “BRIX recebido +líquido (taxa X
   sats)” e linha de taxa no detalhe da transação. Preservar o bruto e a taxa
   como evidência, sem apresentar o líquido como se fosse o bruto.
3. **Taxa de ordem — fenda AutoPay/Main:** corrigir a fenda ainda aberta no
   `main`, aplicando a correção curta já repassada pela dona ao agente
   responsável. O diff exato de seis linhas não está neste worktree; o agente
   deve recuperá-lo da conversa original e anexá-lo à revisão, sem inventar
   uma variante. Testar o caminho “already paid” para comprovar que a taxa da
   plataforma é enviada uma única vez e que nenhum novo pagamento é disparado
   em duplicidade.
4. **Base BRIX já especificada:** manter `PROMPT_BRIX_CLAIM_FEE.md` como
   referência local para claim-quote, desconto da taxa e `needs_funding`; o
   arquivo é intencionalmente ignorado pelo Git e não deve ser commitado.

Critérios de aceite: testes de apresentação bruto/taxa/líquido, histórico e
compatibilidade; teste da taxa de ordem com evidência de invoice/hash e
idempotência; double review antes de qualquer merge.

QA/execução de testes: **Nemotron 3.5 Lightning**. Revisão de corrida/estado:
**Nemotron 3 Ultra**. Decisão de merge: dona + assento do integrador.

## Trilha 3 — PERF-UI (celular esquentando)

Escopo restrito (do relatório PERF-UI de 18/11): Home sem `listPayments()`
no build + cache; reconciliação única de carteira; proteção de concorrência.
**Não tocar OrderProvider nem serviços Nostr** nessa trilha.

- Implementação (só `main.dart`, `home_screen.dart`, `breez_provider.dart`
  + testes focados): **Kimi K3.1 Pro**
- Revisão de concorrência/listeners/ciclo de vida: **Nemotron 3 Ultra**
- Testes/métricas (CPU/jank antes×depois): **Nemotron 3.5 Lightning**
- Revisão final de arquitetura/invariantes: **GPT-5.4 Pro**

Sequência: baseline (profile no aparelho) → PERF-UI-1 (Home cache) →
PERF-UI-2 (reconciliação única) → validação isolada → integração.

## Trilha 3.5 — Latência do billcode (queixa da dona, 19/11)

Sintoma real: a notificação chega rápido, mas o billcode demora ~8 minutos
pra chegar ao provedor. 8 min é tempo de suporte e ansiedade de usuário.

Investigação inicial (assento do integrador): o fast-lane v750 existe
(`_scheduleBillCodeFastLane`) — medir onde os 8min moram: (a) o comprador
demora pra perceber o aceite? (b) o provedor demora pra baixar o billcode
(seu próximo poll/sync)? (c) o push billcode_ready (v742) não dispara ou
cai? Suspeita principal: o provedor só busca o billcode no próximo ciclo
de sync dele (timer), não no push. Alvo: billcode na mão do provedor em
<30s. Dono: assento do integrador (encosta na máquina de estados).
Revisão: **Nemotron 3 Ultra**. Medição: **Nemotron 3.5 Lightning**.

## Trilha 4 (depois) — PERF-SYNC

Coalescência de sync, backoff, republicações redundantes. Proposta: **GLM-5.3**.
Revisão (encosta em dinheiro): **GPT-5.4 Pro**. Execução de testes:
**Nemotron 3.5 Lightning**.

## Sucessão do assento do integrador (Kimi K3 aposentando)

O trabalho deste assento é: forense de relay/carteira, revisão de caminhos
de dinheiro, merges, deploys, disciplina de evidência. Substituição indicada:
**GPT-5.4 Pro**. (Implementação de features continua no Kimi K3.1 Pro; a
dupla revisão entre os dois assentos se mantém.)

## Ordem de merges pro main

1. v823 (certificação) — assim que o teste der DELIVERED.
2. R3 — quando a dona terminar os testes curto + longo.
3. PERF-UI — depois de validado isolado.
4. PERF-SYNC — por último.

Antes de cada merge: suíte completa verde + double review + tag de rollback.
