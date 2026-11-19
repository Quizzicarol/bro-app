# Bro — Relatório unificado de aquecimento, jank e plano de performance

Data da investigação: 18/11/2026  
Base de referência: `release-822-rollback` (`07d3b52`, versionCode 822)  
APK medido: versionCode 823 (`test/v816`, base 822 + R3 + knob de teste)  
Status: investigação somente leitura; nenhum arquivo de código alterado nesta análise.

> Documento para todos os agentes. Não autoriza push para `main`, mudança de
> protocolo, remoção de relays, novos botões ou alteração dos guards de dinheiro.
> Toda implementação segue edição cirúrgica, testes e double review.

---

## 1. Decisão recomendada: R3 ou performance?

**Fazer em paralelo, com donos e branches diferentes:**

1. **Concluir a validação do R3 agora**, sem acrescentar otimizações na branch
   `test/v816`: revisão do merge/knob, teste do ciclo curto no USB e posterior
   teste com a janela real de 60 minutos. O R3 já está implementado e sua suíte
   está verde; falta evidência humana/dispositivo, não mais escopo.
2. **Criar o pacote PERF-UI a partir da `release-822-rollback`**, isolado do R3.
   Começar pelas correções de Home/carteira, que não mudam Nostr, pagamentos ou
   máquina de estados das ordens.
3. Só integrar R3 + PERF depois que cada um tiver sua própria evidência. Fazer
   merge de integração, repetir regressão e obter double review. A entrada em
   `main` continua dependendo de autorização explícita da dona do produto.

**Por quê:** misturar performance ao R3 agora impediria saber qual mudança causou
um eventual problema. Adiar toda a performance até o R3 entrar no main deixaria
um problema mensurável de CPU/aquecimento sem tratamento.

**Primeira implementação sugerida:** PERF-UI-1 (Home) + PERF-UI-2 (reconciliação
inicial), em um único pacote pequeno. Não começar por reescrita do sync Nostr.

---

## 2. Evidências coletadas no aparelho

Ambiente: Samsung conectado por USB, app `app.bro.mobile`, release 1.0.134+823.
A investigação abriu o app e coletou logs/métricas; não criou nem confirmou ordens.
As rotinas automáticas já existentes executaram durante a observação.

- Picos de **113% de CPU no processo** e amostras repetidas de **97–100% na
  thread principal do processo Android**.
- Temperatura do processador passou de aproximadamente **30,2 °C para 37,1 °C**
  durante a investigação. O Android permaneceu em `Thermal Status: 0`; isso não
  prova throttling, mas confirma aumento de temperatura durante o uso.
- Em uma janela de aproximadamente sete minutos de logs: **30 leituras do
  histórico de pagamentos**, **141 tentativas de publicação em relays** e
  **5 reconciliações denominadas “de inicialização”**.
- Memória chegou a aproximadamente **465 MB PSS**, com cerca de **200 MB de
  gráficos**. É um sinal para profiling, não prova de memory leak.
- Foram observados DNS falhando temporariamente para todos os relays, Damus 503
  e `nos.lol` em timeout. Isso descreve esta rede/aparelho naquela janela; **não
  autoriza declarar relay morto nem removê-lo da lista**.
- `dumpsys gfxinfo` não forneceu uma taxa válida de jank para o `SurfaceView`
  do Flutter. O percentual de frames lentos deve ser medido com Flutter
  DevTools em build **profile**, não inferido desses zeros.
- Os pontos críticos de Home, reconciliação e republicação também estão no
  código da v822. **Não há evidência de que o R3 seja a causa do aquecimento.**

---

## 3. Achados técnicos e correções propostas

### PERF-UI-1 — Home executa SDK durante rebuild (prioridade máxima)

**Evidência:** `Consumer2<BreezProvider, OrderProvider>` reconstrói a Home em
`lib/screens/home_screen.dart` (~linha 832). Dentro da árvore,
`_buildMarketplaceActivity` cria `FutureBuilder(future:
breezProvider.listPayments())` (~linha 1513). O método consulta e transforma até
1.000 pagamentos em `lib/providers/breez_provider.dart` (~linha 1381).

