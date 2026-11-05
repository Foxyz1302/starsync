#ifndef RUNNER_CLIPBOARD_IMAGE_H_
#define RUNNER_CLIPBOARD_IMAGE_H_

#include <flutter_linux/flutter_linux.h>

// "starsync/clipboard" (lib/src/platform/desktop/desktop_shell.dart):
// `copyImage` puts PNG bytes on the clipboard as `image/png`, the way a
// screenshot tool does, so chat apps, browsers and image editors paste a
// picture. Returns the channel (the caller keeps it alive).
FlMethodChannel* clipboard_image_channel_new(FlBinaryMessenger* messenger);

#endif  // RUNNER_CLIPBOARD_IMAGE_H_
