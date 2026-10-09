#ifndef RUNNER_HOT_RESTART_GUARD_H_
#define RUNNER_HOT_RESTART_GUARD_H_

#include <flutter_linux/flutter_linux.h>

// Debug builds: before a hot restart tears the Dart isolate down, unhooks
// the libmpv wakeup callbacks that media_kit's players point at that
// isolate's NativeCallables. Without this, the next mpv event on a leftover
// player calls into freed code and the process dies (SIGSEGV on mpv's
// "core" thread). No-op in profile/release.
void hot_restart_guard_attach(FlView* view);

#endif  // RUNNER_HOT_RESTART_GUARD_H_
