# 📋 Changelog - Bro App

## [1.0.131+254] - 2026-03-01

### 🔧 Auto-Repair

- **Ordens com eventos perdidos nos relays**
  - Detecta ordens locais em status terminal (disputed, completed, etc) sem eventos nos relays
  - Republica automaticamente o status update (kind 30080) com tags `#p` do provedor e usuário
  - Funciona no sync do usuário E no sync do provedor
  - Delay 500ms entre reparações para não sobrecarregar relays
  - Resolve caso d37757a8: ordem disputada cujos eventos sumiram dos relays

### Arquivos Modificados
- `lib/providers/order_provider.dart` — _autoRepairMissingOrderEvents(), chamada em ambos syncs

---

## [1.0.131+253] - 2026-02-28

### 🛒 Marketplace

- **Layout grade 3 colunas**
  - ListView substituído por GridView.builder com 3 colunas
  - Cards compactos retangulares com foto, categoria, título, preço
  - Detalhes completos acessíveis ao tocar no card

- **Excluir oferta**
  - Novo botão "Excluir Oferta" nas ofertas próprias (detail sheet)
  - Dupla estratégia: NIP-33 replacement (marcador deleted) + NIP-09 kind 5
  - Ofertas deletadas filtradas no fetch (ambos endpoints)

### 🐛 Bugs Corrigidos

- **Notificação de disputa não chegava ao provedor**
  - `publishDisputeNotification()` agora inclui `['p', providerId]` nos tags
  - Provedor recebe a disputa via #p tag nos relays

- **orderDetails da disputa sem provider_id (lado usuário)**
  - `order_status_screen.dart` agora inclui `provider_id` no mapa de detalhes
  - Garante que a disputa publicada tem referência ao provedor

### Arquivos Modificados
- `lib/screens/marketplace_screen.dart` — Grid layout, card compacto, botão excluir
- `lib/services/nostr_order_service.dart` — deleteMarketplaceOffer(), filtro deleted, fix dispute #p
- `lib/screens/order_status_screen.dart` — provider_id no orderDetails da disputa

---

## [1.0.131+252] - 2026-02-28

### 🐛 Bugs Corrigidos

- **Pull-to-refresh exigia 3 puxadas**
  - Adicionado Completer pattern para aguardar sync em andamento
  - `displacement: 20` em todos RefreshIndicators
  - Corrigido leak de `_isSyncingNostr` no catch block

- **Ordem disputada d37757a8 não aparecia no provedor**
  - `updateOrderStatus()` agora auto-preenche `providerId` e `orderUserPubkey` da ordem existente
  - Adicionada estratégia 4 em `_fetchProviderOrdersRaw`: busca kind 30080 com #p tag

### Arquivos Modificados
- `lib/providers/order_provider.dart` — Completer pattern, auto-fill providerId
- `lib/services/nostr_order_service.dart` — Estratégia 4 busca #p
- `lib/screens/provider_orders_screen.dart` — displacement, fix _isSyncingNostr

---

## [1.0.131+251] - 2026-02-28

### 🐛 Bugs Corrigidos

- **Taxa 2% marketplace não chegava na Coinos**
  - Problema: `feeOrderId` usava `mkt_{offerId}` fixo — dedup guard bloqueava compras repetidas da mesma oferta
  - Solução: ID único por transação: `mkt_{txCode}_{timestamp}` (cada compra gera novo ID)
  - Mínimo 1 sat já estava implementado no `sendPlatformFee()` (v1.0.129+224)

- **Pagamento com carteira travava na tela de loading**
  - Removido self-payment circular (createInvoice + payInvoice para si mesmo, delay 60-90s)
  - Navegação imediata após `createOrder`, operações Nostr em background com timeout 15s

- **Disputa já resolvida permitia re-resolução**
  - Adicionado `_fetchExistingResolution()` no `_initData()` para verificar no Nostr

- **Sold count do marketplace não atualizava após compra**
  - Movido trigger para `_onNewMessage()` (confirmação de pagamento do comprador)

### ✨ Melhorias

