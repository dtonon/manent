import 'package:flutter/material.dart';

AppBar manentAppBar({List<Widget>? actions}) {
  return AppBar(
    backgroundColor: const Color(0xFFe32a6d),
    elevation: 0,
    automaticallyImplyLeading: false,
    centerTitle: true,
    title: const Text(
      'MANENT',
      style: TextStyle(
        color: Colors.white,
        fontSize: 24,
        fontWeight: FontWeight.w500,
        letterSpacing: 2,
      ),
    ),
    actions: actions,
  );
}
