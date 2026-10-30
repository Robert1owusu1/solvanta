import 'package:flutter_test/flutter_test.dart';
import 'package:solvanta/core/api/api_client.dart';

void main() {
  test('config.json addresses resolve against the page', () {
    final page = Uri.parse('http://10.60.101.149:8091/#/login');
    expect(ApiClient.resolveRuntimeApi(':8080', page),
        'http://10.60.101.149:8080');
    expect(ApiClient.resolveRuntimeApi(' https://api.school.com ', page),
        'https://api.school.com');
    expect(ApiClient.resolveRuntimeApi('', page), isNull);
    expect(ApiClient.resolveRuntimeApi(
            ':443', Uri.parse('https://portal.school.com/')),
        'https://portal.school.com:443');
  });
}
