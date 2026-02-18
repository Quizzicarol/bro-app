# Tela de Depósito (DepositScreen)

## Descrição
Tela completa para depósitos via Lightning Network ou Bitcoin On-chain com cálculo automático de taxas e conversão BRL → Sats.

## Funcionalidades

### 📱 Interface com Tabs
- **Tab Lightning**: Depósitos instantâneos via Lightning Network
- **Tab On-chain**: Depósitos via blockchain Bitcoin

### ⚡ Tab Lightning

#### Features:
1. **Input de Valor**
   - Campo para inserir valor em BRL
   - Conversão automática para Sats em tempo real
   - Validação de valor mínimo

2. **Breakdown de Taxas** (via `FeeBreakdownCard`)
   - Valor da conta
   - Taxa do provedor (7%)
   - Taxa da plataforma (2%)
   - Total a depositar
   - Conversão BRL → Sats para cada item

3. **Geração de Invoice**
   - Botão "Gerar Invoice Lightning"
   - Loading state durante geração
   - Integração com backend `/api/lightning/create-invoice`

4. **Exibição de Invoice**
   - QR Code (usando `qr_flutter`)
   - String da invoice (copiável)
   - Botão de copiar com feedback visual

5. **Polling de Pagamento**
   - Verifica pagamento a cada 3 segundos
   - Notificação de sucesso ao receber
   - Atualização automática do saldo
   - Opção de cancelar

### 🔗 Tab On-chain

#### Features:
1. **Input de Valor**
   - Mesmo sistema da tab Lightning
   - Conversão BRL → Sats

2. **Breakdown de Taxas**
   - Mesmo formato da tab Lightning
   - Adicional: Estimativa de taxa de rede Bitcoin
   - Exibição em BTC e Sats

3. **Informações Adicionais**
   - Card informativo com taxa de rede estimada
   - Aviso sobre confirmações necessárias (1 confirmação)

4. **Geração de Endereço**
   - Botão "Gerar Endereço Bitcoin"
   - Loading state durante geração
   - Integração com backend `/api/bitcoin/create-address`

5. **Exibição de Endereço**
   - QR Code (formato BIP21: `bitcoin:address?amount=X`)
   - String do endereço (copiável)
   - Botão de copiar com feedback visual

6. **Polling de Confirmações**
   - Verifica confirmações a cada 30 segundos
   - Notificação ao receber primeira confirmação
   - Atualização automática do saldo
   - Opção de cancelar

## Widgets Auxiliares

### 📊 FeeBreakdownCard

Widget reutilizável para exibir breakdown de taxas.

#### Props:
```dart
FeeBreakdownCard({
  required double accountValue,          // Valor da conta em BRL
  required double providerFee,           // Taxa do provedor em BRL
  required double providerFeePercent,    // Percentual da taxa do provedor
  required double platformFee,           // Taxa da plataforma em BRL
  required double platformFeePercent,    // Percentual da taxa da plataforma
  required double totalBrl,              // Total em BRL
  required int totalSats,                // Total em Sats
  required double brlToSatsRate,         // Taxa de conversão BRL → Sats
  double? networkFee,                    // Taxa de rede (opcional, para on-chain)
})
```

#### Features:
- Exibição clara de cada taxa
- Total destacado em negrito
- Conversão BRL → Sats para cada valor
- Ícone informativo
- Card de informação sobre taxa de conversão
- Suporte opcional para taxa de rede Bitcoin

## Integração com Backend

### Endpoints Necessários

#### 1. POST `/api/lightning/create-invoice`
```json
Request:
{
  "amountSats": 10000,
  "description": "Depósito Paga Conta - R$ 100.00"
}

Response:
{
  "invoice": "lnbc100n1...",
  "paymentHash": "abc123..."
}
```

#### 2. GET `/api/lightning/payment-status/:paymentHash`
```json
Response:
{
  "paid": true,
  "payment": {
    "paymentHash": "abc123...",
    "status": "complete",
    "amount": 10000
  }
}
```

#### 3. POST `/api/bitcoin/create-address`
```json
Request:
{
  "amountSats": 10000
}

Response:
{
  "address": "bc1q...",
  "minAllowedDeposit": 5000,
  "maxAllowedDeposit": 100000000
}
```

