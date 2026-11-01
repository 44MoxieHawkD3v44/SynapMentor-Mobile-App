import 'dart:async';

import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/theme.dart';
import '../services/auth_service.dart';
import '../services/demo_guard.dart';
import '../services/skill_verification_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';
import '../widgets/glass_select.dart';
import '../widgets/html_text.dart';
import '../widgets/true_colors.dart';

enum _View { overview, portfolio, review, demoIntro, demoRules, demoLive, content, verified }

/// Solver skill verification in one screen: portfolio → live demo → content,
/// each reviewed by an admin before the next step unlocks. Every skill is
/// verified on its own.
class SkillVerificationScreen extends StatefulWidget {
  const SkillVerificationScreen({super.key, required this.user});

  final AppUser user;

  @override
  State<SkillVerificationScreen> createState() => _SkillVerificationScreenState();
}

class _SkillVerificationScreenState extends State<SkillVerificationScreen> {
  final _service = SkillVerificationService.instance;

  _View _view = _View.overview;
  SkillApplication? _app;

  /// The step shown on the review view.
  VerifyStep _reviewStep = VerifyStep.portfolio;
  bool _waiting = false;
  bool _loading = false;
  String? _error;

  // Portfolio
  final _focusSearch = TextEditingController();
  final _skillSearch = TextEditingController();
  final _problem = TextEditingController();
  final _solution = TextEditingController();
  final _linkedIn = TextEditingController();
  final _links = <TextEditingController>[];

  /// One skill, then one or more of its focus areas.
  String? _skill;
  final _focusAreas = <String>[];

  /// Keeps the skill and focus-area lists open until the choice is confirmed.
  bool _choosingSkill = false;
  PlatformFile? _pdf;
  int? _pdfBytes;
  final _errors = <String, String>{};

  // Live demo
  bool _understood = false;

  /// The demo started on the server.
  DemoSession? _session;

  // Content
  /// Verification content is always Blog + Video.
  static const _format = ContentFormat.blogVideo;
  final _title = TextEditingController();
  final _body = TextEditingController();
  bool _preview = false;
  String? _presentation;
  PlatformFile? _media;
  int? _mediaBytes;

  /// The portfolio focus area the content is about.
  String? _contentArea;

  List<SkillApplication> get _apps => _service.applications(widget.user);

  @override
  void initState() {
    super.initState();
    _app = _apps.where((a) => !a.verified).firstOrNull ?? _apps.firstOrNull;
    _service.addListener(_onChanged);
    _load();
    // Admin reviews land on the server; pick them up without leaving the screen.
    _poll = Timer.periodic(const Duration(seconds: 15), (_) => _refresh());
    _resume; // and when the app comes back
  }

  Timer? _poll;
  late final AppLifecycleListener _resume = AppLifecycleListener(onResume: _refresh);

  /// Reloads the statuses in the background, except during the live demo.
  void _refresh() {
    if (!mounted || _view == _View.demoLive || _loading) return;
    _service.load(widget.user);
  }

  /// Loads the skills and the solver's verification from the server.
  Future<void> _load() async {
    await _service.load(widget.user);
    if (!mounted) return;
    setState(() {
      _error = _service.loadError;
      if (_view == _View.overview) _app = _apps.where((a) => !a.verified).firstOrNull ?? _apps.firstOrNull;
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _resume.dispose();
    _service.removeListener(_onChanged);
    for (final c in [_focusSearch, _skillSearch, _problem, _solution, _linkedIn, _title, _body, ..._links]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The admin's decision arrives while the solver waits on a review.
  void _onChanged() {
    if (!mounted) return;
    setState(() {
      // A reload replaces the applications; follow the one on screen.
      final shown = _app;
      if (shown != null) {
        _app =
            _apps.where((a) => a.id == shown.id).firstOrNull ??
            _apps.where((a) => a.skill.toLowerCase() == shown.skill.toLowerCase()).firstOrNull ??
            shown;
      }
      final app = _app;
      if (!_waiting || _view != _View.review || app == null) return;
      if (app.statusOf(_reviewStep) == StepStatus.underReview) return;
      _waiting = false;
      _view = app.verified ? _View.verified : _View.overview;
    });
  }

  void _go(_View view) => setState(() {
    _view = view;
    _error = null;
    _waiting = view == _View.review && _app?.statusOf(_reviewStep) == StepStatus.underReview;
  });

  // ---- Navigation between steps ---------------------------------------------

  void _openStep(SkillApplication app, VerifyStep step) {
    _app = app;
    final status = app.statusOf(step);
    _reviewStep = step;
    if (status == StepStatus.underReview) return _go(_View.review);
    switch (step) {
      case VerifyStep.portfolio:
        if (status == StepStatus.approved) return _go(_View.review);
        _startPortfolio(app);
      case VerifyStep.demo:
        _understood = false;
        _go(_View.demoIntro);
      case VerifyStep.content:
        _startContent(app);
    }
  }

  void _newSkill() {
    _app = null;
    _startPortfolio(null);
  }

  void _renew(SkillApplication app) {
    _service.renew(app);
    _app = app;
    _startPortfolio(app);
  }

  /// Opens the portfolio form, prefilled when resubmitting after a rejection.
  void _startPortfolio(SkillApplication? app) {
    final previous = app?.portfolio;
    _skill = app?.skill;
    _focusAreas
      ..clear()
      ..addAll(app?.focusAreas ?? const []);
    _choosingSkill = _skill == null || _focusAreas.isEmpty;
    _focusSearch.clear();
    _skillSearch.clear();
    _problem.text = previous?.problem ?? '';
    _solution.text = previous?.solution ?? '';
    _linkedIn.text = previous?.linkedIn ?? '';
    for (final c in _links) {
      c.dispose();
    }
    _links
      ..clear()
      ..addAll([
        for (final link in previous?.links ?? const ['']) TextEditingController(text: link),
      ]);
    _pdf = null;
    _pdfBytes = null;
    _errors.clear();
    _go(_View.portfolio);
  }

  void _startContent(SkillApplication app) {
    final previous = app.content;
    _title.text = previous?.title ?? '';
    _body.text = previous?.body ?? '';
    _presentation = previous?.presentation;
    _contentArea = app.focusAreas.firstOrNull;
    _preview = false;
    _media = null;
    _mediaBytes = null;
    _errors.clear();
    _go(_View.content);
  }

  // ---- Portfolio -------------------------------------------------------------

  bool get _skillFixed => _app != null;

  Future<void> _choosePdf() async {
    final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['pdf']);
    if (file == null || !mounted) return;
    final bytes = await file.length();
    if (!mounted) return;
    setState(() {
      if (file.extension?.toLowerCase() != 'pdf') {
        _errors['pdf'] = 'Upload your portfolio as a PDF.';
      } else if (bytes == null) {
        _errors['pdf'] = 'Couldn\'t read that file. Try another one.';
      } else if (bytes > SkillVerificationService.maxPdfBytes) {
        _errors['pdf'] = 'That file is over 20 MB. Choose a smaller one.';
      } else {
        _pdf = file;
        _pdfBytes = bytes;
        _errors.remove('pdf');
      }
    });
  }

  static bool _isUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.contains('.');
  }

  Future<void> _submitPortfolio() async {
    final links = [for (final c in _links) c.text.trim()].where((l) => l.isNotEmpty).toList();
    final linkedIn = _linkedIn.text.trim();
    final pdfName = _pdf?.name ?? _app?.portfolio?.pdfName;
    setState(() {
      _errors
        ..clear()
        ..addAll({
          if (_skill == null) 'skill': 'Select the skill you want to verify.',
          if (_skill != null && _focusAreas.isEmpty) 'focus': 'Select at least one focus area.',
          if (_problem.text.trim().length < 20) 'problem': 'Describe the problem in at least 20 characters.',
          if (_solution.text.trim().length < 20) 'solution': 'Explain your solution in at least 20 characters.',
          if (links.isEmpty) 'links': 'Add a GitHub repository or live project link.',
          if (links.any((l) => !_isUrl(l))) 'links': 'Enter full links, starting with https://',
          if (linkedIn.isNotEmpty && !(_isUrl(linkedIn) && linkedIn.contains('linkedin.com')))
            'linkedin': 'Enter a valid LinkedIn profile link.',
          if (pdfName == null) 'pdf': 'Upload your portfolio document.',
        });
      _error = null;
    });
    if (_errors.isNotEmpty) return;
    setState(() => _loading = true);
    try {
      final app = _app ?? _service.start(widget.user, _skill!, [..._focusAreas]);
      app.focusAreas = [..._focusAreas];
      _app = app;
      await _service.submitPortfolio(
        app,
        Portfolio(
          problem: _problem.text.trim(),
          solution: _solution.text.trim(),
          skillsUsed: const [],
          links: links,
          linkedIn: linkedIn.isEmpty ? null : linkedIn,
          pdfName: pdfName!,
          pdfPath: _pdf?.path,
        ),
      );
      _reviewStep = VerifyStep.portfolio;
      if (mounted) _go(_View.review);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ---- Live demo -------------------------------------------------------------

  Future<void> _startDemo() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    // Before the server starts the clock: no screen sharing, recording or split
    // screen, and (Android) the app pinned to the screen.
    final blocked = await DemoGuard.instance.prepare();
    if (!mounted) {
      DemoGuard.instance.release();
      return;
    }
    if (blocked != null) {
      DemoGuard.instance.release();
      setState(() {
        _loading = false;
        _error = blocked;
      });
      return;
    }
    try {
      _session = await _service.startDemo(_app!);
      if (mounted) setState(() => _loading = false);
      if (mounted) _go(_View.demoLive);
    } on AuthException catch (e) {
      DemoGuard.instance.release();
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.message;
        });
      }
    }
  }

