import 'package:flutter_test/flutter_test.dart';

import 'package:sui_flutter_app/src/app.dart';

void main() {
  testWidgets('Sui app shell renders', (WidgetTester tester) async {
    await tester.pumpWidget(const SuiApp());

    // App bar title renders.
    expect(find.text('随手记 Sui'), findsOneWidget);

    // Server URL is shown.
    expect(find.textContaining('服务端：'), findsOneWidget);

    // Let the pending ping future attempt to resolve (offline → cannot-connect).
    // Use a bounded pump, not pumpAndSettle, to avoid hanging on progress animation.
    await tester.pump(const Duration(seconds: 6));
    expect(find.text('无法连接服务端'), findsOneWidget);
  });
}