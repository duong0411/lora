import 'package:flutter_test/flutter_test.dart';
import 'package:landslide_monitor/main.dart';

void main() {
  testWidgets('App builds', (WidgetTester tester) async {
    await tester.pumpWidget(const LandslideApp());
    expect(find.text('Cảnh báo Sạt lở'), findsOneWidget);
  });
}
