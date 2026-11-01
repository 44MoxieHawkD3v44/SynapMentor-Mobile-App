import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api_client.dart';
import '../core/theme.dart';
import '../services/password_policy.dart';
import 'glass.dart';
import 'true_colors.dart';

const double kControlHeight = 54;

/// Centers form controls at roughly three-quarters of the panel width.
class GlassFormColumn extends StatelessWidget {
  const GlassFormColumn({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: FractionallySizedBox(
        widthFactor: 0.84,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}

/// The only fully opaque element: a solid white pill lifted by a tight shadow.
class PrimaryPillButton extends StatelessWidget {
  const PrimaryPillButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
    this.height = kControlHeight,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool loading;
  final double height;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;
    return Semantics(
      button: true,
      label: label,
      enabled: enabled,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 160),
        opacity: onPressed == null && !loading ? 0.55 : 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(999),
            boxShadow: [
              BoxShadow(color: AppColors.primary.withValues(alpha: 0.2), blurRadius: 10, offset: const Offset(0, 4)),
            ],
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: enabled ? onPressed : null,
              child: SizedBox(
                height: height,
                child: Center(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 160),
                    child: loading
                        ? const SizedBox.square(
                            key: ValueKey('loading'),
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2.2, color: AppColors.primary),
                          )
                        : Text(label, key: ValueKey(label), style: AppText.button),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Secondary action: a translucent glass pill with white text.
class GlassPillButton extends StatelessWidget {
  const GlassPillButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.loading = false,
    this.height = kControlHeight,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool loading;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: GlassWell(
        height: height,
        fillTop: 0.04,
        fillBottom: 0.02,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: loading ? null : onPressed,
            child: Center(
              child: loading
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (icon != null) ...[Icon(icon, size: 20, color: Colors.white), const SizedBox(width: 10)],
                        Text(label, style: AppText.button.copyWith(color: Colors.white)),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class GlassIconButton extends StatelessWidget {
  const GlassIconButton({super.key, required this.icon, required this.onPressed, this.tooltip});

  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? '',
      child: SizedBox.square(
        dimension: 44,
        child: GlassPanel(
          radius: 22,
          padding: EdgeInsets.zero,
          floating: false,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onPressed,
              child: Icon(icon, color: Colors.white, size: 22),
            ),
          ),
        ),
      ),
    );
  }
}

class UnderlineLink extends StatelessWidget {
  const UnderlineLink({super.key, required this.label, required this.onTap, this.bold = false});

  final String label;
  final VoidCallback? onTap;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      link: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
              color: onTap == null ? AppColors.white(0.5) : Colors.white,
              decoration: TextDecoration.underline,
              decorationColor: onTap == null ? AppColors.white(0.5) : Colors.white,
              decorationThickness: 1,
            ),
          ),
        ),
      ),
    );
  }
}

class GlassTextField extends StatefulWidget {
  const GlassTextField({
    super.key,
    required this.controller,
    required this.hint,
    this.icon,
    this.obscure = false,
    this.keyboardType,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.none,
    this.autofillHints,
    this.inputFormatters,
    this.onChanged,
    this.onSubmitted,
    this.errorText,
    this.readOnly = false,
    this.maxLines = 1,
    this.focusNode,
    this.height = kControlHeight,
  });

  final TextEditingController controller;
  final String hint;
  final IconData? icon;
  final bool obscure;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final TextCapitalization textCapitalization;
  final Iterable<String>? autofillHints;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final String? errorText;
  final bool readOnly;
  final int maxLines;
  final FocusNode? focusNode;

  /// Height of a single-line field.
  final double height;

  @override
  State<GlassTextField> createState() => _GlassTextFieldState();
}