  Future<void> _submitDemo(DemoRecord record, String? videoPath) async {
    setState(() => _loading = true);
    try {
      await _service.submitDemo(_app!, record, session: _session, videoPath: videoPath);
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _go(_View.demoIntro);
      setState(() => _error = e.message);
      return;
    }
    if (!mounted) return;
    setState(() => _loading = false);
    _reviewStep = VerifyStep.demo;
    _go(_View.review);
    if (record.autoSubmitted) {
      setState(
        () =>
            _error = 'Your demo was submitted automatically because you left it a second time or stayed away too long.',
      );
    }
  }

  // ---- Content ---------------------------------------------------------------

  Future<void> _chooseMedia() async {
    final allowed = _format == ContentFormat.blogVideo
        ? SkillVerificationService.videoExtensions
        : SkillVerificationService.otherExtensions;
    final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: allowed);
    if (file == null || !mounted) return;
    final bytes = await file.length();
    if (!mounted) return;
    setState(() {
      if (!allowed.contains(file.extension?.toLowerCase())) {
        _errors['media'] = 'Use one of: ${allowed.map((e) => e.toUpperCase()).join(', ')}.';
      } else if (bytes == null) {
        _errors['media'] = 'Couldn\'t read that file. Try another one.';
      } else if (bytes > SkillVerificationService.maxVideoBytes) {
        _errors['media'] =
            'That file is over ${SkillVerificationService.maxVideoBytes ~/ (1024 * 1024)} MB. Choose a smaller one.';
      } else {
        _media = file;
        _mediaBytes = bytes;
        _errors.remove('media');
      }
    });
  }

  Future<void> _pickPresentation() async {
    final blog = _format == ContentFormat.blogVideo;
    final picked = await showGlassPicker(
      context,
      title: blog ? 'Video Style' : 'Content Format',
      options: blog ? SkillVerificationService.presentations : SkillVerificationService.otherFormats,
      label: (s) => s,
      selected: _presentation,
    );
    if (picked != null) {
      setState(() {
        _presentation = picked;
        _errors.remove('presentation');
      });
    }
  }

  Future<void> _submitContent() async {
    final blog = _format == ContentFormat.blogVideo;
    final fileName = _media?.name ?? (_app?.content?.format == _format ? _app?.content?.fileName : null);
    final bodyMin = 100;
    setState(() {
      _errors
        ..clear()
        ..addAll({
          if (_title.text.trim().length < 10) 'title': 'Use a title of at least 10 characters.',
          if (_body.text.trim().length < bodyMin)
            'body': blog
                ? 'Write at least 100 characters in your article.'
                : 'Describe your content in at least 100 characters.',
          if (_presentation == null) 'presentation': blog ? 'Choose how your video explains it.' : 'Choose a format.',
          if (fileName == null) 'media': blog ? 'Upload your explanation video.' : 'Upload your content file.',
        });
      _error = null;
    });
    if (_errors.isNotEmpty) return;
    setState(() => _loading = true);
    try {
      await _service.submitContent(
        _app!,
        ContentDraft(
          format: _format,
          title: _title.text.trim(),
          body: _body.text.trim(),
          presentation: _presentation!,
          fileName: fileName!,
          filePath: _media?.path,
        ),
        focusArea: _contentArea,
      );
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
      return;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    if (!mounted) return;
    _reviewStep = VerifyStep.content;
    _go(_View.review);
  }

  /// Wraps the selected text of the article body in an HTML tag.
  void _wrap(String open, String close) {
    final text = _body.text;
    var selection = _body.selection;
    if (!selection.isValid) selection = TextSelection.collapsed(offset: text.length);
    final selected = selection.textInside(text);
    _body.value = TextEditingValue(
      text: selection.textBefore(text) + open + selected + close + selection.textAfter(text),
      selection: TextSelection.collapsed(offset: selection.start + open.length + selected.length),
    );
    setState(() {});
  }

  // ---- Layout ----------------------------------------------------------------

  String get _screenTitle => switch (_view) {
    _View.portfolio => 'Portfolio Submission',
    _View.demoIntro || _View.demoRules || _View.demoLive => 'Live Demo',
    _View.content => 'Content Submission',
    _View.review => switch (_reviewStep) {
      VerifyStep.portfolio => 'Portfolio Submission',
      VerifyStep.demo => 'Live Demo',
      VerifyStep.content => 'Content Submission',
    },
    _ => 'Skill Verification',
  };

  String? get _subtitle =>
      _view == _View.overview ? 'Verify your skills to build trust with Seekers and unlock more sessions.' : null;

  VoidCallback? get _onBack => switch (_view) {
    _View.overview => null, // leave the screen
    _View.demoRules => () => _go(_View.demoIntro),
    _ => () => _go(_View.overview),
  };

  int? get _stepNumber => switch (_view) {
    _View.portfolio => 1,
    _View.demoIntro || _View.demoRules || _View.demoLive => 2,
    _View.content => 3,
    _View.review => switch (_reviewStep) {
      VerifyStep.portfolio => 1,
      VerifyStep.demo => 2,
      VerifyStep.content => 3,
    },
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final step = _stepNumber;
    final live = _view == _View.demoLive;
    return PopScope(
      canPop: _view == _View.overview,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || live) return;
        _onBack?.call();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(
                  children: [
                    if (live)
                      const SizedBox(width: 44)
                    else
                      GlassIconButton(
                        icon: Icons.arrow_back_rounded,
                        tooltip: 'Back',
                        onPressed: _onBack ?? () => Navigator.of(context).maybePop(),
                      ),
                    Expanded(
                      child: Text(
                        _screenTitle.toUpperCase(),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.heading.copyWith(fontSize: 20),
                      ),
                    ),
                    SizedBox(
                      width: 44,
                      child: step == null
                          ? null
                          : GlassWell(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Text(
                                '$step/3',
                                textAlign: TextAlign.center,
                                semanticsLabel: 'Step $step of 3',
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + MediaQuery.paddingOf(context).bottom),
                  children: [
                    if (_subtitle case final subtitle?) ...[
                      Text(subtitle, style: AppText.body, textAlign: TextAlign.center),
                      gap24,
                    ],
                    InlineNotice(message: _error, tone: NoticeTone.error),
                    if (_error != null) gap14,
                    StepSwitcher(
                      child: KeyedSubtree(key: ValueKey(_view), child: _buildView()),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildView() {
    return switch (_view) {
      _View.overview => _buildOverview(),
      _View.portfolio => _buildPortfolio(),
      _View.review => _buildReview(),
      _View.demoIntro => _buildDemoIntro(),
      _View.demoRules => _buildDemoRules(),
      _View.demoLive =>
        _loading
            ? const _Busy(message: 'Uploading your demo securely…')
            : _LiveDemo(session: _session!, onSubmit: _submitDemo, onExit: () => _go(_View.demoIntro)),
      _View.content => _buildContent(),
      _View.verified => _buildVerified(),
    };
  }

  // ---- Overview --------------------------------------------------------------

  Widget _buildOverview() {
    final app = _app;
    final apps = _apps;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (apps.isNotEmpty) ...[
          const _SectionLabel('Your Skills'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final a in apps)
                GlassChip(
                  label: a.expired ? '${a.skill} · Expired' : (a.verified ? '${a.skill} ✓' : a.skill),
                  selected: a == app,
                  onTap: () => setState(() => _app = a),
                ),
            ],
          ),
          gap24,
        ],
        if (app != null) ...[_StepIndicator(app: app), gap24],
        if (app != null && app.expired) ...[
          InlineNotice(
            message:
                'Your ${app.skill} verification expired after 6 months of inactivity. Submit your portfolio again '
                'to renew it.',
            tone: NoticeTone.error,
          ),
          gap14,
          PrimaryPillButton(label: 'Renew Verification', onPressed: () => _renew(app)),
          gap24,
        ] else if (app != null && app.verified) ...[
          _VerifiedBanner(app: app, onTap: () => _go(_View.verified)),
          gap24,
        ],
        for (final (i, step) in VerifyStep.values.indexed) ...[
          if (i > 0) const SizedBox(height: 12),
          _StepCard(
            step: step,
            status: app?.statusOf(step) ?? (step == VerifyStep.portfolio ? StepStatus.open : StepStatus.locked),
            note: app?.notes[step],
            onTap: app == null
                ? (step == VerifyStep.portfolio ? _newSkill : null)
                : (app.expired || app.statusOf(step) == StepStatus.locked || _approvedAndDone(app, step))
                ? null
                : () => _openStep(app, step),
          ),
        ],
        gap24,
        if (app == null)
          PrimaryPillButton(label: 'Start Verification', onPressed: _newSkill)
        else
          GlassPillButton(label: 'Verify Another Skill', icon: Icons.add_rounded, onPressed: _newSkill),
        gap24,
        const _WhyVerify(),
      ],
    );
  }

  /// Approved steps are locked, except the portfolio, which stays viewable.
  static bool _approvedAndDone(SkillApplication app, VerifyStep step) =>
      step != VerifyStep.portfolio && app.statusOf(step) == StepStatus.approved;

  // ---- Portfolio form --------------------------------------------------------

  Widget _buildPortfolio() {
    final note = _app?.notes[VerifyStep.portfolio];
    final skillQuery = _skillSearch.text.trim().toLowerCase();
    final taken = {for (final a in _apps) a.skill.toLowerCase()};
    final skills = SkillVerificationService.focusAreas.keys
        .where((s) => s.toLowerCase().contains(skillQuery) && !taken.contains(s.toLowerCase()))
        .toList();
    final focusQuery = _focusSearch.text.trim();
    final known = SkillVerificationService.focusAreas[_skill] ?? const <String>[];
    final areas = known.where((a) => a.toLowerCase().contains(focusQuery.toLowerCase())).toList();
    final customArea =
        focusQuery.isNotEmpty &&
        !known.any((a) => a.toLowerCase() == focusQuery.toLowerCase()) &&
        !_focusAreas.any((a) => a.toLowerCase() == focusQuery.toLowerCase());
    const maxAreas = SkillVerificationService.maxFocusAreas;

    void toggleArea(String area) => setState(() {
      if (_focusAreas.remove(area)) return;
      if (_focusAreas.length >= maxAreas) {
        _errors['focus'] = 'You can choose up to $maxAreas focus areas.';
        return;
      }
      _focusAreas.add(area);
      _focusSearch.clear();
      _errors.remove('focus');
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (note != null) ...[
          InlineNotice(message: 'Admin feedback: $note', tone: NoticeTone.error, persistent: true),
          gap14,
        ],
        const _SectionLabel('Skill & Focus Areas', number: 1),
        if (_skill != null && _focusAreas.isNotEmpty && !_choosingSkill)
          // Once both are picked, the choice collapses into a clear summary.
          GlassWell(
            radius: 18,
            active: true,
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
            child: Row(
              children: [
                const Icon(Icons.check_circle_rounded, size: 22, color: Colors.white),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    children: [
                      _DetailRow('Skill', _skill!, icon: _skillFixed ? Icons.lock_outline_rounded : null),
                      _DetailRow('Focus Areas', _focusAreas.join(', ')),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                SmallPillButton(label: 'Change', onPressed: () => setState(() => _choosingSkill = true)),
              ],
            ),
          )
        else ...[
          if (_skillFixed)
            GlassWell(
              radius: 18,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: _DetailRow('Skill', _skill ?? '', icon: Icons.lock_outline_rounded),
            )
          else ...[
            Text('Select the skill you want to verify *', style: AppText.caption),
            gap8,
            GlassTextField(
              controller: _skillSearch,
              hint: 'Search skills',
              icon: Icons.search_rounded,
              onChanged: (_) => setState(() {}),
            ),
            gap14,
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final skill in skills)
                  _PickChip(
                    label: skill,
                    selected: skill == _skill,
                    onTap: () => setState(() {
                      if (_skill != skill) _focusAreas.clear();
                      _skill = skill;
                      _focusSearch.clear();
                      _errors.remove('skill');
                    }),
                  ),
                if (skills.isEmpty) Text('No skills match.', style: AppText.caption),
              ],
            ),
            FieldError(_errors['skill']),
          ],
          if (_skill != null) ...[
            gap24,
            Text('Select focus areas in $_skill * (up to $maxAreas)', style: AppText.caption),
            gap8,
            GlassTextField(
              controller: _focusSearch,
              hint: 'Search focus areas in $_skill',
              icon: Icons.search_rounded,
              onChanged: (_) => setState(() {}),
            ),
            gap14,
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                // Chosen ones stay visible even when the search hides them.
                for (final area in {..._focusAreas, ...areas})
                  _PickChip(label: area, selected: _focusAreas.contains(area), onTap: () => toggleArea(area)),
                if (customArea)
                  _PickChip(label: 'Add “$focusQuery”', selected: false, onTap: () => toggleArea(focusQuery)),
              ],
            ),
            gap8,
            Text('${_focusAreas.length} of $maxAreas selected', style: AppText.caption),
            FieldError(_errors['focus']),
            if (_focusAreas.isNotEmpty) ...[
              gap14,
              Align(
                alignment: Alignment.centerRight,
                child: SmallPillButton(label: 'Done', onPressed: () => setState(() => _choosingSkill = false)),
              ),
            ],
          ],
        ],
        gap24,
        const _SectionLabel('Project Details', number: 2),
        _CountedField(
          controller: _problem,
          hint: 'What problem did your project solve?',
          label: 'Problem Statement *',
          min: 20,
          max: 2000,
          lines: 4,
          error: _errors['problem'],
          onChanged: () => setState(() => _errors.remove('problem')),
        ),
        gap14,
        _CountedField(
          controller: _solution,
          hint: 'How did you solve it? Explain your approach.',
          label: 'Solution Explanation *',
          min: 20,
          max: 3000,
          lines: 5,
          error: _errors['solution'],
          onChanged: () => setState(() => _errors.remove('solution')),
        ),
        gap24,
        const _SectionLabel('Project Links', number: 3),
        Text('GitHub repository or live project link *', style: AppText.caption),
        gap8,
        for (final (i, link) in _links.indexed) ...[
          if (i > 0) gap8,
          Row(
            children: [
              Expanded(
                child: GlassTextField(
                  controller: link,
                  hint: i == 0 ? 'https://github.com/you/project' : 'https://',
                  icon: Icons.link_rounded,
                  keyboardType: TextInputType.url,
                  onChanged: (_) {
                    if (_errors.containsKey('links')) setState(() => _errors.remove('links'));
                  },
                ),
              ),
              if (_links.length > 1)
                IconButton(
                  tooltip: 'Remove link',
                  onPressed: () => setState(() => _links.removeAt(i).dispose()),
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                ),
            ],
          ),
        ],
        FieldError(_errors['links']),
        if (_links.length < 5) ...[
          gap8,
          Align(
            alignment: Alignment.centerLeft,
            child: UnderlineLink(
              label: '+ Add another link',
              onTap: () => setState(() => _links.add(TextEditingController())),
            ),
          ),
        ],
        gap14,
        Text('LinkedIn profile (optional)', style: AppText.caption),
        gap8,
        GlassTextField(
          controller: _linkedIn,
          hint: 'https://linkedin.com/in/you',
          icon: Icons.person_outline_rounded,
          keyboardType: TextInputType.url,
          errorText: _errors['linkedin'],
          onChanged: (_) {
            if (_errors.containsKey('linkedin')) setState(() => _errors.remove('linkedin'));
          },
        ),
        gap24,
        const _SectionLabel('Portfolio Document', number: 4),
        _UploadBox(
          title: 'Upload Portfolio (PDF)',
          formats: 'Accepted format: PDF\nMax file size: 20 MB',
          file: _pdf,
          bytes: _pdfBytes,
          previousName: _pdf == null ? _app?.portfolio?.pdfName : null,
          error: _errors['pdf'],
          onChoose: _choosePdf,
          onRemove: () => setState(() {
            _pdf = null;
            _pdfBytes = null;
          }),
        ),
        FieldError(_errors['pdf']),
        gap24,
        const InlineNotice(
          message: 'Your portfolio is sent for admin review. Once approved, it can\'t be edited.',
          tone: NoticeTone.info,
        ),
        gap14,
        PrimaryPillButton(label: 'Submit Portfolio', loading: _loading, onPressed: _submitPortfolio),
      ],
    );
  }

  // ---- Review (all three steps) ----------------------------------------------

  Widget _buildReview() {
    final app = _app!;
    final shown = _reviewStep;
    // The locked portfolio can also be viewed here after approval.
    final approved = app.statusOf(shown) == StepStatus.approved;
    final (icon, title, message) = switch (shown) {
      VerifyStep.portfolio => (
        Icons.folder_outlined,
        approved ? 'Portfolio Approved' : 'Portfolio Submitted',
        approved
            ? 'Your portfolio for ${app.skill} has been approved and is now locked.'
            : 'Your portfolio has been sent for admin review. We\'ll email you once it\'s approved or if changes '
                  'are needed. The Live Demo unlocks after approval.',
      ),
      VerifyStep.demo => (
        Icons.videocam_outlined,
        'Live Demo Submitted',
        'Your recording has been securely uploaded and sent for admin review. Content Submission unlocks after '
            'approval.',
      ),
      VerifyStep.content => (
        Icons.article_outlined,
        'Content Submitted',
        'Your content has been sent for admin review. Once approved, you\'ll be Skill Verified for ${app.skill}.',
      ),
    };
    final portfolio = app.portfolio;
    final demo = app.demo;
    final content = app.content;
    final rows = switch (shown) {
      VerifyStep.portfolio when portfolio != null => [
        _DetailRow('Skill', app.skill),
        if (app.focusAreas.isNotEmpty) _DetailRow('Focus Areas', app.focusAreas.join(', ')),
        _DetailRow('Links', '${portfolio.links.length}'),
        _DetailRow('Document', portfolio.pdfName),
      ],
      VerifyStep.demo when demo != null => [
        _DetailRow('Skill', app.skill),
        _DetailRow('Questions answered', '${demo.answered}'),
        _DetailRow('Duration', _formatDuration(demo.seconds)),
        if (demo.violations > 0) _DetailRow('App switches', '${demo.violations}'),
      ],
      VerifyStep.content when content != null => [
        _DetailRow('Skill', app.skill),
        _DetailRow('Title', content.title),
        _DetailRow(content.format == ContentFormat.blogVideo ? 'Video style' : 'Format', content.presentation),
        _DetailRow('File', content.fileName),
      ],
      _ => const <Widget>[],
    };
    return _Result(
      icon: icon,
      title: title,
      message: message,
      details: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GlassWell(
            radius: 18,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              children: [
                ...rows,
                _DetailRow(
                  'Status',
                  approved ? 'Approved' : 'Under Review',
                  icon: approved ? Icons.check_circle_rounded : Icons.hourglass_top_rounded,
                ),
              ],
            ),
          ),
        ],
      ),
      action: GlassPillButton(label: 'Back to Overview', onPressed: () => _go(_View.overview)),
    );
  }

  // ---- Live demo -------------------------------------------------------------

  Widget _buildDemoIntro() {
    final note = _app?.notes[VerifyStep.demo];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (note != null)
          InlineNotice(message: 'Admin feedback: $note', tone: NoticeTone.error, persistent: true)
        else
          const InlineNotice(
            message: 'Portfolio approved! You can now take the Live Demo.',
            tone: NoticeTone.success,
            persistent: true,
          ),
        gap24,
        const Center(child: GlassIconBadge(icon: Icons.record_voice_over_outlined, size: 72)),
        gap24,
        const Text('WHAT TO EXPECT', style: AppText.title, textAlign: TextAlign.center),
        gap14,
        Text(
          'Answer questions about ${_app?.skill ?? 'your skill'} out loud while your camera and microphone record.',
          style: AppText.body,
          textAlign: TextAlign.center,
        ),
        gap24,
        const _Bullets(
          items: [
            (Icons.hearing_outlined, 'Questions are read out to you — they aren\'t shown on screen.'),
            (Icons.timer_outlined, '${SkillVerificationService.questionSeconds} seconds per question, one at a time.'),
            (Icons.replay_rounded, 'You can repeat each question once. The timer keeps running.'),
            (Icons.videocam_outlined, 'Camera and microphone stay on for the whole demo.'),
            (Icons.lock_outline_rounded, 'Questions are encrypted and only unlocked when your demo starts.'),
          ],
        ),
        gap24,
        PrimaryPillButton(label: 'Continue', onPressed: () => _go(_View.demoRules)),
      ],
    );
  }

  Widget _buildDemoRules() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: GlassIconBadge(icon: Icons.rule_rounded, size: 72)),
        gap24,
        const Text('BEFORE YOU START', style: AppText.title, textAlign: TextAlign.center),
        gap24,
        _Bullets(
          items: [
            (Icons.visibility_off_outlined, 'Keep your eyes closed while you answer each question.'),
            (Icons.light_mode_outlined, 'Sit in a quiet, well-lit place with your face in view.'),
            if (Theme.of(context).platform == TargetPlatform.android)
              (Icons.push_pin_outlined, 'Your phone will ask to pin Synap Mentor to the screen. Allow it.'),
            (Icons.phonelink_lock_outlined, 'Don\'t switch apps or leave this screen.'),
            (Icons.screen_share_outlined, 'No screen sharing, recording, mirroring, split screen or floating windows.'),
            (
              Icons.warning_amber_rounded,
              'First time: a warning, if you\'re back within 10 seconds. Second time: your demo is submitted automatically.',
            ),
            (Icons.cloud_upload_outlined, 'Your recording is stored securely for admin review.'),
          ],
        ),
        gap24,
        GlassWell(
          radius: 18,
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GlassCheckbox(value: _understood, onChanged: (v) => setState(() => _understood = v)),
              const SizedBox(width: 12),
              Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _understood = !_understood),
                  child: const Text(
                    'I understand the rules and allow camera and microphone access for this demo.',
                    style: TextStyle(fontSize: 13.5, height: 1.4, color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        ),
        gap24,
        PrimaryPillButton(label: 'Start Demo', onPressed: _understood ? _startDemo : null),
      ],
    );
  }

  // ---- Content form ----------------------------------------------------------

  Widget _buildContent() {
    final note = _app?.notes[VerifyStep.content];
    final blog = _format == ContentFormat.blogVideo;
    final previousFile = _app?.content?.format == _format ? _app?.content?.fileName : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (note != null)
          InlineNotice(message: 'Admin feedback: $note', tone: NoticeTone.error, persistent: true)
        else
          const InlineNotice(message: 'Live Demo approved! One step left.', tone: NoticeTone.success, persistent: true),
        gap24,
        const _SectionLabel('Skill & Focus Area'),
        Text('From your submitted portfolio', style: AppText.caption),
        gap8,
        GlassSelectField(value: _app?.skill, hint: 'Skill', locked: true),
        if ((_app?.focusAreas.length ?? 0) > 1) ...[
          gap14,
          Text('Which focus area is this content about? *', style: AppText.caption),
          gap8,
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final area in _app!.focusAreas)
                _PickChip(
                  label: area,
                  selected: area == _contentArea,
                  onTap: () => setState(() => _contentArea = area),
                ),
            ],
          ),
        ] else if (_contentArea != null) ...[
          gap14,
          GlassSelectField(value: _contentArea, hint: 'Focus Area', locked: true),
        ],
        gap24,
        _SectionLabel(blog ? 'Article' : 'Details'),
        _CountedField(
          controller: _title,
          label: blog ? 'Article Title *' : 'Title *',
          hint: 'e.g. How I found an SQL injection in a login form',
          min: 10,
          max: 200,
          error: _errors['title'],
          onChanged: () => setState(() => _errors.remove('title')),
        ),
        gap14,
        if (blog) ...[
          Row(
            children: [
              Expanded(child: Text('Article Body *', style: AppText.caption)),
              _ToggleText(
                label: _preview ? 'Edit' : 'Preview',
                icon: _preview ? Icons.edit_outlined : Icons.visibility_outlined,
                onTap: () => setState(() => _preview = !_preview),
              ),
            ],
          ),
          gap8,
          if (_preview)
            GlassWell(
              radius: 18,
              padding: const EdgeInsets.all(16),
              child: _body.text.trim().isEmpty
                  ? Text('Nothing to preview yet.', style: AppText.caption)
                  : HtmlText(_body.text),
            )
          else ...[
            _Toolbar(onWrap: _wrap),
            gap8,
            _CountedField(
              controller: _body,
              hint: 'Write your article. HTML like <b>, <h2>, <ul><li> and <code> is supported.',
              min: 100,
              max: 5000,
              lines: 10,
              error: _errors['body'],
              onChanged: () => setState(() => _errors.remove('body')),
            ),
          ],
          if (_preview) FieldError(_errors['body']),
        ] else
          _CountedField(
            controller: _body,
            label: 'Description *',
            hint: 'What does it explain, and how should viewers use it?',
            min: 50,
            max: 2000,
            lines: 5,
            error: _errors['body'],
            onChanged: () => setState(() => _errors.remove('body')),
          ),
        gap24,
        _SectionLabel(blog ? 'Explanation Video' : 'Content File'),
        Text(blog ? 'How does your video explain it? *' : 'Format *', style: AppText.caption),
        gap8,
        GlassSelectField(
          value: _presentation,
          hint: blog ? 'Select video style' : 'Select format',
          errorText: _errors['presentation'],
          onTap: _pickPresentation,
        ),
        gap14,
        _UploadBox(
          title: blog ? 'Upload Video' : 'Upload File',
          formats: blog
              ? 'Accepted formats: MP4, WEBM, MOV, AVI, MKV\nMax file size: 1000 MB'
              : 'Accepted formats: Video, image, PDF, HTML or ZIP\nMax file size: 1000 MB',
          icon: blog ? Icons.video_file_outlined : Icons.upload_file_outlined,
          file: _media,
          bytes: _mediaBytes,
          previousName: _media == null ? previousFile : null,
          error: _errors['media'],
          onChoose: _chooseMedia,
          onRemove: () => setState(() {
            _media = null;
            _mediaBytes = null;
          }),
        ),
        FieldError(_errors['media']),
        gap24,
        const InlineNotice(
          message:
              'After approval, this is added to your content. It stays a draft until your KYC and skill '
              'verification are both complete, then it\'s published.',
          tone: NoticeTone.info,
        ),
        gap14,
        PrimaryPillButton(label: 'Submit Content', loading: _loading, onPressed: _submitContent),
      ],
    );
  }

  // ---- Verified --------------------------------------------------------------

  Widget _buildVerified() {
    final app = _app!;
    return _Result(
      icon: Icons.workspace_premium_outlined,
      title: 'Skill Verified!',
      message: 'You\'re now a verified ${app.skill} Solver. The badge shows on your profile for Seekers.',
      details: GlassWell(
        radius: 18,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          children: [
            _DetailRow('Skill', app.skill),
            if (app.focusAreas.isNotEmpty) _DetailRow('Focus Areas', app.focusAreas.join(', ')),
            if (app.verifiedAt != null) _DetailRow('Verified On', _formatDate(app.verifiedAt!)),
            _DetailRow('Renew By', '${_formatDate(app.lastActiveAt.add(SkillVerificationService.expiry))} if inactive'),
            _DetailRow(
              'Your Content',
              app.contentPublished ? 'Published' : 'Draft — complete KYC to publish',
              icon: app.contentPublished ? Icons.check_circle_rounded : Icons.edit_note_rounded,
            ),
          ],
        ),
      ),
      action: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PrimaryPillButton(label: 'Verify Another Skill', onPressed: _newSkill),
          gap14,
          GlassPillButton(label: 'Back to Overview', onPressed: () => _go(_View.overview)),
        ],
      ),
    );
  }

  static String _formatDuration(int seconds) => '${seconds ~/ 60}m ${(seconds % 60).toString().padLeft(2, '0')}s';

  static String _formatDate(DateTime t) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${t.day} ${months[t.month - 1]} ${t.year}';
  }
}

