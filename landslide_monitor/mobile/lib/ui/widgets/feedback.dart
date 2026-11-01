import 'package:flutter/material.dart';

import '../theme.dart';

void showAppSnack(
  BuildContext context, {
  required String message,
  bool success = false,
}) {
  ScaffoldMessenger.of(context).hideCurrentSnackBar();
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor:
          success ? SatloTheme.ok.withOpacity(0.9) : SatloTheme.panelSoft,
      behavior: SnackBarBehavior.floating,
    ),
  );
}

Future<void> showSuccessDialog(
  BuildContext context, {
  required String title,
  required String message,
}) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: SatloTheme.panel,
      title: Text(title, style: const TextStyle(color: SatloTheme.soft)),
      content: Text(message, style: const TextStyle(color: SatloTheme.muted)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Tiếp tục', style: TextStyle(color: SatloTheme.amber)),
        ),
      ],
    ),
  );
}