class _GlassTextFieldState extends State<GlassTextField> {
  late bool _obscured = widget.obscure;
  FocusNode? _ownFocus;
  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _ownFocus?.dispose();
    super.dispose();
  }

  void _onFocus() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final multiline = widget.maxLines > 1;
    final iconColor = AppColors.white(widget.readOnly ? 0.45 : 0.75);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        GlassWell(
          radius: multiline ? 24 : null,
          height: multiline ? null : widget.height,
          active: _focus.hasFocus,
          error: widget.errorText != null,
          padding: EdgeInsets.fromLTRB(18, multiline ? 14 : 0, widget.obscure ? 6 : 18, multiline ? 14 : 0),
          child: Row(
            crossAxisAlignment: multiline ? CrossAxisAlignment.start : CrossAxisAlignment.center,
            children: [
              if (widget.icon != null) ...[Icon(widget.icon, size: 19, color: iconColor), const SizedBox(width: 10)],
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  focusNode: _focus,
                  obscureText: _obscured,
                  readOnly: widget.readOnly,
                  keyboardType: multiline ? TextInputType.multiline : widget.keyboardType,
                  textInputAction: widget.textInputAction,
                  textCapitalization: widget.textCapitalization,
                  autofillHints: widget.readOnly ? null : widget.autofillHints,
                  inputFormatters: widget.inputFormatters,
                  onChanged: widget.onChanged,
                  onSubmitted: widget.onSubmitted,
                  minLines: multiline ? 3 : 1,
                  maxLines: widget.maxLines,
                  style: AppText.label.copyWith(color: widget.readOnly ? AppColors.white(0.7) : Colors.white),
                  decoration: InputDecoration(
                    isCollapsed: true,
                    border: InputBorder.none,
                    hintText: widget.hint,
                    hintStyle: AppText.label.copyWith(color: AppColors.white(0.62)),
                  ),
                ),
              ),
              if (widget.obscure)
                IconButton(
                  onPressed: () => setState(() => _obscured = !_obscured),
                  tooltip: _obscured ? 'Show password' : 'Hide password',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    _obscured ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                    size: 19,
                    color: AppColors.white(0.75),
                  ),
                ),
            ],
          ),
        ),
        FieldError(widget.errorText),
      ],
    );
  }
}

class FieldError extends StatelessWidget {
  const FieldError(this.message, {super.key});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: message == null
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.fromLTRB(18, 6, 12, 0),
              child: Text(message!, style: AppText.caption.copyWith(color: AppColors.error)),
            ),
    );
  }
}

/// A [FieldError] for things that just happened, such as a message that
/// couldn't be sent: it shows for a few seconds, then goes away and calls
/// [onHidden] so the same error can show again next time.
class FlashError extends StatefulWidget {
  const FlashError(this.message, {super.key, this.onHidden});

  final String? message;
  final VoidCallback? onHidden;

  /// How long the error stays on screen.
  static const showFor = Duration(seconds: 4);

  @override
  State<FlashError> createState() => _FlashErrorState();
}

class _FlashErrorState extends State<FlashError> {
  Timer? _timer;
  bool _hidden = false;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(FlashError old) {
    super.didUpdateWidget(old);
    if (old.message != widget.message) _schedule();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _schedule() {
    _timer?.cancel();
    _hidden = false;
    if (widget.message == null) return;
    _timer = Timer(FlashError.showFor, () {
      if (!mounted) return;
      setState(() => _hidden = true);
      widget.onHidden?.call();
    });
  }

  @override
  Widget build(BuildContext context) => FieldError(_hidden ? null : widget.message);
}

/// Six glass cells backed by one invisible field, so paste and SMS/email
/// autofill work as a single value.
class OtpInput extends StatefulWidget {
  const OtpInput({super.key, required this.controller, this.onCompleted, this.length = 6});

  final TextEditingController controller;
  final ValueChanged<String>? onCompleted;
  final int length;

