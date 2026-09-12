import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'window_buttons.dart';

class WindowChromeBar extends StatelessWidget {
  final String title;
  final Widget? leading;
  const WindowChromeBar({super.key, required this.title, this.leading});

  @override
  Widget build(BuildContext context) {
    return DragToMoveArea(
      child: Container(
        height: 36,
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Row(
          children: [
            if (leading != null) leading!,
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Spacer(),
            const WindowButtons(),
          ],
        ),
      ),
    );
  }
}
