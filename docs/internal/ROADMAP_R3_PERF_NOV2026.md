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
| `test/r3-perf-integration` | R3 + PERF + recuperação tardia | `96c140a` + alterações locais em validação |

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
5. BRIX claim/fee permanece em trilha separada (`test/brix-claim-fee`), com
   requisitos em `PROMPT_BRIX_CLAIM_FEE.md`; não foi implementado aqui.

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
