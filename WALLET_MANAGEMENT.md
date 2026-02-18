# Bro App - Gerenciamento de Carteira Lightning ⚡

## 📍 Para Onde Vão os Pagamentos?

### Arquitetura do Breez SDK Spark (Nodeless)

O Bro App usa o **Breez SDK Spark** (também chamado de "Nodeless") para processar pagamentos Lightning.

**Como funciona:**
1. Cada dispositivo que roda o app tem sua **própria carteira Lightning**
2. A carteira é derivada do **mnemonic (seed)** gerado na primeira execução
3. O seed fica salvo localmente no dispositivo (via `StorageService`)
4. Os fundos recebidos ficam **na carteira local do dispositivo**

### 🔑 Chave API (Certificado)

O certificado do Breez SDK é configurado via `env.json`.
Veja `env.example.json` para o formato.

O certificado (`breezApiKey`) apenas **autoriza** o uso do serviço Breez, mas **não controla os fundos**. Os fundos são controlados pelo mnemonic do dispositivo.

---

## 💰 Onde Estão os Saldos?

### Cada Instalação = Carteira Diferente

| Dispositivo/Projeto | Carteira | Status |
|---------------------|----------|--------|
| Dispositivo principal | Carteira do dispositivo | ✅ Ativa |
| Instalações anteriores | Carteiras separadas | ⚠️ Podem ter saldo |
| Qualquer outro telefone | Nova carteira | Separada |

### Como Ver o Saldo

O saldo pode ser verificado:
1. **No app**: Via `BreezProvider.getBalance()`
2. **Tela de Admin**: Use a nova tela de administração (ver abaixo)

---

## 🔄 Como Recuperar Saldo de Outros Dispositivos

### Opção 1: Exportar/Importar Mnemonic

1. **No dispositivo antigo**: Encontre o mnemonic salvo
2. **No novo dispositivo**: Importe o mesmo mnemonic

```dart
// Recuperar seed salvo
final seed = await StorageService().getBreezMnemonic();
print('Seed: $seed'); // 12-24 palavras
```

### Opção 2: Enviar Saldo para Nova Carteira

1. Na carteira antiga: Pegue o saldo via `getBalance()`
2. Na carteira nova: Gere um endereço Lightning ou Bitcoin
3. Na carteira antiga: Envie para o endereço novo

---

## 📱 Gerar Endereços para Receber

### Endereço Lightning (Invoice)

```dart
final result = await breezProvider.createInvoice(
  amountSats: 10000, // ou qualquer valor
  description: 'Recebimento de taxas',
);
final invoice = result?['invoice']; // bolt11 string
```

### Endereço Bitcoin On-Chain

```dart
final result = await breezProvider.createOnchainAddress();
final address = result?['swap']['bitcoinAddress'];
```

**Nota**: Depósitos on-chain são convertidos automaticamente para Lightning via swap (pode ter taxa adicional).

---

## 🏦 Taxas e Receita do Provedor

### Como Funciona a Taxa de 5%

1. Cliente paga R$ 100 para conta de energia
2. Provedor recebe **R$ 95** (após taxa)
3. **Taxa de R$ 5** fica com o provedor que processou

### Onde Fica a Taxa?

No modelo atual (P2P direto):
- O pagamento vai **direto para o provedor**
- A taxa é **calculada**, mas não retida automaticamente

### Para Reter Taxas (Modelo Escrow)

No modo escrow (quando implementado):
1. Cliente paga para **carteira do escrow**
2. Escrow retém a taxa (5%)
3. Escrow libera o restante para o provedor
4. Taxa acumulada pode ser retirada pelo administrador

---

## 🛠️ Tela de Administração

Foi criada uma nova tela de administração (`admin_wallet_screen.dart`) que permite:

- ✅ Ver saldo atual da carteira
- ✅ Gerar endereço Bitcoin on-chain
- ✅ Gerar invoice Lightning
- ✅ Ver histórico de pagamentos
- ✅ Ver/Copiar mnemonic (backup)

Acesse via: Settings > Opções Avançadas > Admin Wallet

---

## ⚠️ Importante

### Segurança do Mnemonic
- O mnemonic (seed de 12-24 palavras) é a **única forma de recuperar fundos**
- **NUNCA** compartilhe o mnemonic
- Faça **backup** em local seguro (offline)
- Se perder o mnemonic, perde os fundos

### Testnet vs Mainnet
```dart
// No arquivo config/breez_config.dart
static const bool useMainnet = true; // MAINNET = Bitcoin REAL!
```

⚠️ **ATENÇÃO**: O app está configurado para **MAINNET**, ou seja, transações são com **Bitcoin REAL** e são **irreversíveis**!

---

## 📊 Comandos Úteis (Debug)

```dart
// Ver saldo
final balance = await breezProvider.getBalance();
print('Saldo: ${balance['balance']} sats');

// Ver histórico
final payments = await breezProvider.listPayments();
payments.forEach((p) => print('${p['type']}: ${p['amount']} sats'));

// Gerar endereço on-chain
final addr = await breezProvider.createOnchainAddress();
print('Bitcoin Address: ${addr['swap']['bitcoinAddress']}');

// Criar invoice
final invoice = await breezProvider.createInvoice(amountSats: 1000);
print('Invoice: ${invoice['invoice']}');
```

---

## 🔗 Links Úteis

- [Breez SDK Docs](https://sdk-doc.breez.technology/)
- [Breez SDK Flutter](https://github.com/breez/breez-sdk-flutter)
- [Lightning Network](https://lightning.network/)