**Cadeia:** evento de carteira/ordem → rebuild → nova leitura do SDK → mais
trabalho/notificações → outro rebuild.

**Implementação:**
- Nunca chamar SDK dentro de `build`.
- Manter `Future`/resultado em estado ou no provider, com cache e invalidação
  explícita.
- Carregar na abertura; atualizar em pull-to-refresh e eventos de pagamento
  relevantes. Não invalidar por eventos de ordem que não mudam pagamentos.
- Isolar a seção de Marketplace e usar `Selector`/escopos menores para evitar
  reconstruir a Home inteira por qualquer notificação.
- Preservar exatamente os dados e a apresentação atuais; sem botões novos.

**Aceite:** 10 rebuilds consecutivos não geram 10 chamadas ao SDK; pagamento novo
ainda atualiza a seção; pull-to-refresh continua atualizando; navegação e scroll
não reiniciam consultas desnecessárias.

**Risco:** baixo. Não altera protocolo, estado canônico ou pagamento.

### PERF-UI-2 — Reconciliação “de inicialização” repete a cada notify

**Evidência:** `_scheduleReconciliationOnStartup` em `lib/main.dart` (~linha 609)
adiciona listener que chama `_tryReconciliation` sempre que o provider notifica
com `isInitialized == true`. Não há transição false→true, guard de concorrência,
execução única nem remoção do listener.

**Implementação:**
- Executar somente na transição real para carteira inicializada.
- Adicionar guard single-flight para impedir reconciliações sobrepostas.
- Remover o listener após cumprir sua finalidade e garantir descarte correto.
- Manter intactos callbacks de pagamentos novos e reconciliadores de segurança
  v820/v820f; esta mudança é apenas sobre a reconciliação inicial redundante.

**Aceite:** uma inicialização real produz uma reconciliação inicial; eventos
`Synced`/notifies posteriores não repetem a rotina; pagamento novo segue tendo
seu tratamento próprio.

**Risco:** baixo/médio por tocar `main.dart`; revisão independente obrigatória.

### PERF-SYNC-1 — Coordenar gatilhos sem remover nenhum canal

**Evidência:** Home faz polling (~45 s), tela de ordem força sync a cada 15 s
(`lib/screens/order_status_screen.dart`, ~linha 586), RT/FCM força sync e um
sync recebido durante outro agenda nova execução. Cada passe ainda contém cauda
de manutenção (`lib/providers/order_provider.dart`, ~linha 6305).

**Implementação:**
- Coordenador single-flight + coalescência: um passe ativo e no máximo um passe
  pendente, preservando a urgência `force` e os subtipos de eventos.
- Nenhum aceite, comprovante ou complete pode ser descartado.
- Na tela de detalhe, priorizar fetch da ordem visível em vez de repetir toda a
  manutenção global quando isso for suficiente.
- Manter timer, RT e FCM. A skill de performance diz que os três são necessários;
  a otimização é evitar trabalho duplicado, não remover redundância de entrega.
- Preservar o save+notify cedo da v820c antes da cauda de manutenção.

**Aceite:** rajada de eventos produz no máximo um passe ativo + um coalescido;
aceite/comprovante chegam sem esperar o timer; nenhuma regressão nos fluxos de
corrida, disputa, cancelamento e conclusão.

**Risco:** médio/alto. Pacote separado do PERF-UI e double review de protocolo.

### PERF-SYNC-2 — Muitas conexões de leitura por passe

**Estimativa estática no estado observado (18 ordens ativas):** aproximadamente
49 conexões no fetch mirado + 5 no fetch de ordens + 14 no fetch amplo de status,
ou **~68 conexões de leitura por passe**, fora realtime e publicações. Não é uma
contagem de conexões simultâneas.

