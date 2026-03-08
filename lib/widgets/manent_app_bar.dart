import 'package:flutter/material.dart';

import '../theme.dart';

AppBar manentAppBar({List<Widget>? actions, VoidCallback? onTitleTap}) {
  return AppBar(
    backgroundColor: accent,
    elevation: 0,
    automaticallyImplyLeading: false,
    centerTitle: true,
    title: GestureDetector(
      onTap: onTitleTap,
      child: const Text(
        'MANENT',
        style: TextStyle(
          color: Colors.white,
          fontSize: 24,
          fontWeight: FontWeight.w500,
          letterSpacing: 2,
        ),
      ),
    ),
    actions: actions,
  );
}
