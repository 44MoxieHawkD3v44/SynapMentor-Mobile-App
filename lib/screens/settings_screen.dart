import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/navigation.dart';
import '../core/theme.dart';
import '../services/auth_service.dart';
import '../services/countries.dart';
import '../services/device_notifications.dart';
import '../services/password_policy.dart';
import '../services/settings_service.dart';
import '../widgets/app_tour.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';
import '../widgets/glass_select.dart';
import 'booking_sheet.dart';
import 'login_screen.dart';
import 'support_screen.dart';

enum _Tab {
  notifications('Notifications', Icons.notifications_none_rounded),
  policies('Policies', Icons.description_outlined),
  switchRole('Switch Role', Icons.sync_rounded),
  security('Security Settings', Icons.shield_outlined);

  const _Tab(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Settings in one screen: notification preferences, policies, role
/// switching and account security. Security actions open bottom sheets.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.user});

  final AppUser user;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _settings = SettingsService.instance;
  _Tab _tab = _Tab.notifications;
  bool _switching = false;
  String? _notice;

  String? _error;

  AppUser get _user => widget.user;
  UserRole get _otherRole => _user.role == UserRole.seeker ? UserRole.solver : UserRole.seeker;

  @override
  void initState() {
    super.initState();
    _settings.load(_user).catchError((Object e) {
      if (mounted) setState(() => _error = e is AuthException ? e.message : 'Couldn\'t load your settings.');
    });
  }

  Future<void> _setPref(NotificationPref pref, bool value) async {
    setState(() => _error = null);
    try {
      await _settings.setEnabled(_user, pref, value);
      // Push also needs the phone's permission to show notifications.
      if (pref == NotificationPref.push && value && !await DeviceNotifications.instance.requestPermission()) {
        if (mounted) setState(() => _error = _permissionHint);
      }
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<T?> _sheet<T>(Widget sheet) => showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (_) => sheet,
  );

  void _toLogin(String notice) {
    Navigator.of(context)
        .pushAndRemoveUntil(glassRoute(LoginScreen(initialEmail: _user.email, notice: notice)), (_) => false);
  }

  Future<void> _switchRole() async {
    final confirmed = await _sheet<bool>(
      _ConfirmSheet(
        title: 'Switch to ${_otherRole.label}?',
        message:
            'You\'ll be signed out on all devices. Sign in again with the same email and password to '
            'continue as a ${_otherRole.label}.',
        confirmLabel: 'Switch Role',
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _switching = true);
    try {
      final role = await AuthService.instance.switchRole();
      if (mounted) _toLogin('You\'re now a ${role.label}. Sign in again to continue.');
    } on AuthException catch (e) {
      if (mounted) setState(() => _notice = e.message);
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  /// The number changes and every session ends, so the solver signs in again.
  Future<void> _changePhone() async {
    final changed = await _sheet<bool>(_ChangePhoneSheet(user: _user));
    if (changed == true && mounted) _toLogin('Mobile number changed. Sign in again to continue.');
  }

  Future<void> _changePassword() async {
    final changed = await _sheet<bool>(const _ChangePasswordSheet());
    if (changed != true || !mounted) return;
    // Seekers are signed out everywhere after a password change.
    if (AuthService.instance.currentUser == null) {
      _toLogin('Password changed. Sign in with your new password.');
    } else {
      setState(() => _notice = 'Password updated.');
    }
  }

  Future<void> _deactivate() async {
    final done = await _sheet<bool>(const _AccountActionSheet(delete: false));
    if (done == true && mounted) {
      _toLogin('Your account is deactivated. Sign in again anytime to reactivate it.');
    }
  }

  Future<void> _delete() async {
    final done = await _sheet<bool>(const _AccountActionSheet(delete: true));
    if (done == true && mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        glassRoute(const LoginScreen(notice: 'Your account and all associated data have been deleted.')),
        (_) => false,
      );
    }
  }

  void _openPolicy(PolicyDoc policy) => _sheet<void>(_PolicySheet(policy: policy));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  GlassIconButton(
                    icon: Icons.arrow_back_rounded,
                    tooltip: 'Back',
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  Expanded(
                    child: Text('SETTINGS', textAlign: TextAlign.center, style: AppText.heading.copyWith(fontSize: 20)),
                  ),
                  const SizedBox(width: 44),
                ],
              ),
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: _settings,
                builder: (context, _) => ListView(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + MediaQuery.paddingOf(context).bottom),
                  children: [
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 640),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                for (final tab in _Tab.values) ...[
                                  if (tab != _Tab.values.first) const SizedBox(width: 8),
                                  Expanded(
                                    child: GlassOption(
                                      height: 74,
                                      radius: 18,
                                      selected: _tab == tab,
                                      onTap: () => setState(() {
                                        _tab = tab;
                                        _notice = null;
                                      }),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 4),
                                        child: Column(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Icon(tab.icon, size: 21, color: Colors.white),
                                            const SizedBox(height: 6),
                                            FittedBox(
                                              fit: BoxFit.scaleDown,
                                              child: Text(
                                                // Two lines keep the longest label readable.
                                                tab == _Tab.security ? 'Security\nSettings' : tab.label,
                                                textAlign: TextAlign.center,
                                                style: AppText.label.copyWith(fontSize: 12.5, height: 1.2),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            gap24,
                            InlineNotice(message: _notice, tone: NoticeTone.success),
                            InlineNotice(message: _error, tone: NoticeTone.error),
                            StepSwitcher(
                              child: KeyedSubtree(
                                key: ValueKey(_tab),
                                child: switch (_tab) {
                                  _Tab.notifications => _buildNotifications(),
                                  _Tab.policies => _buildPolicies(),
                                  _Tab.switchRole => _buildSwitchRole(),
                                  _Tab.security => _buildSecurity(),
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotifications() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle(Icons.contrast_rounded, 'Appearance'),
        gap14,
        ValueListenableBuilder<Appearance>(
          valueListenable: appearance,
          builder: (context, mode, _) => Row(
            children: [
              for (final (option, icon, label) in const [
                (Appearance.dark, Icons.dark_mode_outlined, 'Dark'),
                (Appearance.light, Icons.light_mode_outlined, 'Light'),
              ]) ...[
                if (option == Appearance.light) const SizedBox(width: 10),
                Expanded(
                  child: GlassOption(
                    height: 56,
                    radius: 18,
                    selected: mode == option,
                    onTap: () => appearance.value = option,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(icon, size: 20, color: Colors.white),
                        const SizedBox(width: 8),
                        Text(label, style: _tileTitle),
                        if (mode == option) ...[
                          const SizedBox(width: 6),
                          const Icon(Icons.check_circle_rounded, size: 16, color: Colors.white),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        gap24,
        const _SectionTitle(Icons.notifications_none_rounded, 'Notification Settings'),
        gap14,
        for (final pref in NotificationPref.forRole(_user.role)) ...[
          _ToggleTile(
            icon: switch (pref) {
              NotificationPref.email => Icons.mail_outline_rounded,
              NotificationPref.calendar => Icons.calendar_month_outlined,
              NotificationPref.push => Icons.notifications_active_outlined,
              NotificationPref.messages => Icons.chat_bubble_outline_rounded,
              NotificationPref.weeklyDigest => Icons.summarize_outlined,
              NotificationPref.anonymousPool => Icons.visibility_off_outlined,
              NotificationPref.achievements => Icons.emoji_events_outlined,
              NotificationPref.community => Icons.groups_outlined,
            },
            title: pref.title,
            subtitle: pref.subtitle,
            value: _settings.isEnabled(_user, pref),
            onChanged: (v) => _setPref(pref, v),
          ),
          const SizedBox(height: 10),
        ],
        gap14,
        const _SectionTitle(Icons.phone_iphone_rounded, 'On This Device'),
        gap14,
        _ToggleTile(
          icon: Icons.checklist_rounded,
          title: 'TODO Reminders',
          subtitle: 'A reminder an hour before a task is due and when it\'s due, even when the app is closed',
          value: DeviceNotifications.instance.todoRemindersOn,
          onChanged: _setTodoReminders,
        ),
        const SizedBox(height: 10),
      ],
    );
  }

  Future<void> _setTodoReminders(bool on) async {
    setState(() => _error = null);
    if (on && !await DeviceNotifications.instance.requestPermission()) {
      if (mounted) setState(() => _error = _permissionHint);
    }
    await DeviceNotifications.instance.setTodoRemindersOn(on);
    if (mounted) setState(() {});
  }

  static const _permissionHint =
      'Notifications are turned off for Synap Mentor on this phone. Allow them in your phone\'s settings to get them.';

  Widget _buildPolicies() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle(Icons.description_outlined, 'Policies'),
        gap14,
        for (final (policy, icon) in [
          for (final (i, p) in SettingsService.policies.indexed)
            (
              p,
              const [
                    Icons.subscriptions_outlined,
                    Icons.report_gmailerrorred_outlined,
                    Icons.group_add_outlined,
                    Icons.payments_outlined,
                    Icons.privacy_tip_outlined,
                  ].elementAtOrNull(i) ??
                  Icons.description_outlined,
            ),
        ]) ...[
          _LinkTile(icon: icon, title: policy.title, subtitle: policy.subtitle, onTap: () => _openPolicy(policy)),
          const SizedBox(height: 10),
        ],
        _LinkTile(
          icon: Icons.support_agent_outlined,
          title: 'Contact Support',
          subtitle: 'Reach our team for help',
          onTap: () => Navigator.of(context).push(glassRoute(SupportScreen(user: _user))),
        ),
        const SizedBox(height: 10),
        _LinkTile(
          icon: Icons.tour_outlined,
          title: 'App Tour',
          subtitle: 'See the guided tour of the app again',
          onTap: () {
            Navigator.of(context).popUntil((route) => route.isFirst);
            AppTourMemory.replay.value++;
          },
        ),
        if (_user.role != UserRole.seeker) ...[
          gap24,
          const _SectionTitle(Icons.shield_outlined, 'Your Privacy Choices'),
          gap14,
          _ToggleTile(
            icon: Icons.insights_outlined,
            title: 'Share Analytics Data',
            subtitle: 'Help improve the platform by sharing usage data',
            value: _settings.sharesAnalytics(_user),
            onChanged: (v) => _settings.setSharesAnalytics(_user, v),
          ),
        ],
        gap24,
        const _SectionTitle(Icons.event_note_outlined, 'Session Policy'),
        gap14,
        for (final policy in SettingsService.sessionPolicies) ...[
          GlassWell(
            radius: 18,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => _openPolicy(policy),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(policy.title, style: _tileTitle),
                            const SizedBox(height: 4),
                            Text(
                              policy.body,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.caption.copyWith(color: AppColors.white(0.82)),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right_rounded, color: Colors.white),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _buildSwitchRole() {
    final other = _otherRole;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle(Icons.sync_rounded, 'Switch Role'),
        gap14,
        GlassPanel(
          radius: 24,
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'You\'re signed in as a ${_user.role.label}. Switch to ${other.label} mode with this same account. '
                'Switching will:',
                style: AppText.body,
              ),
              gap14,
              for (final line in [
                other == UserRole.solver
                    ? 'Make your solver profile visible and bookable'
                    : 'Let you explore and book solvers',
                'Sign you out of all devices. Sign in again with the same email and password',
                'Keep your wallet, subscriptions and bookings safe for when you switch back',
                'Keep your verification, so nothing needs to be redone',
              ])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 3),
                        child: Icon(Icons.check_rounded, size: 16, color: Colors.white),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(line, style: AppText.caption.copyWith(color: AppColors.white(0.85))),
                      ),
                    ],
                  ),
                ),
              gap24,
              PrimaryPillButton(label: 'Switch to ${other.label} Mode', loading: _switching, onPressed: _switchRole),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSecurity() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Heading(
          icon: Icons.shield_outlined,
          title: 'Security Settings',
          subtitle: 'Manage your account security and take action when needed.',
        ),
        gap14,
        _LinkTile(
          icon: Icons.key_outlined,
          title: 'Change Password',
          subtitle: 'Update your password to keep your account secure',
          onTap: _changePassword,
        ),
        if (_user.role == UserRole.solver) ...[
          const SizedBox(height: 10),
          _LinkTile(
            icon: Icons.phone_iphone_rounded,
            title: 'Change Mobile Number',
            subtitle: 'Move your verified number, confirmed with a code sent to your email',
            onTap: _changePhone,
          ),
        ],
        gap24,
        GlassPanel(
          radius: 24,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.warning_amber_rounded, size: 20, color: AppColors.error),
                  const SizedBox(width: 8),
                  Text('Danger Zone', style: _tileTitle.copyWith(fontSize: 16, color: AppColors.error)),
                ],
              ),
              gap14,
              _LinkTile(
                icon: Icons.pause_circle_outline_rounded,
                title: 'Deactivate Account',
                subtitle: 'Temporarily disable your account',
                danger: true,
                onTap: _deactivate,
              ),
              const SizedBox(height: 10),
              _LinkTile(
                icon: Icons.delete_outline_rounded,
                title: 'Delete Account',
                subtitle: 'Permanently remove your account',
                danger: true,
                onTap: _delete,
              ),
            ],
          ),
        ),
      ],
    );
  }

  static const _tileTitle = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white);
}

// ---- Sheets -------------------------------------------------------------------------

class _PolicySheet extends StatelessWidget {
  const _PolicySheet({required this.policy});

  final PolicyDoc policy;

  @override
  Widget build(BuildContext context) {
    return FlowSheetFrame(
      title: policy.title,
      body: Text(policy.body, style: AppText.body),
      footer: GlassPillButton(label: 'Close', onPressed: () => Navigator.of(context).pop()),
    );
  }
}

class _ConfirmSheet extends StatelessWidget {
  const _ConfirmSheet({required this.title, required this.message, required this.confirmLabel});

  final String title;
  final String message;
  final String confirmLabel;

  @override
  Widget build(BuildContext context) {
    return FlowSheetFrame(
      title: title,
      body: Text(message, style: AppText.body),
      footer: Row(
        children: [
          Expanded(
            child: GlassPillButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop(false)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: PrimaryPillButton(label: confirmLabel, onPressed: () => Navigator.of(context).pop(true)),
          ),
        ],
      ),
    );
  }
}

class _ChangePasswordSheet extends StatefulWidget {
  const _ChangePasswordSheet();

  @override
  State<_ChangePasswordSheet> createState() => _ChangePasswordSheetState();
}

class _ChangePasswordSheetState extends State<_ChangePasswordSheet> {
  final _current = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  final _errors = <String, String?>{};
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _error = null;
      _errors
        ..['current'] = _current.text.isEmpty ? 'Enter your current password.' : null
        ..['new'] = Validators.newPassword(_new.text)
        ..['confirm'] = Validators.confirmPassword(_new.text, _confirm.text);
    });
    if (_errors.values.any((e) => e != null)) return;
    setState(() => _saving = true);
    try {
      await AuthService.instance.changePassword(_current.text, _new.text);
      if (mounted) Navigator.of(context).pop(true);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FlowSheetFrame(
      title: 'Change Password',
      body: AutofillGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InlineNotice(message: _error, tone: NoticeTone.error),
            const Text('Current Password', style: _label),
            gap8,
            GlassTextField(
              controller: _current,
              hint: 'Enter current password',
              obscure: true,
              autofillHints: const [AutofillHints.password],
              errorText: _errors['current'],
              onChanged: (_) => setState(() => _errors['current'] = null),
            ),
            gap14,
            const Text('New Password', style: _label),
            gap8,
            GlassTextField(
              controller: _new,
              hint: 'Enter new password',
              obscure: true,
              autofillHints: const [AutofillHints.newPassword],
              errorText: _errors['new'],
              onChanged: (_) => setState(() => _errors['new'] = null),
            ),
            PasswordChecklist(password: _new.text, visible: true),
            gap14,
            const Text('Confirm New Password', style: _label),
            gap8,
            GlassTextField(
              controller: _confirm,
              hint: 'Confirm new password',
              obscure: true,
              autofillHints: const [AutofillHints.newPassword],
              errorText: _errors['confirm'],
              onChanged: (_) => setState(() => _errors['confirm'] = null),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      footer: Row(
        children: [
          Expanded(
            child: GlassPillButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop(false)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: PrimaryPillButton(label: 'Update Password', loading: _saving, onPressed: _submit),
          ),
        ],
      ),
    );
  }

  static const _label = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white);
}

/// Solvers move their verified mobile number: the password and the new number,
/// then the code the server emails. Pops `true` once changed (every session
/// has ended by then).
class _ChangePhoneSheet extends StatefulWidget {
  const _ChangePhoneSheet({required this.user});

  final AppUser user;

  @override
  State<_ChangePhoneSheet> createState() => _ChangePhoneSheetState();
}

class _ChangePhoneSheetState extends State<_ChangePhoneSheet> {
  final _password = TextEditingController();
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _errors = <String, String?>{};
  late final _country = Countries.byName(widget.user.profile.countryName);

  /// The code has been emailed; the second step is showing.
  bool _codeSent = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _error = null;
      _errors
        ..['password'] = _password.text.isEmpty ? 'Enter your current password.' : null
        ..['phone'] = _phone.text.isEmpty ? 'Enter your new mobile number.' : null;
    });
    if (_errors.values.any((e) => e != null)) return;
    setState(() => _saving = true);
    try {
      await AuthService.instance.requestPhoneChange(_password.text, _phone.text);
      if (mounted) setState(() => _codeSent = true);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirm() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _error = null;
      _errors['code'] = _code.text.trim().length != 6 ? 'Enter the 6-digit code.' : null;
    });
    if (_errors['code'] != null) return;
    setState(() => _saving = true);
    try {
      await AuthService.instance.confirmPhoneChange(_code.text);
      if (mounted) Navigator.of(context).pop(true);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final country = _country;
    return FlowSheetFrame(
      title: 'Change Mobile Number',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InlineNotice(message: _error, tone: NoticeTone.error),
          if (!_codeSent) ...[
            Text(
              'We\'ll email a code to ${widget.user.email} to confirm. Once it\'s changed you\'ll be signed out '
              'everywhere and sign in again.',
              style: AppText.caption,
            ),
            gap14,
            const Text('Current Password', style: _ChangePasswordSheetState._label),
            gap8,
            GlassTextField(
              controller: _password,
              hint: 'Enter current password',
              obscure: true,
              autofillHints: const [AutofillHints.password],
              errorText: _errors['password'],
              onChanged: (_) => setState(() => _errors['password'] = null),
            ),
            gap14,
            const Text('New Mobile Number', style: _ChangePasswordSheetState._label),
            gap8,
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 92,
                  child: GlassSelectField(value: country?.dialCode, hint: '+ —', locked: true),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: GlassTextField(
                    controller: _phone,
                    hint: 'Phone number',
                    keyboardType: TextInputType.phone,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(country?.phoneDigits ?? 15),
                    ],
                    errorText: _errors['phone'],
                    onChanged: (_) => setState(() => _errors['phone'] = null),
                  ),
                ),
              ],
            ),
          ] else ...[
            Text('Enter the 6-digit code we emailed to ${widget.user.email}.', style: AppText.caption),
            gap14,
            GlassTextField(
              controller: _code,
              hint: '6-digit code',
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
              errorText: _errors['code'],
              onChanged: (_) => setState(() => _errors['code'] = null),
              onSubmitted: (_) => _confirm(),
            ),
            gap8,
            UnderlineLink(label: 'Didn\'t get it? Send again', onTap: _saving ? null : _sendCode),
          ],
        ],
      ),
      footer: Row(
        children: [
          Expanded(
            child: GlassPillButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop(false)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: PrimaryPillButton(
              label: _codeSent ? 'Change Number' : 'Send Code',
              loading: _saving,
              onPressed: _codeSent ? _confirm : _sendCode,
            ),
          ),
        ],
      ),
    );
  }
}

