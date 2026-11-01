class PasswordRule {
  const PasswordRule(this.label, this._pattern, {this.minLength});

  final String label;
  final String? _pattern;
  final int? minLength;

  bool isMet(String password) {
    if (minLength != null) return password.length >= minLength!;
    return RegExp(_pattern!).hasMatch(password);
  }
}

abstract final class PasswordPolicy {
  static const rules = <PasswordRule>[
    PasswordRule('At least 12 characters', null, minLength: 12),
    PasswordRule('One uppercase letter', r'[A-Z]'),
    PasswordRule('One lowercase letter', r'[a-z]'),
    PasswordRule('One number', r'\d'),
    PasswordRule('One special character', r'[^A-Za-z0-9]'),
  ];

  static bool isValid(String password) => rules.every((r) => r.isMet(password));
}

abstract final class Validators {
  static final _email = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]{2,}$');

  static String? email(String value) {
    final v = value.trim();
    if (v.isEmpty) return 'Enter your email address.';
    if (!_email.hasMatch(v)) return 'Enter a valid email address.';
    return null;
  }

  static String? required(String value, String message) => value.trim().isEmpty ? message : null;

  static String? newPassword(String value) {
    if (value.isEmpty) return 'Create a password.';
    if (!PasswordPolicy.isValid(value)) return 'Password doesn\'t meet every requirement below.';
    return null;
  }

  static String? confirmPassword(String password, String confirm) {
    if (confirm.isEmpty) return 'Confirm your password.';
    if (password != confirm) return 'Passwords don\'t match.';
    return null;
  }
}
