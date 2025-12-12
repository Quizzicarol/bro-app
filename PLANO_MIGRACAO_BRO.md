# 🚀 Plano de Migração: Paga Conta → BRO

## 📋 Resumo Executivo

**De:** Paga Conta (paga_conta_clean)  
**Para:** BRO  
**Tipo:** Rebranding completo sem modificar projeto original

---

## 🎨 Nova Identidade Visual

### Paleta de Cores
| Nome | Hex | CSS Variable |
|------|-----|--------------|
| **Mint (Primary)** | `#3DE98C` | `--mint` |
| **Coral (Accent)** | `#FF6B6B` | `--coral` |
| **Turquoise** | `#00CC7A` | `--turquoise` |
| **Cream (Background)** | `#F7F4ED` | `--cream` |
| **Dark (Foreground)** | `#141414` | `--foreground` |

### Tipografia
- **Display Font:** Fredoka (títulos, headers)
- **Body Font:** Inter (corpo de texto, UI)

### Assets Disponíveis
- `bro-logo-dark-on-mint.png` - Logo escuro em fundo mint
- `bro-logo-shadow-light.png` - Logo com sombra clara
- `bro-logo-shadow-transparent.png` - Logo transparente (principal)

---

## 📁 Estrutura do Novo Projeto

```
bro_app/
├── android/
│   └── app/
│       └── src/main/
│           ├── AndroidManifest.xml (android:label="Bro")
│           └── res/
│               └── mipmap-*/  (novos ícones)
├── ios/
│   └── Runner/
│       ├── Info.plist (CFBundleName = "Bro")
│       └── Assets.xcassets/
├── assets/
│   ├── images/
│   │   ├── logo.png
│   │   ├── logo-dark.png
│   │   └── splash.png
│   └── fonts/
│       ├── Fredoka-*.ttf
│       └── Inter-*.ttf
├── lib/
│   ├── theme/
│   │   └── bro_theme.dart (Design System)
│   └── ... (código migrado)
├── pubspec.yaml (name: bro_app)
└── README.md
```

---

## ✅ Checklist de Migração

### 1. Configuração do Projeto
- [ ] Criar pasta `bro_app`
- [ ] Copiar estrutura de `paga_conta_clean`
- [ ] Renomear `pubspec.yaml` → `name: bro_app`
- [ ] Atualizar `description` no pubspec

### 2. Android
- [ ] `build.gradle`: `applicationId = "app.bro.mobile"`
- [ ] `build.gradle`: `namespace = "app.bro.mobile"`
- [ ] `AndroidManifest.xml`: `android:label="Bro"`
- [ ] Gerar novos ícones com logo Bro
- [ ] Atualizar `MainActivity.kt` package

### 3. iOS
- [ ] `Info.plist`: `CFBundleName = "Bro"`
- [ ] `Info.plist`: `CFBundleDisplayName = "Bro"`
- [ ] Gerar novos ícones AppIcon
- [ ] Atualizar `project.pbxproj`

### 4. Design System Flutter
- [ ] Criar `lib/theme/bro_theme.dart`
- [ ] Criar `lib/theme/bro_colors.dart`
- [ ] Criar `lib/theme/bro_typography.dart`
- [ ] Adicionar fontes ao pubspec.yaml
- [ ] Atualizar `main.dart` com novo tema

### 5. Assets
- [ ] Copiar logos para `assets/images/`
- [ ] Baixar fontes Fredoka e Inter
- [ ] Criar splash screen
- [ ] Configurar assets no pubspec.yaml

### 6. UI/UX Updates
- [ ] Substituir cores laranjas por Mint/Coral
- [ ] Atualizar textos "Paga Conta" → "Bro"
- [ ] Atualizar textos descritivos
- [ ] Revisar botões e componentes

### 7. GitHub
- [ ] Criar novo repositório `bro-app`
- [ ] Push inicial
- [ ] Configurar Actions (opcional)

---

## 🎯 Próximos Passos

1. **Fase 1:** Criar estrutura básica do projeto
2. **Fase 2:** Configurar Android/iOS
3. **Fase 3:** Implementar Design System
4. **Fase 4:** Migrar código com novo branding
5. **Fase 5:** Testar e publicar

---

## 📝 Notas

- O projeto `paga_conta_clean` permanece **intacto**
- Toda funcionalidade será mantida
- Apenas identidade visual e nome mudam
- Fluxos de usuário permanecem os mesmos

