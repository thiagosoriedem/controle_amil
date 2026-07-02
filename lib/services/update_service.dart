import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

class DownloadProgress {
  final int count;
  final int total;
  final String status; // e.g., 'downloading', 'completed', 'error'
  final String? filePath; // path to the downloaded file

  DownloadProgress({
    required this.count,
    required this.total,
    required this.status,
    this.filePath,
  });
}

class UpdateService {
  // Tornando a URL pública para ser acessível nos testes
  static const String githubApiUrl =
      'https://api.github.com/repos/thiagosoriedem/controle_amil/releases/latest';

  final http.Client _client;

  // Construtor que permite injetar um http.Client para testes.
  UpdateService({http.Client? client}) : _client = client ?? http.Client();

  Future<Map<String, String>?> checkForUpdate() async {
    try {
      final PackageInfo packageInfo = await PackageInfo.fromPlatform();
      final String currentVersion = packageInfo.version;

      // Para evitar o "API rate limit", usamos um token de acesso pessoal do GitHub
      // carregado a partir do arquivo .env.
      // NUNCA coloque o token diretamente no código.
      final String githubToken = dotenv.env['GITHUB_TOKEN'] ?? '';

      final headers = {
        'Accept': 'application/vnd.github.v3+json',
        if (githubToken.isNotEmpty) 'Authorization': 'Bearer $githubToken',
      };

      final response = await _client.get(
        Uri.parse(githubApiUrl),
        headers: headers,
      );
      if (response.statusCode != 200) {
        print(
          'Falha ao verificar atualização. Status: ${response.statusCode}, Corpo: ${response.body}',
        );
        return null;
      }

      final json = jsonDecode(response.body);
      final latestVersion = (json['tag_name'] as String).replaceAll('v', '');
      final releaseNotes = json['body'] as String;

      print(
        'Versão atual: $currentVersion, Versão mais recente: $latestVersion',
      );

      if (isUpdateAvailable(currentVersion, latestVersion)) {
        print('✅ Atualização disponível. Procurando URL de download...');
        final downloadUrl = _getDownloadUrlForPlatform(json['assets']);
        if (downloadUrl != null) {
          print('✅ URL de download encontrada: $downloadUrl');
          return {
            'version': latestVersion,
            'notes': releaseNotes,
            'url': downloadUrl,
          };
        } else {
          print('❌ URL de download NÃO encontrada para a plataforma atual.');
        }
      } else {
        print(
          'ℹ️ Nenhuma atualização disponível. A versão já é a mais recente.',
        );
      }
    } catch (e) {
      print('Error checking for update: $e');
    }

    // Se chegou até aqui, algo falhou ou não havia atualização.
    return null;
  }

  /// Compares two version strings (e.g., '1.2.3' vs '1.3.0') and returns true if a new version is available.
  bool isUpdateAvailable(String currentVersion, String latestVersion) {
    final currentParts = currentVersion
        .split('.')
        .map((e) => int.tryParse(e) ?? 0)
        .toList();
    final latestParts = latestVersion
        .split('.')
        .map((e) => int.tryParse(e) ?? 0)
        .toList();

    final len = max(currentParts.length, latestParts.length);

    for (var i = 0; i < len; i++) {
      final latest = i < latestParts.length ? latestParts[i] : 0;
      final current = i < currentParts.length ? currentParts[i] : 0;
      if (latest > current) return true;
      if (latest < current) return false;
    }
    return false;
  }

  String? _getDownloadUrlForPlatform(List<dynamic> assets) {
    // Tenta encontrar o asset de download com base na extensão do arquivo para a plataforma.
    // É crucial que os nomes dos arquivos na release do GitHub terminem com as extensões esperadas.
    // Ex: 'controle_amil-1.0.0.apk', 'controle_amil-1.0.0-windows.exe', 'controle_amil-1.0.0.dmg'

    List<String> targetExtensions = [];
    if (Platform.isAndroid) {
      targetExtensions = ['.apk'];
    } else if (Platform.isWindows) {
      // Para Windows, pode ser .msix (instalador moderno), .exe (instalador tradicional) ou .zip.
      targetExtensions = ['.msix', '.exe', '.zip'];
    } else if (Platform.isLinux) {
      // Para Linux, AppImage é uma boa opção portável.
      targetExtensions = ['.appimage', '.deb', '.zip'];
    } else if (Platform.isMacOS) {
      targetExtensions = ['.dmg', '.zip'];
    }

    if (targetExtensions.isNotEmpty) {
      for (final ext in targetExtensions) {
        final asset = assets.firstWhere(
          (asset) => (asset['name'] as String).toLowerCase().endsWith(ext),
          orElse: () => null,
        );
        if (asset != null) {
          return asset['browser_download_url'];
        }
      }
    }

    // For iOS and Web, we'll handle the URL separately or just open the main releases page.
    if (Platform.isIOS) {
      return 'https://apps.apple.com/app/id<YOUR_APP_ID>'; // Placeholder
    }

    // Se nenhum asset específico for encontrado, retorna a página principal de releases.
    return 'https://github.com/thiagosoriedem/controle_amil/releases/latest';
  }

  Future<void> launchUpdate(String url) async {
    final uri = Uri.parse(url);
    print('🚀 Tentando abrir a URL de atualização: $url');
    if (await canLaunchUrl(uri)) {
      print('✅ URL pode ser aberta. Lançando...');
      try {
        final bool launched = await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
        if (!launched) {
          print('❌ launchUrl retornou false. Não foi possível abrir a URL.');
        } else {
          print('✅ launchUrl executado com sucesso.');
        }
      } catch (e) {
        print('❌ Erro ao executar launchUrl: $e');
      }
    } else {
      print(
        '❌ Não é possível abrir a URL: $url. Verifique as configurações do AndroidManifest.xml (queries).',
      );
    }
  }

  Stream<DownloadProgress> downloadUpdate(String url) async* {
    try {
      final client = http.Client();
      final request = http.Request('GET', Uri.parse(url));
      final response = await client.send(request);

      final contentLength = response.contentLength;
      if (contentLength == null) {
        throw Exception(
          'Não foi possível obter o tamanho do arquivo de atualização.',
        );
      }

      // Extrai o nome do arquivo da URL para salvar com o nome correto.
      final fileName = Uri.parse(url).pathSegments.last;
      final tempDir = await getTemporaryDirectory();
      final filePath = '${tempDir.path}/$fileName';
      final file = File(filePath);
      final sink = file.openWrite();

      int received = 0;
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        yield DownloadProgress(
          count: received,
          total: contentLength,
          status: 'downloading',
        );
      }

      await sink.close();
      client.close();

      yield DownloadProgress(
        count: contentLength,
        total: contentLength,
        status: 'completed',
        filePath: filePath,
      );
    } catch (e) {
      print('❌ Erro durante o download da atualização: $e');
      yield DownloadProgress(count: 0, total: 0, status: 'error');
    }
  }
}
