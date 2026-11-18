import 'package:flutter_test/flutter_test.dart';
import 'package:getterx_core/link_parser.dart';

void main() {
  test('app can use the core package', () {
    expect(parseSourceLink('https://github.com/a/b')?.ref, 'a/b');
  });
}
