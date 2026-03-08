import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../l10n/app_localizations.dart';

/// Manages app locale with persistence via SharedPreferences.
class LocaleProvider extends ChangeNotifier {
  static const _prefKey = 'app_locale';

  Locale _locale = const Locale('pt');
  bool _initialized = false;

  Locale get locale => _locale;
  bool get isInitialized => _initialized;

  Future<void> initialize() async {
    if (_initialized) return;

    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefKey);

    if (saved != null) {
      _locale = Locale(saved);
    } else {
      final sys = WidgetsBinding.instance.platformDispatcher.locale;
      final supported = AppLocalizations.supportedLocales
          .map((l) => l.languageCode)
          .contains(sys.languageCode);
      _locale = supported ? Locale(sys.languageCode) : const Locale('pt');
    }

    _initialized = true;
    notifyListeners();
  }

  Future<void> setLocale(Locale newLocale) async {
    if (_locale == newLocale) return;
    _locale = newLocale;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, newLocale.languageCode);
  }

  List<Map<String, dynamic>> get availableLocales {
    return AppLocalizations.supportedLocales.map((locale) {
      return {
        'locale': locale,
        'name': AppLocalizations.localeDisplayName(locale),
        'flag': AppLocalizations.localeFlag(locale),
        'isSelected': locale.languageCode == _locale.languageCode,
      };
    }).toList();
  }
}
