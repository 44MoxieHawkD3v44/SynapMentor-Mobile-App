import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../api/skill_verification_api.dart';
import 'auth_service.dart';

enum StepStatus {
  locked('Locked'),
  open('Pending'),
  underReview('Under review'),
  approved('Approved'),
  rejected('Needs changes');

  const StepStatus(this.label);
  final String label;
}

enum VerifyStep { portfolio, demo, content }

class Portfolio {
  const Portfolio({
    required this.problem,
    required this.solution,
    required this.skillsUsed,
    required this.links,
    required this.pdfName,
    this.linkedIn,
    this.pdfPath,
  });

  /// The PDF on this device, for uploading.
  final String? pdfPath;

  final String problem;
  final String solution;
  final List<String> skillsUsed;
  final List<String> links;
  final String? linkedIn;
  final String pdfName;
}

class DemoRecord {
  const DemoRecord({
    required this.seconds,
    required this.answered,
    required this.violations,
    required this.autoSubmitted,
  });

  final int seconds;
  final int answered;

  /// Times the solver broke the demo rules: left the app, used another app or
  /// window, split the screen, recorded or mirrored it, or unpinned the app.
  final int violations;

  /// True when the demo ended because of a second violation.
  final bool autoSubmitted;
}

enum ContentFormat { blogVideo, other }

class ContentDraft {
  const ContentDraft({
    required this.format,
    required this.title,
    required this.body,
    required this.presentation,
    required this.fileName,
    this.filePath,
  });

  /// The file on this device, for uploading.
  final String? filePath;

  final ContentFormat format;
  final String title;

  /// Blog body (may contain HTML) or, for other formats, a description.
  final String body;

  /// How the solver presents it, e.g. "Screen recording with voice-over".
  final String presentation;

  /// The uploaded video or file.
  final String fileName;
}

class SkillApplication {
  SkillApplication({required this.id, required this.skill, this.focusAreas = const [], this.remote = false});

  /// Loaded from the API.
  final bool remote;

  final String id;

  /// The skill being verified (a content category on the server).
  final String skill;

  /// The focus areas chosen under [skill] (its sub-categories).
  List<String> focusAreas;

  StepStatus portfolioStatus = StepStatus.open;
  StepStatus demoStatus = StepStatus.locked;
  StepStatus contentStatus = StepStatus.locked;

  /// The admin's reason when a step needs changes.
  final notes = <VerifyStep, String>{};

  Portfolio? portfolio;
  DemoRecord? demo;
  ContentDraft? content;

  /// Set when the approved content has been published to the solver's content.
  bool contentPublished = false;
  DateTime? verifiedAt;
  DateTime lastActiveAt = DateTime.now();

  StepStatus statusOf(VerifyStep step) => switch (step) {
    VerifyStep.portfolio => portfolioStatus,
    VerifyStep.demo => demoStatus,
    VerifyStep.content => contentStatus,
  };

  bool get verified =>
      portfolioStatus == StepStatus.approved &&
      demoStatus == StepStatus.approved &&
      contentStatus == StepStatus.approved;

  /// Verification expires after six months without activity.
  bool get expired => verified && DateTime.now().difference(lastActiveAt) > SkillVerificationService.expiry;

  /// The step waiting on the admin, if any.
  VerifyStep? get inReview => VerifyStep.values.where((s) => statusOf(s) == StepStatus.underReview).firstOrNull;
}

/// A live demo started on the server: its sealed questions open one at a
/// time, each after the previous one's answer time.
class DemoSession {
  const DemoSession({
    required this.id,
    required this.questionCount,
    required this.firstQuestion,
    required this.listenSeconds,
    required this.answerSeconds,
    required this.expiresAt,
  });

  final String id;
  final int questionCount;
  final String firstQuestion;
  final int listenSeconds;
  final int answerSeconds;
  final DateTime expiresAt;
}

/// Skill verification: portfolio, live demo and content, each reviewed by
/// the admin. A solver's runs come from the skill verification API; the server
/// keeps one active run plus the skills already verified.
class SkillVerificationService extends ChangeNotifier {
  static final SkillVerificationService instance = SkillVerificationService();

  // ---- API -----------------------------------------------------------------------

  /// The video styles the API accepts, by label.
  static const _videoFormats = {
    'Practical demo': 'practical_demo',
    '3D animation': '3d_animation',
    'Slide-based': 'slide_based',
  };

