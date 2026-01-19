# 🟢 Bro

> **O app de escambo digital via Nostr**

Comunidade de trocas simples, seguras e privadas. Como um aperto de mão entre amigos.

Publique o que você tem, encontre o que você quer. Pague contas com Bitcoin via Lightning. Sem bancos, sem intermediários.

🌐 **Site:** [brostr.app](https://www.brostr.app)

---

## ✨ Por que usar o Bro?

| | |
|---|---|
| 🔄 **Troca Fácil** | Publique o que você tem, encontre o que você quer. Simples assim. |
| 🔒 **Seguro** | Trocas privadas via Nostr sem intermediários. |
| 👥 **Comunidade** | Troque e pague contas com quem você confia. |
| 🌐 **Descentralizado** | Sem servidores centrais, você decide onde armazenar seus dados. |
| 📖 **Open Source** | Código aberto e transparente para todos. |
| 🕵️ **Privacidade** | Sem registro, sem número de telefone, sem dados pessoais. |

---

## 📱 Funcionalidades

### Para Usuários
- ⚡ Pague boletos e PIX com Bitcoin via Lightning Network
- 📸 Escaneie códigos de barras e QR codes
- 📊 Acompanhe status dos pagamentos em tempo real
- 📜 Histórico completo de transações

### Para Provedores
- 💼 Aceite ordens de pagamento da comunidade
- 🔐 Deposite garantia para operar (modelo trustless)
- ₿ Receba pagamentos em Bitcoin
- 📈 Dashboard com estatísticas

---

## 🛠 Tecnologias

| Tecnologia | Uso |
|------------|-----|
| **Flutter** | Framework mobile multiplataforma |
| **Breez SDK Spark** | Lightning Network (self-custodial) |
| **Nostr** | Comunicação P2P descentralizada |
| **Provider** | Gerenciamento de estado |

---

## 🚀 Como Rodar

### Pré-requisitos
- Flutter 3.0+
- Android Studio ou VS Code

### Instalação

```bash
# Clone o repositório
git clone https://github.com/Quizzicarol/Bro.git
cd bro_app

# Instale as dependências
flutter pub get

# Rode o app
flutter run
```

### Build

```bash
# Android APK
flutter build apk --release

# iOS
flutter build ios --release
```

---

## 📁 Estrutura do Projeto

```
lib/
├── main.dart            # Entry point
├── config.dart          # Configurações
├── models/              # Modelos de dados
├── providers/           # State management
├── screens/             # Telas do app
├── services/            # Serviços (Nostr, Lightning, Storage)
├── theme/               # Tema e cores
└── widgets/             # Componentes reutilizáveis
```

---

## 🤝 Contribuindo

1. Fork o projeto
2. Crie sua branch (`git checkout -b feature/nova-feature`)
3. Commit suas mudanças (`git commit -m 'Add nova feature'`)
4. Push para a branch (`git push origin feature/nova-feature`)
5. Abra um Pull Request

---

## 📄 Licença

MIT License

---

**Quem tem Bro, tem tudo.** 🟢⚡

Feito com 💚 para conectar pessoas.
