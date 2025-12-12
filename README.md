# 🟢 Bro App

> **O app de pagamentos P2P com Bitcoin que conecta pessoas**

Pague contas, transfira valores e conecte-se com provedores usando Bitcoin via Lightning Network. Sem bancos, só conexão entre pessoas.

---

## 🎨 Identidade Visual

| Cor | Hex | Uso |
|-----|-----|-----|
| 🟢 **Mint** | `#3DE98C` | Cor primária, botões principais |
| 🔴 **Coral** | `#FF6B6B` | Destaques, alertas |
| 🔵 **Turquoise** | `#00CC7A` | Cor secundária |
| ⚪ **Cream** | `#F7F4ED` | Background light mode |
| ⚫ **Dark** | `#141414` | Background dark mode |

### Tipografia
- **Display:** Fredoka (títulos)
- **Body:** Inter (corpo de texto)

---

## 🚀 Como Rodar

### Pré-requisitos
- Flutter 3.0+
- Android Studio ou VS Code
- Dispositivo Android ou emulador

### Instalação

```bash
# Clone o repositório
git clone https://github.com/seu-usuario/bro-app.git
cd bro_app

# Instale as dependências
flutter pub get

# Rode o app
flutter run
```

### Build para Android

```bash
# APK debug
flutter build apk --debug

# APK release
flutter build apk --release
```

---

## 📱 Funcionalidades

### Para Usuários
- ✅ Escaneie boletos e códigos PIX
- ✅ Pague com Bitcoin via Lightning Network
- ✅ Acompanhe status dos pagamentos
- ✅ Histórico de transações

### Para Provedores
- ✅ Aceite ordens de pagamento
- ✅ Deposite garantia para operar
- ✅ Receba pagamentos em Bitcoin
- ✅ Dashboard com estatísticas

---

## 🛠 Tecnologias

- **Flutter** - Framework de UI
- **Breez SDK Spark** - Lightning Network (self-custodial)
- **Nostr** - Comunicação P2P descentralizada
- **Provider** - Gerenciamento de estado

---

## 📁 Estrutura

```
lib/
├── config.dart          # Configurações do app
├── main.dart            # Entry point
├── theme/               # Design System
│   ├── bro_colors.dart  # Paleta de cores
│   ├── bro_theme.dart   # ThemeData completo
│   └── bro_typography.dart # Tipografia
├── models/              # Modelos de dados
├── providers/           # State management
├── screens/             # Telas do app
├── services/            # Serviços e APIs
└── widgets/             # Componentes reutilizáveis
```

---

## 🎯 Design System

### Importando o tema

```dart
import 'package:bro_app/theme/theme.dart';

// No MaterialApp
MaterialApp(
  theme: BroTheme.darkTheme,
  // ou BroTheme.lightTheme
);
```

### Usando cores

```dart
import 'package:bro_app/theme/bro_colors.dart';

Container(
  color: BroColors.mint,
  child: Text('Bro!'),
);
```

---

## 📄 Licença

MIT License - Feito com 💚 pela comunidade Bitcoin Brasil

---

## 🤝 Contribuindo

1. Fork o projeto
2. Crie sua branch (`git checkout -b feature/nova-feature`)
3. Commit suas mudanças (`git commit -m 'Add nova feature'`)
4. Push para a branch (`git push origin feature/nova-feature`)
5. Abra um Pull Request

---

**Bro** - Conectando pessoas através do Bitcoin 🟢⚡
