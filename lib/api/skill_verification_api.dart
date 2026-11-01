import 'dart:convert';

import 'api_client.dart';

/// Solver skill verification (Postman: Solver App > Verification): a
/// portfolio, then a recorded live demo answering sealed questions, then proof
/// content, each reviewed by the admin.
abstract final class SkillVerificationApi {
  static ApiClient get _api => ApiClient.instance;

  /// GET /public/content-categories: skills with their focus areas.
  static Future<Map<String, List<String>>> skills() async {
    final data = await _api.get('/public/content-categories');
    final list = data is Map ? data['categories'] : null;
    return {
      if (list is List)
        for (final c in list)
          if (c is Map && c['is_active'] != false && c['name'] is String)
            c['name'] as String: [
              for (final s in c['sub_categories'] as List? ?? const [])
                if (s is Map && s['is_active'] != false && s['name'] is String) s['name'] as String,
            ],
    };
  }

  /// GET /solver/verification/status: the current run, its steps and the
  /// verified skills.
  static Future<Map<String, dynamic>> status() async => _map(await _api.get('/solver/verification/status'));

  /// GET /solver/verification/portfolio: submitted portfolios, newest first.
  static Future<List<Map<String, dynamic>>> portfolios() async {
    final data = await _api.get('/solver/verification/portfolio');
    return [
      if (data is List)
        for (final p in data) _map(p),
    ];
  }

  /// POST /solver/verification/add-skill: a new run once the current one is
  /// verified or expired.
  static Future<void> addSkill() => _api.post('/solver/verification/add-skill');

  /// POST /solver/verification/portfolio-pdf (PDF up to 20 MB).
  static Future<void> submitPortfolio({
    required String skill,
    required List<String> focusAreas,
    required String problem,
    required String solution,
    required List<String> links,
    required String pdfPath,
    required String pdfName,
    String? linkedIn,
  }) => _api.upload(
    '/solver/verification/portfolio-pdf',
    files: [UploadFile(field: 'portfolio_pdf', path: pdfPath, fileName: pdfName, contentType: 'application/pdf')],
    fields: {
      'category': skill,
      'focus_areas': focusAreas.join(','),
      'linkedin_url': ?linkedIn,
      'projects': jsonEncode([
        {'problem_statement': problem, 'solution_explanation': solution, 'project_links': links},
      ]),
    },
  );

  /// POST /solver/verification/start-demo: the demo id, sealed questions and
  /// timings. Only the first question can be opened straight away.
  static Future<Map<String, dynamic>> startDemo() async => _map(await _api.post('/solver/verification/start-demo'));

  /// GET /solver/verification/demo/:id/question/:order (from 1): unlocks the
  /// next question once the previous one's answer time is over.
  static Future<Map<String, dynamic>> question(String demoId, int order) async =>
      _map(_map(await _api.get('/solver/verification/demo/$demoId/question/$order'))['question']);

  /// POST /solver/verification/demo: the recording (up to 200 MB).
  static Future<void> submitDemo(String demoId, {required String path, required String fileName}) => _api.upload(
    '/solver/verification/demo',
    files: [UploadFile(field: 'video', path: path, fileName: fileName, contentType: videoType(fileName))],
    fields: {'demo_id': demoId},
  );

  /// POST /solver/verification/content: an article plus a video or PPTX (up
  /// to 100 MB). [videoFormat] is `practical_demo`, `3d_animation` or
  /// `slide_based`; [focusArea] must be one from the portfolio.
  static Future<void> submitContent({
    required String title,
    required String articleHtml,
    required String videoFormat,
    required String focusArea,
    required String path,
    required String fileName,
  }) => _api.upload(
    '/solver/verification/content',
    files: [UploadFile(field: 'video', path: path, fileName: fileName, contentType: videoType(fileName))],
    fields: {'blog_title': title, 'blog_content': articleHtml, 'video_format': videoFormat, 'sub_category': focusArea},
  );

  /// The part type the API checks for each allowed extension.
  static String videoType(String fileName) => switch (fileName.split('.').last.toLowerCase()) {
    'webm' => 'video/webm',
    'mov' => 'video/quicktime',
    'avi' => 'video/x-msvideo',
    'mkv' => 'video/x-matroska',
    'pptx' => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    _ => 'video/mp4',
  };

  static Map<String, dynamic> _map(Object? data) => data is Map ? Map<String, dynamic>.from(data) : const {};
}
