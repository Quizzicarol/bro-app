# BROSPEC-05: Sistema de Reputação

`draft` `optional`

## Resumo

Esta especificação define o sistema de reputação para provedores e usuários no Protocolo Bro.

## Motivação

Em um sistema P2P sem intermediários, a reputação é crucial para:
- Identificar provedores confiáveis
- Incentivar bom comportamento
- Reduzir fraudes
- Construir confiança na rede

## Componentes da Reputação

### 1. Métricas Quantitativas

| Métrica | Descrição | Peso |
|---------|-----------|------|
| `totalOrders` | Total de ordens completadas | Alto |
| `successRate` | % de ordens com sucesso | Muito Alto |
| `avgTimeSeconds` | Tempo médio de execução | Médio |
| `totalVolume` | Volume total em sats | Médio |
| `disputeRate` | % de ordens com disputa | Alto (negativo) |
| `activeSince` | Data de início | Baixo |

### 2. Avaliações Qualitativas

Usuários podem deixar reviews após ordens:

| Rating | Significado |
|--------|-------------|
| ⭐⭐⭐⭐⭐ (5) | Excelente |
| ⭐⭐⭐⭐ (4) | Bom |
| ⭐⭐⭐ (3) | Regular |
| ⭐⭐ (2) | Ruim |
| ⭐ (1) | Péssimo |

### 3. Web of Trust (WoT)

Reputação baseada em quem você segue no Nostr:
- Provedores seguidos por pessoas que você segue têm mais peso
- Follows de perfis verificados (NIP-05) valem mais

## Eventos de Reputação

### Review de Ordem (NIP-32 Labels)

```json
{
  "kind": 1985,
  "pubkey": "<user_pubkey>",
  "created_at": <timestamp>,
  "tags": [
    ["L", "bro/review"],
    ["l", "positive", "bro/review"],
    ["e", "<order_event_id>"],
    ["p", "<provider_pubkey>"],
    ["rating", "5"],
    ["t", "bro-review"]
  ],
  "content": "Pagamento super rápido! Recomendo."
}
```

### Tags de Review

| Tag | Valores | Descrição |
|-----|---------|-----------|
| `L` | `bro/review` | Namespace do label |
| `l` | `positive`, `negative`, `neutral` | Sentimento |
| `e` | event_id | Ordem avaliada |
| `p` | pubkey | Provedor avaliado |
| `rating` | 1-5 | Nota numérica |

### Perfil de Provedor Atualizado

```json
{
  "kind": 30082,
  "pubkey": "<provider_pubkey>",
  "created_at": <timestamp>,
  "tags": [
    ["d", "provider_profile"],
    ["t", "bro-provider"],
    ["name", "ProviderX"],
    ["stats_orders", "150"],
    ["stats_success", "98.5"],
    ["stats_avg_time", "180"],
    ["stats_volume", "5000000"],
    ["stats_disputes", "1.0"],
    ["verified", "true"]
  ],
  "content": "{...detalhes...}"
}
```

## Cálculo de Score

### Fórmula Base

```javascript
function calculateScore(provider) {
  const {
    totalOrders,
    successRate,
    avgTimeSeconds,
    totalVolume,
    disputeRate,
    daysSinceStart
  } = provider.stats;

  // Pesos
  const W_ORDERS = 0.15;
  const W_SUCCESS = 0.35;
  const W_TIME = 0.15;
  const W_VOLUME = 0.10;
  const W_DISPUTES = 0.20;
  const W_LONGEVITY = 0.05;

  // Normalização (0-100)
  const ordersScore = Math.min(totalOrders / 100, 1) * 100;
  const successScore = successRate;
  const timeScore = Math.max(0, 100 - (avgTimeSeconds / 60)); // Penaliza > 1h
  const volumeScore = Math.min(totalVolume / 10000000, 1) * 100;
  const disputeScore = Math.max(0, 100 - disputeRate * 10);
  const longevityScore = Math.min(daysSinceStart / 365, 1) * 100;

  // Score final (0-100)
  return (
    ordersScore * W_ORDERS +
    successScore * W_SUCCESS +
    timeScore * W_TIME +
    volumeScore * W_VOLUME +
    disputeScore * W_DISPUTES +
    longevityScore * W_LONGEVITY
  );
}
```

### Níveis de Reputação

| Score | Nível | Badge |
|-------|-------|-------|
| 90-100 | Lendário | 💎 |
| 75-89 | Excelente | 🥇 |
| 60-74 | Bom | 🥈 |
| 40-59 | Regular | 🥉 |
| 20-39 | Iniciante | 🌱 |
| 0-19 | Novo | ⭐ |

## Web of Trust

### Cálculo de Confiança

```javascript
function calculateTrust(provider, viewer) {
  let trustScore = 0;
  
  // 1. Viewer segue o provider?
  if (viewer.follows.includes(provider.pubkey)) {
    trustScore += 30;
  }
  
  // 2. Quantos follows em comum?
  const commonFollows = viewer.follows.filter(f => 
    provider.followers.includes(f)
  );
  trustScore += Math.min(commonFollows.length * 2, 30);
  
  // 3. Provider tem NIP-05 verificado?
  if (provider.nip05Verified) {
    trustScore += 20;
  }
  
  // 4. Reviews de pessoas que viewer segue?
  const trustedReviews = provider.reviews.filter(r =>
    viewer.follows.includes(r.reviewerPubkey)
  );
  const avgTrustedRating = average(trustedReviews.map(r => r.rating));
  trustScore += avgTrustedRating * 4; // max 20
  
  return Math.min(trustScore, 100);
}
```

