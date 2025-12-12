# Backend - Paga Conta

Backend Node.js para o sistema de escrow com Bitcoin do Paga Conta.

## 🚀 Instalação

### Pré-requisitos

- Node.js 16+ instalado
- npm ou yarn

### Passo 1: Instalar dependências

```bash
cd backend
npm install
```

### Passo 2: Configurar ambiente (opcional)

Crie um arquivo `.env` se quiser customizar a porta:

```
PORT=3002
```

### Passo 3: Iniciar servidor

**Modo desenvolvimento** (com auto-reload):
```bash
npm run dev
```

**Modo produção**:
```bash
npm start
```

O servidor estará rodando em `http://localhost:3002`

---

## 📡 Endpoints Disponíveis

### Health Check
- **GET** `/health` - Verificar status do servidor

### Orders (Ordens)

- **POST** `/orders/create` - Criar nova ordem após pagamento Lightning
  ```json
  {
    "userId": "string",
    "paymentHash": "string",
    "paymentType": "electricity|water|internet|gas|phone",
    "accountNumber": "string",
    "billValue": 150.50,
    "btcAmount": 0.00027
  }
  ```

- **GET** `/orders/:orderId` - Buscar ordem por ID

- **GET** `/orders/user/:userId` - Listar todas as ordens de um usuário

- **POST** `/orders/:orderId/cancel` - Cancelar ordem (apenas pending)
  ```json
  {
    "userId": "string"
  }
  ```

- **GET** `/orders/available?providerId=xxx` - Listar ordens disponíveis para provedores

- **POST** `/orders/:orderId/accept` - Provedor aceita ordem
  ```json
  {
    "providerId": "string",
    "collateralLocked": 1500
  }
  ```

- **POST** `/orders/:orderId/submit-proof` - Provedor envia comprovante de pagamento
  ```json
  {
    "providerId": "string",
    "proofUrl": "string",
    "proofData": {}
  }
  ```

- **POST** `/orders/:orderId/validate` - Validar pagamento (aprovar/rejeitar)
  ```json
  {
    "approved": true,
    "rejectionReason": "string (opcional)"
  }
  ```

### Collateral (Garantias de Provedores)

- **POST** `/collateral/deposit` - Criar invoice para depósito de garantia
  ```json
  {
    "providerId": "string",
    "tierId": "basic|intermediate|advanced",
    "amountBrl": 500,
    "amountSats": 89820
  }
  ```

- **POST** `/collateral/lock` - Bloquear garantia ao aceitar ordem
  ```json
  {
    "providerId": "string",
    "orderId": "string",
    "lockedSats": 1500
  }
  ```

- **POST** `/collateral/unlock` - Desbloquear garantia após conclusão
  ```json
  {
    "providerId": "string",
    "orderId": "string"
  }
  ```

- **GET** `/collateral/:providerId` - Consultar garantia total do provedor

### Escrow (Bitcoin em Custódia)

- **POST** `/escrow/create` - Criar escrow com Bitcoin do usuário
  ```json
  {
    "orderId": "string",
    "userId": "string",
    "btcAmount": 0.00027
  }
  ```

- **POST** `/escrow/release` - Liberar Bitcoin do escrow para provedor
  ```json
  {
    "orderId": "string",
    "providerId": "string"
  }
  ```

- **GET** `/escrow/:orderId` - Consultar status do escrow

---

## ⚙️ Funcionalidades Automáticas

### Job de Expiração de Ordens

- Roda **a cada 5 minutos** automaticamente
- Verifica ordens no estado `pending` que passaram de 24 horas
- Processa refund automático do Bitcoin
- Atualiza status para `expired`

Logs:
```
[CRON] Verificando ordens expiradas...
⏰ Ordem expirada detectada: abc-123
💰 Processando refund: abc-123 | Valor: 0.00027 BTC
✅ Refund concluído: abc-123
✅ 1 ordem(ns) expirada(s) processada(s)
```

---

## 🗃️ Banco de Dados

Atualmente usando **banco em memória** (Map do JavaScript) para desenvolvimento rápido.

**Para produção**, substituir por:
- **MongoDB** - NoSQL, ideal para JSON
- **PostgreSQL** - SQL, ideal para transações
- **Redis** - Cache rápido

Arquivos a modificar:
- `models/database.js` - Conexão e schemas
- `routes/*.js` - Trocar `Map` por queries do BD

---

## 📊 Estrutura de Status das Ordens

```
pending → accepted → payment_submitted → completed
   ↓                                           ↓
cancelled/expired                         rejected
```

### Status possíveis:
- `pending` - Aguardando provedor aceitar (24h)
- `accepted` - Provedor aceitou e vai pagar a conta
- `payment_submitted` - Provedor enviou comprovante
- `completed` - Pagamento aprovado, Bitcoin liberado
- `rejected` - Pagamento rejeitado na validação
- `cancelled` - Usuário cancelou antes de aceitar
- `expired` - Passou 24h sem provedor aceitar

---

## 💰 Estrutura de Fees

- **Provedor**: 3% (descontado do Bitcoin ao liberar escrow)
- **Plataforma**: 2% (descontado do Bitcoin ao liberar escrow)
- **Total**: 5% de fee sobre o valor da ordem

Exemplo:
- Ordem de R$ 150 = 0.00027 BTC
- Provedor recebe: 0.0002565 BTC (95%)
- Plataforma recebe: 0.0000054 BTC (2%)

---

## 🔐 Segurança (TODO para produção)

- [ ] Adicionar autenticação JWT nos endpoints
- [ ] Validar assinaturas das requisições
- [ ] Rate limiting para evitar spam
- [ ] HTTPS obrigatório
- [ ] Logs de auditoria
- [ ] Backup automático do banco de dados
- [ ] Monitoramento de transações suspeitas

---

## 🐛 Debug

**Ver logs em tempo real:**
```bash
npm run dev
```

**Testar endpoint:**
```bash
curl http://localhost:3002/health
```

**Ver todas as ordens em memória:**
- Endpoints GET retornam o estado atual
- Logs no terminal mostram todas as operações

---

## 📝 Próximos Passos

1. ✅ Estrutura básica com 13 endpoints
2. ✅ Job de expiração automático
3. ✅ Sistema de fees (3% + 2%)
4. ⏳ Integrar com Breez SDK para pagamentos reais
5. ⏳ Implementar banco de dados persistente
6. ⏳ Sistema de autenticação
7. ⏳ Upload de comprovantes (S3/Firebase)
8. ⏳ OCR para validação automática de recibos
9. ⏳ Painel administrativo

---

## 🆘 Problemas Comuns

**Porta 3002 já em uso:**
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

**Servidor não inicia:**
- Verificar Node.js versão 16+: `node --version`
- Verificar erros no console
- Verificar se `package.json` existe

---

## 📞 Suporte

Para dúvidas sobre integração com o app Flutter, consulte:
- `../FLUXO_COMPLETO_ORDENS.md` - Documentação do fluxo completo
- Logs do servidor mostram todas as operações em tempo real
