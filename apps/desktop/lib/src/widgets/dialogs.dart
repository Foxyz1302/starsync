import 'package:flutter/material.dart';

Future<bool?> showKickConfirmDialog(
    BuildContext context, String memberName) {
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Remove $memberName?'),
      content: const Text('They can come straight back in.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Remove'),
        ),
      ],
    ),
  );
}
