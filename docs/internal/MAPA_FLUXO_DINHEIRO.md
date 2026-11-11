"# MAPA DE FLUXO DE DINHEIRO - BRO

> Re-emissao limpa (10/11/2026) a partir do codigo real. Fonte: leitura de `lib/` nesta sessao + `git log v764-v783`. Documento anterior deletado (contaminado desde o nascimento).
>
> **Escopo**: todo sat que entra, sai ou e prometido dentro do app + no edge BRIX. Fora de escopo: HODL Vault (branch `feature/hodl-collateral`, nao mergeado) e motor Spark interno.
>
> **Como ler**: cada corredor lista Entrada -> Custodia -> Saida, gates de seguranca com referencia a commit, e incidentes reais do historico.

---

## Arquitetura dos corredores (visao de 30.000 pes)

```
COMPRADOR (tem R$ a pagar)             PROVEDOR/BRO (tem sats)              PLATAFORMA
       |                                       |                              |
  1 Paga sats em LN                        5 Recebe invoice               7 Taxa plataforma
       |   (base + 5%)                         | (base + 3%)                      | (2% do base)
       |                                       |                              |
       +----------> 2 ORDEM 30078 <------------+                              |
                     | (Nostr, c/ billCode NIP-44)                            |
                     |                                       6 Accept 30082 -+
                     |
              3 PROVA (30081, NIP-44) <---------+
                     | (imagem + e2eId)         | 4 Coordenador recebe taxa
                     |                          |    (LN address, allowlist)
                     v
              Autopay dispara ------> 5 paga invoice do provedor
                     |
              6 Comprador confirma (30080) -> status 'completed'
```

- `1` deposito do comprador (wallet Breez Spark, custodia local).
- `2` ordem publicada no Nostr (kind 30078) = promessa, nao fluxo de dinheiro ainda.
- `3` prova anexada (kind 30080/30081, NIP-44) = gatilho para autopay.
- `4` taxa da plataforma roteada ao coordinator (hoje: Apex Cord, allowlistada).
- `5` autopay paga invoice do provedor (LN, via Breez).
- `6` confirmacao fecha o loop.

---

## Corredor 0 - Identidade / Nostr (o terreno onde o dinheiro se move)

**Nao move dinheiro, mas decide quem pode mover.**

| Elemento | Detalhe real (codigo) |
|---|---|
| Chave privada | `lib/services/secure_storage_service.dart` (`nostr_private_key`), Secure Storage |
| Pubkey | identifica usuario; toda ordem tem `userPubkey` (criador) e `providerId` (aceitador) |
| Relays hoje | `lib/services/relay_service.dart` L20-31: damus.io, nostr.band, nos.lol, snort.social, nostr.wine, primal.net + 2 premium |
| Auth com edge | NIP-98 (kind 27235) - ver `brix/server/middleware/nip98.js` (v782 last_seen) |
| Coordinator announce | kind 30082, assinatura verificada - **mas assinatura != identidade** (v781-H3) |

**Gate critico**: `_fixCorruptedUserPubkeys` (order_provider.dart L3180) impede que ordem importada de outro usuario corrompa a lista local. Toda ordem em `_orders` deve satisfazer `order.userPubkey == currentUserPubkey || order.providerId == currentUserPubkey` (filtro `_saveOnlyUserOrders` L1091).

**Falha conhecida**: v773/v774 - `_fetchProviderOrdersRaw` sem prova de posse canonica permitia perdedor de corrida ver ordem como dele. Fix v773 exige prova antes de marcar.

---

## Corredor 1 - Deposito de sats (COMPRADOR carrega a wallet)

**Dinheiro entra no app pela wallet Breez Spark (Lightning, custodiada no dispositivo).**

| Etapa | Arquivo real | O que acontece |
|---|---|---|
| 1. Invoice | `lib/providers/breez_provider.dart` L631 `createInvoice` | Cria invoice BOLT11 com valor em sats |
| 2. Recebimento | `breez_provider.dart` L896 `waitForPayment` + L4717 `reconcileOnStartup` | Quando pago, registra saldo; reconcilia com historico no boot |
| 3. Protecao tier | `lib/providers/collateral_provider.dart` L180 `depositCollateral` | Deposito pode atualizar tier/limite - **nao autoriza ordem sozinho** |
| 4. Reconciliacao | `breez_provider.dart` L503 `_persistBrixPaymentLocally` / L512 `_persistPayment` | Pagamentos BRIX recebidos sao persistidos e reconciliados |

