import 'package:flutter_test/flutter_test.dart';

import 'package:synapmentor/services/password_policy.dart';

// Sign-in, registration and password reset now run against the API, so they
// are tested against the server rather than here.
void main() {
  test('password policy matches the API (12+ chars, upper, lower, digit, special)', () {
    expect(PasswordPolicy.isValid('short'), isFalse);
    expect(PasswordPolicy.isValid('alllowercase1!'), isFalse);
    expect(PasswordPolicy.isValid('NoSpecial12345'), isFalse);
    expect(PasswordPolicy.isValid('Valid#Pass1'), isFalse, reason: 'under 12 characters');
    expect(PasswordPolicy.isValid('Valid#Pass123'), isTrue);
  });

  test('email validation', () {
    expect(Validators.email(''), isNotNull);
    expect(Validators.email('not-an-email'), isNotNull);
    expect(Validators.email('user@example.com'), isNull);
  });
}
