import 'package:flutter_test/flutter_test.dart';
import 'package:landslide_monitor/main.dart';

void main() {
  testWidgets('App builds', (WidgetTester tester) async {
    await tester.pumpWidget(const LandslideApp());
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(LandslideApp), findsOneWidget);
  });
}
