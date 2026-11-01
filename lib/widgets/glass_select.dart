import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'auth_scaffold.dart';
import 'glass.dart';
import 'glass_controls.dart';

/// Opens a glass sheet listing [options]; resolves to the picked one, or null.
Future<T?> showGlassPicker<T>(
  BuildContext context, {
  required String title,
  required List<T> options,
  required String Function(T) label,
  T? selected,

  /// Adds a search field, for long lists such as countries.
  bool searchable = false,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (context) => searchable
        ? _SearchablePicker<T>(title: title, options: options, label: label, selected: selected)
        : GlassSheet(
            title: title,
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                for (final option in options)
                  _SheetOption(
                    label: label(option),
                    selected: option == selected,
                    onTap: () => Navigator.of(context).pop(option),
                  ),
              ],
            ),
          ),
  );
}

/// Pill that shows a value and opens a picker; [locked] shows a lock instead.
class GlassSelectField extends StatelessWidget {
  const GlassSelectField({
    super.key,
    required this.value,
    required this.hint,
    this.onTap,
    this.locked = false,
    this.errorText,
    this.trailingIcon,
  });

  final String? value;
  final String hint;
  final VoidCallback? onTap;
  final bool locked;
  final String? errorText;
  final IconData? trailingIcon;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: onTap != null,
          label: value ?? hint,
          child: GlassWell(
            height: kControlHeight,
            error: errorText != null,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          value ?? hint,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.label.copyWith(
                            color: value == null ? AppColors.white(0.62) : AppColors.white(locked ? 0.8 : 1),
                          ),
                        ),
                      ),
                      if (locked)
                        Icon(Icons.lock_outline_rounded, size: 16, color: AppColors.white(0.6))
                      else
                        Icon(trailingIcon ?? Icons.keyboard_arrow_down_rounded, size: 20, color: AppColors.white(0.8)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        FieldError(errorText),
      ],
    );
  }
}

/// Glass bottom sheet used for the pickers and the pseudo-name confirmation.
class GlassSheet extends StatelessWidget {
  const GlassSheet({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      minimum: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7, maxWidth: 480),
        child: GlassPanel(
          radius: 30,
          blur: 5,
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title.toUpperCase(), style: AppText.title, textAlign: TextAlign.center),
              gap14,
              Flexible(child: child),
            ],
          ),
        ),
      ),
    );
  }
}

/// [showGlassPicker] with a search field above the list. The sheet rises
/// with the keyboard so the matches stay in view.
class _SearchablePicker<T> extends StatefulWidget {
  const _SearchablePicker({required this.title, required this.options, required this.label, this.selected});

  final String title;
  final List<T> options;
  final String Function(T) label;
  final T? selected;

  @override
  State<_SearchablePicker<T>> createState() => _SearchablePickerState<T>();
}

class _SearchablePickerState<T> extends State<_SearchablePicker<T>> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.text.trim().toLowerCase();
    final matches = q.isEmpty
        ? widget.options
        : widget.options.where((o) => widget.label(o).toLowerCase().contains(q)).toList();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: GlassSheet(
        title: widget.title,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GlassTextField(
              controller: _query,
              hint: 'Search',
              icon: Icons.search_rounded,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: matches.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      child: Text('No matches.', style: AppText.caption, textAlign: TextAlign.center),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      itemCount: matches.length,
                      itemBuilder: (context, i) => _SheetOption(
                        label: widget.label(matches[i]),
                        selected: matches[i] == widget.selected,
                        onTap: () => Navigator.of(context).pop(matches[i]),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetOption extends StatelessWidget {
  const _SheetOption({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          highlightColor: AppColors.white(0.08),
          splashColor: AppColors.white(0.1),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: Colors.white,
                    ),
                  ),
                ),
                if (selected) const Icon(Icons.check_rounded, size: 20, color: Colors.white),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
