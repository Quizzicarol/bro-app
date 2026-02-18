# 🚀 Bro App - Deploy Checklist

## 📱 Status Atual

- **Versão:** 1.0.0+1
- **Nome:** Bro
- **Package Android:** app.bro.mobile
- **Bundle iOS:** (configurar no Xcode)

## ✅ Pré-Deploy Checklist

### 1. Ícone do App
O ícone precisa ser configurado manualmente:

1. **Salvar a imagem do ícone** (o "B" coral que você enviou) em:
   - `assets/icon/bro_icon.png` (1024x1024px recomendado)
   - `assets/icon/bro_icon_foreground.png` (para Android adaptive icon)

2. **Gerar ícones automaticamente:**
   ```bash
   flutter pub get
   dart run flutter_launcher_icons
   ```

3. **Ou manualmente:**
   - Android: Substituir arquivos em `android/app/src/main/res/mipmap-*/`
   - iOS: Substituir em `ios/Runner/Assets.xcassets/AppIcon.appiconset/`

### 2. Taxas da Plataforma
- ✅ **Modo atual:** TRACKING ONLY
- ✅ Taxas vão 100% para provedores
- ✅ Sistema de tracking registra 2% para análise futura
- ✅ Painel admin via rota secreta (7 toques em Configurações)

### 3. Build Android (Google Play)

```bash
# Build release
flutter build appbundle --release

# O arquivo estará em:
# build/app/outputs/bundle/release/app-release.aab
```

**Para assinar o APK:**
1. Criar keystore: `keytool -genkey -v -keystore bro-release.keystore -alias bro -keyalg RSA -keysize 2048 -validity 10000`
2. Criar `android/key.properties`:
   ```properties
   storePassword=SUA_SENHA
   keyPassword=SUA_SENHA
   keyAlias=bro
   storeFile=../bro-release.keystore
   ```

### 4. Build iOS (TestFlight)

**Pré-requisitos:**
- Mac com Xcode instalado
- Conta Apple Developer ($99/ano)
- Certificados configurados

**Passos:**
```bash
# No Mac:
flutter build ios --release

# Depois abrir no Xcode:
open ios/Runner.xcworkspace
```

No Xcode:
1. Product > Archive
2. Distribute App > App Store Connect
3. Upload

### 5. Configurações iOS (Xcode)

Abrir `ios/Runner.xcworkspace` e verificar:
- **Bundle Identifier:** `app.bro.mobile` (ou seu ID)
- **Display Name:** Bro
- **Version:** 1.0.0
- **Build:** 1
- **Team:** Sua conta Apple Developer

## 🔐 Segurança

### Acesso Admin
- Rota secreta: configurada no código-fonte
- Acesso: 7 toques no título "Configurações"
- Dados de taxas apenas para visualização

### Carteira
- Self-custodial via Breez SDK Spark
- Seed de 12 palavras gerada localmente
- Backup responsabilidade do usuário

## 📊 Taxas (Modo Futuro)

Quando tivermos servidor próprio:
1. Ativar `PlatformFeeService.setAutoCollection(true)`
2. Configurar `PlatformWalletService` com mnemonic master
3. Ativar `EscrowSplitService` para split automático

## 🧪 Testes Antes do Deploy

- [ ] Login/registro funciona
- [ ] Criar ordem como cliente
- [ ] Aceitar ordem como provedor
- [ ] Gerar QR code Lightning
- [ ] Pagamento detectado corretamente
- [ ] Transações aparecem no histórico
- [ ] Configurações funcionam
- [ ] Backup de seed funciona

## 📝 Notas

- Breez SDK Spark é nodeless (não precisa de node Lightning)
- Funciona em mainnet e testnet
- API Key da Breez já configurada
