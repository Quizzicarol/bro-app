# 🗓️ ROADMAP NOVEMBRO 2026 — Bro

> Dona do produto: Carol (decide escopo, ordem e liberação). Execução: agente externo (implementa + testa). Verificação: Copilot (revisão dupla + testes independentes). Aprovação final: Carol, depois de retestar.
> Regras vigentes: **zero botões novos sem permissão explícita**; evidência de relay/watchtower para qualquer afirmação sobre dinheiro; edições cirúrgicas; config em UTF-8; branch `feature/hodl-collateral` **nunca** sobe pros remotes.

Prazo: tudo entregue e aprovado até **30/nov**.

---

## R1 — Comprovante com tela preta (BUG, produção) 🥇
**Prioridade 1** — afeta disputa/mediação HOJE.

**Sintoma:** comprovante de alguns provedores abre como tela preta no app de quem recebe.

**Hipóteses a investigar (nessa ordem):**
1. Provedor em build antigo envia imagem > 65535 bytes de plaintext → o campo de tamanho do NIP-44 v2 (2 bytes) dá a volta → decriptação devolve imagem truncada → renderiza preto/quebrado. (A compressão `compressImageToBase64ForNip44` só existe no build novo — build velho manda bomba.)
2. Formato HEIC/HEIF (foto de iPhone) — `package:image` não decodifica → tela preta.
3. Falha silenciosa de decriptação caindo em widget sem estado de erro.

**O que fazer:**
- No lado do RECEBEDOR: detecção defensiva — se o base64 decriptado não decodifica como imagem, mostrar estado de erro legível ("comprovante ilegível — peça reenvio") **nunca tela preta**, com log (`broLog`) de formato+tamanho pra diagnóstico.
- No lado do REMETENTE: garantir que todo envio passa por `compressImageToBase64ForNip44` (v783 já faz nos pickers; verificar se existe algum outro caminho de envio que bypassa).
- Mensagem automática ao provedor quando a imagem chega corrompida (sem botão pro usuário — detecção e aviso automáticos).

**Critério de aceite:** comprovante corrompido/HEIC/gigante NUNCA renderiza tela preta; teste de widget cobrindo os 3 casos; log diagnóstico presente.

---

## R2 — Tier R$10 sem garantia: "Meus Primeiros Sats" 🥈
**Objetivo (Carol):** qualquer pessoa SEM bitcoin vira provedor no tier de R$10 — usa a liquidez fiat pra começar a acumular sats. Garantia passa a ser exigida só nos tiers maiores.

**O que fazer:**
- `provider_collateral_screen.dart` + lógica de tier: tier-1 (R$10) com `collateralRequired = 0`; tiers acima mantêm a tabela atual.
- Backend: onde quer que valide garantia por tier, aceitar tier-1 sem lock (manter validação para os demais).
- Copy: programa "Meus Primeiros Sats" — textos em `app_strings.dart` (pt/en/es) explicando: comece sem garantia, acumule, suba de tier se quiser.
- **Interação com HODL Vault (T2):** o gate de lock do T2 deve ler a exigência por tier — então R2 e T2 precisam nascer compatíveis: o T2 NÃO pode assumir "todo tier exige garantia". Ordem sugerida: R2 define a tabela de exigência → T2 consome a tabela.
- Risco a mitigar: provedor sem garantia que some depois do aceite → o R3 (timeout de 2h) é a proteção natural; limitar tier-1 a 1 ordem ativa por vez.

**Critério de aceite:** conta nova sem sats conclui ativação de tier-1 e recebe ordem de ≤ R$10; tier-2+ continua exigindo garantia; teste cobrindo os dois caminhos.

---

## R3 — Timeout de 2h pro provedor pagar 🥉
**Problema:** provedor aceita e some → liquidez presa, usuário ansioso.

**Fluxo aprovado (palavras da Carol):** aceite tem **2 horas** pra pagar. Estourou → o aceite cai, provedor recebe **notificação**, usuário vê em **Minhas Ordens** o aviso com as duas escolhas: **republicar** a ordem ou **cancelar e sacar os sats**. (Os dois botões dessa escolha estão AUTORIZADOS — pedido explícito da Carol.)

**O que fazer:**
- Timer no app do usuário a partir do `acceptedAt` (clampado, v775) do aceite canônico: +2h sem comprovante/30081 → aceite expirado.
- **NÃO deletar o aceite com NIP-09** (lição da semana: deleção apaga evidência). Expiração é um NOVO evento 30080 `accept_expired` + estado local — histórico permanece intacto pra mediação.
- Push ao provedor expirado ("seu aceite expirou") via fluxo FCM existente.
- Republicar = volta a ordem a `pending` com novo 30078 (mesma ordem, novo round de aceites). Cancelar = fluxo de cancelamento existente + saque dos sats pra carteira dela.
- Anti-corrida: se o comprovante chegar NO LIMITE (relágio do provedor adiantado), vale o `created_at` clampado — mesma regra do v775.

**Critério de aceite:** teste de corrida novo em `test/race/` (aceite expira aos 120min; comprovante aos 119min mantém; comprovante aos 121min não ressuscita); notificação disparada; ordem republicável; cancelamento devolve sats.

---

## R4 — Revisão geral da tela de Admin 🧹
**Sintoma (Carol):** "parece que nenhuma mediação funciona ali, nem as estatísticas".

**O que fazer:**
- Auditoria ponta a ponta de `platform_admin_screen.dart` × rotas admin do backend: lista de disputas, detalhe/evidências, estatísticas, usuários/ordens. Pra CADA painel: de onde vem o dado → a rota responde? → o widget renderiza?
- Consertar o que estiver morto (rota 404/500, campo renomeado, auth) e REMOVER o que for enfeite sem backend.
- Regla da casa: admin não pode depender de relay específico — dados de mediação vêm do backend (`bro-api`) como fonte da verdade, relay só pra evidência NIP-44.

**Critério de aceite:** cada painel com dado real demonstrado em teste manual guiado (checklist no PR); zero seções "em breve" fantasmas.

---

## Sequência (19 dias)

| Semana | Entregas |
|---|---|
| 11–15/nov | **R1** (bug, sai logo) + HODL T1a/T1b |
| 16–20/nov | **R2** (tabela de garantia) + HODL T2/T3 (consome a tabela do R2) |
| 21–26/nov | **R3** (timeout 2h) |
| 27–30/nov | **R4** (admin) + rodada de regressão (24 testes + novos) + build candidato |

**Régua de liberação:** cada item só vai pros testadores quando (1) agente implementou + testou, (2) Copilot revisou + rodou testes independentes, (3) Carol retestou no aparelho e aprovou. 💜
