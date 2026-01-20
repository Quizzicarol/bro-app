<h1 align="center">🟢 Bro</h1>

<p align="center">
  <strong>O app de escambo digital via Nostr</strong><br>
  Pague contas, troque produtos ou serviços. Sem bancos. Sem dados.
</p>

<p align="center">
  <a href="https://testflight.apple.com/join/rkHbPQ94">
    <img src="https://img.shields.io/badge/TestFlight_Beta-0D96F6?style=for-the-badge&logo=apple&logoColor=white" alt="TestFlight">
  </a>
  <a href="https://api.codemagic.io/artifacts/2fa39094-261b-4c42-a832-ae89dc8b21fe/206f592d-63e5-456b-819b-8273a22a265e/app-release.apk">
    <img src="https://img.shields.io/badge/Android_APK-3DDC84?style=for-the-badge&logo=android&logoColor=white" alt="Android APK">
  </a>
</p>

<p align="center">
    <img src="https://img.shields.io/badge/Lightning-792EE5?style=flat-square&logo=lightning&logoColor=white" alt="Lightning">
  <img src="https://img.shields.io/badge/Nostr-8B5CF6?style=flat-square&logo=nostr&logoColor=white" alt="Nostr">
  <img src="https://img.shields.io/badge/License-MIT-green?style=flat-square" alt="License">
</p>

<p align="center">
  <a href="https://www.brostr.app">Website</a> •
  <a href="#features">Features</a> •
  <a href="#download">Download</a> •
  <a href="#architecture">Architecture</a> •
  <a href="#contributing">Contributing</a>
</p>

---

## 📖 About

**Bro** é uma plataforma P2P que permite pagar boletos, código pix e contas usando Bitcoin via Lightning Network e Nostr, sem precisar de bancos ou intermediários.

Como funciona:
1. 📸 **Escaneie** seu boleto ou código PIX
2. ⚡ **Pague** com Bitcoin via Lightning
3. ✅ **Pronto** — um provedor da comunidade efetua o pagamento e te envia o comprovante
4. 🔍 **Verifique** o pagamento no seu banco ou app

Tudo isso de forma privada, apoiado em Bitcoin e comunicação descentralizada via **Nostr**.

---

## ✨ Features

<table>
<tr>
<td width="50%">

### 👤 Para Usuários

- ⚡ Pague boletos e PIX com Bitcoin
- 📸 Scanner de código de barras e QR Code
- 🔐 Carteira Lightning self-custodial
- 📊 Acompanhamento em tempo real
- 📜 Histórico de transações
- 🔑 Login com chave Nostr (nsec)

</td>
<td width="50%">

### 💼 Para Provedores

- 📥 Receba ordens de pagamento
- 💰 Ganhe spread nas transações
- 🔒 Sistema de garantia (colateral)
- 📈 Dashboard de acompanhamento


</td>
</tr>
</table>

---

## 🤔 Por que usar o Bro?

> **Sem taxas para a plataforma.** Um protocolo que conecta pessoas e facilita a vida.

| | |
|:---:|---|
| **🔄 Troca Fácil** | Publique o que você tem, encontre o que você quer. Simples assim. |
| **🔒 Seguro** | Trocas privadas via Nostr sem intermediários. |
| **👥 Comunidade** | Troque e pague contas com quem você confia. |
| **🌐 Descentralizado** | Sem servidores centrais, você decide onde armazenar seus dados. |
| **📖 Open Source** | Código aberto e transparente para todos. |
| **🕵️ Privacidade** | O Bro não exige registro, números de telefone ou informações pessoais. |
| **⚡ Lightning** | Pagamentos instantâneos via Bitcoin Lightning Network. |
| **🔐 Self-Custodial** | Suas chaves, seu Bitcoin. Você controla seus fundos. |

---

## 📱 Download

<p align="center">
  <strong>🍎 Disponível em TestFlight</strong>
</p>

