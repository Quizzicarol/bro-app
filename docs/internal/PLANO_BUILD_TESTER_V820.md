# Plano — Build de teste v820 "só bugfix" (SEM R3)

Data: 17/11/2026
Regra da casa: o build de tester v820 **não inclui** o R3 (expiração de aceite de 1h
+ republicação). R3 segue isolado em `test/v816` para teste dedicado e demorado.
Também ficam fora v819/v819b (filtros de aceite pré-republicação), porque a
semântica deles só faz sentido acoplada ao R3 — testar junto com o R3, não antes.

## Branch

- `test/v820` nasce de `main` (33f5f60).
- Cherry-pick do **v818** (proof_ready — backend já deployado; lado app só trata o
  push novo). Latência de comprovante cai de ~25s para ~2s — ataca direto a
  fila de suporte "travado esperando comprovante".
- `test/v816` continua existindo para o teste isolado do R3.
- ATENÇÃO: o APK instalado no aparelho USB em 17/11 era do `test/v816`
  (contém R3). O próximo build interno deve vir do `test/v820`.

## Os 5 matadores de suporte (escopo cirúrgico, zero mudança de protocolo)

### v820a — v696 cego a prova plaintext ✅ prioridade máxima
- Sintoma real (ordem 27c916e7, 17/11): comprovante no relay, usuário no build
  817, app nunca mostra; única ordem do usuário que não destravou.
- Causa: `fetchProofFromRelay` descarta eventos sem `proofImage_nip44`. Quando o
  provedor completou uma ordem API-sourced (userPubkey=''), o NIP-44 falha e a
  prova sai em `proofImage` plaintext — o buscador de último recurso fica cego.
- Fix: aceitar `proofImage` plaintext quando `proofImage_nip44` ausente (a tela
  já renderiza plaintext — só o fetcher filtra).
- Risco: baixíssimo. Teste: repro forense com o evento real da 27c916e7.

### v820b — provedor resolve userPubkey do 30078 antes de completar
- Sintoma real: provas saindo em PLAINTEXT em relay público (privacidade) e
  caindo na fenda do v696.
- Causa: ordem vinda do snapshot API (R5b) chega com `userPubkey=''` → NIP-44
  para '' falha → fallback plaintext.
- Fix: antes de publicar o complete, se `order.userPubkey` vazio → buscar o
  30078 da ordem no relay e extrair o userPubkey do content; cifrar normal.
  Se mesmo assim não achar: mantém o comportamento atual (não bloquear
  pagamentos por causa de relay).
- Risco: baixo. Teste: complete de ordem API-sourced sai com proofImage_nip44.

### v820c — sync aplica updates por fase (fim do "botão travado")
- Sintoma real (27c916e7, disputa aberta pelo usuário 17/11): botão de
  confirmação nunca aparece porque o passe de sync é tudo-ou-nada e leva
  13-60s+ (scans largos de 500 eventos + relays mortos + ordens gigantes do
  usuário). Passe interrompido = nada aplicado = status congelado.
- Fix: aplicar os resultados de `fetchOrderUpdatesForUser` (fase mirada, ~8s,
  carrega aceites/completes) MESMO se a fase pesada (`fetchUserOrders` +
  broad scan) ainda não terminou — ou inverter a ordem das fases.
- Risco: médio (mexe no coração do sync). Mitigação: testes de regressão nos
  89 atuais + repro forense de ponta a ponta.

### v820d — perdedor de corrida para de agir
- Sintoma real (98bc3e84, 17/11): o perdedor (fe533154) publicou
  invoice_refresh 1h40 DEPOIS de perder a corrida — ruído que confunde
  provedores e suporte.
- Fix: lado provedor — se a corrida já foi decidida contra mim
  (canonical ≠ eu), não publicar invoice_refresh nem re-tentar fluxo.
- Risco: baixo. Teste: loser não publica refresh após race_lost.

### v820e — "completed sem pagamento" (falso-positivo do guarda)
- Sintoma real (98bc3e84): ordem marcada completed às 21:21:45, provedor
  canônico jura que os 41.998 sats não chegaram.
- Hipótese forte: caminho `_forceCompletedNoPayment` (guarda anti-double-pay
  ou detecção "already paid" por string) finaliza a ordem sem verificar que
  um ENVIO LIQUIDADO existe no histórico da carteira.
- Fix: antes de `_forceCompletedNoPayment`, exigir evidência de envio
  settled (paymentHash no histórico com status complete). Sem evidência →
  manter awaiting_confirmation e deixar o fluxo seguir (sem botões novos —
  só não avançar).
- Risco: médio (caminho de dinheiro). Teste: simular guarda populada sem
  pagamento real → ordem NÃO pode completar.

## Fica de fora (congelado até a dona mandar)

- R3 (expiração de aceite 1h) + v819/v819b → só `test/v816`, teste demorado.
- R4 (admin overhaul). HODL Vault (branch local, nunca push).
- Qualquer mudança de versão de marketing (1.0.134 congelada).

## Critério de saída do v820

- 89/89 testes + novos testes dos 5 itens verdes.
- Build interno → aparelho de teste → os 2 casos reais de 17/11 simulados:
  prova plaintext aparece; ordem não completa sem envio settled.
- Só depois: proposta de merge pra main (decisão dela).
