import 'package:flutter/material.dart';

import '../../core/strings/app_strings.dart';

/// What the user typed in the add-word form.
typedef NewWord = ({String filipino, String english, bool still});

/// Asks for a new word and its section; [problemWith] returns the reason a
/// word cannot be added.
class AddWordDialog extends StatefulWidget {
  const AddWordDialog({super.key, required this.problemWith});

  final String? Function(String filipino, String english) problemWith;

  @override
  State<AddWordDialog> createState() => _AddWordDialogState();
}

class _AddWordDialogState extends State<AddWordDialog> {
  final _filipino = TextEditingController();
  final _english = TextEditingController();
  bool _still = false;
  String? _problem;

  @override
  void dispose() {
    _filipino.dispose();
    _english.dispose();
    super.dispose();
  }

  void _submit() {
    final problem = widget.problemWith(_filipino.text, _english.text);
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    Navigator.pop<NewWord>(context, (
      filipino: _filipino.text,
      english: _english.text,
      still: _still,
    ));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        scrollable: true,
        title: const Text(AppStrings.addWord),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('add-word-filipino'),
              controller: _filipino,
              autofocus: true,
              maxLength: 40,
              decoration: InputDecoration(
                labelText: AppStrings.addWordFilipino,
                errorText: _problem,
                errorMaxLines: 3,
              ),
            ),
            TextField(
              key: const Key('add-word-english'),
              controller: _english,
              maxLength: 40,
              decoration:
                  const InputDecoration(labelText: AppStrings.addWordEnglish),
            ),
            const Text(AppStrings.moveWordBody),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text(AppStrings.moveWordMovement),
                  selected: !_still,
                  onSelected: (_) => setState(() => _still = false),
                ),
                ChoiceChip(
                  label: const Text(AppStrings.moveWordStill),
                  selected: _still,
                  onSelected: (_) => setState(() => _still = true),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(AppStrings.addWordNote),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(AppStrings.addWordCancel),
          ),
          FilledButton(
            key: const Key('add-word-confirm'),
            onPressed: _submit,
            child: const Text(AppStrings.addWordConfirm),
          ),
        ],
      );
}
