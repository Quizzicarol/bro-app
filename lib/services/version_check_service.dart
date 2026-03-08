import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:url_launcher/url_launcher.dart';

/// Serviço de verificação de versão do app
/// 
/// Consulta o GitHub Releases do repo público para verificar se há
/// uma versão mais recente disponível. Mostra dialog/banner para o usuário.
/// Detecta plataforma (iOS → TestFlight, Android → APK do GitHub).
class VersionCheckService {
  static final VersionCheckService _instance = VersionCheckService._internal();
  factory VersionCheckService() => _instance;
  VersionCheckService._internal();

  /// Repo público de releases
  static const String _repoOwner = 'Quizzicarol';
  static const String _repoName = 'bro-releases';
  static const String _githubApiUrl = 
      'https://api.github.com/repos/$_repoOwner/$_repoName/releases/latest';

  /// URL do TestFlight para iOS
  static const String _testFlightUrl = 'https://testflight.apple.com/join/rkHbPQ94';

  /// Build mínimo obrigatório (abaixo disso, forçar atualização)
  /// Atualizar este valor quando houver mudanças críticas de segurança/protocolo
  static const int _minimumRequiredBuild = 238;

  /// Cache: não mostrar mais de uma vez por sessão
  bool _alreadyChecked = false;
  bool _updateAvailable = false;
  String? _latestVersion;
  String? _downloadUrl;
  String? _releaseNotes;
  bool _isCritical = false;

  /// Verificar se há atualização disponível
  /// Retorna true se há uma versão mais recente
  Future<bool> checkForUpdate({bool force = false}) async {
    if (_alreadyChecked && !force) return _updateAvailable;
    
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentBuild = int.tryParse(packageInfo.buildNumber) ?? 0;
      final currentVersion = packageInfo.version;
      
      broLog('🔄 Verificando atualização... versão atual: $currentVersion+$currentBuild');
      
      final response = await http.get(
        Uri.parse(_githubApiUrl),
        headers: {'Accept': 'application/vnd.github.v3+json'},
      ).timeout(const Duration(seconds: 10));
      
      if (response.statusCode != 200) {
        broLog('⚠️ GitHub API retornou ${response.statusCode}');
        _alreadyChecked = true;
        return false;
      }
      
      final data = json.decode(response.body) as Map<String, dynamic>;
      final tagName = data['tag_name'] as String? ?? '';
      _releaseNotes = data['body'] as String? ?? '';
      
      // Extrair build number do tag (formato: v1.0.129-b238)
      final buildMatch = RegExp(r'b(\d+)').firstMatch(tagName);
      final remoteBuild = buildMatch != null 
          ? int.tryParse(buildMatch.group(1)!) ?? 0 
          : 0;
      
      // Extrair versão do tag (formato: v1.0.129-b238)
      final versionMatch = RegExp(r'v?([\d.]+)').firstMatch(tagName);
      _latestVersion = versionMatch?.group(1) ?? tagName;
      
      // Buscar URL do APK nos assets
      final assets = data['assets'] as List<dynamic>? ?? [];
      for (final asset in assets) {
        final name = asset['name'] as String? ?? '';
        if (name.endsWith('.apk')) {
          _downloadUrl = asset['browser_download_url'] as String?;
          break;
        }
      }
      
      // Fallback: URL da release page
      _downloadUrl ??= data['html_url'] as String?;
      
      _updateAvailable = remoteBuild > currentBuild;
      _isCritical = currentBuild < _minimumRequiredBuild;
      
      broLog('📦 Versão remota: $_latestVersion (build $remoteBuild) | '
          'Local: $currentVersion (build $currentBuild) | '
          'Atualização: $_updateAvailable | Crítica: $_isCritical');
      
      _alreadyChecked = true;
      return _updateAvailable;
      
    } catch (e) {
      broLog('⚠️ Erro ao verificar atualização: $e');
      _alreadyChecked = true;
      return false;
    }
  }

  /// Mostrar dialog de atualização
  /// Se [critical] = true, o dialog não pode ser fechado sem atualizar
  Future<void> showUpdateDialog(BuildContext context) async {
    if (!_updateAvailable) return;
    
    await showDialog(
      context: context,
      barrierDismissible: !_isCritical,
      builder: (ctx) => WillPopScope(
        onWillPop: () async => !_isCritical,
        child: AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          backgroundColor: _isCritical ? const Color(0xFF1A1A2E) : null,
          title: Row(
            children: [
              Icon(
                _isCritical ? Icons.error : Icons.system_update,
                color: _isCritical ? Colors.red : Colors.blue,
                size: 28,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _isCritical 
                      ? '⚠️ Atualização Obrigatória'
                      : '🆕 Nova Versão Disponível',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: _isCritical ? Colors.white : null,
                  ),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_isCritical) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.withOpacity(0.3)),
                  ),
                  child: const Text(
                    'Sua versão do app não suporta funcionalidades '
                    'críticas como mensagens do mediador em disputas.\n\n'
                    'Atualize para continuar usando o Bro com segurança.',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Text(
                'Versão disponível: $_latestVersion',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: _isCritical ? Colors.white70 : null,
                ),
              ),
              if (_releaseNotes != null && _releaseNotes!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  constraints: const BoxConstraints(maxHeight: 150),
                  child: SingleChildScrollView(
                    child: Text(
                      _releaseNotes!,
                      style: TextStyle(
                        fontSize: 12,
                        color: _isCritical ? Colors.white60 : Colors.grey[600],
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            if (!_isCritical)
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Depois'),
              ),
            ElevatedButton.icon(
              onPressed: () {
                _openDownloadUrl();
                if (!_isCritical) Navigator.pop(ctx);
              },
              icon: Icon(Platform.isIOS ? Icons.apple : Icons.download, size: 18),
              label: Text(Platform.isIOS ? 'Abrir TestFlight' : 'Baixar APK'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _isCritical ? Colors.red : Colors.blue,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Abrir URL de download (iOS → TestFlight, Android → APK GitHub)
  Future<void> _openDownloadUrl() async {
    try {
      final String url;
      if (Platform.isIOS) {
        // iOS: Redirecionar para TestFlight
        url = _testFlightUrl;
        broLog('🍎 iOS detectado: abrindo TestFlight');
      } else {
        // Android: Baixar APK do GitHub
        if (_downloadUrl == null) return;
        url = _downloadUrl!;
        broLog('🤖 Android detectado: abrindo APK download');
      }
      
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      broLog('❌ Erro ao abrir URL de download: $e');
    }
  }

  /// Getters para uso externo
  bool get updateAvailable => _updateAvailable;
  bool get isCriticalUpdate => _isCritical;
  String? get latestVersion => _latestVersion;
  String? get downloadUrl => _downloadUrl;

  /// Abrir download diretamente (para reinstalação)
  Future<void> openDownload() async {
    await _openDownloadUrl();
  }
}