#### 4. GET `/api/bitcoin/address-status/:address`
```json
Response:
{
  "address": "bc1q...",
  "confirmations": 1,
  "received": 10000
}
```

## Providers Utilizados

### BreezProvider

Métodos necessários:
- `createInvoice({required int amountSats, String? description})`
- `checkPaymentStatus(String paymentHash)`
- `createBitcoinAddress({required int amountSats})`
- `checkAddressStatus(String address)`
- `refreshBalance()`

### OrderProvider
- Pode ser usado para registrar depósitos no histórico

## Configurações

### Taxas
```dart
final double _providerFeePercent = 7.0;   // 7% taxa do provedor
final double _platformFeePercent = 2.0;   // 2% taxa da plataforma
```

### Polling
```dart
// Lightning: 3 segundos
Timer.periodic(Duration(seconds: 3), ...)

// On-chain: 30 segundos
Timer.periodic(Duration(seconds: 30), ...)
```

### Taxa de Conversão
```dart
double _brlToSatsRate = 100.0;  // Mock: 1 BRL = 100 sats
// TODO: Buscar taxa real do backend/API
```

## Como Usar

### 1. Adicionar ao Router
```dart
import 'package:paga_conta_mobile/screens/deposit_screen.dart';

// No router
'/deposit': (context) => const DepositScreen(),
```

### 2. Navegar para a Tela
```dart
Navigator.pushNamed(context, '/deposit');
```

### 3. Exemplo Completo
```dart
// Em qualquer tela
ElevatedButton(
  onPressed: () {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const DepositScreen(),
      ),
    );
  },
  child: const Text('Depositar'),
)
```

## TODO / Melhorias Futuras

### Backend Integration
- [ ] Implementar integração real com `/api/lightning/create-invoice`
- [ ] Implementar integração real com `/api/bitcoin/create-address`
- [ ] Buscar taxa de conversão BRL/BTC em tempo real
- [ ] Buscar estimativa de taxa de rede Bitcoin

### Validações
- [ ] Validar valor mínimo/máximo para depósito
- [ ] Validar limites do swap on-chain
- [ ] Adicionar confirmação antes de gerar invoice/endereço

### UX
- [ ] Adicionar animações de transição
- [ ] Melhorar feedback visual durante polling
- [ ] Adicionar histórico de depósitos
- [ ] Suportar múltiplas moedas fiduciárias

### Performance
- [ ] Implementar debounce no input de valor
- [ ] Cache de taxa de conversão
- [ ] Otimizar polling (usar WebSocket se disponível)

## Dependências

```yaml
dependencies:
  flutter:
    sdk: flutter
  provider: ^6.1.1
  qr_flutter: ^4.1.0
```

## Notas Técnicas

1. **Memory Leaks**: Os timers de polling são cancelados no `dispose()` para evitar memory leaks
2. **State Management**: Usa `setState()` local para UI reativa
3. **Error Handling**: Tratamento de erros com SnackBar para feedback ao usuário
4. **Clipboard**: Usa `Clipboard.setData()` para copiar invoice/endereço
5. **QR Codes**: Formato padrão Lightning BOLT11 e BIP21 para Bitcoin

## Screenshots

### Tab Lightning
```
┌─────────────────────────────────┐
│  Lightning    On-chain          │
├─────────────────────────────────┤
│                                 │
│  Valor do Depósito              │
│  ┌───────────────────────────┐  │
│  │ R$ 100.00                 │  │
│  │ ≈ 10000 sats              │  │
│  └───────────────────────────┘  │
│                                 │
│  Detalhamento de Taxas          │
│  Valor da conta    R$ 100.00    │
│                    10000 sats   │
│  Taxa Provedor 7%  R$ 7.00      │
│                    700 sats     │
│  Taxa Plataforma   R$ 2.00      │
│                    200 sats     │
│  ────────────────────────────   │
│  Total            R$ 109.00     │
│                   10900 sats    │
│                                 │
│  [Gerar Invoice Lightning]      │
│                                 │
└─────────────────────────────────┘
```

## Suporte

Para dúvidas ou problemas, consulte:
- Documentação do Breez SDK
- Documentação da API backend
- Issues do repositório
