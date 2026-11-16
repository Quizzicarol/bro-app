# COMPLEMENTO ao HANDOFF_v813 (16/11) — o que faltou + correções

> Lê DEPOIS do HANDOFF_v813_2026-11-16.md do outro agente. Aqui está o que ele
> escreveu errado ou não cobriu, com evidência de relay.

## Correções ao handoff dele

1. **1d6f7b53 NÃO está "aguardando mediação"** — foi RESOLVIDA (resolved_user)
   em 16/11 16:51 UTC (13:51 BRT), evento `b0d64220` assinado pela mediadora.
   Prova: relay kind 1 `bro_dispute_resolution`. No admin ela mora na aba
   **Resolvidas** — se "não aparece", é cache velho (admin_disputes_cache_v2):
   pull-to-refresh / reabrir a tela.

2. **A disputa fantasma de outubro é 2706f28d (16/10), não af95b3ab.**
   Mecanismo provado: foi resolvida na época, mas a marca vivia só no storage
   local → reinstall do aparelho apagou as marcas → o kind 1 antigo (sem
   expiração) ressurge como aberta. **Fix raiz (R4): resoluções precisam viver
   no backend** (watchtower v801 já registra terminal das resoluções NOVAS;
   as antigas precisam de backfill ou re-resolução pontual).
   **Ação pontual:** re-resolver 2706f28d uma vez no aparelho atual (fecha de
   vez + o watchtower aprende o terminal via o evento novo).

## O que EU (Copilot) fiz que não está no relatório dele

### v814 — gate da corrida na TELA (commit c88a626, main + test/v814)
Regra da Carol: "só entra na tela de billcode quem ganhou; indeciso fica na
tela de corrida até sair o resultado". Antes o gate v804 era ASYNC — o
perdedor via a tela de billcode ~4s e o popup de perda chegava depois
(flagrante no logcat do USB, ordem ccfcdc52, 16/11 20:04).
- `provider_order_detail_screen.dart`: corrida indecisa → a área de billcode
  NEM RENDERIZA; mostra card "apurando" (string `prov_det_race_checking`
  já existente, pt/en/es).
- Fail-open só após 3 tentativas sem dados (~12-20s) — rede ruim não trava o
  vencedor legítimo.
- **Testado pela Carol no aparelho: passou** ("ficou o aviso de apurando").

### Forense da prova corrompida (ordem 210fdecd, 16/11)
O comprovante do provedor (build iOS ANTIGA 2000000153) chegou ao relay com
**24 bytes de lixo** — corrupção na origem (NIP-44 de build velha). A tela de
erro do R1 ("enviou por versão antiga — peça reenvio") segurou a exibição.
Não é bug novo: é usuário em build velha. **Ação de produto:** provedores com
build < 2000000153 precisam atualizar (forçar aviso de update? decisão Carol).

### Bug ABERTO — prova cruzada no iPhone (build interno 195)
Sintoma (Carol, 16/11 ~22:45): o detalhe da ordem 210fdecd mostrou PRIMEIRO o
comprovante de OUTRA ordem (cdbd6089 — ambas da mesma usuária), depois trocou
pela (corrompida) correta. Hipóteses ativas, em ordem:
1. Escrita cruzada no apply de updates quando 2 completes chegam juntos no
   mesmo sync (proofAccumulator/update map — revisar a montagem por orderId).
2. Navegação por notificação (v809C) abrindo a ordem errada (parse do payload).
Investigar com logcat quando reproduzir; travar com teste de 2 completes no
mesmo ciclo.

## Roadmap — continuação com o agente novo

Ordem atualizada (Carol decide como sempre):
1. **R3 — timeout do provedor: 1 HORA** (ela reduziu de 2h). Aceite expira sem
   comprovante em 1h → aceite cai + push + usuária escolhe republicar/cancelar
   (botões autorizados). Muita gente aceita e não paga — liquidez presa.
   Referência viva: ordem 1d6f7b53 (47h parada → disputa evitável).
2. **R4 — admin de verdade:** inclui "resoluções de disputa no backend"
   (durável, sobrevive a reinstall) + revisão painel a painel.
3. Prova cruzada (acima) — caçar quando reproduzir.
4. HODL Vault: congelado na branch local até Carol mandar.

## Lembretes novos da sessão (além dos do handoff dele)

- Relay morre POR REDE (damus 521 no Fly/PC, vivo no celular da Carol) →
  nunca mais tesoura na lista do app por probe de uma máquina.
- `git push`: PowerShell engole a saída — SEMPRE verificar com ls-remote.
- Identidade de pessoa se prova com o artefato (a imagem, o evento), nunca
  por horário/valor (erro meu, 15/11 — quase deu disputa pro lado errado).
- Fuso: relay é UTC; BRT = UTC-3. Sempre converter antes de acusar assinatura.
- Build interno = push em `test/*` (NUNCA `test/internal` se outro agente
  estiver no meio de um ciclo lá — colisão v812/v813, 16/11). Preferir
  `test/vNNN` numerado.
