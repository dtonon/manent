import 'package:flutter_test/flutter_test.dart';
import 'package:manent/main.dart';

void main() {
  testWidgets('App renders login screen when not authenticated',
      (WidgetTester tester) async {
    await tester.pumpWidget(const ManentApp());
    expect(find.text('MANENT'), findsOneWidget);
  });
}