**Sequência segura:** primeiro reduzir passes redundantes (PERF-SYNC-1). Depois,
se profiling ainda indicar necessidade, avaliar múltiplos `REQ` por conexão por
relay, mantendo filtros, relays, deduplicação e verificação de assinatura.

**Proibido neste pacote:** cortar relays por probe de uma máquina, enfraquecer
filtros #d/#p, reduzir verificação de assinatura ou trocar a verdade Nostr pela API.

### PERF-SYNC-3 — Republicações e reconexões redundantes

**Evidência:** `_republishUnconfirmedCompletions` (~linha 6832 de
`order_provider.dart`) seleciona todas as ordens completed das últimas 48 h sem
comprovar que a contraparte ainda não recebeu o evento. Houve muitas tentativas
de publicação durante falhas de rede e exceções assíncronas de WebSocket.

**Implementação:**
- Cooldown e evidência de ACK por ordem/relay antes de nova republicação.
- Não enviar em socket cuja negociação `channel.ready` falhou.
- Tratar erros assíncronos de conexão e usar backoff exponencial com jitter.
- Não alterar conteúdo, assinatura, d-tags ou regras canônicas dos eventos.
- Não re-publicar resolução de disputa antiga; qualquer exceção exige revisão de
  dinheiro e evidência de relay.

**Risco:** médio/alto; não misturar com o pacote de UI.

### PERF-DETAILS — Trabalho secundário

- BRIX: polling a cada 5 s mesmo ocioso/sem conta. Introduzir backoff quando
  ocioso, preservando reação imediata a FCM e atividade real. Não alterar claim,
  invoice ou fee.
- Logs: reduzir logs repetitivos em release, preservando transições críticas,
  falhas e evidências de dinheiro. Não apagar forense necessário.
- Imagens: usar decodificação dimensionada para exibição (`cacheWidth`/
  `cacheHeight` quando apropriado), sem alterar base64/arquivo original da prova.
- Memória: medir cache de imagens e gráficos antes de propor limpeza agressiva;
  não invalidar o cache write-once de comprovantes.

---

## 4. Alerta independente de protocolo/dinheiro

Nos logs de 18/11, a ordem **af95b3ab**, no lado da usuária, apareceu como curada
localmente, mas o app publicou `disputed` e depois `cancelled` no mesmo ciclo.
Isso não é uma tarefa comum de performance e não deve ser “corrigido” por um
agente de UI.

**Ação:** abrir investigação específica com evento + timestamp de relay, revisar
a ordem de aplicação/republicação e interromper qualquer otimização que possa
ampliar esse comportamento. Não re-publicar resolução antiga para testar.

---

## 5. Plano de execução por etapas

### Etapa 0 — Baseline e coordenação (antes de editar)

- Registrar commit/branch/APK, aparelho, rede e estado do R3.
- Capturar 5 minutos de CPU, memória, logs e contagem de chamadas/publicações.
- Rodar Flutter DevTools em **profile**: Home parada, scroll, abrir detalhe e
  voltar. Salvar timeline de UI/raster e CPU.
- Definir donos de arquivos para evitar dois agentes editando `OrderProvider`.
- Confirmar que `release-822-rollback` continua disponível nos três remotes.

**Saída:** baseline reproduzível e mapa de propriedade das tarefas.

### Etapa 1 — PERF-UI (primeiro pacote de código)

Escopo: `main.dart`, `home_screen.dart`, `breez_provider.dart` e testes focados.
Não editar `order_provider.dart` nem serviços Nostr neste pacote.

1. Cache da Home e fim de SDK no `build`.
2. Reconciliação inicial única e single-flight.
3. Reduzir rebuilds por escopo, sem mudar layout/fluxos.
4. Testes: rebuild não chama SDK; inicialização reconcilia uma vez; atualização
   de pagamento/pull-to-refresh ainda funciona.

**Gate:** testes focados + `flutter test test/race test/integration`, analyze,
profile A/B no mesmo aparelho/rede e double review.

