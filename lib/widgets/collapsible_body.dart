import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../theme.dart';

// Crops [child] to [maxHeight] with a fade into [fadeColor] and a centred
// "Read more" button below. The crop only kicks in when the hidden part is
// clearly taller than the fade and the button, so short overflows show whole.
// [onExpand] receives the height the body will gain, so the owner can keep
// the reading position steady while the content grows.
class CollapsibleBody extends StatelessWidget {
  final Widget child;
  final double maxHeight;
  final bool expanded;
  final Color fadeColor;
  final ValueChanged<double> onExpand;

  const CollapsibleBody({
    super.key,
    required this.child,
    required this.maxHeight,
    required this.expanded,
    required this.fadeColor,
    required this.onExpand,
  });

  // Height the body keyed by [key] would gain if expanded now
  static double hiddenHeight(GlobalKey key) {
    final ro = key.currentContext?.findRenderObject();
    return ro is _RenderCollapsible ? ro.hiddenHeight : 0;
  }

  @override
  Widget build(BuildContext context) {
    final mc = context.mc;
    return _CollapsibleLayout(
      maxHeight: maxHeight,
      expanded: expanded,
      fadeColor: fadeColor,
      children: [
        child,
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Semantics(
            label: 'Read more',
            button: true,
            child: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () {
                  final ro = context
                      .findAncestorRenderObjectOfType<_RenderCollapsible>();
                  onExpand(ro?.hiddenHeight ?? 0);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: mc.card,
                  foregroundColor: mc.primaryText,
                  elevation: 2,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20)),
                ),
                child: const Text('Read more'),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CollapsibleLayout extends MultiChildRenderObjectWidget {
  final double maxHeight;
  final bool expanded;
  final Color fadeColor;

  const _CollapsibleLayout({
    required this.maxHeight,
    required this.expanded,
    required this.fadeColor,
    required super.children,
  });

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderCollapsible(
        maxHeight: maxHeight,
        expanded: expanded,
        fadeColor: fadeColor,
      );

  @override
  void updateRenderObject(
      BuildContext context, _RenderCollapsible renderObject) {
    renderObject
      ..maxHeight = maxHeight
      ..expanded = expanded
      ..fadeColor = fadeColor;
  }
}

class _CollapsibleParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderCollapsible extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _CollapsibleParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _CollapsibleParentData> {
  static const _fadeHeight = 56.0;
  // Hidden content shorter than this is not worth a button
  static const _minHidden = 36.0;

  _RenderCollapsible({
    required double maxHeight,
    required bool expanded,
    required Color fadeColor,
  })  : _maxHeight = maxHeight,
        _expanded = expanded,
        _fadeColor = fadeColor;

  double _maxHeight;
  set maxHeight(double v) {
    if (v == _maxHeight) return;
    _maxHeight = v;
    markNeedsLayout();
  }

  bool _expanded;
  set expanded(bool v) {
    if (v == _expanded) return;
    _expanded = v;
    markNeedsLayout();
  }

  Color _fadeColor;
  set fadeColor(Color v) {
    if (v == _fadeColor) return;
    _fadeColor = v;
    markNeedsPaint();
  }

  bool _cropped = false;

  double get hiddenHeight =>
      _cropped ? math.max(0, _content.size.height - size.height) : 0;

  RenderBox get _content => firstChild!;
  RenderBox get _footer => lastChild!;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _CollapsibleParentData) {
      child.parentData = _CollapsibleParentData();
    }
  }

  @override
  void performLayout() {
    final content = _content;
    final footer = _footer;
    final childConstraints = BoxConstraints(
      minWidth: constraints.minWidth,
      maxWidth: constraints.maxWidth,
    );
    content.layout(childConstraints, parentUsesSize: true);
    footer.layout(childConstraints, parentUsesSize: true);

    final width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : math.max(content.size.width, footer.size.width);
    final footerHeight = footer.size.height;
    _cropped = !_expanded &&
        content.size.height > _maxHeight + footerHeight + _minHidden;

    (content.parentData! as _CollapsibleParentData).offset = Offset.zero;
    (footer.parentData! as _CollapsibleParentData).offset = Offset(
      (width - footer.size.width) / 2,
      _maxHeight,
    );

    size = constraints.constrain(Size(
      width,
      _cropped ? _maxHeight + footerHeight : content.size.height,
    ));
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      _content.getMinIntrinsicWidth(height);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _content.getMaxIntrinsicWidth(height);

  @override
  double computeMinIntrinsicHeight(double width) =>
      _content.getMinIntrinsicHeight(width);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _content.getMaxIntrinsicHeight(width);

  void _paintContent(PaintingContext context, Offset offset) {
    context.paintChild(_content, offset);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!_cropped) {
      _paintContent(context, offset);
      return;
    }
    final clip = Rect.fromLTWH(0, 0, size.width, _maxHeight);
    context.pushClipRect(needsCompositing, offset, clip, _paintContent);

    final fadeRect = Rect.fromLTWH(offset.dx,
        offset.dy + _maxHeight - _fadeHeight, size.width, _fadeHeight);
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [_fadeColor.withValues(alpha: 0), _fadeColor],
      ).createShader(fadeRect);
    context.canvas.drawRect(fadeRect, paint);

    final footerOffset = (_footer.parentData! as _CollapsibleParentData).offset;
    context.paintChild(_footer, offset + footerOffset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (_cropped) {
      final footerOffset =
          (_footer.parentData! as _CollapsibleParentData).offset;
      final hitFooter = result.addWithPaintOffset(
        offset: footerOffset,
        position: position,
        hitTest: (result, transformed) =>
            _footer.hitTest(result, position: transformed),
      );
      if (hitFooter) return true;
      if (position.dy >= _maxHeight) return false;
    }
    return _content.hitTest(result, position: position);
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    visitor(_content);
    if (_cropped) visitor(_footer);
  }
}