**Gate critico**: `reconcilePendingOrdersWithBreez` (L4642) e `reconcileOnStartup` (L4717) cruzam historico da wallet com ordens locais - descobrem pagamento feito fora do fluxo.

**Falha conhecida**: v622 - ordens >48h eram abandonadas como 'stale', provedor nunca recebia (order 9f3986a6). Corrigido removendo corte por idade.

---

## Corredor 2 - Ordem P2P (a promessa de pagamento)

**Quando o comprador cria ordem, ja pagou o invoice Lightning. A ordem e so a *promessa* de que alguem pague o boleto/Pix no mundo real.**

| Etapa | Arquivo real | O que acontece |
|---|---|---|
| 1. Criacao | `order_provider.dart` L1246 `createOrder` | Valida `amount > 0` e `btcAmount > 0`; calcula `providerFee = amount * 3%` e `platformFee = amount * 2%`; grava `coordinatorPubkey` no metadata |
| 2. Salva local primeiro | `createOrder` L1327 | `_orders.insert(0, order); await _saveOrders();` - se Nostr falhar, nao perde (fix v554) |
| 3. Publica | `_publishOrderToNostr` L4847 | Publica kind 30078 com timeout 10s; se falhar, `republishLocalOrdersToNostr` cuida no proximo sync |
| 4. Cancelamento orfao | `_publishOrphanCancel` L1381 | Se a publicacao falhar mas a ordem existir local, publica cancel para nao ver duplicata |
| 5. Validacao | `createOrder` L1273-1284 | Rejeita `amount <= 0` ou `btcAmount <= 0`; bloqueia se houver `_hasUnpaidMediationCharge` (v709) |

**Gate de corrida** (v709): `_hasUnpaidMediationCharge` bloqueia createOrder ate quitar - caso e94caad7 recebeu 22.920 sats indevidos e operou 8 dias.

**Falha conhecida**: v764/v765 - `_fixIncorrectlyPaidOrders` aposentada; revertia `payment_received` -> `pending` e republicava 30078 como ordem nova (zumbi). 7b7542f8/0ebdebc7 mostram ordem completa voltando aceitavel.

---

## Corredor 3 - Prova e Autopay (o gatilho do dinheiro)

**O Bro paga o boleto/Pix no mundo real e posta comprovante. O app do comprador ve a prova e dispara o pagamento dos sats. Corredor mais atacado.**

| Etapa | Arquivo real | O que acontece |
|---|---|---|
| 1. Accept | `order_provider.dart` L2042 `acceptOrder` + L2108 `_sendEncryptedBillCodeForAcceptedOrders` | Bro aceita (kind 30079); billCode NIP-44 criptografado |
| 2. Prova | `order_provider.dart` L3032 `completeOrderAsProvider` | Publica kind 30081 com `proofImage`, `e2eId`, `providerInvoice` |
| 3. Gatilho autopay | `order_provider.dart` L3749 `_autoPayLiquidatedOrders` | Verifica guardrails antes de chamar `onAutoPayLiquidation` |
| 4. Gate prova | `order_provider.dart` L3789 | v727: `hasProof` **obrigatorio** - invoice sozinha NAO autoriza (43b789c7) |
| 5. Conflito provas | `nostr_order_service.dart` `fetchProofFromRelay` -> v781-H1 | Se 2+ pubkeys distintas enviaram prova, retorna campo `conflict`; `main.dart` autopay **recusa** |
| 6. Pagamento | `main.dart` L~805 | v773: fail-closed, excecao nao autoriza fallback |
| 7. Marcacao | `order_provider.dart` L3861 | `autoPaymentCompleted: true` + timestamp |

**Cadeia de guardrails (ordem real no codigo):**
1. `_isAutoPayingLiquidations` - mutex em memoria
2. `currentUserPubkey` vazio -> return
3. `providerId == currentUserPubkey` -> skip (nunca me pago - v770/v771)
4. `autoPaymentCompleted == true` -> skip (idempotencia)
5. Status in {liquidated, completed, awaiting_confirmation} - v584 ampliacao
6. Sem prova (`proofImage`/`paymentProof`/`proofImage_nip44`) -> skip para status != 'liquidated'
7. v781-H1: prova conflitante (2+ pubkeys) -> recusa total
8. v773: excecao na guarda de corrida -> fail-closed
9. Invoice expirado -> pula silenciosamente (v622)

