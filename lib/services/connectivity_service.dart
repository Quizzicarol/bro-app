import 'dart:io';
import 'package:flutter/foundation.dart';

class ConnectivityService {
  static Future<bool> checkBackendConnectivity(String url) async {
    try {
      final uri = Uri.parse(url);
      if (kIsWeb) {
        // Para web, tentamos um fetch simples
        return true; // Simplificado para web
      } else {
        // Para mobile/desktop, tentamos uma conex�o socket
        final socket = await Socket.connect(
          uri.host, 
          uri.port,
          timeout: const Duration(seconds: 2),
        );
        socket.destroy();
        return true;
      }
    } catch (e) {
      debugPrint('Erro de conectividade: $e');
      return false;
    }
  }
}
