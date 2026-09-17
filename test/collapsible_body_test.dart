import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manent/theme.dart';
import 'package:manent/widgets/collapsible_body.dart';

Widget _host(Widget body) => MaterialApp(
      theme: ThemeData(extensions: const [ManentColors.light]),
      home: Scaffold(
        body: ListView(
          children: [
            Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [body]),
          ],
        ),
      ),
    );

void main() {
  testWidgets('tall content is cropped and shows Read more', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    var expanded = false;
    await tester.pumpWidget(_host(StatefulBuilder(
      builder: (context, setState) => CollapsibleBody(
        maxHeight: 600,
        expanded: expanded,
        fadeColor: Colors.white,
        onExpand: (grownBy) {
          expect(grownBy, greaterThan(1200));
          setState(() => expanded = true);
        },
        child: const SizedBox(height: 2000, width: 100),
      ),
    )));
    expect(find.text('Read more'), findsOneWidget);
    final box = tester.renderObject<RenderBox>(find.byType(CollapsibleBody));
    expect(box.size.height, lessThan(700));
    await tester.tap(find.text('Read more'));
    await tester.pump();
    expect(
        tester
            .renderObject<RenderBox>(find.byType(CollapsibleBody))
            .size
            .height,
        2000);
  });

  testWidgets('short content is untouched', (tester) async {
    await tester.pumpWidget(_host(CollapsibleBody(
      maxHeight: 600,
      expanded: false,
      fadeColor: Colors.white,
      onExpand: (_) {},
      child: const SizedBox(height: 620, width: 100),
    )));
    expect(find.text('Read more').hitTestable(), findsNothing);
    expect(
        tester
            .renderObject<RenderBox>(find.byType(CollapsibleBody))
            .size
            .height,
        620);
  });
}
