
import 'package:flutter/material.dart';
import 'package:controle_amil/services/update_service.dart';

class UpdateFeature {
  static Future<void> checkForUpdates(BuildContext context) async {
    final updateService = UpdateService();
    final updateInfo = await updateService.checkForUpdate();
    if (updateInfo != null && context.mounted) {
      _showUpdateDialog(context, updateInfo);
    }
  }

  static void _showUpdateDialog(BuildContext context, Map<String, String> updateInfo) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Nova versão disponível: ${updateInfo['version']}'),
        content: SingleChildScrollView(
          child: Text(updateInfo['notes'] ?? 'Notas da versão não disponíveis.'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Mais tarde'),
          ),
          ElevatedButton(
            onPressed: () {
              final updateService = UpdateService();
              updateService.launchUpdate(updateInfo['url']!);
              Navigator.of(context).pop();
            },
            child: const Text('Atualizar Agora'),
          ),
        ],
      ),
    );
  }
}