// ---- Live demo session -------------------------------------------------------

/// One question at a time: it's read out (never shown), then the solver answers
/// against a fixed timer. Each question can be repeated once while the timer
/// keeps running. Leaving the app once warns; leaving again submits.
/// Why the solver was away from the live demo.
enum _Away { left, otherWindow, split, recorded, unpinned }

class _LiveDemo extends StatefulWidget {
  const _LiveDemo({required this.session, required this.onSubmit, required this.onExit});

  /// The demo started on the server. Its questions open one at a time and the
  /// front camera records the whole demo.
  final DemoSession session;

  /// The recording's path comes with the record when there is one.
  final void Function(DemoRecord record, String? videoPath) onSubmit;

  /// Back out when the camera can't start.
  final VoidCallback onExit;

  @override
  State<_LiveDemo> createState() => _LiveDemoState();
}

class _LiveDemoState extends State<_LiveDemo> with SingleTickerProviderStateMixin {
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(
    onHide: _onHide,
    onShow: _onShow,
    onInactive: _onInactive,
    onResume: _onResume,
  );
  late final AnimationController _wave = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat(reverse: true);
  Timer? _ticker;

  DemoSession get _session => widget.session;
  int get _total => _session.questionCount;
  int get _answerSeconds => _session.answerSeconds;
  int get _listenSeconds => _session.listenSeconds;

