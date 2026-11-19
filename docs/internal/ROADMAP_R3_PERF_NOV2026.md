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
| `test/v816` | R3 (expiração de aceite) sobre base 822 + knob de teste | em teste no USB (janela 2min) |
| `test/v823` | certificação de entrega (preimage + recibo + verificador) | em teste no USB (825) |
| `test/perf-ui` | (a criar) performance de UI | — |

## Trilha 1 — Certificação de entrega (v823) — MAIS CURTA

1. Dona refaz o teste ponta-a-ponta no USB (825): ordem nova, fluxo completo.
2. `node scripts/verify_delivery.mjs <orderId>` tem que dar **DELIVERED**.
3. DELIVERED → merge pro main (só essa trilha) + build 826 + tag de rollback.
4. Sem DELIVERED → eu mergulho de novo antes de qualquer merge.

Responsável: eu (integrador/forense). Revisor: outro agente (já aprovou o
mecanismo; revisar só o follow-up das fendas).

## Trilha 2 — R3 (expiração de aceite 1h)

1. Agora: ciclo curto no USB com a janela de 2min (knob). Quantas vezes a
   dona quiser — idempotência, republicação, cancelamento.
2. Depois: build com a janela real de 60min e o teste longo.
3. Revisão cruzada final → proposta de merge. Só entra no main quando a dona
   disser.

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
