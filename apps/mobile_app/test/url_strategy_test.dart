import 'package:flutter_test/flutter_test.dart';
import 'package:messengerx_app/core/url_strategy.dart';

void main() {
  test('path URL strategy configuration is a no-op off the web', () {
    configureAppUrlStrategy();
  });
}
