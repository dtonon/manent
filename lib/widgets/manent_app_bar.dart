import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

AppBar manentAppBar({List<Widget>? actions, VoidCallback? onTitleTap}) {
  return AppBar(
    backgroundColor: accent,
    // Pink bar in both themes — keep light status bar icons over it
    systemOverlayStyle: const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    ),
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
