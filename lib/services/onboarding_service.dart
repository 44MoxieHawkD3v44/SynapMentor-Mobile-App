import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';
import 'countries.dart';
import 'kyc_service.dart';
import 'skill_verification_service.dart';
import 'solver_service.dart';

/// The mandatory setup steps, in the order they're done. Seekers only need a
/// complete profile; solvers also set their availability, then pass KYC and
/// Skill Verification, after which seekers can find them.
enum OnboardingStep {
  profile('Complete your profile'),
  availability('Set your availability'),
  kyc('Complete KYC verification'),
  skills('Verify a skill');

  const OnboardingStep(this.label);
  final String label;
}

/// Where a user is in their mandatory setup.
class Onboarding {
  const Onboarding({required this.steps, required this.done, required this.missingProfile, required this.checking});

  /// The steps this user must complete, in order.
  final List<OnboardingStep> steps;

  /// The steps known to be complete.
  final Set<OnboardingStep> done;

  /// What the profile still needs, e.g. "Date of birth".
  final List<String> missingProfile;

  /// Steps whose status hasn't loaded yet.
  final Set<OnboardingStep> checking;

  /// The first step not done yet, or null when setup is complete.
  OnboardingStep? get next => steps.where((s) => !done.contains(s)).firstOrNull;

  /// Whether the app's other features stay locked: the next step is known
  /// to be unfinished (a step still loading doesn't lock anything, so a
  /// finished account never flashes a lock).
  bool get locked {
    final step = next;
    return step != null && !checking.contains(step);
  }

  /// How much of the profile is filled in, 0-100.
  int profilePercent(int total) => total == 0 ? 100 : ((total - missingProfile.length) * 100 / total).round();
}

abstract final class OnboardingService {
  /// What a complete profile has, by label. A solver's mobile number isn't
  /// here: it's verified (and filled in) during KYC.
  static List<(String, bool)> profileChecklist(AppUser user) {
    final p = user.profile;
    final country = Countries.byName(p.countryName);
    final solver = user.role == UserRole.solver;
    return [
      ('Profile photo', p.photoPath != null),
      ('First name', p.firstName.trim().isNotEmpty),
      ('Last name', p.lastName.trim().isNotEmpty),
      if (!solver) ('Mobile number', country != null && country.phoneFits(p.phone.length)),
      ('Country', country != null),
      ('City', p.city != null && p.city!.trim().isNotEmpty),
      ('Gender', p.gender != null),
      ('Date of birth', p.dateOfBirth != null),
      ('Timezone', p.timezone != null && p.timezone!.isNotEmpty),
      ('Bio', p.bio.trim().isNotEmpty),
      ('Pseudo name', p.pseudoName != null),
    ];
  }

  static Onboarding of(AppUser user) {
    final solver = user.role == UserRole.solver;
    final checklist = profileChecklist(user);
    final missing = [
      for (final (label, ok) in checklist)
        if (!ok) label,
    ];
    final done = <OnboardingStep>{if (missing.isEmpty) OnboardingStep.profile};
    final checking = <OnboardingStep>{};
    if (solver) {
      final solvers = SolverService.instance;
      if (!solvers.availabilityLoaded(user)) {
        checking.add(OnboardingStep.availability);
      } else if (solvers.hasAvailability(user)) {
        done.add(OnboardingStep.availability);
      }
      final kyc = KycService.instance;
      if (!kyc.isLoaded(user)) {
        checking.add(OnboardingStep.kyc);
      } else if (kyc.stateFor(user).completed) {
        done.add(OnboardingStep.kyc);
      }
      final skills = SkillVerificationService.instance;
      if (!skills.isLoaded(user)) {
        checking.add(OnboardingStep.skills);
      } else if (skills.verifiedSkills(user).isNotEmpty) {
        done.add(OnboardingStep.skills);
      }
    }
    return Onboarding(
      steps: solver ? OnboardingStep.values : const [OnboardingStep.profile],
      done: done,
      missingProfile: missing,
      checking: checking,
    );
  }

  /// Loads what the steps depend on.
  static Future<void> refresh(AppUser user) async {
    final loads = <Future<void>>[KycService.instance.refresh(user).catchError((Object _) {})];
    if (user.role == UserRole.solver) {
      loads
        ..add(SolverService.instance.loadBookingSetup(user).catchError((Object _) {}))
        ..add(SkillVerificationService.instance.load(user).catchError((Object _) {}));
    }
    await Future.wait(loads);
  }

  // A seeker is offered KYC once, right after their profile is complete.
  static String _kycOfferKey(AppUser user) => 'kyc_offered:${user.role.name}:${user.email}';

  static Future<bool> kycOffered(AppUser user) async =>
      (await SharedPreferences.getInstance()).getBool(_kycOfferKey(user)) ?? false;

  static Future<void> markKycOffered(AppUser user) async =>
      (await SharedPreferences.getInstance()).setBool(_kycOfferKey(user), true);
}
