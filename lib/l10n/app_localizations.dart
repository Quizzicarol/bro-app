import 'package:flutter/material.dart';
import 'app_strings.dart';

/// Lightweight i18n for Bro App.
///
/// Usage: `AppLocalizations.of(context).t('key')`
/// With params: `AppLocalizations.of(context).tp('key', {'param': value})`
///
/// Supported: pt (default), en, es
class AppLocalizations {
  final Locale locale;

  AppLocalizations(this.locale);

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)
        ?? AppLocalizations(const Locale('pt'));
  }

  Map<String, String> get _strings {
    switch (locale.languageCode) {
      case 'en':
        return enUS;
      case 'es':
        return esES;
      case 'pt':
      default:
        return ptBR;
    }
  }

  /// Translate a key. Falls back to Portuguese if not found.
  String t(String key) {
    return _strings[key] ?? ptBR[key] ?? key;
  }

  /// Translate with parameters using {name} syntax.
  String tp(String key, Map<String, dynamic> params) {
    String result = t(key);
    params.forEach((k, v) {
      result = result.replaceAll('{$k}', v.toString());
    });
    return result;
  }

  static const List<Locale> supportedLocales = [
    Locale('pt'),
    Locale('en'),
    Locale('es'),
  ];

  static String localeDisplayName(Locale locale) {
    switch (locale.languageCode) {
      case 'en':
        return 'English';
      case 'es':
        return 'Español';
      case 'pt':
      default:
        return 'Português';
    }
  }

  static String localeFlag(Locale locale) {
    switch (locale.languageCode) {
      case 'en':
        return '🇺🇸';
      case 'es':
        return '🇪🇸';
      case 'pt':
      default:
        return '🇧🇷';
    }
  }
}

class AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) {
    return ['pt', 'en', 'es'].contains(locale.languageCode);
  }

  @override
  Future<AppLocalizations> load(Locale locale) async {
    return AppLocalizations(locale);
  }

  @override
  bool shouldReload(AppLocalizationsDelegate old) => false;
}
