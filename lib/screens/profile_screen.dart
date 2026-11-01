import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../core/theme.dart';
import '../services/auth_service.dart';
import '../services/countries.dart';
import '../services/kyc_service.dart';
import '../services/solver_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';
import '../widgets/true_colors.dart';
import '../widgets/glass_select.dart';
import 'booking_sheet.dart' show GlassOption;
import 'solver_profile_tabs.dart';

enum _SolverTab { profile, expertise, availability, bookingLinks }

/// The user's own profile: photo, personal information and the anonymous
/// identity used in the Community. The chosen country sets the phone code,
/// currency and timezone.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, required this.user, this.openAvailability = false});

  final AppUser user;

  /// Opens a solver's profile on the Availability tab.
  final bool openAvailability;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  static const _genders = ['Male', 'Female', 'Non-binary', 'Prefer not to say'];
  static final _pseudoPattern = RegExp(r'^[A-Za-z0-9._-]{3,20}$');

  final _auth = AuthService.instance;
  late final UserProfile _draft = widget.user.profile.copy();

  /// The profile as last saved, to tell whether anything changed since.
  late UserProfile _saved = widget.user.profile.copy();
  late final _first = TextEditingController(text: _draft.firstName);
  late final _last = TextEditingController(text: _draft.lastName);
  late final _email = TextEditingController(text: widget.user.email);
  late final _phone = TextEditingController(text: _draft.phone);
  late final _bio = TextEditingController(text: _draft.bio);
  late final _city = TextEditingController(text: _draft.city);
  final _pseudo = TextEditingController();

  late _SolverTab _solverTab = widget.openAvailability ? _SolverTab.availability : _SolverTab.profile;
  bool _pricingOpen = false;
  bool _personalOpen = false;
  bool _anonymousOpen = false;
  bool _saving = false;
  bool _settingPseudo = false;
  String? _error;
  String? _success;
  String? _pseudoError;
  final _errors = <String, String?>{};

  CountryInfo? get _country => Countries.byName(_draft.countryName);

  /// A solver's mobile number comes from KYC, where it's verified with an
  /// OTP, so it can't be edited here. Seekers enter theirs here.
  bool get _phoneLocked => _isSolver;

  bool get _phoneVerified => KycService.instance.stateFor(widget.user).otp[ContactChannel.mobile]!.verified;

  @override
  void initState() {
    super.initState();
    // Whether the number is verified, so it shows as locked.
    if (_isSolver) {
      KycService.instance.refresh(widget.user).then((_) {
        if (mounted) setState(() {});
      }, onError: (Object _) {});
    }
  }

  /// Everyone types their city.
  bool get _typeCity => true;

  /// A seeker's country and timezone can't change once saved (the server
  /// keeps the country fixed too).
  bool get _placeLocked =>
      !_isSolver && widget.user.profile.countryName != null && widget.user.profile.timezone != null;
  String? get _pseudoName => widget.user.profile.pseudoName;

  @override
  void dispose() {
    for (final c in [_first, _last, _email, _phone, _bio, _pseudo, _city]) {
      c.dispose();
    }
    super.dispose();
  }

  int get _completion {
    final country = _country;
    final checks = [
      _draft.photoPath != null,
      _first.text.trim().isNotEmpty,
      _last.text.trim().isNotEmpty,
      // A solver's mobile number is verified (and filled in) in KYC.
      if (!_isSolver) country != null && country.phoneFits(_phone.text.length),
      country != null,
      _draft.city != null,
      _draft.gender != null,
      _draft.dateOfBirth != null,
      _draft.timezone != null,
      _bio.text.trim().isNotEmpty,
      _pseudoName != null,
    ];
    return (checks.where((c) => c).length * 100 / checks.length).round();
  }

  void _clearError(String field) {
    if (_errors[field] != null || _success != null) {
      setState(() {
        _errors[field] = null;
        _success = null;
      });
    } else {
      setState(() {}); // completion depends on the field
    }
  }

  // ---- Pickers ---------------------------------------------------------------

  Future<T?> _pick<T>(
    String title,
    List<T> options,
    String Function(T) label,
    T? selected, {
    bool searchable = false,
  }) => showGlassPicker(
    context,
    title: title,
    options: options,
    label: label,
    selected: selected,
    searchable: searchable,
  );

  Future<void> _selectCountry() async {
    final picked = await _pick('Country', Countries.all, (c) => c.name, _country, searchable: true);
    if (picked == null || picked.name == _draft.countryName) return;
    setState(() {
      _draft
        ..countryName = picked.name
        ..city = null
        ..timezone = picked.timezones.first.id;
      _city.clear();
      if (_phone.text.length > picked.phoneDigits) {
        _phone.text = _phone.text.substring(0, picked.phoneDigits);
      }
      _errors
        ..['country'] = null
        ..['phone'] = null;
      _success = null;
    });
  }

  Future<void> _selectCity() async {
    final country = _country;
    if (country == null) {
      setState(() => _errors['city'] = 'Select your country first.');
      return;
    }
    final picked = await _pick('City', country.cities, (c) => c, _draft.city);
    if (picked == null) return;
    setState(() {
      _draft.city = picked;
      _errors['city'] = null;
      _success = null;
    });
  }

  Future<void> _selectTimezone() async {
    final country = _country!;
    final current = country.timezones.where((t) => t.id == _draft.timezone).firstOrNull;
    final picked = await _pick('Timezone', country.timezones, (t) => t.label, current);
    if (picked != null) setState(() => _draft.timezone = picked.id);
  }

  Future<void> _selectGender() async {
    final picked = await _pick('Gender', _genders, (g) => g, _draft.gender);
    if (picked != null) {
      setState(() {
        _draft.gender = picked;
        _success = null;
      });
    }
  }

  Future<void> _selectDateOfBirth() async {
    final now = DateTime.now();
    final latest = DateTime(now.year - 13, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: _draft.dateOfBirth ?? latest,
      firstDate: DateTime(1900),
      lastDate: latest,
      helpText: 'DATE OF BIRTH',
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.dark(
            primary: Colors.white,
            onPrimary: AppColors.primary,
            surface: AppColors.primary,
            onSurface: Colors.white,
          ),
          dialogTheme: const DialogThemeData(backgroundColor: AppColors.primary),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(() {
        _draft.dateOfBirth = picked;
        _errors['dob'] = null;
        _success = null;
      });
    }
  }

  Future<void> _changePhoto() async {
    final source = await _pick<ImageSource>(
      'Profile Photo',
      const [ImageSource.camera, ImageSource.gallery],
      (s) => s == ImageSource.camera ? 'Take a photo' : 'Choose from gallery',
      null,
    );
    if (source == null) return;
    try {
      final file = await ImagePicker().pickImage(source: source, maxWidth: 800, imageQuality: 85);
      if (file != null && mounted) {
        setState(() {
          _draft.photoPath = file.path;
          _success = null;
        });
      }
    } on PlatformException {
      if (mounted) {
        setState(
          () => _error =
              'Couldn\'t open the ${source == ImageSource.camera ? 'camera' : 'gallery'}. Check the app\'s permissions.',
        );
      }
    }
  }

  // ---- Save ------------------------------------------------------------------

  bool _isAtLeast13(DateTime dob) {
    final now = DateTime.now();
    return !DateTime(dob.year + 13, dob.month, dob.day).isAfter(DateTime(now.year, now.month, now.day));
  }

  bool _validate() {
    final country = _country;
    final dob = _draft.dateOfBirth;
    setState(() {
      _errors
        ..['first'] = _first.text.trim().isEmpty ? 'Enter your first name.' : null
        ..['last'] = _last.text.trim().isEmpty ? 'Enter your last name.' : null
        ..['phone'] = _isSolver
            ? null
            : country == null
            ? 'Select your country to set the phone code.'
            : !country.phoneFits(_phone.text.length)
            ? 'Enter the ${country.phoneLengthLabel} number.'
            : null
        ..['country'] = country == null ? 'Select your country.' : null
        ..['city'] = _draft.city == null
            ? (_typeCity ? 'Enter your city.' : 'Select your city.')
            : _draft.city!.length < 2
            ? 'Use at least 2 letters.'
            : null
        ..['dob'] = dob == null
            ? 'Select your date of birth.'
            : !_isAtLeast13(dob)
            ? 'You must be 13 or older.'
            : null;
    });
    return _errors.values.every((e) => e == null);
  }

  /// The profile has edits that aren't saved yet.
  bool get _profileChanged {
    final s = _saved;
    return _first.text.trim() != s.firstName.trim() ||
        _last.text.trim() != s.lastName.trim() ||
        (!_isSolver && _phone.text != s.phone) ||
        _bio.text.trim() != s.bio.trim() ||
        _draft.photoPath != s.photoPath ||
        _draft.countryName != s.countryName ||
        (_draft.city?.trim() ?? '') != (s.city?.trim() ?? '') ||
        _draft.gender != s.gender ||
        _draft.dateOfBirth != s.dateOfBirth ||
        _draft.timezone != s.timezone;
  }

  bool get _availabilityChanged => _isSolver && SolverService.instance.availabilityChanged(widget.user);

  /// Going back with unsaved changes asks whether to save or discard them.
  Future<void> _confirmLeave() async {
    FocusScope.of(context).unfocus();
    final choice = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (context) => GlassSheet(
        title: 'Unsaved Changes',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'You have changes that aren\'t saved. Save them before leaving?',
              style: AppText.body,
              textAlign: TextAlign.center,
            ),
            gap24,
            GlassFormColumn(
              children: [
                PrimaryPillButton(label: 'Save Changes', onPressed: () => Navigator.of(context).pop(true)),
                gap8,
                GlassPillButton(label: 'Discard', onPressed: () => Navigator.of(context).pop(false)),
                gap8,
                Center(
                  child: UnderlineLink(label: 'Keep Editing', onTap: () => Navigator.of(context).pop()),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice) {
      // Each part saves on its own; an error keeps the screen open on it.
      if (_profileChanged && !await _save()) {
        if (mounted && _isSolver) setState(() => _solverTab = _SolverTab.profile);
        return;
      }
      if (_availabilityChanged && !await SolverService.instance.saveAvailability(widget.user)) {
        if (mounted) setState(() => _solverTab = _SolverTab.availability);
        return;
      }
    } else if (_isSolver) {
      SolverService.instance.discardAvailability(widget.user);
    }
    if (mounted) Navigator.of(context).pop();
  }

  /// True when the profile was saved.
  Future<bool> _save() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _error = null;
      _success = null;
    });
    if (!_validate()) {
      setState(() {
        _personalOpen = true;
        _error = 'Please fix the highlighted fields.';
      });
      return false;
    }
    _draft
      ..firstName = _first.text.trim()
      ..lastName = _last.text.trim()
      ..phone = _phone.text
      ..bio = _bio.text.trim();
    setState(() => _saving = true);
    try {
      await _auth.saveProfile(_draft);
      if (mounted) {
        setState(() {
          _draft.photoPath = widget.user.profile.photoPath; // the saved photo
          _saved = _draft.copy();
          _success = 'Profile saved.';
        });
      }
      return true;
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _setPseudoName() async {
    final name = _pseudo.text.trim();
    if (!_pseudoPattern.hasMatch(name)) {
      setState(() => _pseudoError = 'Use 3–20 letters, numbers, dots, hyphens or underscores.');
      return;
    }
    FocusScope.of(context).unfocus();
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (context) => GlassSheet(
        title: 'Set Pseudo Name?',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'You\'ll appear as "$name" in the Community. This can\'t be changed later.',
              style: AppText.body,
              textAlign: TextAlign.center,
            ),
            gap24,
            GlassFormColumn(
              children: [
                PrimaryPillButton(label: 'Confirm', onPressed: () => Navigator.of(context).pop(true)),
                gap8,
                Center(
                  child: UnderlineLink(label: 'Cancel', onTap: () => Navigator.of(context).pop(false)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _settingPseudo = true;
      _pseudoError = null;
    });
    try {
      await _auth.setPseudoName(name);
      if (mounted) setState(() {});
    } on AuthException catch (e) {
      if (mounted) setState(() => _pseudoError = e.message);
    } finally {
      if (mounted) setState(() => _settingPseudo = false);
    }
  }

  // ---- Layout ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final fullName = '${_first.text.trim()} ${_last.text.trim()}'.trim();
    // Rebuilt on availability edits too, which happen in the service.
    return ListenableBuilder(
      listenable: SolverService.instance,
      builder: (context, child) => PopScope(
        canPop: !_profileChanged && !_availabilityChanged,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _confirmLeave();
        },
        child: child!,
      ),
      child: _buildScaffold(fullName),
    );
  }

  Widget _buildScaffold(String fullName) {
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
                    child: Text('PROFILE', textAlign: TextAlign.center, style: AppText.heading.copyWith(fontSize: 20)),
                  ),
                  const SizedBox(width: 44),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + MediaQuery.paddingOf(context).bottom),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_isSolver) ...[_buildSolverTabs(), gap14],
                          if (_isSolver && _solverTab != _SolverTab.profile)
                            switch (_solverTab) {
                              _SolverTab.expertise => SolverExpertiseTab(user: widget.user),
                              _SolverTab.availability => SolverAvailabilityTab(user: widget.user),
                              _ => SolverBookingLinksTab(user: widget.user),
                            }
                          else ...[
                            _buildHeader(fullName.isEmpty ? widget.user.name : fullName),
                            const SizedBox(height: 14),
                            _CompletionCard(percent: _completion),
                            if (_isSolver) ...[
                              const SizedBox(height: 14),
                              _CollapsibleCard(
                                icon: Icons.toll_outlined,
                                title: 'Current Pricing',
                                expanded: _pricingOpen,
                                onToggle: () => setState(() => _pricingOpen = !_pricingOpen),
                                child: PricingTierCard(user: widget.user, embedded: true),
                              ),
                            ],
                            const SizedBox(height: 14),
                            _CollapsibleCard(
                              icon: Icons.person_outline_rounded,
                              title: 'Personal Information',
                              expanded: _personalOpen,
                              onToggle: () => setState(() => _personalOpen = !_personalOpen),
                              child: _buildPersonalInfo(),
                            ),
                            const SizedBox(height: 14),
                            _CollapsibleCard(
                              icon: Icons.theater_comedy_outlined,
                              title: 'Anonymous Identity',
                              expanded: _anonymousOpen,
                              onToggle: () => setState(() => _anonymousOpen = !_anonymousOpen),
                              child: _buildAnonymousIdentity(),
                            ),
                            gap24,
                            InlineNotice(message: _error, tone: NoticeTone.error),
                            InlineNotice(message: _success, tone: NoticeTone.success),
                            PrimaryPillButton(label: 'Save Profile', loading: _saving, onPressed: _save),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool get _isSolver => widget.user.role == UserRole.solver;

  /// Solvers get extra tabs; only the Profile tab shows the header card.
  Widget _buildSolverTabs() {
    return Row(
      children: [
        for (final (tab, label) in const [
          (_SolverTab.profile, 'Profile'),
          (_SolverTab.expertise, 'Expertise'),
          (_SolverTab.availability, 'Availability'),
          (_SolverTab.bookingLinks, 'Booking Links'),
        ]) ...[
          if (tab != _SolverTab.profile) const SizedBox(width: 6),
          Expanded(
            child: GlassOption(
              height: 44,
              radius: 16,
              selected: _solverTab == tab,
              onTap: () => setState(() => _solverTab = tab),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(label, style: AppText.label.copyWith(fontSize: 13)),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildHeader(String name) {
    final initials = name
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .take(2)
        .map((p) => p[0].toUpperCase())
        .join();
    return GlassPanel(
      radius: 28,
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          _ProfilePhoto(path: _draft.photoPath, initials: initials, onEdit: _changePhoto),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Colors.white),
                ),
                if (_isSolver) ...[
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      const Icon(Icons.verified_outlined, size: 15, color: Colors.white),
                      const SizedBox(width: 5),
                      Text('Verified Solver', style: AppText.caption.copyWith(color: Colors.white)),
                    ],
                  ),
                ],
                gap8,
                GlassWell(
                  radius: 14,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.lock_outline_rounded, size: 15, color: AppColors.white(0.8)),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          widget.user.email,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.caption.copyWith(color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_draft.photoPath != null) ...[
                  const SizedBox(height: 10),
                  SmallPillButton(
                    label: 'Remove photo',
                    onPressed: () => setState(() {
                      _draft.photoPath = null;
                      _success = null;
                    }),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPersonalInfo() {
    final country = _country;
    final letters = [FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z ]'))];
    final multipleZones = country != null && country.timezones.length > 1;
    final zone = country?.timezones.where((t) => t.id == _draft.timezone).firstOrNull;
    final dob = _draft.dateOfBirth;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _FieldLabel(icon: Icons.badge_outlined, label: 'First Name', required: true),
        GlassTextField(
          controller: _first,
          hint: 'First name',
          textCapitalization: TextCapitalization.words,
          inputFormatters: letters,
          errorText: _errors['first'],
          onChanged: (_) => _clearError('first'),
        ),
        const _Helper('Letters only'),
        gap14,
        const _FieldLabel(icon: Icons.person_outline_rounded, label: 'Last Name', required: true),
        GlassTextField(
          controller: _last,
          hint: 'Last name',
          textCapitalization: TextCapitalization.words,
          inputFormatters: letters,
          errorText: _errors['last'],
          onChanged: (_) => _clearError('last'),
        ),
        const _Helper('Letters only'),
        gap14,
        const _FieldLabel(icon: Icons.mail_outline_rounded, label: 'Registered Email', note: 'locked'),
        GlassTextField(controller: _email, hint: 'Email', readOnly: true),
        gap14,
        const _FieldLabel(icon: Icons.smartphone_rounded, label: 'Phone Number', required: true),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 92,
              child: GlassSelectField(
                value: country?.dialCode,
                hint: '+ —',
                locked: true,
                onTap: _placeLocked ? null : _selectCountry,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: GlassTextField(
                controller: _phone,
                hint: 'Phone number',
                keyboardType: TextInputType.phone,
                readOnly: _phoneLocked,
                autofillHints: const [AutofillHints.telephoneNumberNational],
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(country?.phoneDigits ?? 15),
                ],
                errorText: _errors['phone'],
                onChanged: (_) => _clearError('phone'),
              ),
            ),
          ],
        ),
        _Helper(
          _isSolver && _phoneVerified
              ? 'Verified in KYC. To use a different number, go to Settings → Security → Change Mobile Number.'
              : _isSolver
              ? 'Your mobile number is added when you verify it in KYC (Email & Mobile step).'
              : country == null
              ? 'Select your country below to set the code.'
              : '${country.dialCode} is set from ${country.name}. Enter the ${country.phoneLengthLabel} number without the code.',
        ),
        gap14,
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _FieldLabel(
                    icon: Icons.public_rounded,
                    label: 'Country',
                    required: true,
                    note: _placeLocked ? 'locked' : null,
                  ),
                  GlassSelectField(
                    value: country?.name,
                    hint: 'Select',
                    locked: _placeLocked,
                    errorText: _errors['country'],
                    onTap: _placeLocked ? null : _selectCountry,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _FieldLabel(icon: Icons.location_on_outlined, label: 'City', required: true),
                  if (_typeCity)
                    GlassTextField(
                      controller: _city,
                      hint: 'Enter city',
                      textCapitalization: TextCapitalization.words,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r"[\p{L}\p{M} .'-]", unicode: true)),
                        LengthLimitingTextInputFormatter(100),
                      ],
                      errorText: _errors['city'],
                      onChanged: (v) {
                        _draft.city = v.trim().isEmpty ? null : v.trim();
                        _clearError('city');
                      },
                    )
                  else
                    GlassSelectField(
                      value: _draft.city,
                      hint: 'Select',
                      errorText: _errors['city'],
                      onTap: _selectCity,
                    ),
                ],
              ),
            ),
          ],
        ),
        gap14,
        const _FieldLabel(icon: Icons.payments_outlined, label: 'Currency'),
        GlassSelectField(value: country?.currencyLabel, hint: 'Set by country', locked: true),
        const _Helper('Auto-set from country'),
        gap14,
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _FieldLabel(icon: Icons.wc_rounded, label: 'Gender'),
                  GlassSelectField(value: _draft.gender, hint: 'Select', onTap: _selectGender),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _FieldLabel(icon: Icons.calendar_today_outlined, label: 'Date of Birth', required: true),
                  GlassSelectField(
                    value: dob == null
                        ? null
                        : '${dob.day.toString().padLeft(2, '0')}-${dob.month.toString().padLeft(2, '0')}-${dob.year}',
                    hint: 'DD-MM-YYYY',
                    trailingIcon: Icons.calendar_today_outlined,
                    errorText: _errors['dob'],
                    onTap: _selectDateOfBirth,
                  ),
                  const _Helper('You must be 13 or older'),
                ],
              ),
            ),
          ],
        ),
        gap14,
        _FieldLabel(
          icon: Icons.schedule_rounded,
          label: 'Timezone',
          required: true,
          note: country == null || (multipleZones && !_placeLocked) ? null : 'locked',
        ),
        GlassSelectField(
          value: zone?.label,
          hint: 'Set by country',
          locked: !multipleZones || _placeLocked,
          onTap: multipleZones && !_placeLocked ? _selectTimezone : null,
        ),
        _Helper(
          _placeLocked
              ? 'Your country and timezone are set and can\'t be changed. Contact Support if they\'re wrong.'
              : multipleZones
              ? '${country.name} has several timezones. Pick yours.'
              : 'Auto-set from country. Times across the app are shown in this timezone.',
        ),
        gap14,
        const _FieldLabel(icon: Icons.description_outlined, label: 'Bio'),
        GlassTextField(
          controller: _bio,
          hint: 'Tell others a little about yourself',
          maxLines: 8,
          textCapitalization: TextCapitalization.sentences,
          inputFormatters: [LengthLimitingTextInputFormatter(1000)],
          onChanged: (_) => _clearError('bio'),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(top: 6, right: 6),
            child: Text('${_bio.text.length}/1000', style: AppText.caption.copyWith(fontSize: 12)),
          ),
        ),
      ],
    );
  }

  Widget _buildAnonymousIdentity() {
    final pseudoName = _pseudoName;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Set a pseudo name for anonymous community interactions. This keeps your real identity private '
          'while you take part in discussions.',
          style: AppText.body,
        ),
        gap14,
        const InlineNotice(message: 'Important: once set, your pseudo name cannot be changed. Choose carefully!'),
        const Text('Your Pseudo Name', style: AppText.label),
        gap8,
        if (pseudoName != null)
          GlassWell(
            height: kControlHeight,
            padding: const EdgeInsets.fromLTRB(18, 0, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    pseudoName,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    color: AppColors.white(0.08),
                    border: Border.all(color: AppColors.white(0.35)),
                  ),
                  child: const Text(
                    'Anonymous Identity Active',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: Colors.white),
                  ),
                ),
              ],
            ),
          )
        else ...[
          GlassTextField(
            controller: _pseudo,
            hint: 'Enter a pseudo name',
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9._-]')),
              LengthLimitingTextInputFormatter(20),
            ],
            errorText: _pseudoError,
            onChanged: (_) => setState(() => _pseudoError = null),
          ),
          const _Helper('3–20 letters, numbers, dots, hyphens or underscores. Type your own or auto-generate one.'),
          gap14,
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              SmallPillButton(
                label: 'Auto-generate',
                onPressed: () async {
                  try {
                    final name = await _auth.suggestPseudoName();
                    if (mounted) {
                      setState(() {
                        _pseudo.text = name;
                        _pseudoError = null;
                      });
                    }
                  } on AuthException catch (e) {
                    if (mounted) setState(() => _pseudoError = e.message);
                  }
                },
              ),
              _settingPseudo
                  ? const Padding(
                      padding: EdgeInsets.all(8),
                      child: SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      ),
                    )
                  : SmallPillButton(label: 'Set Pseudo Name', primary: true, onPressed: _setPseudoName),
            ],
          ),
        ],
      ],
    );
  }
}

