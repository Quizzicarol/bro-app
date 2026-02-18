import 'dart:io';

/// Configura��o do Greenlight (Blockstream Lightning)
/// 
/// O Greenlight permite rodar um n� Lightning na nuvem sem gerenciar infraestrutura.
/// 
/// **COMO OBTER CREDENCIAIS:**
/// 
/// **Op��o 1: Developer Certificate (Produ��o - Recomendado)**
/// - V� para: https://greenlight.blockstream.com/
/// - Crie uma conta e solicite Partner Credentials
/// - Baixe `client.crt` e `client-key.pem`
/// - Coloque na pasta `gl-certs/` do projeto
/// - O c�digo abaixo ler� automaticamente
/// 
/// **Op��o 2: Invite Code (Desenvolvimento)**
/// - Visite: https://greenlight.blockstream.com/
/// - Solicite um invite code
/// - Configure abaixo em `inviteCode`
/// 
/// **Op��o 3: Sem Credenciais (Fallback)**
/// - O app funcionar� com backend LNURL de terceiros
/// - N�o ter� detec��o autom�tica de pagamentos
/// - Use apenas para testes de UI
class GreenlightConfig {
  /// Developer Certificate (Partner Credentials) - PRODU��O
  /// 
  /// Se voc� tem gl-certs/client.crt e gl-certs/client-key.pem no projeto,
  /// eles ser�o lidos automaticamente.
  static String? get partnerCertificatePEM {
    try {
      final certFile = File('gl-certs/client.crt');
      if (certFile.existsSync()) {
        return certFile.readAsStringSync();
      }
    } catch (e) {
      // Arquivo n�o existe, retornar null
    }
    return null;
  }

  static String? get partnerKeyPEM {
    try {
      final keyFile = File('gl-certs/client-key.pem');
      if (keyFile.existsSync()) {
        return keyFile.readAsStringSync();
      }
    } catch (e) {
      // Arquivo n�o existe, retornar null
    }
    return null;
  }

  /// Invite Code (alternativa para desenvolvimento)
  /// 
  /// Se voc� n�o tem Partner Credentials, use um invite code.
  /// Obtenha em: https://greenlight.blockstream.com/
  /// 
  /// Exemplo: 'abc123def456'
  static String? get inviteCode {
    // Configure seu invite code aqui se necess�rio:
    return null; // ou return 'SEU_INVITE_CODE_AQUI';
  }

  /// Se true, mostra avisos quando credenciais n�o est�o configuradas
  static bool get showWarningIfNotConfigured => true;

  /// Verifica se h� alguma credencial configurada
  static bool get hasCredentials {
    return partnerCertificatePEM != null || inviteCode != null;
  }

  /// Descri��o do modo atual
  static String get currentMode {
    if (partnerCertificatePEM != null) {
      return 'Developer Certificate (Produ��o)';
    } else if (inviteCode != null) {
      return 'Invite Code (Desenvolvimento)';
    } else {
      return 'Backend LNURL (Fallback - Sem credenciais)';
    }
  }
}