**Falhas reais (documentadas com orderId no codigo):**
- v766 (0ebdebc7): autopay pagou 3866 sats, re-confirmar cobraria 2a vez -> fix: checa historico wallet
- v770 (7b7542f8): providerId corrompido fez compradora auto-pagar a si mesma -> fix: nunca aceitar a propria ordem
- v767/v768: invoice_refresh self-assinado envenenava completer -> fix: ignora eventos do proprio comprador
- v773 (55e37a9e): guarda de corrida fail-open -> fix: fail-closed com desempate via watchtower

---

## Corredor 4 - Lightning send (sat real saindo)

**Unico arquivo que toca o motor Spark: `lib/providers/breez_provider.dart`.**

| Etapa | Linha | O que acontece |
|---|---|---|
| Decode BOLT11 | L1147-1174 | Se LNURL/lightning-address, exige `amountSats` manual |
| Saldo check | L1195-1218 | `syncWallet()` + `effectiveBalance = balance + escrowCoverSats` |
| Prepare | L1232-1241 | `PrepareSendPaymentRequest`, timeout 30s |
| Send | L1249-1257 | `sendPayment`, timeout 60s (routing) |
| Payment hash | L1264-1268 | Extrai hash se `PaymentDetails_Lightning` |
| Callback | L1273-1276 | `onPaymentSent` -> reconcilia ordem |
| Retorno | L1286-1296 | `{success, payment:{id, amount, status, paymentHash}}` |

**Gate critico**: `escrowCoverSats` permite pagar invoice com escrow imobilizado - sem isso, liberacao de escrow falharia com 'saldo insuficiente' falso (escrow recem-recebido ainda nao sincronizado).

---

## Corredor 5 - Watchtower (autoridade canonica)

**Servidor bro-api (api.brostr.app) que decide quem e o aceitante canonico de uma ordem. O app consulta antes de revelar o billCode.**

| Endpoint / Job | Arquivo | Funcao |
|---|---|---|
| `GET /canonical/:orderId` | backend | Responde pubkey canonico |
| `GET /known/:orderId` | backend | True se ordem e conhecida |
| Aceites persistidos | v758b | SQLite (antes em memoria - zerava no deploy) |
| Heartbeat | v775c | 5min: relays + aceites + contadores |
| Republish clients | backend | Re-publica updates para clientes desconectados |

**Gate critico (v758)**: app consulta `/canonical` antes de revelar billCode. Caso 55e37a9e - fetch parcial escondeu aceite canonico, billCode foi ao perdedor.

**Clamp temporal (v775)**: `acceptedAt` e `created_at` com tolerancia de +5 min na ordenacao canonica. Caso 5cd0b7f7: relogio 1h atrasado virou canonico.

**Protecao NIP-09 (v775b)**: aceites de ordem em disputa nunca deletados.

**Protecao zumbi (v764/v765)**: ordem terminal conhecida nunca re-broadcasta.

---

## Corredor 6 - Taxa da plataforma (2% para o coordinator)

**A cada ordem completada, 2% do valor base vai para o Lightning Address do coordinator.**

| Etapa | Arquivo real | O que acontece |
|---|---|---|
| 1. Calculo | `createOrder` L1280 | `platformFee = amount * 0.02` |
| 2. Anuncio | `coordinator_service.dart` L172 `fetchCoordinatorCards` | Busca anuncios kind 30082 nos relays |
| 3. Allowlist | `lib/config.dart` L113-118 | `approvedCoordinatorPubkeys` - so a pubkey Apex pode rotear taxa (v781-H3) |
| 4. Resolve | `coordinator_service.dart` L98 `resolveForNewOrder` | Retorna `{pubkey, name, lnAddress}`; se nao homologado, cai no `platformLightningAddress` fixo |
| 5. Envio | `order_provider.dart` `_reconcilePlatformFees` L4221 | Lote mensal para o LN address do coordinator |

**Gate critico (v781-H3)**: allowlist impede que qualquer key anuncie 'bro-coordinator' com LN address proprio e receba as taxas da plataforma. Assinatura verificada no Nostr **NAO e identidade**.

**Atual coordinator homologado**: `1cbaf4c76fcb2906d989635ced23da7c0c25f0ad7e07d66b8510234f364560fe` (Apex Cord, unico valido em 18/12/2025).

---

## Corredor 7 - BRIX (edge de recebimento Lightning Address)

