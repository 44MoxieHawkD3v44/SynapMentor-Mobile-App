import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';
import '../services/auth_service.dart';
import '../services/explore_service.dart';
import '../services/session_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/glass_controls.dart';
import 'booking_sheet.dart';

/// Blocks the whole app while the signed-in seeker has a finished session
/// without a review. It can't be dismissed; it comes back after sign-out and
/// sign-in because it's derived from the sessions, not from screen state.
class ReviewGate extends StatefulWidget {
  const ReviewGate({super.key});

  @override
  State<ReviewGate> createState() => _ReviewGateState();
}

class _ReviewGateState extends State<ReviewGate> {
  // Sits above the app's Navigator, so it brings its own Overlay for text
  // selection in the form fields.
  final _entry = OverlayEntry(builder: (_) => const _GateHost());

  @override
  void dispose() {
    _entry
      ..remove()
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Overlay(initialEntries: [_entry]);
}

class _GateHost extends StatelessWidget {
  const _GateHost();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SessionService.instance,
      builder: (context, _) {
        final user = AuthService.instance.currentUser;
        if (user == null) return const SizedBox.shrink();
        // Solvers review too; their minutes are credited only after it.
        final solver = user.role == UserRole.solver;
        final pending = solver
            ? SessionService.instance.pendingSolverReview(user)
            : SessionService.instance.pendingReview(user);
        if (pending == null) return const SizedBox.shrink();
        return Stack(
          children: [
            // Swallows every tap on the app underneath.
            Positioned.fill(child: ModalBarrier(color: Colors.black.withValues(alpha: 0.45), dismissible: false)),
            Material(
              type: MaterialType.transparency,
              child: solver
                  ? _SolverReviewForm(key: ValueKey(pending.id), booking: pending)
                  : _ReviewForm(key: ValueKey(pending.id), user: user, booking: pending),
            ),
          ],
        );
      },
    );
  }
}

class _ReviewForm extends StatefulWidget {
  const _ReviewForm({super.key, required this.user, required this.booking});

  final AppUser user;
  final Booking booking;

  @override
  State<_ReviewForm> createState() => _ReviewFormState();
}

class _ReviewFormState extends State<_ReviewForm> {
  final _feedback = TextEditingController();
  final _learned = TextEditingController();
  final _helpful = <String>{};
  final _unclear = <String>{};

  /// What the seeker typed after choosing Others.
  final _helpfulOther = TextEditingController();
  final _unclearOther = TextEditingController();
  int _rating = 0;
  bool? _rebook;
  bool _saving = false;
  String? _error;
  final _errors = <String, String?>{};

  static const _others = 'Others';

  @override
  void dispose() {
    _feedback.dispose();
    _learned.dispose();
    _helpfulOther.dispose();
    _unclearOther.dispose();
    super.dispose();
  }

