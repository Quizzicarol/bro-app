# Contributing to Bro

Thank you for your interest in contributing to Bro! This document provides guidelines for contributing to the project.

## Getting Started

### Prerequisites

- Flutter 3.19+ ([Install](https://docs.flutter.dev/get-started/install))
- Dart 3.3+
- Android Studio or VS Code with Flutter extensions
- Xcode 15+ (for iOS development)
- A [Breez SDK](https://breez.technology/sdk/) API key
- Node.js 18+ (for backend development)

### Setting Up the Development Environment

```bash
# 1. Fork and clone the repository
git clone https://github.com/YOUR_USERNAME/bro.git
cd bro

# 2. Install Flutter dependencies
flutter pub get

# 3. Create your environment config
cp env.json.example env.json
# Edit env.json with your Breez API key and other settings

# 4. Run in debug mode
flutter run --dart-define-from-file=env.json
```

### Environment Configuration

Create an `env.json` file in the project root (it's gitignored):

```json
{
  "BREEZ_API_KEY": "your-breez-sdk-api-key",
  "PLATFORM_LIGHTNING_ADDRESS": "your@lightning.address",
  "BACKEND_URL": "http://localhost:3002"
}
```

### Running the Backend (Optional)

```bash
cd backend
npm install
node server.js
```

## How to Contribute

### Reporting Bugs

1. Check [existing issues](https://github.com/Brostr/bro/issues) first
2. Create a new issue with:
   - Clear description of the bug
   - Steps to reproduce
   - Expected vs actual behavior
   - Device/OS information
   - Screenshots if applicable

### Suggesting Features

Open an issue tagged `enhancement` with:
- Clear description of the feature
- Why it would be useful
- How it might work (optional)

### Submitting Code

1. **Fork** the repository
2. **Create a branch** from `master`:
   ```bash
   git checkout -b feature/your-feature-name
   ```
3. **Make your changes** following the code style guidelines below
4. **Test** your changes thoroughly
5. **Commit** with clear messages:
   ```bash
   git commit -m "feat: add relay connection indicator"
   ```
6. **Push** to your fork and open a **Pull Request**

## Code Style

### Dart/Flutter

- Follow [Effective Dart](https://dart.dev/effective-dart) guidelines
- Use the project's `analysis_options.yaml` for linting
- Use `broLog()` instead of `debugPrint()` or `print()` for logging (see `lib/services/log_utils.dart`)
- Use `const` constructors where possible
- Name files with `snake_case`
- Name classes with `PascalCase`
- Name variables and functions with `camelCase`

### Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add new feature
fix: resolve bug description
docs: update documentation
refactor: restructure code
security: fix vulnerability
chore: update dependencies
```

### Security Guidelines

- **Never** hardcode API keys, secrets, or credentials
- Use `String.fromEnvironment()` for sensitive configuration
- Use `FlutterSecureStorage` for sensitive data on device
- Use `broLog()` for logging — it's disabled in release builds
- Encrypt sensitive data with NIP-44 before publishing to Nostr
- Validate all Nostr event signatures before processing
- Clear clipboard within 2 minutes when copying sensitive data

## Architecture

### Key Principles

- **Services** handle business logic and external communication
- **Providers** manage state and expose it to the UI
- **Screens** are the top-level UI components
- **Widgets** are reusable UI building blocks
- **Models** define data structures

### Important Files

| File | Purpose |
|------|---------|
| `lib/config.dart` | App configuration (env vars) |
| `lib/services/nostr_order_service.dart` | Nostr event management |
| `lib/services/nip44_service.dart` | E2E encryption |
| `lib/providers/order_provider.dart` | Order state management |
| `lib/services/background_notification_service.dart` | Background tasks |

## Testing

```bash
# Run all tests
flutter test

# Run a specific test
flutter test test/your_test.dart

# Run with coverage
flutter test --coverage
```

## Protocol

If you're extending the Bro protocol (new event kinds, new status flows), please:

1. Document in `specs/` following the existing spec format
2. Ensure backward compatibility with existing events
3. Use parameterized replaceable events (kind 30xxx) for mutable data
4. Follow NIP conventions for tags and content structure

## Questions?

- Open an issue for questions about the codebase
- Check the [`specs/`](specs/) folder for protocol documentation
- See [BRO_PROTOCOL_SPEC.md](BRO_PROTOCOL_SPEC.md) for protocol details

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
