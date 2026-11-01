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
      backgroundColor: success ? SatloTheme.ok.withOpacity(0.9) : SatloTheme.panelSoft,
      behavior: SnackBarBehavior.floating,
    ),
  );
}