  /// The chosen options in the order they're listed, with Others replaced by
  /// what was typed. The server keeps them comma-joined, so commas are left out.
  static List<String> _answers(List<String> options, Set<String> chosen, TextEditingController other) => [
    for (final o in options)
      if (chosen.contains(o)) o == _others ? '$_others: ${other.text.trim().replaceAll(',', ';')}' : o,
  ];

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    String? describe(Set<String> chosen, TextEditingController other) =>
        chosen.contains(_others) && other.text.trim().isEmpty ? 'Tell us what you mean by Others.' : null;
    setState(() {
      _errors
        ..['helpful'] = describe(_helpful, _helpfulOther)
        ..['unclear'] = describe(_unclear, _unclearOther);
    });
    if (_errors.values.any((e) => e != null)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await SessionService.instance.submitReview(
        widget.booking,
        SessionReview(
          rating: _rating,
          helpful: _answers(SessionReview.helpfulOptions, _helpful, _helpfulOther),
          unclear: _answers(SessionReview.unclearOptions, _unclear, _unclearOther),
          feedback: _feedback.text.trim(),
          learned: _learned.text.trim(),
          wouldRebook: _rebook,
        ),
      );
      // The gate rebuilds without this form once the review is stored.
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // PopScope keeps the system back gesture from getting around the review.
    return PopScope(
      canPop: false,
      child: FlowSheetFrame(
        title: 'Session Feedback',
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Feedback is required - please rate and submit to continue.', style: AppText.caption),
            gap14,
            InlineNotice(message: _error, tone: NoticeTone.error),
            const Text('What was helpful?', style: _label),
            gap8,
            _Choices(
              options: SessionReview.helpfulOptions,
              icon: Icons.check_circle_outline_rounded,
              chosen: _helpful,
              onToggle: (o) => setState(() {
                _helpful.contains(o) ? _helpful.remove(o) : _helpful.add(o);
                _errors['helpful'] = null;
              }),
            ),
            if (_helpful.contains(_others)) ...[
              gap8,
              GlassTextField(
                controller: _helpfulOther,
                hint: 'What else was helpful?',
                inputFormatters: [LengthLimitingTextInputFormatter(200)],
                textCapitalization: TextCapitalization.sentences,
                errorText: _errors['helpful'],
                onChanged: (_) => setState(() => _errors['helpful'] = null),
              ),
            ],
            gap14,
            const Text('What was unclear?', style: _label),
            gap8,
            _Choices(
              options: SessionReview.unclearOptions,
              icon: Icons.close_rounded,
              chosen: _unclear,
              onToggle: (o) => setState(() {
                _unclear.contains(o) ? _unclear.remove(o) : _unclear.add(o);
                _errors['unclear'] = null;
              }),
            ),
            if (_unclear.contains(_others)) ...[
              gap8,
              GlassTextField(
                controller: _unclearOther,
                hint: 'What else was unclear?',
                inputFormatters: [LengthLimitingTextInputFormatter(200)],
                textCapitalization: TextCapitalization.sentences,
                errorText: _errors['unclear'],
                onChanged: (_) => setState(() => _errors['unclear'] = null),
              ),
            ],
            gap14,
            const Text('Overall rating', style: _label),
            gap8,
            Row(
              children: [
                for (var i = 1; i <= 5; i++) ...[
                  if (i > 1) const SizedBox(width: 8),
                  SizedBox(
                    width: 44,
                    child: Semantics(
                      label: '$i star${i == 1 ? '' : 's'}',
                      child: GlassOption(
                        height: 40,
                        radius: 10,
                        selected: i <= _rating,
                        onTap: () => setState(() => _rating = i),
                        child: Icon(
                          i <= _rating ? Icons.star_rounded : Icons.star_outline_rounded,
                          size: 20,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            gap14,
            const _OptionalLabel('Additional feedback'),
            gap8,
            GlassTextField(
              controller: _feedback,
              hint: 'Share any additional thoughts about the session...',
              maxLines: 3,
              inputFormatters: [LengthLimitingTextInputFormatter(2000)],
              textCapitalization: TextCapitalization.sentences,
            ),
            gap14,
            const _OptionalLabel('What did you learn?'),
            gap8,
            GlassTextField(
              controller: _learned,
              hint: 'What was your key takeaway or learning outcome from this session?',
              maxLines: 3,
              inputFormatters: [LengthLimitingTextInputFormatter(1000)],
              textCapitalization: TextCapitalization.sentences,
            ),
            gap14,
            const Text('Would you book again?', style: _label),
            gap8,
            Row(
              children: [
                for (final (label, icon, v) in const [
                  ('Yes', Icons.thumb_up_alt_outlined, true),
                  ('No', Icons.thumb_down_alt_outlined, false),
                ]) ...[
                  if (!v) const SizedBox(width: 10),
                  Expanded(
                    child: GlassOption(
                      height: 44,
                      radius: 12,
                      selected: _rebook == v,
                      onTap: () => setState(() => _rebook = v),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(icon, size: 16, color: Colors.white),
                          const SizedBox(width: 6),
                          Text(label, style: AppText.label.copyWith(fontSize: 14)),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
        // Rating is the one required answer.
        footer: PrimaryPillButton(label: 'Submit Feedback', loading: _saving, onPressed: _rating == 0 ? null : _submit),
      ),
    );
  }

  static const _label = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white);
}

/// A field label followed by a muted "(optional)".
class _OptionalLabel extends StatelessWidget {
  const _OptionalLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text.rich(
    TextSpan(
      text: text,
      style: _ReviewFormState._label,
      children: [
        TextSpan(
          text: ' (optional)',
          style: AppText.caption.copyWith(fontSize: 12, fontWeight: FontWeight.w400),
        ),
      ],
    ),
  );
}

/// Two columns of toggles, each with [icon] before its label.
class _Choices extends StatelessWidget {
  const _Choices({required this.options, required this.icon, required this.chosen, required this.onToggle});

  final List<String> options;
  final IconData icon;
  final Set<String> chosen;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    return OptionGrid(
      columns: 2,
      spacing: 8,
      children: [
        for (final o in options)
          GlassOption(
            height: 40,
            radius: 12,
            selected: chosen.contains(o),
            onTap: () => onToggle(o),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(icon, size: 15, color: chosen.contains(o) ? Colors.white : AppColors.white(0.6)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      o,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.label.copyWith(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// The solver's side of the mandatory review.
class _SolverReviewForm extends StatefulWidget {
  const _SolverReviewForm({super.key, required this.booking});

  final Booking booking;

  @override
  State<_SolverReviewForm> createState() => _SolverReviewFormState();
}

class _SolverReviewFormState extends State<_SolverReviewForm> {
  final _feedback = TextEditingController();
  final _punctualityOther = TextEditingController();
  final _engagementOther = TextEditingController();
  int _rating = 0;
  SeekerPunctuality? _punctuality;
  SeekerEngagement? _engagement;
  bool _saving = false;
  String? _error;
  final _errors = <String, String?>{};

  @override
  void dispose() {
    _feedback.dispose();
    _punctualityOther.dispose();
    _engagementOther.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    final otherPunctuality = _punctuality == SeekerPunctuality.other;
    final otherEngagement = _engagement == SeekerEngagement.other;
    setState(() {
      _error = null;
      _errors
        ..['rating'] = _rating == 0 ? 'Rate the session.' : null
        ..['punctuality'] = _punctuality == null
            ? 'Choose how punctual the seeker was.'
            : (otherPunctuality && _punctualityOther.text.trim().isEmpty ? 'Describe it in a few words.' : null)
        ..['engagement'] = _engagement == null
            ? 'Choose how engaged the seeker was.'
            : (otherEngagement && _engagementOther.text.trim().isEmpty ? 'Describe it in a few words.' : null)
        ..['feedback'] = _feedback.text.trim().length < 10 ? 'Share at least 10 characters of feedback.' : null;
    });
    if (_errors.values.any((e) => e != null)) return;
    setState(() => _saving = true);
    try {
      await SessionService.instance.submitSolverReview(
        widget.booking,
        SolverSessionReview(
          rating: _rating,
          punctuality: _punctuality!,
          engagement: _engagement!,
          punctualityOther: otherPunctuality ? _punctualityOther.text.trim() : '',
          engagementOther: otherEngagement ? _engagementOther.text.trim() : '',
          feedback: _feedback.text.trim(),
        ),
      );
      // The gate rebuilds without this form once the review is stored.
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.booking;
    const label = _ReviewFormState._label;
    return PopScope(
      canPop: false,
      child: FlowSheetFrame(
        title: 'Review Session',
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Student', style: AppText.caption),
            const SizedBox(height: 2),
            Text(b.seekerLabel, style: label),
            gap8,
            Text('Session', style: AppText.caption),
            const SizedBox(height: 2),
            Text(b.title, style: label),
            gap14,
            InlineNotice(message: _error, tone: NoticeTone.error),
            const Text('Rating *', style: label),
            gap8,
            Row(
              children: [
                for (var i = 1; i <= 5; i++)
                  IconButton(
                    tooltip: '$i star${i == 1 ? '' : 's'}',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setState(() {
                      _rating = i;
                      _errors['rating'] = null;
                    }),
                    icon: Icon(
                      i <= _rating ? Icons.star_rounded : Icons.star_outline_rounded,
                      size: 28,
                      color: Colors.white,
                    ),
                  ),
              ],
            ),
            FieldError(_errors['rating']),
            gap14,
            const Text('Seeker Punctuality *', style: label),
            gap8,
            _SingleChoice(
              options: [for (final p in SeekerPunctuality.values) p.label],
              selected: _punctuality?.label,
              onSelect: (i) => setState(() {
                _punctuality = SeekerPunctuality.values[i];
                _errors['punctuality'] = null;
              }),
            ),
            if (_punctuality == SeekerPunctuality.other) ...[
              gap8,
              GlassTextField(
                controller: _punctualityOther,
                hint: 'Describe their punctuality',
                inputFormatters: [LengthLimitingTextInputFormatter(200)],
                textCapitalization: TextCapitalization.sentences,
                onChanged: (_) => setState(() => _errors['punctuality'] = null),
              ),
            ],
            FieldError(_errors['punctuality']),
            gap14,
            const Text('Seeker Engagement *', style: label),
            gap8,
            _SingleChoice(
              options: [for (final e in SeekerEngagement.values) e.label],
              selected: _engagement?.label,
              onSelect: (i) => setState(() {
                _engagement = SeekerEngagement.values[i];
                _errors['engagement'] = null;
              }),
            ),
            if (_engagement == SeekerEngagement.other) ...[
              gap8,
              GlassTextField(
                controller: _engagementOther,
                hint: 'Describe their engagement',
                inputFormatters: [LengthLimitingTextInputFormatter(200)],
                textCapitalization: TextCapitalization.sentences,
                onChanged: (_) => setState(() => _errors['engagement'] = null),
              ),
            ],
            FieldError(_errors['engagement']),
            gap14,
            const Text('Feedback *', style: label),
            gap8,
            GlassTextField(
              controller: _feedback,
              hint: 'Share at least 10 characters of feedback...',
              maxLines: 4,
              inputFormatters: [LengthLimitingTextInputFormatter(2000)],
              textCapitalization: TextCapitalization.sentences,
              errorText: _errors['feedback'],
              onChanged: (_) => setState(() => _errors['feedback'] = null),
            ),
          ],
        ),
        footer: PrimaryPillButton(label: 'Submit Review', loading: _saving, onPressed: _submit),
      ),
    );
  }
}

/// Two columns of options where one can be chosen; the last one spans the
/// row when it's on its own, as Other does.
class _SingleChoice extends StatelessWidget {
  const _SingleChoice({required this.options, required this.selected, required this.onSelect});

  final List<String> options;
  final String? selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    Widget option(int i) => GlassOption(
      height: 40,
      radius: 12,
      selected: options[i] == selected,
      onTap: () => onSelect(i),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(options[i], style: AppText.label.copyWith(fontSize: 13)),
        ),
      ),
    );
    final paired = options.length.isOdd ? options.length - 1 : options.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OptionGrid(columns: 2, spacing: 8, children: [for (var i = 0; i < paired; i++) option(i)]),
        if (paired < options.length) ...[const SizedBox(height: 8), option(paired)],
      ],
    );
  }
}