  int _index = 0;
  late int _remaining = _answerSeconds;
  late int _listening = _listenSeconds;
  int _elapsed = 0;
  final _repeated = <int>{};
  int _violations = 0;
  bool _submitted = false;

  /// Breaking the demo rules counts once per time away, however long it
  /// lasts: leaving the app, another app or window in use, split screen,
  /// screen recording or mirroring, unpinning (Android). Set while away.
  _Away? _away;
  DateTime? _awaySince;

  /// Why the solver was away last time, for the warning once they're back.
  _Away? _lastAway;

  /// The app is in the background, or the screen is off.
  bool _hidden = false;

  /// Since when another app, window or system panel has had focus.
  DateTime? _unfocusedSince;

  /// Phone prompts showing now (permissions, pinning): they take focus without
  /// counting.
  int _prompts = 0;

  /// The screen is recorded, mirrored or split right now.
  bool _exposed = false;

  /// Pinned to the screen for the demo (Android).
  bool _pinned = DemoGuard.instance.pinned;

  /// Unpinned during the demo: pinning is asked again once the solver is back.
  bool _repinWanted = false;
  bool _checking = false;

  /// The question was cut off, or opened, while the solver was away; it's read
  /// out once they're back.
  bool _unheard = false;
  bool _speaking = false;

