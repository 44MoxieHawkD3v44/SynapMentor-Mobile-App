import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../api/auth_api.dart';
import '../core/navigation.dart';
import '../core/theme.dart';
import '../services/auth_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/glass_controls.dart';
import 'booking_sheet.dart';
import 'register_screen.dart';

/// Signs in (or up) with GitHub and returns the user, or null if they backed
/// out. [signup] with a [role] creates the account straight away; otherwise
/// a GitHub account that isn't linked yet asks for a role and the EULA first.
///
/// The app starts the sign-in with the API itself, shows only GitHub's page,
/// and hands GitHub's answer back to the API, so the session lands in the
/// app's own client.
Future<AppUser?> continueWithGitHub(
  BuildContext context, {
  bool signup = false,
  UserRole? role,
  String? referralCode,
}) async {
  final start = await AuthApi.githubStart(signup: signup, role: role?.name, referralCode: referralCode);
  if (!context.mounted) return null;
  final answer = await Navigator.of(context)
      .push<Map<String, String>>(glassRoute(_GitHubPage(authorizeUrl: start.authorizeUrl)));
  if (answer == null || !context.mounted) return null;
  final code = answer['code'];
  final state = answer['state'];
  if (code == null || state == null) {
    throw AuthException(
      answer['error'] == 'access_denied'
          ? 'GitHub sign-in was cancelled.'
          : (answer['message'] ?? 'GitHub sign-in didn\'t finish. Please try again.'),
    );
  }
  final result = await AuthApi.githubCallback({'code': code, 'state': state}, start.nonce);
  final auth = AuthService.instance;
  final pending = result.pendingSignup;
  if (pending != null) {
    if (!context.mounted) return null;
    final picked = role ?? await _pickRole(context);
    if (picked == null) return null;
    return auth.completeGitHubSignup(signupCookie: pending, role: picked);
  }
  return auth.finishGitHubSignIn();
}

/// GitHub's own sign-in page. When GitHub sends the user back, the page
/// closes with its answer (code and state, or an error) instead of loading
/// it.
class _GitHubPage extends StatefulWidget {
  const _GitHubPage({required this.authorizeUrl});

  final Uri authorizeUrl;

  @override
  State<_GitHubPage> createState() => _GitHubPageState();
}

class _GitHubPageState extends State<_GitHubPage> {
  bool _loading = true;
  bool _done = false;

  late final _controller = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) {
          final url = Uri.tryParse(request.url);
          if (url == null || !url.path.endsWith('/auth/oauth/github/callback')) return NavigationDecision.navigate;
          _finish(url.queryParameters);
          return NavigationDecision.prevent;
        },
        onPageFinished: (_) {
          if (mounted) setState(() => _loading = false);
        },
        onWebResourceError: (error) {
          if (error.isForMainFrame == false) return;
          _finish({'message': 'Couldn\'t reach GitHub. Check your connection and try again.'});
        },
      ),
    )
    ..loadRequest(widget.authorizeUrl);

  void _finish(Map<String, String> answer) {
    if (_done || !mounted) return;
    _done = true;
    Navigator.of(context).pop(answer);
  }

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
                    icon: Icons.close_rounded,
                    tooltip: 'Cancel',
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  Expanded(
                    child: Text('GITHUB', textAlign: TextAlign.center, style: AppText.heading.copyWith(fontSize: 20)),
                  ),
                  const SizedBox(width: 44),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: Stack(
                    children: [
                      WebViewWidget(controller: _controller),
                      if (_loading)
                        const Center(child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// First GitHub sign-in: how they'll use Synap Mentor, and the EULA.
Future<UserRole?> _pickRole(BuildContext context) => showModalBottomSheet<UserRole>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  barrierColor: Colors.black.withValues(alpha: 0.35),
  builder: (_) => const _RoleSheet(),
);

class _RoleSheet extends StatefulWidget {
  const _RoleSheet();

  @override
  State<_RoleSheet> createState() => _RoleSheetState();
}

class _RoleSheetState extends State<_RoleSheet> {
  UserRole? _role;
  bool _eula = false;
  String? _error;

  Future<void> _showEula() async {
    final accepted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: AppColors.primary.withValues(alpha: 0.45),
      builder: (_) => const EulaSheet(),
    );
    if (accepted == true && mounted) setState(() => _eula = true);
  }

  void _continue() {
    if (_role == null || !_eula) {
      setState(() => _error = _role == null ? 'Choose how you\'ll use Synap Mentor.' : 'Accept the EULA to continue.');
      return;
    }
    Navigator.of(context).pop(_role);
  }

  @override
  Widget build(BuildContext context) {
    return FlowSheetFrame(
      title: 'Finish Signing Up',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Your GitHub account is verified. I am joining as a', style: AppText.label, textAlign: TextAlign.center),
          gap14,
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final role in UserRole.values) ...[
                if (role != UserRole.values.first) const SizedBox(width: 10),
                Expanded(
                  child: GlassChoiceTile(
                    icon: role == UserRole.seeker ? Icons.travel_explore_rounded : Icons.lightbulb_outline_rounded,
                    title: role.label,
                    subtitle: role == UserRole.seeker ? 'I have problems to solve' : 'I solve problems',
                    selected: _role == role,
                    compact: true,
                    onTap: () => setState(() {
                      _role = role;
                      _error = null;
                    }),
                  ),
                ),
              ],
            ],
          ),
          gap14,
          Row(
            children: [
              GlassCheckbox(
                value: _eula,
                onChanged: (v) => setState(() {
                  _eula = v;
                  _error = null;
                }),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('I have read and accept the ', style: AppText.label.copyWith(fontSize: 13)),
                    UnderlineLink(label: 'EULA', bold: true, onTap: _showEula),
                  ],
                ),
              ),
            ],
          ),
          FieldError(_error),
        ],
      ),
      footer: PrimaryPillButton(label: 'Continue', onPressed: _continue),
    );
  }
}