/// Deactivate (reason optional) or delete (reason and typed "DELETE" required).
class _AccountActionSheet extends StatefulWidget {
  const _AccountActionSheet({required this.delete});

  final bool delete;

  @override
  State<_AccountActionSheet> createState() => _AccountActionSheetState();
}

class _AccountActionSheetState extends State<_AccountActionSheet> {
  static const _reasons = [
    'I\'m taking a break',
    'I didn\'t find it useful',
    'Privacy concerns',
    'Too expensive',
    'I have another account',
    'Other',
  ];

  final _details = TextEditingController();
  final _confirmText = TextEditingController();
  final _password = TextEditingController();
  String? _reason;
  bool _working = false;
  String? _error;
  final _errors = <String, String?>{};

  bool get _delete => widget.delete;

  @override
  void dispose() {
    _details.dispose();
    _confirmText.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _pickReason() async {
    final picked = await showGlassPicker(
      context,
      title: 'Reason',
      options: _reasons,
      label: (r) => r,
      selected: _reason,
    );
    if (picked != null) {
      setState(() {
        _reason = picked;
        _errors['reason'] = null;
      });
    }
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    final details = _details.text.trim();
    setState(() {
      _error = null;
      _errors
        ..['reason'] = _delete && _reason == null ? 'Select a reason.' : null
        ..['details'] = details.isNotEmpty && details.length < 10
            ? 'Use at least 10 characters, or leave it empty.'
            : null
        ..['password'] = _password.text.isEmpty ? 'Enter your password.' : null
        ..['confirm'] = _delete && _confirmText.text.trim() != 'DELETE' ? 'Type DELETE to confirm.' : null;
    });
    if (_errors.values.any((e) => e != null)) return;
    setState(() => _working = true);
    try {
      final auth = AuthService.instance;
      if (_delete) {
        await auth.deleteAccount(reason: _reason!, details: details.isEmpty ? null : details, password: _password.text);
      } else {
        await auth.deactivateAccount(
          reason: _reason,
          details: details.isEmpty ? null : details,
          password: _password.text,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FlowSheetFrame(
      title: _delete ? 'Delete Account' : 'Deactivate Account',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InlineNotice(
            message: _delete
                ? 'This will permanently delete your account and all associated data. This cannot be undone.'
                : 'Your account will be temporarily disabled. You can reactivate it anytime by signing back in.',
            tone: NoticeTone.error,
            persistent: true,
          ),
          InlineNotice(message: _error, tone: NoticeTone.error),
          Text(_delete ? 'Reason *' : 'Reason (optional)', style: _label),
          gap8,
          GlassSelectField(value: _reason, hint: 'Select a reason', errorText: _errors['reason'], onTap: _pickReason),
          gap14,
          const Text('Additional Details (optional)', style: _label),
          gap8,
          GlassTextField(
            controller: _details,
            hint: 'Tell us more (min 10 characters)',
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            errorText: _errors['details'],
            onChanged: (_) => setState(() => _errors['details'] = null),
          ),
          gap14,
          const Text('Current Password *', style: _label),
          gap8,
          GlassTextField(
            controller: _password,
            hint: 'Enter your password to confirm',
            obscure: true,
            autofillHints: const [AutofillHints.password],
            errorText: _errors['password'],
            onChanged: (_) => setState(() => _errors['password'] = null),
          ),
          if (_delete) ...[
            gap14,
            const Text('Type "DELETE" to confirm', style: _label),
            gap8,
            GlassTextField(
              controller: _confirmText,
              hint: 'DELETE',
              textCapitalization: TextCapitalization.characters,
              errorText: _errors['confirm'],
              onChanged: (_) => setState(() => _errors['confirm'] = null),
            ),
          ],
        ],
      ),
      footer: Row(
        children: [
          Expanded(
            child: GlassPillButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop(false)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: PrimaryPillButton(
              label: _delete ? 'Delete Account' : 'Deactivate Account',
              loading: _working,
              onPressed: _submit,
            ),
          ),
        ],
      ),
    );
  }

  static const _label = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white);
}

// ---- Pieces ---------------------------------------------------------------------------

class _Heading extends StatelessWidget {
  const _Heading({required this.icon, required this.title, required this.subtitle});

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        GlassIconBadge(icon: icon, size: 48),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Colors.white),
              ),
              const SizedBox(height: 2),
              Text(subtitle, style: AppText.caption),
            ],
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.icon, this.title);

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 22, color: Colors.white),
        const SizedBox(width: 10),
        Text(
          title,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Colors.white),
        ),
      ],
    );
  }
}