  /// Submitted while the app was in the background: the recording is finished
  /// and uploaded once it's back, since the camera stops there.
  bool? _finishLater;
  bool _finished = false;

  /// How long another app or window can have focus before it counts. System
  /// panels and prompts are brief.
  static const _focusGrace = Duration(seconds: 3);

  /// Away longer than this submits the demo, even the first time.
  static const _awayLimit = Duration(seconds: 10);

  /// The current question. It is only read aloud, never shown.
  String? _question;
  final _tts = FlutterTts();

  /// Hears "repeat" for a while after each question starts playing.
  final _speech = SpeechToText();
  bool _speechReady = false;
  static const _repeatWindow = Duration(seconds: 15);

  /// English, which "repeat" is said in, whatever the phone's language.
  String? _speechLocale;

  /// Ends when the recogniser stops listening (it stops on its own after a
  /// short silence) or reports an error.
  Completer<void>? _hearingDone;
  String? _speechError;

  /// Listening for "repeat" right now, shown under the question.
  bool _hearing = false;

  /// The recording is paused so the recogniser can use the microphone.
  bool _pausedForSpeech = false;

  CameraController? _camera;
  String? _cameraError;

  @override
  void initState() {
    super.initState();
    _lifecycle; // start listening
    _question = _session.firstQuestion;
    _startRecording();
    _tts.awaitSpeakCompletion(true);
    _prompts++; // the phone may ask for speech recognition
    _speech
        .initialize(
          onError: (e) {
            _speechError = e.errorMsg;
            _endHearing();
          },
          onStatus: (status) {
            if (status == 'done' || status == 'notListening') _endHearing();
          },
        )
        .then((ready) async {
          _speechReady = ready;
          if (ready) _speechLocale = await _englishLocale();
        })
        .catchError((Object _) {})
        .whenComplete(() {
          _promptDone();
          return _speak();
        });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    // The phone stays awake for the whole demo.
    WakelockPlus.enable().catchError((Object _) {});
  }

  @override
  void dispose() {
    WakelockPlus.disable().catchError((Object _) {});
    DemoGuard.instance.release();
    _ticker?.cancel();
    _lifecycle.dispose();
    _wave.dispose();
    _tts.stop();
    _speech.cancel();
    _camera?.dispose();
    super.dispose();
  }

