#include "hot_restart_guard.h"

#ifdef NDEBUG

void hot_restart_guard_attach(FlView* view) {}

#else

#include <dlfcn.h>
#include <stdint.h>
#include <unistd.h>

namespace {

// Mirrors media_kit's NativeReferenceHolder (debug only): a calloc'd buffer
// of kReferenceBufferSize intptr slots holding live mpv_handle addresses,
// its address written in decimal to <tmp>/<kFilePrefix><pid>.
constexpr int kReferenceBufferSize = 512;
constexpr char kFilePrefix[] = "com.alexmercerind.media_kit.NativeReferenceHolder.";

using SetWakeupCallback = void (*)(void* ctx, void (*cb)(void*), void* d);

SetWakeupCallback find_set_wakeup_callback() {
  static const char* const kNames[] = {"libmpv.so.2", "libmpv.so", "libmpv.so.1"};
  for (const char* name : kNames) {
    void* lib = dlopen(name, RTLD_NOW | RTLD_NOLOAD);
    if (lib == nullptr) continue;
    auto fn = reinterpret_cast<SetWakeupCallback>(
        dlsym(lib, "mpv_set_wakeup_callback"));
    dlclose(lib);  // Drops only the reference NOLOAD added.
    if (fn != nullptr) return fn;
  }
  return nullptr;
}

// Runs on the engine's UI thread before the old isolate shuts down, so the
// buffer is not being written concurrently. Clearing the callback takes the
// same lock mpv calls it under: once this returns, mpv never calls it again.
// The handles stay in the buffer: media_kit's startup in the new isolate
// still sends them "quit".
void on_pre_engine_restart(FlEngine* engine, gpointer user_data) {
  g_autofree gchar* name = g_strdup_printf("%s%d", kFilePrefix, getpid());
  g_autofree gchar* path = g_build_filename(g_get_tmp_dir(), name, nullptr);
  g_autofree gchar* contents = nullptr;
  if (!g_file_get_contents(path, &contents, nullptr, nullptr)) return;
  const guint64 address = g_ascii_strtoull(contents, nullptr, 10);
  if (address == 0) return;
  const SetWakeupCallback set_wakeup = find_set_wakeup_callback();
  if (set_wakeup == nullptr) return;
  const auto* slots = reinterpret_cast<const intptr_t*>(address);
  int cleared = 0;
  for (int i = 0; i < kReferenceBufferSize; i++) {
    if (slots[i] == 0) continue;
    set_wakeup(reinterpret_cast<void*>(slots[i]), nullptr, nullptr);
    cleared++;
  }
  if (cleared > 0) {
    g_message("hot restart: unhooked %d mpv wakeup callback(s)", cleared);
  }
}

}  // namespace

void hot_restart_guard_attach(FlView* view) {
  g_signal_connect(fl_view_get_engine(view), "on-pre-engine-restart",
                   G_CALLBACK(on_pre_engine_restart), nullptr);
}

#endif