  @override
  State<OtpInput> createState() => _OtpInputState();
}

class _OtpInputState extends State<OtpInput> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refresh);
    _focus.addListener(_refresh);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    _focus.dispose();
    super.dispose();
  }

  void _refresh() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final code = widget.controller.text;
    return SizedBox(
      height: kControlHeight,
      child: Stack(
        children: [
          Row(
            children: [
              for (var i = 0; i < widget.length; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3.5),
                    child: GlassWell(
                      radius: 16,
                      height: kControlHeight,
                      active:
                          _focus.hasFocus &&
                          (i == code.length || (i == widget.length - 1 && code.length == widget.length)),
                      child: Center(
                        child: Text(
                          i < code.length ? code[i] : '',
                          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Colors.white),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          Positioned.fill(
            child: Opacity(
              opacity: 0,
              child: TextField(
                controller: widget.controller,
                focusNode: _focus,
                keyboardType: TextInputType.number,
                autofillHints: const [AutofillHints.oneTimeCode],
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(widget.length),
                ],
                showCursor: false,
                enableInteractiveSelection: false,
                decoration: const InputDecoration(border: InputBorder.none, counterText: ''),
                onChanged: (value) {
                  if (value.length == widget.length) widget.onCompleted?.call(value);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum NoticeTone { error, success, info }

/// Inline status message inside a panel. Pass null to collapse it.
class InlineNotice extends StatefulWidget {
  const InlineNotice({super.key, required this.message, this.tone = NoticeTone.info, this.persistent = false});

  final String? message;
  final NoticeTone tone;

  /// Keeps a success or error notice up, for one that describes a state (a
  /// rejection reason, a warning) rather than the result of an action.
  final bool persistent;

  /// How long the result of an action stays up.
  static const showFor = Duration(seconds: 3);

  @override
  State<InlineNotice> createState() => _InlineNoticeState();
}

/// Success and error notices hide on their own after [InlineNotice.showFor];
/// information notices stay.
class _InlineNoticeState extends State<InlineNotice> {
  Timer? _timer;
  bool _hidden = false;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(InlineNotice old) {
    super.didUpdateWidget(old);
    if (old.message != widget.message || old.tone != widget.tone) _schedule();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _schedule() {
    _timer?.cancel();
    _hidden = false;
    if (widget.message == null || widget.tone == NoticeTone.info || widget.persistent) return;
    _timer = Timer(InlineNotice.showFor, () {
      if (mounted) setState(() => _hidden = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final message = _hidden ? null : widget.message;
    final (tint, icon) = switch (widget.tone) {
      NoticeTone.error => (AppColors.noticeError, Icons.error_outline_rounded),
      NoticeTone.success => (AppColors.noticeSuccess, Icons.check_circle_outline_rounded),
      NoticeTone.info => (Colors.white, Icons.info_outline_rounded),
    };
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: message == null
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: tint.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: tint.withValues(alpha: 0.38)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, size: 18, color: Colors.white),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(message, style: AppText.caption.copyWith(color: Colors.white, fontSize: 13)),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

/// Selectable glass tile, used for role and reset-method choices.
class GlassChoiceTile extends StatelessWidget {
  const GlassChoiceTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.error = false,
    this.compact = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  final bool error;

  /// Tighter padding for screens that must fit without scrolling.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      child: GlassWell(
        radius: 22,
        active: selected,
        error: error && !selected,
        fillTop: selected ? 0.08 : 0,
        fillBottom: selected ? 0.05 : 0,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: onTap,
            child: Padding(
              padding: compact ? const EdgeInsets.fromLTRB(12, 10, 10, 10) : const EdgeInsets.fromLTRB(14, 14, 10, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(icon, size: compact ? 21 : 24, color: Colors.white),
                      const Spacer(),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 160),
                        child: Icon(
                          selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                          key: ValueKey(selected),
                          size: 18,
                          color: AppColors.white(selected ? 1 : 0.45),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: compact ? 6 : 10),
                  Text(
                    title,
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                  const SizedBox(height: 2),
                  Text(subtitle, style: AppText.caption.copyWith(fontSize: 11.5)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class GlassChip extends StatelessWidget {
  const GlassChip({super.key, required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GlassWell(
      active: selected,
      fillTop: selected ? 0.08 : 0,
      fillBottom: selected ? 0.05 : 0,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A checkbox with its statement beside it, e.g. a recording consent. The
/// text toggles it too.
class GlassConsentRow extends StatelessWidget {
  const GlassConsentRow({super.key, required this.value, required this.onChanged, required this.text});

  final bool value;
  final ValueChanged<bool> onChanged;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        GlassCheckbox(value: value, onChanged: onChanged),
        const SizedBox(width: 12),
        Expanded(
          child: GestureDetector(
            onTap: () => onChanged(!value),
            child: Text(text, style: AppText.label.copyWith(fontSize: 13.5)),
          ),
        ),
      ],
    );
  }
}

class GlassCheckbox extends StatelessWidget {
  const GlassCheckbox({super.key, required this.value, required this.onChanged, this.error = false});

  final bool value;
  final ValueChanged<bool> onChanged;
  final bool error;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      checked: value,
      child: GestureDetector(
        onTap: () => onChanged(!value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: value ? Colors.white : AppColors.white(0.16),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: error && !value ? AppColors.error : AppColors.white(value ? 1 : 0.5)),
          ),
          child: value ? const Icon(Icons.check_rounded, size: 16, color: AppColors.primary) : null,
        ),
      ),
    );
  }
}

/// Live password-policy checklist shown under a new-password field.
class PasswordChecklist extends StatelessWidget {
  const PasswordChecklist({super.key, required this.password, required this.visible});

  final String password;
  final bool visible;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: !visible
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 8, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final rule in PasswordPolicy.rules)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          Icon(
                            rule.isMet(password) ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                            size: 15,
                            color: AppColors.white(rule.isMet(password) ? 1 : 0.45),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            rule.label,
                            style: AppText.caption.copyWith(color: AppColors.white(rule.isMet(password) ? 0.95 : 0.65)),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

/// Shown while waiting for the user to open an emailed magic link.
class MagicLinkWaiting extends StatelessWidget {
  const MagicLinkWaiting({super.key, required this.email, required this.message, required this.resend});

  final String email;
  final String message;
  final Widget resend;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const GlassIconBadge(icon: Icons.mark_email_unread_outlined),
        const SizedBox(height: 16),
        const Text('CHECK YOUR INBOX', style: AppText.title, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text.rich(
          TextSpan(
            children: [
              const TextSpan(text: 'We sent a secure link to '),
              TextSpan(
                text: email,
                style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white),
              ),
              TextSpan(text: '. $message'),
            ],
          ),
          style: AppText.body,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 1.8, color: Colors.white),
            ),
            const SizedBox(width: 10),
            Text('Waiting for verification…', style: AppText.caption),
          ],
        ),
        const SizedBox(height: 14),
        resend,
      ],
    );
  }
}

class GlassIconBadge extends StatelessWidget {
  const GlassIconBadge({super.key, required this.icon, this.size = 64});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: GlassWell(
        radius: size / 2,
        fillTop: 0.06,
        fillBottom: 0.03,
        child: Icon(icon, color: Colors.white, size: size * 0.44),
      ),
    );
  }
}

/// Initials in a glass circle.
class GlassAvatar extends StatelessWidget {
  const GlassAvatar({
    super.key,
    required this.initials,
    this.size = 48,
    this.photoPath,
    this.photoUrl,
    this.onPhotoError,
  });

  final String initials;
  final double size;

  /// A profile photo on the device; shown instead of the initials.
  final String? photoPath;

  /// A photo from the web (e.g. a community logo); shown instead of the
  /// initials, which stay while it loads or if it fails.
  final String? photoUrl;

  /// Called when [photoUrl] fails to load, e.g. to fetch a fresh link.
  final VoidCallback? onPhotoError;

  @override
  Widget build(BuildContext context) {
    final text = Center(
      child: Text(
        initials,
        style: TextStyle(fontSize: size * 0.34, fontWeight: FontWeight.w700, color: Colors.white),
      ),
    );
    final photo = photoPath;
    final url = photoUrl;
    return SizedBox.square(
      dimension: size,
      child: GlassWell(
        radius: size / 2,
        fillTop: 0.06,
        fillBottom: 0.03,
        child: photo == null && url != null && ApiClient.isApiLink(url)
            ? ClipOval(
                child: TrueColors(
                  child: _ApiPhoto(url: url, size: size, fallback: text),
                ),
              )
            : photo == null && url != null
            ? ClipOval(
                child: TrueColors(
                  child: Image.network(
                    url,
                    width: size,
                    height: size,
                    fit: BoxFit.cover,
                    loadingBuilder: (_, child, progress) => progress == null ? child : text,
                    errorBuilder: (_, _, _) {
                      final retry = onPhotoError;
                      if (retry != null) WidgetsBinding.instance.addPostFrameCallback((_) => retry());
                      return text;
                    },
                  ),
                ),
              )
            : photo == null
            ? text
            : ClipOval(
                child: TrueColors(
                  child: Image.file(
                    File(photo),
                    width: size,
                    height: size,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => text,
                  ),
                ),
              ),
      ),
    );
  }
}

/// A picture on the API server, loaded with the session (profile pictures
/// are only for signed-in users). Downloads are kept for the app's run.
class _ApiPhoto extends StatelessWidget {
  const _ApiPhoto({required this.url, required this.size, required this.fallback});

  final String url;
  final double size;
  final Widget fallback;

  static final _cache = <String, Future<Uint8List>>{};

  @override
  Widget build(BuildContext context) {
    final bytes = _cache[url] ??= ApiClient.instance.download(url)
      ..catchError((Object _) {
        // A failed download is tried again next time.
        _cache.remove(url);
        return Uint8List(0);
      });
    return FutureBuilder<Uint8List>(
      future: bytes,
      builder: (context, snap) {
        final data = snap.data;
        if (data == null || data.isEmpty) return fallback;
        return Image.memory(data, width: size, height: size, fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback);
      },
    );
  }
}

/// Compact pill for in-card actions: glass by default, opaque white when
/// [primary].
class SmallPillButton extends StatelessWidget {
  const SmallPillButton({super.key, required this.label, required this.onPressed, this.primary = false});

  final String label;
  final VoidCallback onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final content = Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(
            label,
            style: AppText.button.copyWith(fontSize: 13, color: primary ? AppColors.primary : Colors.white),
          ),
        ),
      ),
    );
    if (!primary) {
      return Semantics(button: true, child: GlassWell(fillTop: 0.04, fillBottom: 0.02, child: content));
    }
    return Semantics(
      button: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(999),
          boxShadow: [
            BoxShadow(color: AppColors.primary.withValues(alpha: 0.2), blurRadius: 8, offset: const Offset(0, 3)),
          ],
        ),
        child: content,
      ),
    );
  }
}
