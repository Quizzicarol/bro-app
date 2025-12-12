import 'dart:io';

/// Configuração do Greenlight (Blockstream Lightning)
/// 
/// O Greenlight permite rodar um nó Lightning na nuvem sem gerenciar infraestrutura.
/// 
/// **COMO OBTER CREDENCIAIS:**
/// 
/// **Opção 1: Developer Certificate (Produção - Recomendado)**
/// - Vá para: https://greenlight.blockstream.com/
/// - Crie uma conta e solicite Partner Credentials
/// - Baixe `client.crt` e `client-key.pem`
/// - Coloque na pasta `gl-certs/` do projeto
/// - O código abaixo lerá automaticamente
/// 
/// **Opção 2: Invite Code (Desenvolvimento)**
/// - Visite: https://greenlight.blockstream.com/
/// - Solicite um invite code
/// - Configure abaixo em `inviteCode`
/// 
/// **Opção 3: Sem Credenciais (Fallback)**
/// - O app funcionará com backend LNURL de terceiros
/// - Não terá detecção automática de pagamentos
/// - Use apenas para testes de UI
class GreenlightConfig {
  /// Developer Certificate (Partner Credentials) - PRODUÇÃO
  /// 
  /// Se você tem gl-certs/client.crt e gl-certs/client-key.pem no projeto,
  /// eles serão lidos automaticamente.
  static String? get partnerCertificatePEM {
    try {
      final certFile = File('gl-certs/client.crt');
      if (certFile.existsSync()) {
        return certFile.readAsStringSync();
      }
    } catch (e) {
      // Arquivo não existe, retornar null
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
      // Arquivo não existe, retornar null
    }
    return null;
  }

  /// Invite Code (alternativa para desenvolvimento)
  /// 
  /// Se você não tem Partner Credentials, use um invite code.
  /// Obtenha em: https://greenlight.blockstream.com/
  /// 
  /// Exemplo: 'abc123def456'
  static String? get inviteCode {
    // Configure seu invite code aqui se necessário:
    return null; // ou return 'SEU_INVITE_CODE_AQUI';
  }

  /// Se true, mostra avisos quando credenciais não estão configuradas
  static bool get showWarningIfNotConfigured => true;

  /// Verifica se há alguma credencial configurada
  static bool get hasCredentials {
    return partnerCertificatePEM != null || inviteCode != null;
  }

  /// Descrição do modo atual
  static String get currentMode {
    if (partnerCertificatePEM != null) {
      return 'Developer Certificate (Produção)';
    } else if (inviteCode != null) {
      return 'Invite Code (Desenvolvimento)';
    } else {
      return 'Backend LNURL (Fallback - Sem credenciais)';
    }
  }
}
