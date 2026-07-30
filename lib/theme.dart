import 'package:flutter/material.dart';

// Brand pink — fixed in both light and dark modes
const accent = Color(0xFFe32a6d);
// Text selection highlight — fixed in both modes
const textSelectionColor = Color(0x44FFEE58);

// Semantic color tokens resolved per brightness. Read via `context.mc`.
// Colors that are semantically fixed (white-on-accent, media black, image
// overlay badges) stay literal at the call site and are not tokens here.
@immutable
class ManentColors extends ThemeExtension<ManentColors> {
  final Color appBarBg; // top app bar — pink in light, dark gray in dark
  final Color appBarTitle; // MANENT title — white on pink, soft grey on dark
  final Color surface; // scaffold background
  final Color card; // raised surfaces: note cards, dialogs, sheets, input bar
  final Color cardDim; // dimmed/inactive card, chips, image placeholder bg
  final Color border; // dividers and outlines
  final Color primaryText; // body text
  final Color secondaryText; // muted labels and secondary text
  final Color faintText; // timestamps and the faintest meta text
  final Color hintText; // text field placeholders
  final Color iconMuted; // low-emphasis action icons
  final Color shadow; // elevation shadows
  final Color strongButtonBg; // high-contrast neutral button (e.g. log out)
  final Color strongButtonFg;
  final Color selectedFill; // active filter chip/row — neutral, not accent

  const ManentColors({
    required this.appBarBg,
    required this.appBarTitle,
    required this.surface,
    required this.card,
    required this.cardDim,
    required this.border,
    required this.primaryText,
    required this.secondaryText,
    required this.faintText,
    required this.hintText,
    required this.iconMuted,
    required this.shadow,
    required this.strongButtonBg,
    required this.strongButtonFg,
    required this.selectedFill,
  });

  static const light = ManentColors(
    appBarBg: accent,
    appBarTitle: Color(0xFFFFFFFF),
    surface: Color(0xFFF5F5F5),
    card: Color(0xFFFFFFFF),
    cardDim: Color(0xFFEEEEEE),
    border: Color(0xFFE0E0E0),
    primaryText: Color(0xDD000000), // black87
    secondaryText: Color(0xFF757575), // grey 600
    faintText: Color(0xFFBDBDBD), // grey 400
    hintText: Color(0xFF9E9E9E), // grey
    iconMuted: Color(0xFFBDBDBD), // grey 400
    shadow: Color(0x14000000),
    strongButtonBg: Color(0xFF1A1A1A),
    strongButtonFg: Color(0xFFFFFFFF),
    selectedFill: Color(0xFF666666),
  );

  static const dark = ManentColors(
    appBarBg: Color(0xFF1E1E1E),
    appBarTitle: Color(0xFFB0B0B0),
    surface: Color(0xFF121212),
    card: Color(0xFF1E1E1E),
    cardDim: Color(0xFF2A2A2A),
    border: Color(0xFF333333),
    primaryText: Color(0xDEFFFFFF), // white ~87%
    secondaryText: Color(0xFFA8A8A8),
    faintText: Color(0xFF6E6E6E),
    hintText: Color(0xFF7A7A7A),
    iconMuted: Color(0xFF9A9A9A),
    shadow: Color(0x66000000),
    strongButtonBg: Color(0xFFEDEDED),
    strongButtonFg: Color(0xFF1A1A1A),
    selectedFill: Color(0xFF4D4D4D),
  );

  @override
  ManentColors copyWith({
    Color? appBarBg,
    Color? appBarTitle,
    Color? surface,
    Color? card,
    Color? cardDim,
    Color? border,
    Color? primaryText,
    Color? secondaryText,
    Color? faintText,
    Color? hintText,
    Color? iconMuted,
    Color? shadow,
    Color? strongButtonBg,
    Color? strongButtonFg,
    Color? selectedFill,
  }) {
    return ManentColors(
      appBarBg: appBarBg ?? this.appBarBg,
      appBarTitle: appBarTitle ?? this.appBarTitle,
      surface: surface ?? this.surface,
      card: card ?? this.card,
      cardDim: cardDim ?? this.cardDim,
      border: border ?? this.border,
      primaryText: primaryText ?? this.primaryText,
      secondaryText: secondaryText ?? this.secondaryText,
      faintText: faintText ?? this.faintText,
      hintText: hintText ?? this.hintText,
      iconMuted: iconMuted ?? this.iconMuted,
      shadow: shadow ?? this.shadow,
      strongButtonBg: strongButtonBg ?? this.strongButtonBg,
      strongButtonFg: strongButtonFg ?? this.strongButtonFg,
      selectedFill: selectedFill ?? this.selectedFill,
    );
  }

  @override
  ManentColors lerp(ThemeExtension<ManentColors>? other, double t) {
    if (other is! ManentColors) return this;
    return ManentColors(
      appBarBg: Color.lerp(appBarBg, other.appBarBg, t)!,
      appBarTitle: Color.lerp(appBarTitle, other.appBarTitle, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      card: Color.lerp(card, other.card, t)!,
      cardDim: Color.lerp(cardDim, other.cardDim, t)!,
      border: Color.lerp(border, other.border, t)!,
      primaryText: Color.lerp(primaryText, other.primaryText, t)!,
      secondaryText: Color.lerp(secondaryText, other.secondaryText, t)!,
      faintText: Color.lerp(faintText, other.faintText, t)!,
      hintText: Color.lerp(hintText, other.hintText, t)!,
      iconMuted: Color.lerp(iconMuted, other.iconMuted, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
      strongButtonBg: Color.lerp(strongButtonBg, other.strongButtonBg, t)!,
      strongButtonFg: Color.lerp(strongButtonFg, other.strongButtonFg, t)!,
      selectedFill: Color.lerp(selectedFill, other.selectedFill, t)!,
    );
  }
}

extension ManentColorsX on BuildContext {
  ManentColors get mc => Theme.of(this).extension<ManentColors>()!;
}