| Plataforma | Link | Status |
|------------|------|--------|
| 🍎 iOS Beta | [TestFlight](https://testflight.apple.com/join/rkHbPQ94) | ✅ Disponível |
| 🤖 Android Beta | [Download APK](https://api.codemagic.io/artifacts/2fa39094-261b-4c42-a832-ae89dc8b21fe/206f592d-63e5-456b-819b-8273a22a265e/app-release.apk) | ✅ Disponível |
| 🤖 Google Play | Em breve | 🔜 Aguardando |
| 🍎 iOS App Store | Em breve | 🔜 Aguardando |

---

## 🏗 Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        BRO APP                              │
├─────────────────────────────────────────────────────────────┤
│  UI Layer (Flutter)                                         │
│  ├── Screens (Home, Wallet, Orders, Settings)               │
│  ├── Widgets (Reusable Components)                          │
│  └── Theme (Dark/Light Mode)                                │
├─────────────────────────────────────────────────────────────┤
│  State Management (Provider)                                │
│  ├── WalletProvider (Balance, Transactions)                 │
│  ├── OrderProvider (P2P Orders)                             │
│  └── AuthProvider (Nostr Keys)                              │
├─────────────────────────────────────────────────────────────┤
│  Services Layer                                             │
│  ├── BreezService (Lightning Network)                       │
│  ├── NostrService (P2P Communication)                       │
│  ├── StorageService (Secure Local Storage)                  │
│  └── ScannerService (Barcode/QR)                            │
├─────────────────────────────────────────────────────────────┤
│  External                                                   │
│  ├── Breez SDK Spark (Self-custodial Lightning)             │
│  ├── Nostr Relays (Decentralized Messaging)                 │
│  └── Backend (Order Matching)                               │
└─────────────────────────────────────────────────────────────┘
```

### Tech Stack

| Layer | Technology |
|-------|------------|
| **Framework** | Flutter 3.x / Dart |
| **Lightning** | [Breez SDK Spark](https://breez.technology/sdk/) (self-custodial) |
| **Protocol** | [Nostr](https://nostr.com/) (NIPs 01, 04) |
| **State** | Provider + ChangeNotifier |
| **Storage** | SharedPreferences + FlutterSecureStorage |
| **CI/CD** | Codemagic |
| **Distribution** | App Store, Google Play, TestFlight |

---

## 🚀 Development

### Prerequisites

- Flutter 3.19+ ([Install](https://docs.flutter.dev/get-started/install))
- Dart 3.3+
- Android Studio / VS Code
- Xcode 15+ (para iOS)

### Quick Start

```bash
# Clone
git clone https://github.com/Quizzicarol/Bro.git
cd bro_app

# Install dependencies
flutter pub get

# Run
flutter run
```

### Build

```bash
# Android Release
flutter build apk --release

# iOS Release
flutter build ios --release

# Build Runner (if needed)
flutter pub run build_runner build
```

### Project Structure

```
lib/
├── main.dart                 # App entry point
├── config.dart               # Environment configuration
├── models/                   # Data models
│   ├── order.dart
│   ├── transaction.dart
│   └── user.dart
├── providers/                # State management
│   ├── wallet_provider.dart
│   └── order_provider.dart
├── screens/                  # UI screens
│   ├── home_screen.dart
│   ├── wallet_screen.dart
│   ├── orders_screen.dart
│   └── settings_screen.dart
├── services/                 # Business logic
│   ├── breez_service.dart    # Lightning Network
│   ├── nostr_service.dart    # P2P communication
│   └── storage_service.dart  # Local storage
├── theme/                    # App theming
│   ├── bro_colors.dart
│   └── bro_theme.dart
└── widgets/                  # Reusable components
```

---

## 🤝 Contributing

Contribuições são bem-vindas! 

---

## 📄 License

Distribuído sob a licença MIT. Veja [LICENSE](LICENSE) para mais informações.

---

## 📞 Contact

- 🌐 Website: [brostr.app](https://www.brostr.app)
- 🐙 GitHub: [@Quizzicarol](https://github.com/Quizzicarol)
- ⚡ Nostr: `npub...`

---

<p align="center">
  <strong>Quem tem Bro, tem tudo.</strong> 🟢⚡
</p>

<p align="center">
  Feito com 💚 para conectar pessoas
</p>