  /// The front camera records the demo with sound from the start.
  Future<void> _startRecording() async {
    _prompts++; // the phone may ask for camera and microphone access
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return _cameraFailed('No camera was found on this device.');
      final front = cameras.where((c) => c.lensDirection == CameraLensDirection.front).firstOrNull ?? cameras.first;
      final camera = CameraController(front, ResolutionPreset.medium);
      _camera = camera;
      await camera.initialize();
      if (!mounted) return;
      await camera.startVideoRecording();
      if (mounted) setState(() {});
    } on CameraException catch (e) {
      _cameraFailed(
        e.code.contains('AccessDenied') || e.code.contains('Restricted')
            ? 'Camera and microphone access are needed for the live demo. Allow them for Synap Mentor in your phone\'s settings, then start again.'
            : 'Couldn\'t start the camera. Close other apps using it and start again.',
      );
    } finally {
      _promptDone();
    }
  }

  void _cameraFailed(String message) {
    _ticker?.cancel();
    // Not held on the screen with nothing to do.
    DemoGuard.instance.release();
    if (mounted) setState(() => _cameraError = message);
  }

  /// A phone prompt is gone: focus elsewhere from now on counts afresh.
  void _promptDone() {
    if (_prompts > 0) _prompts--;
    if (_unfocusedSince != null) _unfocusedSince = DateTime.now();
  }

  Future<void> _speak() async {
    final question = _question;
    if (question == null) return;
    // Nothing is read out while the solver is away; it is once they're back.
    if (_away != null) {
      _unheard = true;
      return;
    }
    final index = _index;
    final started = DateTime.now();
    _speaking = true;
    try {
      await _speech.cancel();
      await _tts.stop();
      // Some phones never report the end of speech; don't wait for ever.
      await _tts.speak(question).timeout(const Duration(seconds: 25), onTimeout: () => null);
    } catch (_) {
      // "Repeat question" below reads it again.
    } finally {
      _speaking = false;
    }
    _listenForRepeat(index, started);
  }

  /// The phone's English recogniser, Indian English first.
  Future<String?> _englishLocale() async {
    try {
      final english = (await _speech.locales()).where((l) => l.localeId.toLowerCase().startsWith('en')).toList();
      bool region(String id, String code) => id.toUpperCase().replaceAll('-', '_').endsWith('_$code');
      return (english.where((l) => region(l.localeId, 'IN')).firstOrNull ??
              english.where((l) => region(l.localeId, 'US')).firstOrNull ??
              english.firstOrNull)
          ?.localeId;
    } catch (_) {
      return null;
    }
  }

  void _endHearing() {
    final done = _hearingDone;
    if (done != null && !done.isCompleted) done.complete();
  }

  /// "Repeat", "repeat it", "please repeat", "again", "one more time"…
  static bool _saysRepeat(String words) =>
      RegExp(r'\b(re ?peat\w*|ripeat|repit|repeet|again|one more time|pardon)\b').hasMatch(words.toLowerCase());

  /// Until 15 seconds after the question started playing (at least a few
  /// seconds once it ends), saying "repeat" reads it again. The phone's
  /// recogniser stops after a short silence, so it's started again until the
  /// time is up.
  Future<void> _listenForRepeat(int index, DateTime started) async {
    if (!_speechReady || _submitted || !mounted || index != _index || _repeated.contains(index) || _away != null) {
      return;
    }
    final end = started.add(_repeatWindow);
    final deadline = end.difference(DateTime.now()) < const Duration(seconds: 5)
        ? DateTime.now().add(const Duration(seconds: 5))
        : end;
    bool open() =>
        mounted &&
        !_submitted &&
        _away == null &&
        index == _index &&
        !_repeated.contains(index) &&
        DateTime.now().isBefore(deadline);
    var heard = false;
    if (mounted) setState(() => _hearing = true);
    try {
      while (open() && !heard) {
        _speechError = null;
        final done = _hearingDone = Completer<void>();
        await _speech.listen(
          onResult: (result) {
            if (index != _index) return;
            final said = [result.recognizedWords, ...result.alternates.map((a) => a.recognizedWords)];
            if (said.any(_saysRepeat)) {
              heard = true;
              _endHearing();
            }
          },
          listenOptions: SpeechListenOptions(
            listenFor: deadline.difference(DateTime.now()),
            pauseFor: const Duration(seconds: 5),
            listenMode: ListenMode.dictation,
            localeId: _speechLocale,
            cancelOnError: true,
          ),
        );
        await done.future.timeout(deadline.difference(DateTime.now()) + const Duration(seconds: 1), onTimeout: () {});
        if (heard) break;
        // The demo recording can hold the microphone on some phones: pause it
        // for the rest of the window so the recogniser can hear.
        final error = _speechError ?? '';
        if (!_pausedForSpeech && (error.contains('audio') || error.contains('busy') || error.contains('client'))) {
          await _pauseForSpeech();
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    } catch (_) {
      // Speech recognition isn't available; the link below still works.
    } finally {
      await _speech.cancel();
      await _resumeAfterSpeech();
      if (mounted) setState(() => _hearing = false);
    }
    if (heard && mounted && !_submitted && _away == null && index == _index) _repeat();
  }

  Future<void> _pauseForSpeech() async {
    final camera = _camera;
    if (camera == null || !camera.value.isRecordingVideo || camera.value.isRecordingPaused) return;
    try {
      await camera.pauseVideoRecording();
      _pausedForSpeech = true;
    } on CameraException {
      // Keeps recording; the link below still works.
    }
  }

  Future<void> _resumeAfterSpeech() async {
    if (!_pausedForSpeech) return;
    _pausedForSpeech = false;
    final camera = _camera;
    // In the background it's resumed once the app is back.
    if (camera == null || !camera.value.isRecordingPaused || _hidden) return;
    await camera.resumeVideoRecording().catchError((Object _) {});
  }

  void _tick() {
    if (_submitted || _cameraError != null) return;
    setState(() {
      _elapsed++;
      if (_listening > 0) _listening--;
      _remaining--;
    });
    if (DateTime.now().isAfter(_session.expiresAt)) {
      _submit();
      return;
    }
    if (_remaining <= 0) _next();
    _watch();
  }

  void _onHide() {
    _hidden = true;
    if (_submitted) return;
    final camera = _camera;
    if (camera != null && camera.value.isRecordingVideo) camera.pauseVideoRecording().catchError((Object _) {});
    _flag(_Away.left);
  }

  void _onShow() {
    _hidden = false;
    final auto = _finishLater;
    if (auto != null) {
      _finish(auto: auto);
      return;
    }
    if (_submitted || !mounted) return;
    _settle();
    final camera = _camera;
    if (!_submitted && camera != null && camera.value.isRecordingPaused) {
      camera.resumeVideoRecording().catchError((Object _) {});
    }
  }

  void _onInactive() => _unfocusedSince ??= DateTime.now();

  void _onResume() {
    _unfocusedSince = null;
    _settle();
  }

  /// Every second: another app or window in focus for a while, split screen,
  /// screen recording or mirroring, and unpinning each count as being away.
  Future<void> _watch() async {
    if (_checking || _submitted) return;
    _checking = true;
    try {
      final state = await DemoGuard.instance.check();
      if (!mounted || _submitted) return;
      if (state != null) _exposed = state.captured || state.split;
      // What came up in an earlier check can end now; what comes up in this
      // one lasts until the next at least.
      _settle();
      if (_submitted) return;
      final unfocused = _unfocusedSince;
      if (unfocused != null && !_hidden && _prompts == 0 && DateTime.now().difference(unfocused) >= _focusGrace) {
        _flag(_Away.otherWindow);
      }
      if (state == null) return;
      if (state.captured) _flag(_Away.recorded);
      if (state.split) _flag(_Away.split);
      if (_pinned && !state.pinned) {
        _pinned = false;
        _repinWanted = true;
        _flag(_Away.unpinned);
      }
    } finally {
      _checking = false;
    }
  }

  /// Counts a break of the demo rules, once per time away. The first is a
  /// warning; the second submits the demo.
  void _flag(_Away why) {
    if (_submitted || _cameraError != null || _away != null) return;
    _away = why;
    _awaySince = DateTime.now();
    _violations++;
    if (_speaking) _unheard = true;
    _tts.stop();
    if (_violations >= 2) {
      _submit(auto: true);
      return;
    }
    if (mounted) setState(() {});
  }

  /// Ends the time away once the solver is back: the app in front and in
  /// focus, full screen, and nothing recording it. Away too long submits the
  /// demo.
  void _settle() {
    final since = _awaySince;
    if (!mounted || _submitted || _away == null || since == null) return;
    if (DateTime.now().difference(since) >= _awayLimit) {
      _submit(auto: true);
      return;
    }
    if (_hidden || _unfocusedSince != null || _exposed) return;
    setState(() {
      _lastAway = _away;
      _away = null;
      _awaySince = null;
    });
    if (_repinWanted) {
      _repinWanted = false;
      _repin();
    }
    if (_unheard) {
      _unheard = false;
      _speak();
    }
  }

  /// Asks to pin the app again after it was unpinned (Android).
  Future<void> _repin() async {
    _prompts++;
    try {
      _pinned = await DemoGuard.instance.pin() == true;
    } finally {
      _promptDone();
    }
    // Pinned after the demo ended: let go again.
    if (!mounted) DemoGuard.instance.release();
  }

  /// While away and still on screen: what to fix. Once back: the warning.
  String get _notice {
    final away = _away;
    if (away != null) {
      final fix = switch (away) {
        _Away.split => 'Close split screen or floating windows',
        _Away.recorded => 'Stop recording or mirroring your screen',
        _ => 'Come back to the demo',
      };
      return '$fix within ${_awayLimit.inSeconds} seconds, or your demo is submitted automatically.';
    }
    final why = switch (_lastAway) {
      _Away.otherWindow => 'another app or window was in use',
      _Away.split => 'split screen or a floating window was open',
      _Away.recorded => 'your screen was recorded or mirrored',
      _Away.unpinned => 'the app was unpinned',
      _Away.left || null => 'you left the demo',
    };
    return 'Warning: $why. If it happens again, your demo is submitted automatically.';
  }

  void _repeat() {
    if (_repeated.contains(_index)) return;
    setState(() {
      _repeated.add(_index);
      _listening = _listenSeconds; // the timer keeps running
    });
    _speak();
  }

  Future<void> _next() async {
    if (_index == _total - 1) return _submit();
    final order = _index + 2;
    setState(() {
      _index++;
      _remaining = _answerSeconds;
      _listening = _listenSeconds;
      _question = null;
    });
    final session = _session;
    // The server opens the next question once the previous answer time is
    // over; a moment early, it's asked again.
    for (var attempt = 0; attempt < 4 && mounted && !_submitted; attempt++) {
      try {
        final question = await SkillVerificationService.instance.demoQuestion(session, order);
        if (!mounted) return;
        setState(() => _question = question);
        await _speak();
        return;
      } on AuthException {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  }

  Future<void> _submit({bool auto = false}) async {
    if (_submitted) return;
    _submitted = true;
    _ticker?.cancel();
    await _speech.cancel();
    await _tts.stop();
    // The camera stops in the background (iOS suspends the app), so the
    // recording is finished and uploaded once the app is back.
    if (_hidden) {
      _finishLater = auto;
      return;
    }
    await _finish(auto: auto);
  }

  Future<void> _finish({required bool auto}) async {
    if (_finished) return;
    _finished = true;
    _finishLater = null;
    String? video;
    final camera = _camera;
    if (camera != null && (camera.value.isRecordingVideo || camera.value.isRecordingPaused)) {
      try {
        video = (await camera.stopVideoRecording()).path;
      } on CameraException {
        video = null;
      }
    }
    widget.onSubmit(
      DemoRecord(seconds: _elapsed, answered: _index + 1, violations: _violations, autoSubmitted: auto),
      video,
    );
  }

  @override
  Widget build(BuildContext context) {
    final total = _total;
    final listening = _listening > 0;
    final last = _index == total - 1;
    final fraction = _remaining / _answerSeconds;
    final camera = _camera;
    final recording = camera != null && camera.value.isInitialized;
    if (_cameraError != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InlineNotice(message: _cameraError, tone: NoticeTone.error, persistent: true),
          gap14,
          GlassPillButton(label: 'Back', onPressed: widget.onExit),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            GlassWell(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedBuilder(
                    animation: _wave,
                    builder: (context, _) => Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.error.withValues(alpha: 0.5 + 0.5 * _wave.value),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'REC ${_LiveDemoState._clock(_elapsed)}',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                ],
              ),
            ),
            const Spacer(),
            GlassWell(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(
                'Question ${_index + 1} of $total',
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Colors.white),
              ),
            ),
          ],
        ),
        if (_away != null || _lastAway != null) ...[
          gap14,
          InlineNotice(message: _notice, tone: NoticeTone.error, persistent: true),
        ],
        gap24,
        // Camera preview.
        GlassWell(
          radius: 24,
          height: 200,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (recording)
                  FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: camera.value.previewSize?.height ?? 1,
                      height: camera.value.previewSize?.width ?? 1,
                      child: TrueColors(child: CameraPreview(camera)),
                    ),
                  )
                else
                  Center(child: Icon(Icons.face_outlined, size: 84, color: AppColors.white(0.5))),
                Positioned(
                  left: 12,
                  bottom: 10,
                  child: Row(
                    children: [
                      const Icon(Icons.videocam_rounded, size: 16, color: Colors.white),
                      const SizedBox(width: 6),
                      const Icon(Icons.mic_rounded, size: 16, color: Colors.white),
                      const SizedBox(width: 8),
                      Text('Camera & mic on', style: AppText.caption.copyWith(fontSize: 11.5)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        gap24,
        Center(
          child: SizedBox.square(
            dimension: 132,
            child: CustomPaint(
              foregroundPainter: _RingPainter(fraction.clamp(0, 1)),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _LiveDemoState._clock(_remaining.clamp(0, 999)),
                      style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: Colors.white),
                    ),
                    Text('left', style: AppText.caption),
                  ],
                ),
              ),
            ),
          ),
        ),
        gap24,
        GlassWell(
          radius: 18,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              if (listening)
                AnimatedBuilder(
                  animation: _wave,
                  builder: (context, _) => Row(
                    children: [
                      for (var i = 0; i < 4; i++)
                        Container(
                          width: 4,
                          height: 8 + 14 * ((i.isEven ? _wave.value : 1 - _wave.value)),
                          margin: const EdgeInsets.only(right: 3),
                          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(2)),
                        ),
                    ],
                  ),
                )
              else
                const Icon(Icons.visibility_off_outlined, size: 20, color: Colors.white),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  listening
                      ? (_question == null
                            ? 'Opening the next question…'
                            : 'Listen to the question. Say “Repeat” to hear it again.')
                      : 'Close your eyes and answer out loud.',
                  style: AppText.label.copyWith(fontSize: 14),
                ),
              ),
            ],
          ),
        ),
        gap14,
        if (_hearing) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.mic_rounded, size: 15, color: Colors.white),
              const SizedBox(width: 6),
              Text('Listening… say “Repeat” to hear it again', style: AppText.caption.copyWith(fontSize: 12)),
            ],
          ),
          gap8,
        ],
        Center(
          child: UnderlineLink(
            label: _repeated.contains(_index) ? 'Question already repeated' : 'Repeat question (once)',
            onTap: _repeated.contains(_index) || listening ? null : _repeat,
          ),
        ),
        gap14,
        Text(
          last
              ? 'Your demo is submitted automatically when the answer time ends.'
              : 'The next question starts automatically when the answer time ends.',
          style: AppText.caption.copyWith(fontSize: 11.5),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  static String _clock(int seconds) =>
      '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
}

