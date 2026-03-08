# Bro App — Changelog v1.0.129 → v1.0.131

## O que há de novo (para divulgação)

---

### 🛒 Marketplace P2P (NOVO!)
- **Marketplace de classificados** integrado ao Nostr (NIP-15, kind 30019)
- Crie ofertas de **produtos e serviços** com fotos, preço em sats, cidade e link
- **Fotos do produto** com carrossel e moderação de conteúdo (NSFW via ML)
- **Sistema de reputação** com avaliações de atendimento e qualidade do produto (👍👌👎)
- **Pagamento Lightning automático** em 3 cliques: comprador pede → vendedor gera invoice → comprador paga
- **Chat P2P criptografado** (NIP-04) entre compradores e vendedores
- **Controle de estoque**: quantidade disponível, vendidos, esgotado
- **ID de anúncio** numérico único (#XXXXXX) para rastreabilidade
- **Filtro por categoria**: Produto, Serviço, Outro
- Integração com **BTCMap** para localizar comerciantes Bitcoin por cidade
- **Sistema de reports** (NIP-56) com ocultação automática após 2 denúncias
- **Moderação de conteúdo**: palavras proibidas, detecção NSFW por IA, validação de formato de imagem
- **Taxa de 2%** da plataforma cobrada automaticamente nas vendas
- Aba "Minhas Ofertas" para gerenciar anúncios com botão "Ver Mensagens de Interessados"

### ⚖️ Sistema de Disputas Melhorado
- **Mediação completa**: tela dedicada para o mediador com todas as evidências
- **Upload de evidências** por ambas as partes (usuário e provedor) com fotos e texto
- **Criptografia NIP-44** ponta a ponta nas evidências de disputa
- **Validação E2E do PIX**: comprovante cruzado com dados do boleto (beneficiário, CNPJ)
- **Mensagens do mediador** visíveis na tela da ordem (usuário e provedor)
- **Resposta ao mediador** via texto direto na thread da disputa
- **Backup NIP-04 DM**: mensagens do mediador também enviadas como DM criptografada
- **Sinalização de reincidentes**: disputas perdidas ficam registradas, mediador vê aviso amarelo (1-2x) ou vermelho "REINCIDENTE!" (3x+)
- **Histórico de disputas** do admin com abas Abertas/Resolvidas
- Fix: disputa reaberta e status inconsistente entre user/provider

### 🔄 Atualizações Automáticas
- **Verificação de versão** automática ao abrir o app
- Notificação quando há versão nova disponível
- Botão de atualização no dashboard

### 🔒 Segurança e Performance
- **Verificação de assinatura** de eventos Nostr (rejeita eventos forjados)
- **Imagens comprimidas** para caber nos relays (600x600, q40 ≈ 20-40KB)
- **NSFW Detection** via ML (TFLite) com timeout robusto de 15s
- **Taxa da plataforma**: 2% enviada para endereço Coinos via Lightning Address
- **Prevenção de taxa duplicada** com lock síncrono + persistência em SharedPreferences
- **Aviso de conta vencendo**: alerta quando o boleto está próximo do vencimento

### 🐛 Correções
- Fix: evidências/comprovantes não enviavam (imagem muito grande para relays)
- Fix: crash ao criar oferta no marketplace (TFLite native crash)
- Fix: status da disputa aparecia errado após resolução
- Fix: ordens liquidadas mostrando UI incorreta
- Fix: auto-liquidação com bugs de UI e registro de ganhos
- Fix: disputas resolvidas aparecendo como "em disputa" na lista

---

## Versões detalhadas

| Build | Destaque |
|-------|----------|
| +236 | Melhorias no sistema de disputas + migração 36h |
| +237 | Criptografia NIP-44 para evidências + Validação E2E PIX |
| +238 | Respostas ao mediador + mensagens visíveis + aviso de vencimento |
| +239 | Verificação automática de versão + DMs NIP-04 do admin |
| +241 | Fix disputa reaberta + status inconsistente |
| +242 | Marketplace: reputação, fotos, BTCMap, disclaimer, pagamento Lightning |
| +243 | Botão atualizar, sistema de estoque, invoice automática, moderação de imagem |
| +244 | Fix botão atualizar, NSFW ML, taxa 2% no spread, remover LNURL exposto |
| +245 | Fluxo de pagamento automático no chat (3 cliques) |
| +246 | Labels de marketplace na wallet/dashboard + upload de imagem na mediação |
| +247 | Fix evidências (compressão), crash marketplace, disputas reincidentes |
| +248 | Mensagens na oferta do vendedor, taxa 2% Coinos, sold count, ID de anúncio |
| +251 | Código de pedido no marketplace, fix taxa 2% dedup, fix wallet timeout, fix disputa re-resolve, fix sold count |