### Etapa 2 — Validar R3 independentemente

- Revisar merge da base 822 e knob `ACCEPT_EXPIRY_MINUTES`.
- No APK com janela curta: aceite expira uma única vez, ordem volta a Disponíveis,
  aceite antigo não contamina nova corrida, cancelamento/saque seguem íntegros.
- Testar comprovante antes/depois do limite e evento duplicado/atrasado.
- Repetir com janela real de 60 minutos antes de propor main.
- Não incluir mudanças de performance nessa evidência.

### Etapa 3 — Integração R3 + PERF-UI

- Integrar somente depois das etapas 1 e 2 terem resultados separados.
- Repetir suíte completa, analyze, teste de dispositivo e double review.
- Se houver problema, isolar por pacote; rollback continua sendo v822.

### Etapa 4 — PERF-SYNC (pacote posterior)

- Primeiro coalescência de sync e backoff de conexão.
- Depois dedup/cooldown de republicações com evidência de ACK.
- Só então avaliar compartilhamento de conexões/REQ, se ainda necessário.
- Testes de corrida, relay offline, DNS indisponível, eventos duplicados,
  comprovante no limite e retomada do app.

### Etapa 5 — PERF-DETAILS e fechamento

- BRIX ocioso, logs e imagens, cada alteração com teste apropriado.
- Comparar baseline × candidato em profile/release por pelo menos 10 minutos de
  Home parada e um ciclo completo de ordem.
- Publicar somente com aprovação da dona do produto.

---

## 6. Divisão de trabalho sugerida

| Frente | Responsável | Arquivos principais | Restrição |
|---|---|---|---|
| R3 | Agente que já implementou + revisor independente | `order_provider`, `nostr_order_service`, telas R3 | Não adicionar PERF |
| PERF-UI | Agente Flutter/estado | `main`, `home_screen`, `breez_provider` | Não tocar sync/Nostr |
| PERF-SYNC | Agente Nostr/protocolo | `order_provider`, `order_status`, serviços Nostr | Só após PERF-UI; double review |
| Revisão dinheiro | Revisor sem edição concorrente | guards, disputas, republicações | Evidência relay/log |
| Medição | Agente de QA/performance | testes, profile, ADB | Não alterar comportamento |

---

## 7. Modelos disponíveis no “Tokens for Friends” — papéis recomendados

A lista abaixo cobre os modelos visíveis nesta instalação em 18/11/2026. A
atribuição é por **adequação de tarefa e risco**, não por benchmark local: estes
modelos ainda não foram comparados no mesmo teste do Bro. Nomes comerciais não
garantem capacidade idêntica neste endpoint; validar custo, contexto e ferramentas
na aba antes de escalar trabalho.

| Modelo disponível | Melhor papel neste plano | Como extrair o melhor / cautela |
|---|---|---|
| **GPT-5.4 Pro** | Arquiteto/revisor principal de PERF-SYNC e dinheiro | Pedir revisão de invariantes, corridas e evidências; não precisa editar tudo. Ideal para decisão final de risco. |
| **Kimi K3.1 Pro** | Implementação principal de PERF-UI e integração | Dar arquivos, baseline e aceites fechados; exigir patches pequenos e testes. Bom candidato para “dono” do pacote UI. |
| **Kimi K3 Abliterated** | Prototipação descartável de testes/diagnóstico | Não usar como revisor final nem em dinheiro; toda saída precisa de revisão independente rigorosa. |
| **GLM-5.3** | Segunda implementação ou investigação de sync | Bom para proposta alternativa de coalescência/backoff; revisar conflitos com R3 antes de aplicar. |
| **GLM-5.3 Flash** | Inventário de timers, FutureBuilders e chamadas SDK | Usar em buscas repetitivas e geração de checklist; não dar o núcleo de sync sem revisão. |
| **GLM-5.3 Flash Uncensored FP8** | Tarefas mecânicas de baixo risco | Contagem de logs, chamadas duplicadas, testes simples; não usar para decisões de protocolo. |
| **GLM-5.3 Uncensored FP8** | Análise ampla secundária | Pode mapear dependências e casos de teste; exigir evidência de código e revisão humana/de outro modelo. |
| **Nemotron 3 Ultra** | Revisor independente de concorrência e ciclo de vida | Pedir caça a races, listeners duplicados, timers sem cancelamento e testes que falhariam sem o patch. |
| **Nemotron 3.5 Lightning** | QA rápido e execução de comandos | Rodar testes, analyze, coletar métricas e resumir falhas; não escolher arquitetura. |
| **Qwen3.8 27B** | Testes de widget/unidade e refactors locais | Bom para cache da Home e testes de reconciliação; fornecer APIs exatas e limitar escopo de arquivos. |
| **DeepSeek V4.1 Flash 1017** | Triage de logs e classificação de causas | Agrupar logs por operação/relay e gerar tabelas; não concluir dinheiro/estado sem evento e timestamp. |