// ---- Pieces ------------------------------------------------------------------

/// A focus-area or skill choice. The selected one shows a check mark so the
/// choice is easy to spot in a long list.
class _PickChip extends StatelessWidget {
  const _PickChip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      child: GlassWell(
        active: selected,
        fillTop: selected ? 0.14 : 0,
        fillBottom: selected ? 0.08 : 0,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.fromLTRB(selected ? 10 : 14, 9, 14, 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (selected) ...[
                    const Icon(Icons.check_circle_rounded, size: 16, color: Colors.white),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StepIndicator extends StatelessWidget {
  const _StepIndicator({required this.app});

  final SkillApplication app;

  static const _labels = ['Portfolio', 'Live Demo', 'Content'];

  @override
  Widget build(BuildContext context) {
    final steps = VerifyStep.values;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, step) in steps.indexed) ...[
          if (i > 0)
            Expanded(
              child: Container(
                height: 1.5,
                margin: const EdgeInsets.only(top: 17),
                color: AppColors.white(app.statusOf(steps[i - 1]) == StepStatus.approved ? 0.8 : 0.22),
              ),
            ),
          SizedBox(
            width: 72,
            child: Column(
              children: [
                _dot(i, app.statusOf(step)),
                const SizedBox(height: 6),
                Text(_labels[i], textAlign: TextAlign.center, style: AppText.caption.copyWith(fontSize: 11.5)),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _dot(int i, StepStatus status) {
    final approved = status == StepStatus.approved;
    final current = status == StepStatus.open || status == StepStatus.underReview || status == StepStatus.rejected;
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: approved ? Colors.white : AppColors.white(current ? 0.14 : 0.04),
        border: Border.all(color: AppColors.white(approved || current ? 0.9 : 0.25), width: 1.2),
      ),
      child: approved
          ? const Icon(Icons.check_rounded, size: 18, color: AppColors.primary)
          : Text(
              '${i + 1}',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.white(current ? 1 : 0.5)),
            ),
    );
  }
}

class _StepCard extends StatelessWidget {
  const _StepCard({required this.step, required this.status, required this.onTap, this.note});

  final VerifyStep step;
  final StepStatus status;
  final String? note;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final (icon, title, subtitle) = switch (step) {
      VerifyStep.portfolio => (
        Icons.folder_outlined,
        'Portfolio Submission',
        'Share a project that shows your skill: problem, solution, links and a PDF.',
      ),
      VerifyStep.demo => (
        Icons.videocam_outlined,
        'Live Demo',
        'Answer spoken questions on camera, one at a time, against a timer.',
      ),
      VerifyStep.content => (
        Icons.article_outlined,
        'Content Submission',
        'Publish a blog with an explanation video, or another visual format.',
      ),
    };
    final locked = status == StepStatus.locked;
    final done = status == StepStatus.approved;
    return Opacity(
      opacity: locked ? 0.55 : 1,
      child: GlassWell(
        radius: 22,
        active: onTap != null,
        error: status == StepStatus.rejected,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  GlassIconBadge(icon: icon, size: 48),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                title,
                                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(color: AppColors.white(0.35)),
                              ),
                              child: Text(
                                status.label,
                                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(note ?? subtitle, style: AppText.caption),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    done
                        ? Icons.check_circle_rounded
                        : (locked ? Icons.lock_outline_rounded : Icons.chevron_right_rounded),
                    size: 20,
                    color: Colors.white,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _VerifiedBanner extends StatelessWidget {
  const _VerifiedBanner({required this.app, required this.onTap});

  final SkillApplication app;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GlassWell(
      radius: 20,
      active: true,
      fillTop: 0.06,
      fillBottom: 0.02,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                const Icon(Icons.workspace_premium_rounded, size: 26, color: Colors.white),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${app.skill} · Skill Verified',
                        style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: Colors.white),
                      ),
                      Text(
                        app.contentPublished
                            ? 'Your content is published.'
                            : 'Content saved as draft until KYC is complete.',
                        style: AppText.caption,
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, size: 20, color: Colors.white),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WhyVerify extends StatelessWidget {
  const _WhyVerify();

  @override
  Widget build(BuildContext context) {
    return GlassWell(
      radius: 22,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Why verify your skills?',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
          ),
          gap8,
          const _Bullets(
            items: [
              (Icons.verified_outlined, 'A verified badge Seekers trust when booking.'),
              (Icons.trending_up_rounded, 'Rank higher in Explore and get more sessions.'),
              (Icons.article_outlined, 'Your submitted content is published to your profile.'),
              (Icons.autorenew_rounded, 'Stays valid while you\'re active; renew after 6 months of inactivity.'),
            ],
          ),
        ],
      ),
    );
  }
}

class _Bullets extends StatelessWidget {
  const _Bullets({required this.items});

  final List<(IconData, String)> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final (icon, text) in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 19, color: Colors.white),
                const SizedBox(width: 12),
                Expanded(child: Text(text, style: AppText.label.copyWith(fontSize: 13.5, height: 1.4))),
              ],
            ),
          ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {this.number});

