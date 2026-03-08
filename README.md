<p align="center">
  <img src="https://github.com/Brostr/bro/blob/main/assets/images/bro-logo.png?raw=true" alt="Bro Logo" width="200">
</p>

<p align="center">
  <strong>Pay bills with Bitcoin. No banks. No KYC.</strong><br>
  A peer-to-peer protocol for exchanging Bitcoin (Lightning) for fiat payments, built on Nostr.
</p>

<p align="center">
  <a href="https://testflight.apple.com/join/rkHbPQ94">
    <img src="https://img.shields.io/badge/TestFlight_Beta-0D96F6?style=for-the-badge&logo=apple&logoColor=white" alt="TestFlight">
  </a>
  <a href="https://github.com/Brostr/bro/releases">
    <img src="https://img.shields.io/badge/Android_APK-3DDC84?style=for-the-badge&logo=android&logoColor=white" alt="Android APK">
  </a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Lightning-792EE5?style=flat-square&logo=lightning&logoColor=white" alt="Lightning">
  <img src="https://img.shields.io/badge/Nostr-8B5CF6?style=flat-square&logo=nostr&logoColor=white" alt="Nostr">
  <img src="https://img.shields.io/badge/License-MIT-green?style=flat-square" alt="License">
  <img src="https://img.shields.io/badge/Flutter-02569B?style=flat-square&logo=flutter&logoColor=white" alt="Flutter">
</p>

<p align="center">
  <a href="https://www.brostr.app">Website</a> •
  <a href="#how-it-works">How It Works</a> •
  <a href="#download">Download</a> •
  <a href="#architecture">Architecture</a> •
  <a href="CONTRIBUTING.md">Contributing</a> •
  <a href="SECURITY.md">Security</a>
</p>

---

## About

**Bro** is an open P2P protocol that lets anyone pay bills (PIX, Boleto, TED) using Bitcoin via the Lightning Network. Communication between users and providers happens entirely over **Nostr** — no central server, no accounts, no KYC.

### How It Works

1. **Scan** your bill (barcode or PIX QR code)
2. **Pay** with Bitcoin via Lightning
3. **Done** — a community provider executes the fiat payment and sends you the receipt
4. **Verify** the payment in your banking app

All communication is encrypted (NIP-44) and relayed through decentralized Nostr relays.

---

## Features

<table>
<tr>
<td width="50%">

### For Users

- ⚡ Pay PIX, Boleto, and TED bills with Bitcoin
- 📸 Barcode & QR code scanner
- 🔐 Self-custodial Lightning wallet (Breez Spark)
- 📊 Real-time order tracking
- 📜 Transaction history
- 🔑 Login with Nostr key (nsec) or BIP-39 seed

</td>
<td width="50%">

### For Providers (Bros)

- 📥 Accept payment orders from the network
- 💰 Earn fees on every transaction (5%)
- 🔒 Collateral tiers (Trial → Master)
- 📈 Marketplace reviews and ratings
- 🤖 Auto-liquidation after 36h confirmation timeout
- 🛡️ AI-assisted dispute resolution

</td>
</tr>
</table>

---

## Why Bro?

| | |
|:---:|---|
| **🔒 Private** | No registration, no phone number, no personal data. Your keys, your identity. |
| **🌐 Decentralized** | Built on Nostr — no central servers, no single point of failure. |
| **⚡ Instant** | Lightning payments settle in seconds. |
| **🔐 Self-Custodial** | You hold your own keys and funds at all times. |
| **📖 Open Source** | Fully transparent — audit the code yourself. |
| **🛡️ Secure** | NIP-44 encrypted proofs, NIP-98 authenticated API, event signature verification. |
| **🤝 Trustless** | Collateral system and marketplace reviews minimize counterparty risk. |

---

## Download

