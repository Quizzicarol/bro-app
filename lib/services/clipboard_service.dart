import 'package:flutter/services.dart';

/// Copies text to clipboard and auto-clears after [clearAfter].
/// Used for sensitive data like seeds, private keys, invoices.
Future<void> copyWithAutoClear(String text, {Duration clearAfter = const Duration(minutes: 2)}) async {
  await Clipboard.setData(ClipboardData(text: text));
  Future.delayed(clearAfter, () async {
    final current = await Clipboard.getData('text/plain');
    if (current?.text == text) {
      await Clipboard.setData(const ClipboardData(text: ''));
    }
  });
}