  final String text;
  final int? number;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 10),
      child: Row(
        children: [
          if (number != null) ...[
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.white(0.5)),
              ),
              child: Text(
                '$number',
                style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Colors.white),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Text(
            text,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
          ),
        ],
      ),
    );
  }
}

/// A text field with a live "x / max" counter and a minimum length hint.
class _CountedField extends StatelessWidget {
  const _CountedField({
    required this.controller,
    required this.hint,
    required this.min,
    required this.max,
    required this.onChanged,
    this.label,
    this.lines = 1,
    this.error,
  });

  final TextEditingController controller;
  final String hint;
  final String? label;
  final int min;
  final int max;
  final int lines;
  final String? error;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final length = controller.text.trim().length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (label != null) ...[Text(label!, style: AppText.caption), gap8],
        GlassTextField(
          controller: controller,
          hint: hint,
          maxLines: lines,
          textCapitalization: TextCapitalization.sentences,
          keyboardType: lines > 1 ? TextInputType.multiline : null,
          inputFormatters: [LengthLimitingTextInputFormatter(max)],
          errorText: error,
          onChanged: (_) => onChanged(),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6, left: 6, right: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  length < min ? 'Minimum $min characters' : '',
                  style: AppText.caption.copyWith(fontSize: 11.5),
                ),
              ),
              Text('$length / $max', style: AppText.caption.copyWith(fontSize: 11.5)),
            ],
          ),
        ),
      ],
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.onWrap});

  final void Function(String open, String close) onWrap;

  @override
  Widget build(BuildContext context) {
    final tools = <(IconData, String, String, String)>[
      (Icons.format_bold_rounded, 'Bold', '<b>', '</b>'),
      (Icons.format_italic_rounded, 'Italic', '<i>', '</i>'),
      (Icons.title_rounded, 'Heading', '<h2>', '</h2>'),
      (Icons.format_list_bulleted_rounded, 'List', '<ul>\n<li>', '</li>\n</ul>'),
      (Icons.link_rounded, 'Link', '<a href="https://">', '</a>'),
      (Icons.code_rounded, 'Code', '<code>', '</code>'),
    ];
    return GlassWell(
      radius: 16,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          for (final (icon, tip, open, close) in tools)
            IconButton(
              tooltip: tip,
              visualDensity: VisualDensity.compact,
              onPressed: () => onWrap(open, close),
              icon: Icon(icon, size: 20, color: Colors.white),
            ),
        ],
      ),
    );
  }
}

class _ToggleText extends StatelessWidget {
  const _ToggleText({required this.label, required this.icon, required this.onTap});

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: Colors.white),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

class _UploadBox extends StatelessWidget {
  const _UploadBox({
    required this.title,
    required this.formats,
    required this.file,
    required this.bytes,
    required this.onChoose,
    required this.onRemove,
    this.previousName,
    this.error,
    this.icon = Icons.upload_file_outlined,
  });

  final String title;
  final String formats;
  final IconData icon;
  final PlatformFile? file;
  final int? bytes;

  /// A file already submitted earlier, kept unless replaced.
  final String? previousName;
  final String? error;
  final VoidCallback onChoose;
  final VoidCallback onRemove;

  static String _formatBytes(int bytes) =>
      bytes >= 1024 * 1024 ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB' : '${(bytes / 1024).ceil()} KB';

  @override
  Widget build(BuildContext context) {
    final name = file?.name ?? previousName;
    return GlassWell(
      radius: 22,
      error: error != null,
      padding: const EdgeInsets.fromLTRB(18, 22, 18, 20),
      child: name == null
          ? Column(
              children: [
                Icon(icon, size: 36, color: Colors.white),
                gap14,
                Text(
                  title,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
                ),
                const SizedBox(height: 4),
                Text('Tap to browse your files', style: AppText.caption),
                gap14,
                SmallPillButton(label: 'Choose File', onPressed: onChoose),
                gap14,
                Text(formats, style: AppText.caption.copyWith(fontSize: 11.5), textAlign: TextAlign.center),
              ],
            )
          : Row(
              children: [
                const Icon(Icons.description_outlined, size: 28, color: Colors.white),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white),
                      ),
                      Text(file == null ? 'Previously submitted' : _formatBytes(bytes ?? 0), style: AppText.caption),
                    ],
                  ),
                ),
                if (file == null)
                  SmallPillButton(label: 'Replace', onPressed: onChoose)
                else
                  IconButton(
                    tooltip: 'Remove file',
                    onPressed: onRemove,
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                  ),
              ],
            ),
    );
  }
}

class _Result extends StatelessWidget {
  const _Result({required this.icon, required this.title, required this.message, this.details, this.action});

  final IconData icon;
  final String title;
  final String message;
  final Widget? details;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(child: GlassIconBadge(icon: icon, size: 80)),
        gap24,
        Text(title.toUpperCase(), style: AppText.title, textAlign: TextAlign.center),
        gap14,
        Text(message, style: AppText.body, textAlign: TextAlign.center),
        if (details != null) ...[gap24, details!],
        if (action != null) ...[gap24, action!],
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow(this.label, this.value, {this.icon});

  final String label;
  final String value;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppText.caption),
          const SizedBox(width: 12),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (icon != null) ...[Icon(icon, size: 14, color: Colors.white), const SizedBox(width: 4)],
                Flexible(
                  child: Text(
                    value,
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter(this.value);

  final double value;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(3);
    canvas.drawArc(
      rect,
      0,
      6.283,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = AppColors.white(0.16),
    );
    canvas.drawArc(
      rect,
      -1.5708,
      6.283 * value,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.value != value;
}

class _Busy extends StatelessWidget {
  const _Busy({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 60),
      child: Column(
        children: [
          const SizedBox.square(dimension: 28, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white)),
          gap14,
          Text(message, style: AppText.body),
        ],
      ),
    );
  }
}
