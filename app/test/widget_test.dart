import 'package:flutter_test/flutter_test.dart';
import 'package:app/main.dart';

void main() {
  testWidgets('renders the upload client in logged-out mode', (tester) async {
    await tester.pumpWidget(const HiveCliApp());
    await tester.pumpAndSettle();
    expect(find.text('选择或拖放文件'), findsOneWidget);
    expect(find.text('本地打包视频'), findsOneWidget);
  });
}