**Servidor separado (brix.brostr.app) que da Lightning Addresses `@brostr.app` aos usuarios. Sats recebidos aqui precisam de claim-push para acordar o app.**

| Componente | Arquivo real | O que faz |
|---|---|---|
| Recebimento | `brix/server/routes/brix.js` POST /lnurlp + webhook Spark | Recebe pagamento LN e coloca na fila |
| Claim | `lib/providers/breez_provider.dart` `_processUnclaimedDepositsFromEvent` L436 | Processa quando o app abre e verifica depositos pendentes |
| Push de claim | `brix/server/services/push.js` `sendClaimPush` | FCM data-only + `content-available: 1` para acordar o app em background |
| Gate de build | `brix/server/services/push.js` | v782: bloqueia push se `app_build < 587` (primeiro build com handler de claim) |
| Log de push | `brix/server/models/database.js` | v782: tabela `brix_claim_push_log` registra cada tentativa |
| Observabilidade | `brix/server/routes/brix.js` GET /admin/pending-support-report | v782: mostra pagamentos pendentes + last_seen + app_build + resultado do ultimo push |

**Falha conhecida**: smlbnr (10/11/2026) - 14.585 sats recebidos, 7 pushes aceitos pelo FCM, claim nunca disparou no app. Fix v782 = observabilidade + gate de build, sem reembolso manual (decisao Carol: o app nao paga sem prova no dispositivo).

**Deploy**: manual com `flyctl deploy -a brix` da pasta `brix/` (nao ha workflow automatico).

---

## Push (o nervo que acorda o app)

**Push data-only (FCM) e como ordens atrasadas e claims BRIX acordam o app em background. Sem push, uma ordem completa pode ficar invisivel por ate 45s (timer de sync normal).**

| Push | Arquivo real | Conteudo |
|---|---|---|
| new_order | backend `pushService.js` | Dados: `{type: 'new_order', orderId}`; v780-app: provider atualiza lista na hora |
| payment_proof | backend | Provider postou comprovante |
| claim | `brix/server/services/push.js` | Dados: `{type: 'claim', paymentId}`; v782 grava log |

**v780-app**: push de new_order agora dispara fetch instantaneo no Modo Bro (antes so sync do comprador rodava; provedor esperava timer de 45s+).

---

## Matriz de risco atual (pos-v783)

| Risco | Severidade | Mitigacao ativa | Gap restante |
|---|---|---|---|
| Ordem zumbi republicada | Critico | v764/v765: `_fixIncorrectlyPaidOrders` aposentada | Nenhum conhecido |
| Perdedor de corrida ve ordem como dele | Critico | v773/v774: prova de posse canonica | Fetch de 30078 no push new_order ainda nao implementado (residual) |
| Self-payment | Critico | v770/v771: recusa userPubkey == providerId | Nenhum conhecido |
| Coordinator MITM | Critico | v781-H3: allowlist + fallback endereco fixo | Nenhum conhecido |
| Prova conflitante | Alto | v781-H1: recusa autopay + marca `conflict` | Sem UI de mediacao para humano revisar (pendente Carol) |
| Claim-push perdido (BRIX) | Alto | v782: gate de build + log + admin report | Usuario precisa abrir app 1x com build >= 587 para registrar app_build |
| Relogio desviado vira canonico | Alto | v775: clamp +-5min | Nenhum conhecido |
| Aceite deletado em disputa | Medio | v775b: NIP-09 nunca em disputa | Nenhum conhecido |
| Dependencias backend | Medio | v780: axios, body-parser, express-rate-limit bumped | 12 moderadas em firebase-admin/node-cron/uuid (major bumps pendentes) |
| Seed inheritance (V2) | Alto | A3 design pronto no Docs | Implementacao pendente (dialogo de usuario) |
| HODL Vault | - | design completo | Branch `feature/hodl-collateral` nao mergeado |

---

## O que este mapa NAO cobre (explicito)

- **HODL Vault**: branch separada, nao mergeada. Quando for, o Corredor 6 ganha um sub-fluxo de escrow em Bitcoin.
- **BRIX interno**: motor Spark da BRIX e terceirizado e tem sua propria superficie. Este mapa cobre so a fronteira app-BRIX.
- **Fiat real**: Pix e boleto existem fora da cadeia; o app so ve comprovante.
- **Testes**: a suite `test/race/` (24 testes) valida os gates deste mapa, mas nao e o objeto deste documento.

*Ultima verificacao do codigo: 10/11/2026, commits ate v783.*"