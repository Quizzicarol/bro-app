# 🚀 Guia de Deploy - Bro App
## TestFlight (iOS) e Google Play Store via Codemagic

---

## 📋 PRÉ-REQUISITOS

### Contas Necessárias
- [ ] **Apple Developer Account** ($99/ano) - https://developer.apple.com
- [ ] **Google Play Console** ($25 único) - https://play.google.com/console
- [ ] **Codemagic** (gratuito para começar) - https://codemagic.io

### Ferramentas Locais
- [ ] Flutter SDK instalado
- [ ] Xcode (Mac) ou acesso a Mac para builds iOS
- [ ] Android Studio com SDK

---

## 🍎 PARTE 1: CONFIGURAÇÃO iOS (TestFlight)

### 1.1 Apple Developer Portal

1. Acesse https://developer.apple.com/account
2. Vá em **Certificates, IDs & Profiles**
3. Crie um **App ID**:
   - Bundle ID: `app.bro.mobile`
   - Capabilities: Push Notifications (se usar)

### 1.2 App Store Connect

1. Acesse https://appstoreconnect.apple.com
2. Clique em **My Apps** > **+** > **New App**
3. Preencha:
   - Platform: iOS
   - Name: Bro
   - Primary Language: Portuguese (Brazil)
   - Bundle ID: app.bro.mobile
   - SKU: bro-app-001

### 1.3 Certificados e Provisioning Profiles

**Opção A: Automático (Recomendado com Codemagic)**
- Codemagic gerencia automaticamente via App Store Connect API

**Opção B: Manual**
1. Crie um Distribution Certificate (.p12)
2. Crie um App Store Provisioning Profile
3. Exporte e guarde em local seguro

### 1.4 App Store Connect API Key (para Codemagic)

1. App Store Connect > Users and Access > Keys
2. Clique **+** para gerar nova API Key
3. Nome: "Codemagic CI"
4. Access: App Manager
5. **BAIXE O .p8** (só aparece uma vez!)
6. Anote: Key ID e Issuer ID

---

## 🤖 PARTE 2: CONFIGURAÇÃO ANDROID (Google Play)

### 2.1 Google Play Console

1. Acesse https://play.google.com/console
2. Crie novo app:
   - Nome: Bro
   - Idioma: Português (Brasil)
   - App ou Jogo: App
   - Gratuito ou Pago: Gratuito

### 2.2 Keystore (Assinatura do App)

```bash
# Gerar keystore (GUARDE EM LOCAL SEGURO!)
keytool -genkey -v -keystore bro-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias bro

# Você precisará informar:
# - Senha do keystore
# - Nome, Organização, Cidade, Estado, País
```

### 2.3 Configurar android/key.properties

Crie o arquivo `android/key.properties`:
```properties
storePassword=SUA_SENHA_KEYSTORE
keyPassword=SUA_SENHA_KEY
keyAlias=bro
storeFile=../bro-release.jks
```

**⚠️ IMPORTANTE: Adicione ao .gitignore:**
```
android/key.properties
*.jks
```

### 2.4 Google Cloud Service Account (para Codemagic)

1. Google Cloud Console > IAM & Admin > Service Accounts
2. Criar conta de serviço
3. Dar permissão de "Service Account User"
4. Criar chave JSON
5. No Google Play Console:
   - Settings > API Access
   - Link a service account
   - Grant access: Release manager

---

## ⚙️ PARTE 3: CONFIGURAÇÃO CODEMAGIC

### 3.1 Conectar Repositório

1. Acesse https://codemagic.io
2. Sign in with GitHub
3. Authorize Codemagic
4. Add application > Select "bro_app" repo

### 3.2 Configurar Variáveis de Ambiente

**Settings > Environment Variables > Add group**

#### Grupo: `keystore_credentials`
| Variable | Value |
|----------|-------|
| CM_KEYSTORE | (base64 do arquivo .jks) |
| CM_KEYSTORE_PASSWORD | sua_senha |
| CM_KEY_PASSWORD | sua_senha |
| CM_KEY_ALIAS | bro |

Para converter keystore em base64:
```bash
base64 -i bro-release.jks | pbcopy  # Mac
base64 bro-release.jks > keystore.txt  # Windows/Linux
```