  /// Whether the server lets the solver start verifying another skill.
  bool _canAddSkill = false;

  /// Why loading failed, if it did.
  String? loadError;

  /// Loads the skills to choose from and the solver's verification runs.
  Future<void> load(AppUser user) async {
    if (user.role != UserRole.solver) return;
    try {
      final results = await Future.wait([
        SkillVerificationApi.skills(),
        SkillVerificationApi.status(),
        SkillVerificationApi.portfolios(),
      ]);
      setReferenceData(
        areas: results[0] as Map<String, List<String>>,
        videoStyles: _videoFormats.keys.toList(),
        formats: _videoFormats.keys.toList(),
      );
      final status = results[1] as Map<String, dynamic>;
      final portfolios = results[2] as List<Map<String, dynamic>>;
      _apps[user.email] = _appsFrom(status, portfolios);
      _verifiedAreas[user.email] = _verifiedAreasFrom(status, portfolios);
      loadError = null;
    } on AuthException catch (e) {
      loadError = e.message;
    }
    notifyListeners();
  }

  List<SkillApplication> _appsFrom(Map<String, dynamic> s, List<Map<String, dynamic>> portfolios) {
    _canAddSkill = s['can_add_skill'] == true;
    final run = s['verification'] is Map
        ? Map<String, dynamic>.from(s['verification'] as Map)
        : const <String, dynamic>{};
    final skill = (run['skill_name'] as String? ?? '').trim();
    final apps = <SkillApplication>[];
    final verified = [for (final v in s['verified_skills'] as List? ?? const []) '$v'];
    for (final name in verified) {
      if (name.toLowerCase() == skill.toLowerCase()) continue;
      apps.add(
        SkillApplication(id: 'verified-$name', skill: name, remote: true)
          ..portfolioStatus = StepStatus.approved
          ..demoStatus = StepStatus.approved
          ..contentStatus = StepStatus.approved,
      );
    }
    if (skill.isEmpty) return apps;
    final portfolio = portfolios.where((p) => p['category'] == skill || p['skill_category'] == skill).firstOrNull;
    final focusAreas = [
      for (final f in '${portfolio?['focus_areas'] ?? ''}'.split(','))
        if (f.trim().isNotEmpty) f.trim(),
    ];
    final project = (portfolio?['projects'] as List?)?.whereType<Map>().firstOrNull;
    final demo = s['live_demo'] is Map ? s['live_demo'] as Map : const {};
    final content = s['content'] is Map ? s['content'] as Map : const {};
    // Each step follows the server's status. A verified run has every step
    // approved, and an approved step means the ones before it were too.
    final runVerified = '${run['status']}'.toLowerCase() == 'verified';
    var contentStatus = _stepStatus(run['content_status'], open: false);
    if (runVerified || _contentApproved(content['status'])) contentStatus = StepStatus.approved;
    var demoStatus = _stepStatus(run['live_demo_status'], open: false);
    if (contentStatus != StepStatus.locked) demoStatus = StepStatus.approved;
    if (demoStatus == StepStatus.locked && _stepStatus(demo['status'], open: false) == StepStatus.approved) {
      demoStatus = StepStatus.approved;
    }
    var portfolioStatus = _stepStatus(run['portfolio_status'], open: true);
    if (demoStatus != StepStatus.locked) portfolioStatus = StepStatus.approved;
    if (demoStatus == StepStatus.locked && portfolioStatus == StepStatus.approved) demoStatus = StepStatus.open;
    if (contentStatus == StepStatus.locked && demoStatus == StepStatus.approved) contentStatus = StepStatus.open;
    final app = SkillApplication(id: '${run['id']}', skill: skill, focusAreas: focusAreas, remote: true)
      ..portfolioStatus = portfolioStatus
      ..demoStatus = demoStatus
      ..contentStatus = contentStatus
      ..verifiedAt = DateTime.tryParse('${run['verified_at']}')?.toLocal()
      ..lastActiveAt = (DateTime.tryParse('${run['updated_at']}') ?? DateTime.now()).toLocal();
    // The content sent for review, so it shows again after a restart.
    final title = '${content['title'] ?? ''}'.trim();
    if (title.isNotEmpty) {
      final format = '${content['format'] ?? ''}';
      final media = '${content['media_url'] ?? ''}'.split('?').first.split('/').last;
      app
        ..content = ContentDraft(
          format: ContentFormat.blogVideo,
          title: title.replaceFirst(RegExp(r'\s*[—-]\s*Video Explanation$'), ''),
          body: '${content['body_html'] ?? content['description'] ?? ''}',
          presentation: _videoFormats.entries.where((e) => e.value == format).firstOrNull?.key ?? 'Practical demo',
          fileName: media.isEmpty ? 'Explanation video' : media,
        )
        ..contentPublished = '${content['status']}'.toLowerCase() == 'published' || content['published_at'] != null;
    }
    if (project != null) {
      app.portfolio = Portfolio(
        problem: '${project['problem_statement'] ?? ''}',
        solution: '${project['solution_explanation'] ?? ''}',
        skillsUsed: const [],
        links: [for (final l in project['project_links'] as List? ?? const []) '$l'],
        linkedIn: portfolio?['linkedin_url'] as String?,
        pdfName: 'Portfolio.pdf',
      );
    }
    String? feedback(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
    // Feedback explains a step that needs changes; once approved it's history.
    if (feedback(s['portfolio_feedback']) case final note? when portfolioStatus != StepStatus.approved) {
      app.notes[VerifyStep.portfolio] = note;
    }
    if (feedback(demo['admin_feedback']) case final note? when demoStatus != StepStatus.approved) {
      app.notes[VerifyStep.demo] = note;
    }
    if (feedback(content['admin_feedback']) case final note? when contentStatus != StepStatus.approved) {
      app.notes[VerifyStep.content] = note;
    }
    if (s['is_expired'] == true) app.lastActiveAt = DateTime.now().subtract(expiry * 2);
    return apps..add(app);
  }

  /// Verified skills (by their taxonomy name) with the focus areas from their
  /// portfolios, preferring the approved ones.
  Map<String, List<String>> _verifiedAreasFrom(Map<String, dynamic> s, List<Map<String, dynamic>> portfolios) {
    final run = s['verification'] is Map ? s['verification'] as Map : const {};
    final runSkill = '${run['skill_name'] ?? ''}'.trim();
    final names = <String>{
      for (final v in s['verified_skills'] as List? ?? const []) '$v'.trim(),
      if ('${run['status']}'.toLowerCase() == 'verified') runSkill,
    }..remove('');
    String skillOf(Map<String, dynamic> p) {
      final category = '${p['category'] ?? ''}'.trim();
      return category.isNotEmpty ? category : '${p['skill_category'] ?? ''}'.split(',').first.trim();
    }

    String? canonical(Iterable<String> options, String name) =>
        options.where((o) => o.toLowerCase() == name.toLowerCase()).firstOrNull;
    final result = <String, List<String>>{};
    for (final name in names) {
      final mine = portfolios.where((p) => skillOf(p).toLowerCase() == name.toLowerCase()).toList();
      final approved = mine.where((p) => '${p['status']}'.toLowerCase() == 'approved').toList();
      final areas = <String>[
        for (final p in approved.isEmpty ? mine : approved) ...'${p['focus_areas'] ?? ''}'.split(','),
        if (name.toLowerCase() == runSkill.toLowerCase())
          for (final f in s['run_focus_areas'] as List? ?? const []) '$f',
      ];
      final skill = canonical(focusAreas.keys, name) ?? name;
      final known = focusAreas[skill] ?? const <String>[];
      final list = result.putIfAbsent(skill, () => []);
      for (final raw in areas) {
        final area = raw.trim();
        if (area.isEmpty || canonical(list, area) != null) continue;
        list.add(canonical(known, area) ?? area);
      }
    }
    for (final list in result.values) {
      list.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    }
    return result;
  }

  final _verifiedAreas = <String, Map<String, List<String>>>{};

  /// The skills the solver is verified in, with their focus areas: the
  /// categories and sub-categories they can create content in.
  Map<String, List<String>> verifiedCategories(AppUser user) => _verifiedAreas[user.email] ?? const {};

  /// Whether the solver's verification has been loaded yet.
  bool isLoaded(AppUser user) => _verifiedAreas.containsKey(user.email);

  static StepStatus _stepStatus(Object? status, {required bool open}) => switch ('$status'.toLowerCase()) {
    'approved' || 'verified' || 'accepted' || 'completed' || 'passed' || 'published' => StepStatus.approved,
    'rejected' || 'needs_changes' || 'changes_requested' || 'failed' => StepStatus.rejected,
    'submitted' || 'pending' || 'under_review' || 'in_review' || 'pending_review' => StepStatus.underReview,
    _ => open ? StepStatus.open : StepStatus.locked,
  };

  /// The content row is a draft until the admin accepts it.
  static bool _contentApproved(Object? status) =>
      const {'published', 'approved', 'accepted'}.contains('$status'.toLowerCase());

  /// Starts the live demo. Fails until the admin has assigned questions.
  Future<DemoSession> startDemo(SkillApplication app) async {
    final d = await SkillVerificationApi.startDemo();
    final first = d['first_question'] is Map ? Map<String, dynamic>.from(d['first_question'] as Map) : null;
    if (d['demo_id'] is! String || first == null) {
      throw const AuthException('The live demo couldn\'t be started. Please try again.');
    }
    return DemoSession(
      id: d['demo_id'] as String,
      questionCount: d['question_count'] is int ? d['question_count'] as int : 1,
      firstQuestion: await _openSealed(first),
      listenSeconds: d['listen_duration_sec'] is int ? d['listen_duration_sec'] as int : 10,
      answerSeconds: d['answer_duration_sec'] is int ? d['answer_duration_sec'] as int : 70,
      expiresAt: (DateTime.tryParse('${d['expires_at']}') ?? DateTime.now().add(const Duration(minutes: 10))).toLocal(),
    );
  }

  /// Opens question [order] (from 1) of a running demo.
  Future<String> demoQuestion(DemoSession session, int order) async =>
      _openSealed(await SkillVerificationApi.question(session.id, order));

  /// Questions arrive sealed with AES-256-GCM (nonce, ciphertext and tag in
  /// one base64 value); the key comes only once a question is unlocked.
  Future<String> _openSealed(Map<String, dynamic> q) async {
    final sealed = q['question_ciphertext'] as String?;
    final key = q['question_key'] as String?;
    if (sealed == null || key == null) {
      final plain = q['question_text'] as String?;
      if (plain != null && plain.isNotEmpty) return plain;
      throw const AuthException('This question isn\'t available yet. Please try again.');
    }
    final bytes = base64Decode(sealed);
    if (bytes.length < 12 + 16) throw const AuthException('This question couldn\'t be opened.');
    final cipher = AesGcm.with256bits();
    final clear = await cipher.decrypt(
      SecretBox(
        bytes.sublist(12, bytes.length - 16),
        nonce: bytes.sublist(0, 12),
        mac: Mac(bytes.sublist(bytes.length - 16)),
      ),
      secretKey: SecretKey(base64Decode(key)),
    );
    return utf8.decode(clear);
  }

  static const expiry = Duration(days: 180);
  static const questionSeconds = 60;
  static const maxPdfBytes = 20 * 1024 * 1024;
  static const maxVideoBytes = 100 * 1024 * 1024;
  static const videoExtensions = ['mp4', 'webm', 'mov', 'avi', 'mkv'];
  static const otherExtensions = ['mp4', 'webm', 'mov', 'avi', 'mkv', 'pptx'];

  /// A portfolio covers one skill and up to this many of its focus areas.
  static const maxFocusAreas = 5;

  // Skills (with their focus areas) and content formats, loaded from the API.
  static final focusAreas = <String, List<String>>{};
  static final presentations = <String>[];
  static final otherFormats = <String>[];

  /// Replaces the skills, focus areas and formats with what the API returned.
  void setReferenceData({Map<String, List<String>>? areas, List<String>? videoStyles, List<String>? formats}) {
    if (areas != null) {
      focusAreas
        ..clear()
        ..addAll(areas);
    }
    if (videoStyles != null) {
      presentations
        ..clear()
        ..addAll(videoStyles);
    }
    if (formats != null) {
      otherFormats
        ..clear()
        ..addAll(formats);
    }
    notifyListeners();
  }

  final _apps = <String, List<SkillApplication>>{};

  List<SkillApplication> applications(AppUser user) => _apps.putIfAbsent(user.email, () => []);

  List<String> verifiedSkills(AppUser user) =>
      applications(user).where((a) => a.verified && !a.expired).map((a) => a.skill).toList();

  /// Starts verification for a new skill. Verifying one skill never affects
  /// another, so each skill has its own application. Solvers verify one skill
  /// at a time on the server.
  SkillApplication start(AppUser user, String skill, List<String> focusAreas) {
    final existing = applications(user).where((a) => a.skill.toLowerCase() == skill.toLowerCase()).firstOrNull;
    if (existing != null) {
      throw AuthException(
        existing.verified ? 'You\'re already verified for $skill.' : 'You\'re already verifying $skill.',
      );
    }
    final solver = user.role == UserRole.solver;
    final active = applications(user).where((a) => a.remote && !a.verified && !a.expired).firstOrNull;
    if (solver && active != null) {
      throw AuthException('Finish verifying ${active.skill} before adding another skill.');
    }
    final app = SkillApplication(
      id: '${DateTime.now().millisecondsSinceEpoch}',
      skill: skill,
      focusAreas: focusAreas,
      remote: solver,
    );
    applications(user).add(app);
    notifyListeners();
    return app;
  }

  /// Drops an application that hasn't been submitted yet.
  void discard(AppUser user, SkillApplication app) {
    if (app.portfolio != null) return;
    applications(user).remove(app);
    notifyListeners();
  }

  /// The skill is the category the server verifies; the chosen focus areas
  /// (and any skills used) are its sub-categories.
  Future<void> submitPortfolio(SkillApplication app, Portfolio portfolio) async {
    final path = portfolio.pdfPath;
    if (path == null) throw const AuthException('Upload your portfolio document again.');
    // A finished or expired run makes way for a new one first.
    if (_canAddSkill && app.portfolio == null) {
      await SkillVerificationApi.addSkill();
      _canAddSkill = false;
    }
    await SkillVerificationApi.submitPortfolio(
      skill: app.skill,
      focusAreas: {...app.focusAreas, ...portfolio.skillsUsed}.toList(),
      problem: portfolio.problem,
      solution: portfolio.solution,
      links: portfolio.links,
      pdfPath: path,
      pdfName: portfolio.pdfName,
      linkedIn: portfolio.linkedIn,
    );
    app
      ..portfolio = portfolio
      ..portfolioStatus = StepStatus.underReview
      ..lastActiveAt = DateTime.now();
    app.notes.remove(VerifyStep.portfolio);
    notifyListeners();
  }

  /// Uploads the recording of [session] for review. The recording is stored
  /// in Cloudflare R2 by the backend.
  Future<void> submitDemo(SkillApplication app, DemoRecord record, {DemoSession? session, String? videoPath}) async {
    if (session == null || videoPath == null) throw const AuthException('The demo recording is missing.');
    final extension = videoPath.split('.').last.toLowerCase();
    await SkillVerificationApi.submitDemo(session.id, path: videoPath, fileName: 'live-demo.$extension');
    app
      ..demo = record
      ..demoStatus = StepStatus.underReview
      ..lastActiveAt = DateTime.now();
    app.notes.remove(VerifyStep.demo);
    notifyListeners();
  }

  /// [focusArea] must be one of the portfolio's focus areas.
  Future<void> submitContent(SkillApplication app, ContentDraft draft, {String? focusArea}) async {
    final path = draft.filePath;
    if (path == null) throw const AuthException('Upload your file again.');
    final body = draft.body.trim();
    await SkillVerificationApi.submitContent(
      title: draft.title,
      // Plain text becomes paragraphs; HTML is sent as written.
      articleHtml: body.contains('<')
          ? body
          : [
              for (final p in body.split(RegExp(r'\n\s*\n')))
                if (p.trim().isNotEmpty) '<p>${const HtmlEscape().convert(p.trim())}</p>',
            ].join(),
      videoFormat: _videoFormats[draft.presentation] ?? 'practical_demo',
      focusArea: focusArea ?? app.focusAreas.firstOrNull ?? app.skill,
      path: path,
      fileName: draft.fileName,
    );
    app
      ..content = draft
      ..contentStatus = StepStatus.underReview
      ..lastActiveAt = DateTime.now();
    app.notes.remove(VerifyStep.content);
    notifyListeners();
  }

  /// Renewal after expiry: the portfolio is submitted again from scratch.
  void renew(SkillApplication app) {
    app
      ..portfolio = null
      ..demo = null
      ..portfolioStatus = StepStatus.open
      ..demoStatus = StepStatus.locked
      ..contentStatus = StepStatus.locked
      ..verifiedAt = null
      ..lastActiveAt = DateTime.now();
    app.notes.clear();
    notifyListeners();
  }
}