class _ProfilePhoto extends StatelessWidget {
  const _ProfilePhoto({required this.path, required this.initials, required this.onEdit});

  final String? path;
  final String initials;
  final VoidCallback onEdit;

  static const _size = 84.0;

  @override
  Widget build(BuildContext context) {
    final avatar = path == null
        ? GlassAvatar(initials: initials, size: _size)
        : CustomPaint(
            foregroundPainter: const GlassRimPainter(radius: _size / 2),
            child: ClipOval(
              child: TrueColors(
                child: Image.file(
                  File(path!),
                  width: _size,
                  height: _size,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => GlassAvatar(initials: initials, size: _size),
                ),
              ),
            ),
          );
    return Semantics(
      button: true,
      label: path == null ? 'Add profile photo' : 'Change profile photo',
      child: GestureDetector(
        onTap: onEdit,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            SizedBox.square(dimension: _size, child: avatar),
            const Positioned(
              right: -2,
              bottom: -2,
              child: SizedBox.square(
                dimension: 32,
                child: GlassWell(
                  radius: 16,
                  fillTop: 0.08,
                  fillBottom: 0.04,
                  child: Icon(Icons.photo_camera_outlined, size: 16, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CompletionCard extends StatelessWidget {
  const _CompletionCard({required this.percent});

  final int percent;

  @override
  Widget build(BuildContext context) {
    const heading = TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: Colors.white);
    return GlassPanel(
      radius: 24,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(child: Text('Profile Completion', style: heading)),
              Text('$percent%', style: heading),
            ],
          ),
          gap14,
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: percent / 100),
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeOutCubic,
              builder: (context, value, _) => LinearProgressIndicator(
                value: value,
                minHeight: 8,
                backgroundColor: AppColors.white(0.16),
                valueColor: const AlwaysStoppedAnimation(Colors.white),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: Text('Complete all details to keep your profile updated.', style: AppText.caption)),
              if (percent == 100)
                Text(
                  'Complete!',
                  style: AppText.caption.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Glass card whose body opens only when its header arrow is tapped.
class _CollapsibleCard extends StatelessWidget {
  const _CollapsibleCard({
    required this.icon,
    required this.title,
    required this.expanded,
    required this.onToggle,
    required this.child,
  });

  final IconData icon;
  final String title;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      radius: 28,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: expanded,
            label: title,
            excludeSemantics: true,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: BorderRadius.vertical(
                  top: const Radius.circular(28),
                  bottom: Radius.circular(expanded ? 0 : 28),
                ),
                onTap: onToggle,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
                  child: Row(
                    children: [
                      SizedBox.square(
                        dimension: 42,
                        child: GlassWell(radius: 21, child: Icon(icon, size: 21, color: Colors.white)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Colors.white),
                        ),
                      ),
                      AnimatedRotation(
                        turns: expanded ? 0.5 : 0,
                        duration: const Duration(milliseconds: 240),
                        curve: Curves.easeOutCubic,
                        child: const Icon(Icons.keyboard_arrow_down_rounded, size: 28, color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: expanded
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(height: 1, color: AppColors.white(0.12)),
                      Padding(padding: const EdgeInsets.fromLTRB(16, 18, 16, 20), child: child),
                    ],
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.icon, required this.label, this.required = false, this.note});

  final IconData icon;
  final String label;
  final bool required;
  final String? note;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.white(0.9)),
          const SizedBox(width: 8),
          Flexible(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: label),
                  if (required) const TextSpan(text: ' *'),
                  if (note != null) TextSpan(text: '  ($note)', style: AppText.caption.copyWith(fontSize: 11.5)),
                ],
              ),
              style: const TextStyle(fontSize: 14, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

class _Helper extends StatelessWidget {
  const _Helper(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
      child: Text(text, style: AppText.caption.copyWith(fontSize: 12)),
    );
  }
}
