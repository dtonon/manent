import 'package:flutter/material.dart';

AppBar manentAppBar({List<Widget>? actions, VoidCallback? onTitleTap}) {
  // Background, elevation and status bar style come from appBarTheme
  return AppBar(
    automaticallyImplyLeading: false,
    centerTitle: true,
    title: GestureDetector(
      onTap: onTitleTap,
      child: const Text(
        // Color comes from appBarTheme.titleTextStyle (theme-aware)
        'MANENT',
        style: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w500,
          letterSpacing: 2,
        ),
      ),
    ),
    actions: actions,
  );
}