#### Grupo: `google_play_credentials`
| Variable | Value |
|----------|-------|
| GCLOUD_SERVICE_ACCOUNT_CREDENTIALS | (conteúdo do JSON) |

#### Grupo: `app_store_credentials`
| Variable | Value |
|----------|-------|
| APP_STORE_CONNECT_KEY_IDENTIFIER | Key ID do .p8 |
| APP_STORE_CONNECT_ISSUER_ID | Issuer ID |
| APP_STORE_CONNECT_PRIVATE_KEY | (conteúdo do .p8) |

### 3.3 Configurar Code Signing iOS

1. Settings > iOS code signing
2. Upload do certificado .p12 ou usar automático
3. Selecionar provisioning profile ou "Automatic"

---

## 🚀 PARTE 4: PRIMEIRO DEPLOY

### 4.1 Preparar o App para Produção

1. Copie `env.example.json` para `env.json` e preencha os valores:
```json
{
  "BREEZ_API_KEY": "<seu-certificado-breez>",
  "PLATFORM_LIGHTNING_ADDRESS": "<seu-lightning-address>",
  "BACKEND_URL": "https://api.bro.app"
}
```

2. Verifique `lib/config.dart`:
```dart
static const bool testMode = false;
static const bool providerTestMode = false;
```

### 4.2 Atualizar Versão

Edite `pubspec.yaml`:
```yaml
version: 1.0.0+1  # formato: major.minor.patch+buildNumber
```

### 4.3 Commit e Push

```bash
git add -A
git commit -m "Release v1.0.0 - Preparado para produção"
git push origin main
```

### 4.4 Criar Release Branch (Trigger automático)

```bash
git checkout -b release/1.0.0
git push origin release/1.0.0
```

O Codemagic iniciará o build automaticamente!

---

## 📱 PARTE 5: PUBLICAÇÃO

### 5.1 TestFlight (iOS)

1. Build concluído no Codemagic → IPA enviado automaticamente
2. App Store Connect > TestFlight
3. Aguardar processamento (~10-30 min)
4. Adicionar testers ou grupos de teste
5. Testers recebem convite por email

### 5.2 Google Play Internal Testing

1. Build concluído → AAB enviado automaticamente
2. Google Play Console > Testing > Internal testing
3. Criar release
4. Adicionar testers por email
5. Compartilhar link de opt-in

---

## 🔄 PARTE 6: FLUXO DE ATUALIZAÇÕES

### Para cada nova versão:

1. **Desenvolva e teste localmente**
2. **Atualize versão** em `pubspec.yaml`
3. **Commit para develop** (build de teste)
4. **Merge para main** ou crie branch `release/X.Y.Z`
5. **Codemagic builda automaticamente**
6. **Teste no TestFlight/Internal Testing**
7. **Promova para produção** quando aprovado

---

## 📊 CHECKLIST FINAL PRÉ-PUBLICAÇÃO

### App Store (iOS)
- [ ] Screenshots (6.5" e 5.5")
- [ ] App Icon (1024x1024)
- [ ] Descrição do app
- [ ] Palavras-chave
- [ ] Política de Privacidade URL
- [ ] Categoria: Finance
- [ ] Age Rating: 17+ (por Bitcoin)

### Google Play
- [ ] Screenshots (phone e tablet)
- [ ] Feature Graphic (1024x500)
- [ ] App Icon (512x512)
- [ ] Descrição curta e longa
- [ ] Política de Privacidade URL
- [ ] Categoria: Finance
- [ ] Content Rating questionnaire

---

## 🆘 TROUBLESHOOTING

### Build iOS falha
- Verifique Bundle ID no Xcode e App Store Connect
- Regenere provisioning profiles
- Limpe: `flutter clean && cd ios && pod deintegrate && pod install`

### Build Android falha
- Verifique keystore path e senhas
- Atualize Gradle: `cd android && ./gradlew clean`

### Upload falha
- Verifique credenciais das service accounts
- Confirme permissões no Play Console/App Store Connect

---

## 📞 SUPORTE

- **Codemagic Docs**: https://docs.codemagic.io
- **Flutter Deployment**: https://docs.flutter.dev/deployment
- **App Store Guidelines**: https://developer.apple.com/app-store/review/guidelines/
- **Google Play Policies**: https://play.google.com/about/developer-content-policy/

---

*Guia criado em 13/12/2025 para Bro App v1.0.0*
