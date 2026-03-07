# Backend — Bro

Backend Node.js para o protocolo **Bro** — sistema P2P de pagamento de contas com Bitcoin via Lightning Network + Nostr.

## Instalação

### Pré-requisitos

- Node.js 16+
- npm

### Setup

```bash
cd backend
npm install
```

### Configurar ambiente (opcional)

Crie um arquivo `.env` para customizar:

```
PORT=3002
NODE_ENV=development
ALLOWED_ORIGINS=http://localhost:3000
```

### Iniciar servidor

**Desenvolvimento** (com auto-reload):
```bash
npm run dev
```

**Produção**:
```bash
npm start
```

Servidor roda em `http://localhost:3002`

---

## Autenticação

Todas as rotas de negócio são protegidas por **NIP-98 HTTP Auth** (assinatura Nostr).

Cada request deve incluir um header `Authorization` com um evento Nostr kind 27235 assinado, contendo a URL e o método HTTP.

Única rota pública: `GET /health`

Ver `middleware/verifyNip98Auth.js` para detalhes.

---

## Endpoints

### Health Check
- **GET** `/health` — Status do servidor (público, sem auth)

### Orders

- **POST** `/orders/create` — Criar nova ordem
- **GET** `/orders/:orderId` — Buscar ordem por ID
- **GET** `/orders/user/:userId` — Listar ordens de um usuário
- **POST** `/orders/:orderId/cancel` — Cancelar ordem (apenas `pending`)
- **GET** `/orders/available?providerId=xxx` — Listar ordens disponíveis para provedores
- **POST** `/orders/:orderId/accept` — Provedor aceita ordem
- **POST** `/orders/:orderId/submit-proof` — Provedor envia comprovante
- **POST** `/orders/:orderId/validate` — Validar pagamento (aprovar/rejeitar)

### Collateral (Garantias)

- **POST** `/collateral/deposit` — Criar invoice para depósito de garantia
- **POST** `/collateral/lock` — Bloquear garantia ao aceitar ordem
- **POST** `/collateral/unlock` — Desbloquear garantia após conclusão
- **GET** `/collateral/:providerId` — Consultar garantia do provedor

### Escrow

- **POST** `/escrow/create` — Criar escrow com Bitcoin do usuário
- **POST** `/escrow/release` — Liberar Bitcoin do escrow para provedor
- **GET** `/escrow/:orderId` — Consultar status do escrow

### Agent (Disputas)

- **POST/GET** `/agent/*` — Endpoints do agente automático de disputas

---

## Segurança

O backend já implementa:

- **Helmet** — Headers de segurança HTTP
- **Rate Limiting** — 200 req/15min geral, 5 req/min para criação de ordens/collateral/escrow
- **CORS** — Origens configuráveis via `ALLOWED_ORIGINS` (obrigatório em produção)
- **NIP-98 Auth** — Autenticação via assinatura Nostr em todas as rotas de negócio
- **Body limit** — Máximo 5MB por request

---

## Funcionalidades Automáticas

### Expiração de Ordens

- Job roda **a cada 5 minutos** via `node-cron`
- Ordens `pending` há mais de 24h são expiradas automaticamente
- Refund automático do Bitcoin em escrow

### Agente de Disputas

- Serviço automático para mediação de disputas entre usuário e provedor
- Ver `services/disputeAgentService.js`

---

## Estrutura de Status

```
pending → accepted → payment_submitted → completed
   ↓                                         ↓
cancelled/expired                         rejected
```

- `pending` — Aguardando provedor aceitar (24h)
- `accepted` — Provedor aceitou, vai pagar a conta
- `payment_submitted` — Comprovante enviado
- `completed` — Pagamento aprovado, Bitcoin liberado
- `rejected` — Pagamento rejeitado na validação
- `cancelled` — Usuário cancelou
- `expired` — 24h sem aceitação

---

## Fees

- **Provedor**: 3%
- **Plataforma**: 2%
- **Total**: 5% sobre o valor da ordem (descontado ao liberar escrow)

---

## Banco de Dados

Atualmente usa **banco em memória** (`Map` do JavaScript) para desenvolvimento.

Para produção, substituir em `models/database.js` por MongoDB, PostgreSQL ou equivalente.

---

## Estrutura do Projeto

```
backend/
├── server.js                    # Entry point, middlewares, rotas
├── middleware/
│   └── verifyNip98Auth.js       # Autenticação NIP-98
├── models/
│   └── database.js              # Banco em memória
├── routes/
│   ├── orders.js                # CRUD de ordens
│   ├── collateral.js            # Garantias de provedores
│   ├── escrow.js                # Escrow de Bitcoin
│   └── agent.js                 # Agente de disputas
└── services/
    ├── bitcoinService.js        # Integração Bitcoin/Lightning
    ├── disputeAgentService.js   # Mediação automática
    ├── nostrListenerService.js  # Listener de eventos Nostr
    └── orderExpirationService.js # Job de expiração
```

---

## Troubleshooting

**Porta 3002 em uso:**
```bash
# Windows
netstat -ano | findstr :3002
taskkill /PID <número> /F

# Linux/Mac
lsof -ti:3002 | xargs kill -9
```

**Módulos não encontrados:**
```bash
rm -rf node_modules package-lock.json
npm install
```

---

## Mais informações

- [Especificação do protocolo Bro](../specs/) — BROSPEC-01 a 06
- [README principal](../README.md) — Visão geral do projeto
- [CONTRIBUTING](../CONTRIBUTING.md) — Como contribuir