| Platform | Link | Status |
|----------|------|--------|
| 🍎 iOS Beta | [TestFlight](https://testflight.apple.com/join/rkHbPQ94) | ✅ Available |
| 🤖 Android | [Releases](https://github.com/Brostr/bro/releases) | ✅ Available |
| 🤖 Google Play | Coming soon | 🔜 |
| 🍎 App Store | Coming soon | 🔜 |

---

## Protocol

Bro defines a set of custom Nostr event kinds for P2P order management:

| Kind | Name | Purpose |
|------|------|---------|
| **30078** | Bro Order | User creates a payment order |
| **30079** | Bro Accept | Provider accepts an order |
| **30080** | Bro Update | Status changes, cancellations |
| **30081** | Bro Complete | Provider submits proof of payment |
| **30082** | Bro Provider Profile | Provider capabilities & reputation |

### Order Lifecycle

```
pending → payment_received → accepted → processing → awaiting_confirmation → completed
   ↓           ↓                                              ↓                  ↓
cancelled   cancelled                                     disputed          liquidated
```

Terminal statuses: `completed`, `cancelled`, `liquidated`. Only `disputed` can override a terminal status.

### Nostr NIPs Used

| NIP | Purpose |
|-----|---------|
| [NIP-01](https://github.com/nostr-protocol/nips/blob/master/01.md) | Core protocol & events |
| [NIP-04](https://github.com/nostr-protocol/nips/blob/master/04.md) | Encrypted direct messages (chat) |
| [NIP-05](https://github.com/nostr-protocol/nips/blob/master/05.md) | Provider domain verification |
| [NIP-15](https://github.com/nostr-protocol/nips/blob/master/15.md) | Classifieds marketplace |
| [NIP-19](https://github.com/nostr-protocol/nips/blob/master/19.md) | Entity encoding (npub, nsec) |
| [NIP-33](https://github.com/nostr-protocol/nips/blob/master/33.md) | Parameterized replaceable events |
| [NIP-44](https://github.com/nostr-protocol/nips/blob/master/44.md) | Versioned encryption (proof images) |
| [NIP-98](https://github.com/nostr-protocol/nips/blob/master/98.md) | HTTP authentication (backend API) |

Full protocol specification: [`specs/`](specs/)

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                         BRO APP                              │
├──────────────────────────────────────────────────────────────┤
│  UI Layer (Flutter)                                          │
│  ├── Screens (Home, Wallet, Orders, Marketplace, Settings)   │
│  ├── Widgets (Reusable Components)                           │
│  └── Theme (Dark Mode)                                       │
├──────────────────────────────────────────────────────────────┤
│  State Management (Provider)                                 │
│  ├── WalletProvider    ← Balance, transactions, Lightning    │
│  ├── OrderProvider     ← P2P orders, auto-liquidation        │
│  └── AuthProvider      ← Nostr keys, BIP-39 seed            │
├──────────────────────────────────────────────────────────────┤
│  Services Layer                                              │
│  ├── BreezService      ← Spark SDK (Lightning payments)      │
│  ├── NostrOrderService ← Event publishing/fetching           │
│  ├── NIP44Service      ← E2E encryption for proofs           │
│  ├── BackgroundService ← WorkManager (notifications, auto-liq)│
│  └── ApiService        ← Backend communication (NIP-98)      │
├──────────────────────────────────────────────────────────────┤
│  External                                                    │
│  ├── Breez SDK Spark   ← Self-custodial Lightning wallet     │
│  ├── Breez Liquid      ← Liquid sidechain fallback (Boltz)   │
│  ├── Nostr Relays      ← Decentralized event transport       │
│  └── Backend API       ← Order matching, escrow, disputes    │
└──────────────────────────────────────────────────────────────┘
```

### Tech Stack

| Layer | Technology |
|-------|------------|
| **Framework** | Flutter 3.x / Dart 3.x |
| **Lightning** | [Breez SDK Spark](https://breez.technology/sdk/) (primary) + Liquid (fallback) |
| **Protocol** | [Nostr](https://nostr.com/) (NIPs 01, 04, 05, 15, 19, 33, 44, 98) |
| **Encryption** | NIP-44v2 (XChaCha20-Poly1305) |
| **State** | Provider + ChangeNotifier |
| **Storage** | SharedPreferences + FlutterSecureStorage (encrypted) |
| **Background** | WorkManager (Android) |
| **Backend** | Node.js / Express with NIP-98 auth |
| **CI/CD** | Codemagic → TestFlight + Google Play |

---

## Development

### Prerequisites

- Flutter 3.19+ ([Install](https://docs.flutter.dev/get-started/install))
- Dart 3.3+
- Android Studio or VS Code
- Xcode 15+ (for iOS builds)
- A [Breez SDK](https://breez.technology/sdk/) API key

### Setup

```bash
# Clone the repository
git clone https://github.com/Brostr/bro.git
cd bro

# Install dependencies
flutter pub get

# Create environment config (required)
cat > env.json << EOF
{
  "BREEZ_API_KEY": "your-breez-api-key",
  "PLATFORM_LIGHTNING_ADDRESS": "your@lightning.address",
  "BACKEND_URL": "https://your-backend-url"
}
EOF

# Run in debug mode
flutter run --dart-define-from-file=env.json
```

> **Note:** `env.json` is gitignored and never committed. Get a Breez API key at [breez.technology](https://breez.technology/sdk/).

### Build

```bash
# Android APK (release)
flutter build apk --release --dart-define-from-file=env.json

# iOS (release)
flutter build ipa --release --dart-define-from-file=env.json
```

### Backend

```bash
cd backend
npm install
# Set environment variables (PORT, ALLOWED_ORIGINS, etc.)
node server.js
```

The backend provides order matching, escrow management, and AI dispute resolution. See [`backend/README.md`](backend/README.md).

### Project Structure

```
lib/
├── main.dart                 # App entry point
├── config.dart               # Environment configuration (dart-define)
├── config/                   # Feature configs (Breez, fees, limits)
├── models/                   # Data models (Order, Transaction, User)
├── providers/                # State management
│   ├── order_provider.dart   #   Order lifecycle, auto-liquidation
│   └── wallet_provider.dart  #   Balance, Lightning operations
├── screens/                  # UI screens
│   ├── home_screen.dart
│   ├── wallet_screen.dart
│   ├── orders_screen.dart
│   ├── marketplace_screen.dart
│   └── settings_screen.dart
├── services/                 # Business logic
│   ├── breez_service.dart    #   Lightning Network (Spark SDK)
│   ├── nostr_order_service.dart  # Nostr event publish/fetch
│   ├── nip44_service.dart    #   NIP-44 encryption
│   ├── api_service.dart      #   Backend API (NIP-98)
│   ├── background_notification_service.dart  # WorkManager
│   └── log_utils.dart        #   Production-safe logging
├── theme/                    # App theming
└── widgets/                  # Reusable components
```

---

## Security

Bro takes security seriously. Key protections include:

- **NIP-44v2 encryption** for payment proofs (XChaCha20-Poly1305)
- **NIP-98 HTTP authentication** on all backend API calls
- **Event signature verification** on all incoming Nostr events
- **Dispute authorization** — only order participants can open disputes
- **Future timestamp rejection** (15-min tolerance for clock skew)
- **Clipboard auto-clear** (2 minutes) for sensitive data (seeds, private keys)
- **Auto-liquidation race condition lock** (2-min TTL) between foreground/background
- **Rate limiting** on backend (200 req/15min general, 5 req/min for writes)
- **NSFW detection** on proof images

For details, see [SECURITY.md](SECURITY.md). To report a vulnerability, see [SECURITY.md](SECURITY.md#reporting-a-vulnerability).

---

## Collateral Tiers

Providers deposit collateral (in BRL equivalent via Lightning) to unlock higher order limits:

| Tier | Collateral | Max Order |
|------|-----------|-----------|
| 🧪 Trial | R$ 10 | R$ 10 |
| 🥉 Starter | R$ 50 | R$ 50 |
| 🥈 Basic | R$ 200 | R$ 200 |
| 🥇 Intermediate | R$ 500 | R$ 500 |
| 💎 Advanced | R$ 1,000 | R$ 1,000 |
| 👑 Master | R$ 3,000 | Unlimited |

> **Note:** During the external testing phase, tiers are capped at R$ 200 max.

---

## Reviews & Ratings

Marketplace sellers are rated by buyers on a 3-point scale:

| Rating | Label |
|--------|-------|
| ≥ 2.5 | 👍 Good |
| ≥ 1.5 | 👌 Average |
| < 1.5 | 👎 Poor |

Reviews are published as Nostr events and visible to all users.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on how to contribute.

---

## License

Distributed under the MIT License. See [LICENSE](LICENSE) for details.

---

## Contact

- 🌐 Website: [brostr.app](https://www.brostr.app)
- 🐙 GitHub: [@Brostr](https://github.com/Brostr)
- ⚡ Nostr: Follow us on Nostr for updates

---

<p align="center">
  <strong>Quem tem Bro, tem tudo.</strong> 🟢⚡
</p>

<p align="center">
  Built with 💚 to connect people
</p>
