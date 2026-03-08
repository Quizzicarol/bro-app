# 🎨 Como Configurar o Ícone do Bro App

## Passo 1: Preparar a Imagem

A imagem do ícone (o "B" coral) precisa estar em formato PNG com:
- **Tamanho:** 1024x1024 pixels (recomendado)
- **Formato:** PNG
- **Fundo:** Pode ter fundo transparente ou colorido

## Passo 2: Salvar nos Locais Corretos

Salve a imagem como:
```
assets/icon/bro_icon.png
```

Para o Android Adaptive Icon (opcional, mas recomendado):
```
assets/icon/bro_icon_foreground.png  (apenas o ícone, sem fundo)
```

## Passo 3: Gerar Ícones Automaticamente

Execute no terminal:
```bash
cd C:\Users\produ\Documents\GitHub\bro_app
flutter pub get
dart run flutter_launcher_icons
```

Isso vai gerar automaticamente todos os tamanhos para:
- ✅ Android (mipmap-hdpi, mdpi, xhdpi, xxhdpi, xxxhdpi)
- ✅ iOS (AppIcon.appiconset)
- ✅ Web (favicon)

## Passo 4: Verificar

Rebuild o app:
```bash
flutter build apk --debug
flutter install --debug
```

## Configuração no pubspec.yaml

Já configurei assim:
```yaml
flutter_launcher_icons:
  android: true
  ios: true
  image_path: "assets/icon/bro_icon.png"
  adaptive_icon_background: "#FF6B6B"  # Cor coral de fundo
  adaptive_icon_foreground: "assets/icon/bro_icon_foreground.png"
  min_sdk_android: 21
  remove_alpha_ios: true
  web:
    generate: true
    image_path: "assets/icon/bro_icon.png"
    background_color: "#FF6B6B"
    theme_color: "#FF6B6B"
```

## Tamanhos Gerados

### Android
- mipmap-mdpi: 48x48
- mipmap-hdpi: 72x72
- mipmap-xhdpi: 96x96
- mipmap-xxhdpi: 144x144
- mipmap-xxxhdpi: 192x192
- Adaptive Icon: 432x432

### iOS
- 20x20, 29x29, 40x40, 60x60, 76x76, 83.5x83.5, 1024x1024
- Com variações @2x e @3x

## Dica

Se você tiver a imagem em alta resolução (1024x1024 ou maior), o flutter_launcher_icons vai redimensionar automaticamente para todos os tamanhos necessários.
