import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:stream_watcher_mobile/main.dart';

void main() {
  testWidgets('shows PIN pairing first', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const StreamWatcherMobileApp());
    await tester.pump();

    expect(find.text('페어링 PIN'), findsOneWidget);
    expect(find.text('연결'), findsWidgets);
    expect(find.text('서버 주소'), findsNothing);
  });
}
