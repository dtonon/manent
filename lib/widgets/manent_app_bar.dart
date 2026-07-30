import 'package:flutter/material.dart';

import '../theme.dart';

// Slimmer than Flutter's 56 default — the bar is a title strip, not a nav bar
const manentToolbarHeight = 48.0;

AppBar manentAppBar({
  List<Widget>? actions,
  VoidCallback? onTitleTap,
  Widget? leading,
  double? leadingWidth,
}) {
  // Background, elevation and status bar style come from appBarTheme
  return AppBar(
    automaticallyImplyLeading: false,
    toolbarHeight: manentToolbarHeight,
    leading: leading,
    leadingWidth: leadingWidth,
    centerTitle: true,
    title: GestureDetector(
      onTap: onTitleTap,
      child: const Text(
        // Color comes from appBarTheme.titleTextStyle (theme-aware)
        'MANENT',
        style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w500,
          letterSpacing: 2,
        ),
      ),
    ),
    actions: actions,
  );
}

// Mobile counterpart of manentAppBar, docked at the bottom so its buttons sit
// in the thumb zone. Fixed-width side slots keep the title optically centered
// whether or not a slot is filled.
class ManentBottomBar extends StatelessWidget {
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTitleTap;
  final String title;
  final bool compactTitle;

  const ManentBottomBar({
    super.key,
    this.leading,
    this.trailing,
    this.onTitleTap,
    this.title = 'MANENT',
    this.compactTitle = false,
  });

  static const _slotWidth = 64.0;
  static const _barHeight = 56.0;

  @override
  Widget build(BuildContext context) {
    final mc = context.mc;
    // padding.bottom collapses to 0 while the keyboard is up, which is what we
    // want — no gap between the bar and the keyboard.
    final safeBottom = MediaQuery.of(context).padding.bottom;
    return Container(
      color: mc.appBarBg,
      padding: EdgeInsets.only(bottom: safeBottom),
      child: SizedBox(
        height: _barHeight,
        child: Row(
          children: [
            // Slots align outward; each caller pads its own button so the
            // icon lines up with the content edge, not the tap target.
            SizedBox(
              width: _slotWidth,
              child: Align(
                alignment: Alignment.centerLeft,
                child: leading ?? const SizedBox.shrink(),
              ),
            ),
            Expanded(
              child: Center(
                child: GestureDetector(
                  onTap: onTitleTap,
                  child: Text(
                    title,
                    style: TextStyle(
                      color: mc.appBarTitle,
                      // Smaller than the desktop bar's 24 — mobile also applies
                      // a 1.2 text scaler on top
                      fontSize: compactTitle ? 16 : 19,
                      fontWeight: FontWeight.w500,
                      letterSpacing: compactTitle ? 0 : 2,
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              width: _slotWidth,
              child: Align(
                alignment: Alignment.centerRight,
                child: trailing ?? const SizedBox.shrink(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