class _ToggleTile extends StatelessWidget {
  const _ToggleTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return GlassWell(
      radius: 18,
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
      child: MergeSemantics(
        child: Row(
          children: [
            Icon(icon, size: 22, color: Colors.white),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: _SettingsScreenState._tileTitle),
                  const SizedBox(height: 2),
                  Text(subtitle, style: AppText.caption.copyWith(fontSize: 12)),
                ],
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              thumbColor: WidgetStateProperty.resolveWith(
                (s) => s.contains(WidgetState.selected) ? AppColors.primary : AppColors.white(0.8),
              ),
              trackColor: WidgetStateProperty.resolveWith(
                (s) => s.contains(WidgetState.selected) ? Colors.white : AppColors.white(0.14),
              ),
              trackOutlineColor: WidgetStateProperty.all(AppColors.white(0.3)),
            ),
          ],
        ),
      ),
    );
  }
}

class _LinkTile extends StatelessWidget {
  const _LinkTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.error : Colors.white;
    return GlassWell(
      radius: 18,
      error: danger,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
            child: Row(
              children: [
                Icon(icon, size: 22, color: color),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: _SettingsScreenState._tileTitle.copyWith(color: color)),
                      const SizedBox(height: 2),
                      Text(subtitle, style: AppText.caption.copyWith(fontSize: 12)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: color),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