### Visualização no App

```
┌─────────────────────────────────────────┐
│ 🟢 ProviderX                            │
│ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
│                                         │
│ 💎 Lendário (Score: 94)                 │
│                                         │
│ ⭐ 4.9 (127 avaliações)                 │
│ ✅ 98.5% sucesso                        │
│ ⚡ ~3 min por ordem                     │
│ 📊 R$ 500k+ processados                 │
│                                         │
│ 👥 Confiança: Alta                      │
│    • 3 amigos em comum                  │
│    • 5 reviews de quem você segue       │
│    • Verificado: providerx@nostr.com    │
│                                         │
│ [💬 Chat] [📋 Ver Ordens] [⭐ Avaliar]  │
└─────────────────────────────────────────┘
```

## Prevenção de Fraudes

### Sybil Attack

Provedor cria múltiplas contas para inflar reputação.

**Mitigações:**
- Exigir colateral para cada conta
- Peso maior para avaliações de contas antigas
- Análise de padrões (mesmo IP, horários)
- WoT reduz peso de contas não conectadas

### Review Bombing

Concorrente deixa reviews falsos negativos.

**Mitigações:**
- Reviews só de ordens completadas
- Peso maior para reviews recentes
- Possibilidade de contestar review
- WoT filtra reviews de contas suspeitas

### Self-Trading

Provedor cria ordens próprias para inflar stats.

**Mitigações:**
- Detectar ordens entre mesmas pubkeys
- Analisar padrões de volume/horário
- Exigir diversidade de clientes

## API de Reputação

```typescript
interface ReputationService {
  // Consultas
  getProviderScore(pubkey: string): Promise<ProviderScore>;
  getProviderReviews(pubkey: string, limit?: number): Promise<Review[]>;
  getTrustScore(providerPubkey: string, viewerPubkey: string): Promise<number>;
  
  // Reviews
  submitReview(params: ReviewParams): Promise<void>;
  contestReview(reviewId: string, reason: string): Promise<void>;
  
  // Estatísticas
  updateProviderStats(pubkey: string): Promise<void>;
  recalculateScores(): Promise<void>;
}

interface ProviderScore {
  pubkey: string;
  score: number;
  level: string;
  badge: string;
  stats: {
    totalOrders: number;
    successRate: number;
    avgTimeSeconds: number;
    totalVolume: number;
    disputeRate: number;
  };
  reviews: {
    count: number;
    avgRating: number;
  };
  verified: boolean;
  nip05?: string;
}

interface ReviewParams {
  orderEventId: string;
  providerPubkey: string;
  rating: 1 | 2 | 3 | 4 | 5;
  comment?: string;
  sentiment: 'positive' | 'negative' | 'neutral';
}
```

## Exemplo de Implementação

### Buscar Reviews de um Provedor

```javascript
async function fetchProviderReviews(providerPubkey) {
  const filter = {
    kinds: [1985],
    '#L': ['bro/review'],
    '#p': [providerPubkey],
    limit: 50
  };
  
  const events = await relay.fetch(filter);
  
  return events.map(event => ({
    id: event.id,
    reviewerPubkey: event.pubkey,
    orderEventId: getTagValue(event, 'e'),
    rating: parseInt(getTagValue(event, 'rating')),
    sentiment: getTagValue(event, 'l'),
    comment: event.content,
    createdAt: event.created_at
  }));
}
```

### Publicar Review

```dart
Future<void> publishReview({
  required String orderId,
  required String orderEventId,
  required String providerPubkey,
  required int rating,
  required String comment,
}) async {
  final sentiment = rating >= 4 ? 'positive' 
                  : rating <= 2 ? 'negative' 
                  : 'neutral';

  final event = Event.from(
    kind: 1985,
    tags: [
      ['L', 'bro/review'],
      ['l', sentiment, 'bro/review'],
      ['e', orderEventId],
      ['p', providerPubkey],
      ['rating', rating.toString()],
      ['t', 'bro-review'],
      ['orderId', orderId],
    ],
    content: comment,
    privkey: privateKey,
  );

  await publishToRelays(event);
}
```

## Exibição de Reputação

### Lista de Provedores

```
┌──────────────────────────────────────────────────┐
│ 🔍 Provedores Disponíveis                        │
├──────────────────────────────────────────────────┤
│ 💎 ProviderX          ⭐ 4.9  ✅ 98%  ⚡ 3min    │
│    R$ 10 - R$ 5.000   Taxa: 3.5%                │
├──────────────────────────────────────────────────┤
│ 🥇 BitcoinBro         ⭐ 4.7  ✅ 95%  ⚡ 5min    │
│    R$ 50 - R$ 2.000   Taxa: 4.0%                │
├──────────────────────────────────────────────────┤
│ 🥈 SatoshiPay         ⭐ 4.5  ✅ 92%  ⚡ 8min    │
│    R$ 10 - R$ 1.000   Taxa: 3.0%                │
└──────────────────────────────────────────────────┘
```

### Filtros de Reputação

Usuários podem filtrar por:
- Score mínimo
- Taxa de sucesso mínima
- Tempo médio máximo
- Apenas verificados (NIP-05)
- Apenas seguidos

---

*Versão: 0.1-draft*
*Data: Janeiro 2026*