- **Código de pedido no marketplace** (#XXXXXX)
  - Cada pedido de pagamento, invoice e confirmação agora tem um código único de 6 dígitos
  - Ex: "⚡ PEDIDO DE PAGAMENTO #482931" / "🔖 Pedido #482931"

### Arquivos Modificados
- `lib/screens/marketplace_chat_screen.dart` — Código de pedido, fee orderId único, sold count fix
- `lib/screens/payment_screen.dart` — Removido self-payment, navegação imediata
- `lib/screens/dispute_detail_screen.dart` — Fetch existing resolution on init

---

## [1.0.107] - 2026-02-17

### 🐛 Bugs Críticos Corrigidos

- **Reconciliação automática marcava ordens erradas como "completed"**
  - Problema: Funções de auto-reconciliação (`autoReconcileWithBreezPayments`, `onPaymentSent`, `forceReconcileAllOrders`) não verificavam se a ordem foi criada pelo usuário atual
  - Consequência: Ordens aceitas como PROVEDOR eram erroneamente marcadas como completed
  - Resultado: Duplicidade de transações e confirmação automática antes do usuário confirmar
  - Solução: Adicionar verificação `order.userPubkey == currentUserPubkey` antes de marcar como completed

### ✅ Confirmado Funcionando
- **Invoice do provedor sendo incluído no Nostr** - `hasInvoice=true` confirmado nos logs
- **Taxa da plataforma** - Callback configurado corretamente via `PlatformFeeService`

### Arquivos Modificados
- `lib/providers/order_provider.dart`:
  - `autoReconcileWithBreezPayments()` - Verificar userPubkey antes de marcar completed
  - `onPaymentSent()` - Só processar ordens criadas pelo usuário atual
  - `forceReconcileAllOrders()` - Pular ordens que não foram criadas pelo usuário

---

## [1.0.43] - 2026-01-25

### 🐛 Bug CRÍTICO Corrigido
- **Status "completed" AINDA não chegava ao Bro (causa raiz encontrada!)**
  - Problema: `_fetchAllOrderStatusUpdates` não buscava eventos `kindBroAccept` (30079)
  - Consequência: `providerId` nunca era propagado para as ordens via Nostr
  - Resultado: Bro não conseguia identificar suas ordens aceitas → status never sync
  - Solução: 
    1. Incluir `kindBroAccept` (30079) na busca de updates
    2. Extrair `providerId` do `pubkey` do evento para accepts
    3. `loadOrdersForUser` agora mantém ordens onde `providerId == userPubkey`

### Arquivos Modificados
- `lib/services/nostr_order_service.dart` - Buscar eventos 30079 (accept)
- `lib/providers/order_provider.dart` - Manter ordens aceitas + logs detalhados

---

## [1.0.42] - 2026-01-25

### 🐛 Bug Corrigido
- **Status "completed" ainda não chegava ao Bro (v1.0.41 incompleto)**
  - Problema: Mesmo com tag `#p`, relays nem sempre retornavam eventos
  - Solução: 3 estratégias de busca:
    1. Buscar por `#p` (tag do provedor) - principal
    2. Buscar por `#t` (bro-update) e filtrar por orderId - fallback
    3. Buscar por `#orderId` diretamente - último recurso

### ✨ Melhoria UX
- **Unificar carteiras**: "Ver Carteira do Bro" → "Ver Carteira"
  - Remove duplicação de telas de carteira
  - Navega para `/wallet` (mesma tela de "Minha Carteira")

### Arquivos Modificados
- `lib/services/nostr_order_service.dart` - 3 estratégias de busca
- `lib/screens/provider_orders_screen.dart` - Unificar carteira

---

## [1.0.41] - 2026-01-25

### 🐛 Bug Corrigido
- **Status "completed" não chegava ao Bro após confirmação do usuário**
  - Problema: Usuário confirmava pagamento mas Bro continuava vendo "Aguardando Confirmação"
  - Causa: `providerId` podia ser `null`, então evento Nostr não tinha tag `#p`
  - Solução: Buscar `providerId` de múltiplas fontes, adicionar logs de debug

### Arquivos Modificados
- `lib/screens/order_status_screen.dart` - Fallback para buscar providerId
- `lib/providers/order_provider.dart` - Logs detalhados de publicação Nostr

---

## [1.0.40] - 2026-01-25

### 🐛 Bug Corrigido
- **Comprovante do Bro não aparecia na tela de status (via Nostr)**
  - Problema: Card "Comprovante do Bro" aparecia mas sem imagem
  - Causa: `proofImage` não era capturado dos eventos Nostr durante sincronização
  - Solução: Salvar `proofImage` em `_fetchAllOrderStatusUpdates` e passar `metadata` em `_applyStatusUpdate`

### Arquivos Modificados
- `lib/services/nostr_order_service.dart` - Incluir proofImage nos updates
- `lib/providers/order_provider.dart` - Mesclar metadata ao sincronizar

---

## [1.0.39] - 2026-01-25

### 🐛 Bug Crítico Corrigido
- **Sincronização de status entre usuário e Bro**
  - Problema: Ordem mostrava "Concluída" para usuário mas "Aguardando Usuário" para Bro
  - Causa: Evento Nostr de update não incluía `providerId` na tag `#p`
  - Solução: Passar `providerId` ao confirmar e criar `fetchOrderUpdatesForProvider()`

### Arquivos Modificados
- `lib/screens/order_status_screen.dart` - Passa providerId ao confirmar
- `lib/services/nostr_order_service.dart` - Nova função fetchOrderUpdatesForProvider()
- `lib/providers/order_provider.dart` - Busca updates para ordens aceitas

---

## [1.0.38] - 2026-01-25

### 🚨 Bug CRÍTICO de Segurança Corrigido
- **Vazamento de ordens entre usuários**
  - Problema: Ordens de um usuário apareciam em outro dispositivo com conta diferente
  - Causa: `createOrder()` salvava diretamente sem filtro, `fetchOrder()` inseria sem verificar pubkey
  - Solução: Usar `_saveOrders()` com filtro, verificar pubkey antes de inserir

### 🐛 Bug Corrigido
- **Comprovante do Bro não aparecia para usuário**
  - Problema: `paymentProof` era truncado para `'image_base64_stored'`
  - Solução: Salvar imagem completa em base64

### Arquivos Modificados
- `lib/providers/order_provider.dart` - Filtros de segurança rigorosos
- `lib/screens/order_status_screen.dart` - Buscar metadata do OrderProvider sempre

---

## [1.0.37] - 2026-01-25

### ✨ Melhorias na Tela de Depósito On-chain
- Detecção de transação na mempool
- Barra de progresso com confirmações (0/3, 1/3, 2/3, 3/3)
- Tempo estimado até tier ser liberado (~10min/confirmação)
- 3 confirmações obrigatórias (proteção contra RBF)
- Polling mais rápido: 10s ao invés de 30s
- Padding no final para não ficar atrás da navegação

### Arquivos Modificados
- `lib/screens/deposit_screen.dart` - Widget _buildOnchainStatusCard()

---

## [1.0.36] - 2026-01-25

### 🐛 Bug Corrigido
- **Sats "pendentes" incorretos**
  - Problema: Mostrava 37445 sats como "Ordens Pendentes" mesmo com só 13 sats na carteira
  - Causa: `committedSats` contava ordens que já tiveram invoice paga
  - Solução: `committedSats` retorna 0 (sats já saíram da carteira quando invoice foi paga)

### Arquivos Modificados
- `lib/providers/order_provider.dart` - Getter committedSats retorna 0

---

## [1.0.35] - 2026-01-25

### 🐛 Bugs Corrigidos
1. **Badge "Tier Ativo" inconsistente com ordens bloqueadas**
   - Problema: Badge mostrava "Tier Ativo" mas ordens mostravam "BLOQUEADA"
   - Causa: Estado `_tierAtRisk` redundante não sincronizado com CollateralProvider
   - Solução: Usar CollateralProvider.isTierAtRisk diretamente

2. **Comprovante não visível para usuário**
   - Problema: Usuário não via o comprovante enviado pelo Bro
   - Solução: Adicionar `paymentProof` à cadeia de lookup no metadata

### Arquivos Modificados
- `lib/screens/provider_orders_screen.dart` - Remover _tierAtRisk
- `lib/screens/order_status_screen.dart` - Adicionar paymentProof ao lookup

---

## [1.0.34] - 2026-01-24

### 🐛 Bug Corrigido
- **Erro "order is not a subtype of Map"**
  - Problema: Crash ao entrar no modo Bro
  - Causa: Código esperava Map mas recebia Order
  - Solução: Converter Order para Map usando .toJson()

---

## [1.0.33] - 2026-01-24

### ✨ Melhorias
- Labels de status simplificados (4 categorias principais)
- Tolerância de 10% no saldo de tier para flutuação BTC

---

## [1.0.32] - 2026-01-24

### 🐛 Bug Corrigido
- **Ordens fantasma**
  - Problema: Ordens apareciam sem o usuário ter pago
  - Causa: Ordem era criada ANTES da invoice ser paga
  - Solução: Criar invoice ANTES da ordem, só criar ordem após pagamento

---

## [Anteriores]
Versões anteriores não documentadas neste formato.
