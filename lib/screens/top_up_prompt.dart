import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../services/auth_service.dart';
import '../services/wallet_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';
import 'payments_screen.dart';

/// Below this many minutes, booking or extending asks the seeker to top up.
const lowBalanceMinutes = 30;

/// Checks the seeker's wallet before booking or extending a session. When it
/// holds less than [needed] minutes (at least [lowBalanceMinutes]), offers a
/// top-up and resolves to false.
Future<bool> ensureWalletBalance(BuildContext context, AppUser user, {int needed = lowBalanceMinutes}) async {
  final wallet = WalletService.instance;
  if (!wallet.isLoaded(user)) await wallet.load(user);
  // Without the server balance, the server decides.
  if (!wallet.isLoaded(user)) return true;
  final balance = wallet.balance(user);
  if (balance >= needed && balance >= lowBalanceMinutes) return true;
  if (context.mounted) await showTopUpPrompt(context, user, needed: needed);
  return false;
}

/// "Top Up Your Wallet" popup that opens the Minute Packs. Resolves once the
/// seeker is back from Payments (or dismissed it).
Future<void> showTopUpPrompt(BuildContext context, AppUser user, {int needed = lowBalanceMinutes}) async {
  final balance = WalletService.instance.balance(user);
  final topUp = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: Colors.black.withValues(alpha: 0.3),
    transitionDuration: const Duration(milliseconds: 260),
    // Scale only: fading would strip the blur from the glass.
    transitionBuilder: (context, animation, _, child) => ScaleTransition(
      scale: CurvedAnimation(parent: animation, curve: Curves.easeOutBack, reverseCurve: Curves.easeIn),
      child: child,
    ),
    pageBuilder: (context, _, _) => Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Material(
            type: MaterialType.transparency,
            child: GlassPanel(
              radius: 26,
              blur: 5,
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const GlassIconBadge(icon: Icons.account_balance_wallet_outlined, size: 56),
                  gap14,
                  Text(
                    balance <= 0 ? 'WALLET EMPTY' : 'LOW BALANCE',
                    style: AppText.title,
                    textAlign: TextAlign.center,
                  ),
                  gap8,
                  Text(
                    '${balance <= 0 ? 'Your Synap Wallet has no minutes' : 'You have $balance minutes in your Synap Wallet'}. '
                    'Add at least ${needed > lowBalanceMinutes ? needed : lowBalanceMinutes} minutes to continue.',
                    style: AppText.caption,
                    textAlign: TextAlign.center,
                  ),
                  gap24,
                  PrimaryPillButton(label: 'Top Up Your Wallet', onPressed: () => Navigator.of(context).pop(true)),
                  gap8,
                  GlassPillButton(label: 'Not Now', onPressed: () => Navigator.of(context).pop(false)),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  if (topUp == true && context.mounted) await PaymentsScreen.open(context, user, tab: PaymentsTab.packs);
}