### Combinação recomendada

- **Melhor equilíbrio para começar:** Kimi K3.1 Pro implementa PERF-UI;
  Nemotron 3 Ultra revisa concorrência/ciclo de vida; Nemotron 3.5 Lightning
  executa QA; GPT-5.4 Pro faz revisão final dos invariantes.
- **Alternativa econômica:** Qwen3.8 27B implementa o cache/testes da Home;
  GLM-5.3 Flash faz inventário; Nemotron 3 Ultra revisa; GPT-5.4 Pro aprova o
  desenho antes de qualquer trabalho em sync.
- **Para PERF-SYNC:** GLM-5.3 ou Kimi K3.1 Pro propõe implementação; GPT-5.4 Pro
  revisa protocolo/dinheiro; outro agente roda testes independentes. Quem escreve
  não aprova sozinho.
- **Não usar vários modelos editando o mesmo arquivo ao mesmo tempo.** Paralelizar
  investigação, testes e revisão; serializar edição por pacote.

---

## 8. Gates obrigatórios e critérios de sucesso

### Em todos os pacotes

- Nenhum botão novo; nenhuma mudança de versão de marketing (1.0.134).
- Nenhum push `feature/*`; nada em `main` sem autorização.
- Não alterar guard v727, prova settled v820e, reconciliador v820f ou save cedo
  v820c, exceto em tarefa explícita com revisor de dinheiro.
- `flutter test test/race test/integration` + testes focados + analyze.
- Double review e teste no aparelho antes de publicação.

### Medição A/B

Comparar v822 × candidato no mesmo aparelho/rede e em profile/release:

- CPU média/picos na Home parada e durante scroll;
- temperatura após 10 minutos;
- memória PSS/gráficos;
- número de `listPayments`, syncs, conexões e publicações por minuto;
- timeline Flutter UI/raster e frames acima de 16,7 ms;
- latência de aceite → billcode → comprovante → confirmação.

**Metas iniciais (medir, não prometer):** zero chamadas SDK por rebuild passivo;
uma reconciliação por inicialização; uma rajada de eventos = um sync ativo + no
máximo um coalescido; redução substancial de publicações redundantes; nenhuma
regressão funcional ou de latência dos eventos críticos.

---

## 9. Prompt curto para distribuir aos agentes

> Ler `GUIA_OPERACAO_AGENTES.md` e `RELATORIO_PERF_UI_18NOV2026.md`. Não editar
> fora do pacote assignado. R3 segue em validação isolada; PERF-UI nasce da v822;
> PERF-SYNC só depois. Preservar Nostr como verdade, guards de dinheiro, save cedo
> v820c, todos os canais de entrega e a lista de relays. Entregar patch cirúrgico,
> testes que falham sem a correção, medição A/B e relatório de riscos. Quem escreve
> não aprova; `main` somente com autorização da dona do produto.
