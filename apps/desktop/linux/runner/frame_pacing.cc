// Frame pacing at the monitor's refresh rate (PROTOTYPE).
//
// Two clocks hold a Flutter Linux app at 60 Hz whatever the monitor runs at:
// - the engine: the GTK embedder sets no FlutterProjectArgs.vsync_callback,
//   so the engine uses VsyncWaiterFallback, a fixed 1/60 s timer
//   (engine/src/flutter/shell/common/vsync_waiter_fallback.cc);
// - GTK 3: a window drawn with GL (the Flutter view) never gets frame or
//   presentation feedback from the Wayland compositor (eglSwapBuffers with
//   swap interval 0), so its frame clock free-runs on the default 16667 us
//   refresh interval. X11 behaves the same.
// On a 75 Hz monitor that shows 4 new frames per 5 refreshes: one picture
// stays up twice as long every 66 ms, which reads as a constant fine judder.
//
// This shim fixes both from the runner. It gives the engine a vsync
// callback (the proc table in FlEngine, private) and lets GTK's frame clock
// run at the monitor's interval (GdkFrameTimings.refresh_interval,
// private). On Wayland the vsyncs follow the compositor:
// - "grid" (default): frames start once per refresh at the moment the
//   compositor sends frame callbacks (its own cycle), on the vblank grid
//   from presentation feedback (wp_presentation), and a frame does not wait
//   for the one before it to reach the screen: up to three paints may wait
//   for feedback. A frame then has two refreshes, not one, to get through
//   build, raster and GTK's paint; at 2560x1080 that chain takes 13-15 ms
//   on a heavy page, more than one 75 Hz refresh. Until the first feedback
//   it runs as "callback".
// - "callback": each paint asks the compositor when it used it
//   (wl_surface.frame) and that moment is the next vsync. One frame at a
//   time: a frame that misses the compositor's cycle costs a refresh, and
//   when every frame does, the app runs at half rate.
// Both private layouts are checked at run time; on a mismatch it logs and
// leaves the stock 60 Hz.
//
// Pointer motion is handed to Flutter at most once per 8 ms between frames
// and, while a frame is due, as the newest motion right before the frame
// starts (motion compression in GDK is off, so it is current). A 1000 Hz
// mouse otherwise posts 1000 engine tasks a second, and this Flutter's
// FlTaskRunner re-arms its 1 ms timeout on every post (fixed upstream by
// flutter/flutter#194525, after 3.50), so frames start late and drag
// scrolling drops to every other refresh.
//
// STARSYNC_FRAME_PACING=off: stock; =timer: GTK's clock only, no Wayland
// feedback; =callback: see above. STARSYNC_POINTER=direct: every
// motion goes to Flutter as it comes (stock). STARSYNC_FRAME_PACING_LOG=1:
// a line of frame statistics every 5 s.

#include "frame_pacing.h"

#include <atomic>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <vector>

#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#include <wayland-client.h>

#include "wayland/presentation-time-client.h"
#endif

#include "embedder.h"

namespace {

// _FlEngine (shell/platform/linux/fl_engine.cc) up to embedder_api, as of
// Flutter 3.48 / 3.50.
struct FlEngineHead {
  GObject parent_instance;
  GThread* thread;
  FlDartProject* project;
  gpointer display_monitor;
  FlutterRendererType renderer_type;
  gpointer opengl_manager;
  FlBinaryMessenger* binary_messenger;
  gpointer settings_handler;
  gpointer platform_handler;
  gpointer accessibility_handler;
  gpointer keyboard_manager;
  gpointer text_input_handler;
  gpointer keyboard_handler;
  gpointer mouse_cursor_handler;
  FlTextureRegistrar* texture_registrar;
  gpointer task_runner;
  FlutterEngineAOTData aot_data;
  FLUTTER_API_SYMBOL(FlutterEngine) engine;
  FlutterEngineProcTable embedder_api;
};

// GdkFrameTimings.refresh_interval in GTK >= 3.24.24 (56) and before (48).
constexpr int kRefreshOffsets[] = {56, 48};

// Motion between frames reaches Flutter at most this often.
constexpr gint64 kMotionGapUs = 8000;

// Grid: a frame asked for this soon after a vblank still starts on it
// (fraction of the refresh); later, it waits for the next vblank.
constexpr double kGridLateStart = 0.25;

// Grid: paints that may wait for presentation feedback at once. Feedback
// comes at the vblank, after the compositor has already taken the paint
// in, so one more than the frames in flight.
constexpr int kGridDepth = 3;

enum class Source { kTimer, kCallback, kGrid };

struct Span {
  gint64 sum_us = 0;
  gint64 max_us = 0;
  int n = 0;
  void add(gint64 us) {
    sum_us += us;
    max_us = MAX(max_us, us);
    n++;
  }
  double avg_ms() const { return n > 0 ? sum_us / 1000.0 / n : 0.0; }
  double max_ms() const { return max_us / 1000.0; }
};

struct Stats {
  int vsyncs = 0;
  int paints = 0;
  int presented = 0;
  int discarded = 0;
  int zero_copy = 0;
  // Running frames (gap under 4 refreshes): one, two, three or more
  // refreshes after the previous one.
  int gap[3] = {0, 0, 0};
  // The same for what was shown: new pictures one, two, three or more
  // refreshes after the previous one.
  int shown_gap[3] = {0, 0, 0};
  std::vector<gint64> latencies;  // frame start to shown
  Span to_present;  // frame start to the raster thread handing it over
  Span to_draw;     // handed over to GTK drawing it (main loop wait)
  Span paint;       // GTK drawing to the end of its paint
  Span view;        // of which: the Flutter view's draw (GL blit)
  gint64 since_us = 0;
};

struct Pacing {
  FlutterEngineProcTable api;  // the engine's own functions
  FLUTTER_API_SYMBOL(FlutterEngine) engine = nullptr;
  std::atomic<intptr_t> baton{0};
  GtkWidget* toplevel = nullptr;
  GdkFrameClock* clock = nullptr;
  gint64 interval_us = 16667;
  guint fallback_id = 0;
  int refresh_offset = -2;  // -2 not probed yet, -1 unusable
  Source source = Source::kTimer;
  bool want_grid = false;
  // Callback: a frame was handed out and its paint (which asks for the
  // next frame callback) has not happened yet; the next vsync waits for it.
  bool in_flight = false;
  gint64 frame_start_us = 0;  // of the last frame handed out
  bool log = false;
  Stats stats;
  gint64 draw_us = 0;  // the paint under way began drawing
  gint64 view_us = 0;  // its Flutter view began drawing
  GtkWidget* view = nullptr;
  // Pointer motion at vsync.
  bool coalesce = false;
  GdkEvent* pending_motion = nullptr;
  guint motion_timer = 0;
  gint64 last_motion_us = 0;
#ifdef GDK_WINDOWING_WAYLAND
  struct wl_surface* surface = nullptr;
  struct wl_callback* frame_callback = nullptr;
  struct wp_presentation* presentation = nullptr;
  bool monotonic = false;    // the presentation clock is CLOCK_MONOTONIC
  gint64 vblank_us = 0;      // the newest presented vblank
  gint64 refresh_us = 0;     // the output's refresh, as presented
  gint64 started_vblank_us = 0;  // the vblank the last frame started on
  int awaiting = 0;          // paints waiting for feedback
  GSource* grid_timer = nullptr;
  // Grid: where in the refresh the compositor sends frame callbacks (its
  // own cycle), from the vblank before; frames start there.
  gint64 phase_us = 0;
  bool phase_known = false;
  gint64 last_shown_us = 0;
#endif
};

Pacing* pacing = nullptr;

// Statistics: when the raster thread last handed a frame over.
std::atomic<gint64> presented_us{0};

void log_line(const char* text) {
  fprintf(stderr, "frame pacing: %s\n", text);
}

// The next vsync comes from a compositor frame callback.
bool frame_callback_pending() {
#ifdef GDK_WINDOWING_WAYLAND
  if (pacing->source != Source::kCallback) return false;
  return pacing->frame_callback != nullptr || pacing->in_flight;
#else
  return false;
#endif
}

// The refresh interval of the monitor the window is on.
void update_interval() {
  if (pacing->toplevel == nullptr) return;
  GdkWindow* window = gtk_widget_get_window(pacing->toplevel);
  if (window == nullptr) return;
  GdkMonitor* monitor = gdk_display_get_monitor_at_window(
      gdk_window_get_display(window), window);
  int mhz = monitor != nullptr ? gdk_monitor_get_refresh_rate(monitor) : 0;
  if (mhz > 1000) {
    pacing->interval_us = (G_GINT64_CONSTANT(1000000000) + mhz / 2) / mhz;
  }
}

// Tells GTK's frame clock the interval for this frame, unless the
// compositor already did. Paced by the compositor, GTK only must not hold
// a paint back (half an interval); otherwise it paces at the monitor's.
void pace_gtk(GdkFrameClock* clock) {
  if (pacing->refresh_offset == -1) return;
  GdkFrameTimings* t = gdk_frame_clock_get_current_timings(clock);
  if (t == nullptr) return;
  gint64 us = pacing->source != Source::kTimer ? pacing->interval_us / 2
                                               : pacing->interval_us;
  gint64 have = gdk_frame_timings_get_refresh_interval(t);
  if (have == us) return;
  if (have != 0 && pacing->refresh_offset < 0) return;  // the compositor's
  for (int offset : kRefreshOffsets) {
    if (pacing->refresh_offset >= 0 && offset != pacing->refresh_offset) {
      continue;
    }
    gint64* field =
        reinterpret_cast<gint64*>(reinterpret_cast<char*>(t) + offset);
    gint64 old = *field;
    *field = us;
    if (gdk_frame_timings_get_refresh_interval(t) == us) {
      pacing->refresh_offset = offset;
      return;
    }
    *field = old;
  }
  pacing->refresh_offset = -1;
  log_line("GdkFrameTimings layout unknown: GTK stays at its default interval");
}

// ---- Pointer motion at vsync ------------------------------------------

void deliver_pending() {
  if (pacing->motion_timer != 0) {
    g_source_remove(pacing->motion_timer);
    pacing->motion_timer = 0;
  }
  if (pacing->pending_motion == nullptr) return;
  GdkEvent* event = pacing->pending_motion;
  pacing->pending_motion = nullptr;
  pacing->last_motion_us = g_get_monotonic_time();
  gtk_main_do_event(event);
  gdk_event_free(event);
}

gboolean motion_timer_cb(gpointer) {
  pacing->motion_timer = 0;
  deliver_pending();
  return G_SOURCE_REMOVE;
}

void event_handler(GdkEvent* event, gpointer) {
  if (event->type != GDK_MOTION_NOTIFY) {
    deliver_pending();  // keep the order
    gtk_main_do_event(event);
    return;
  }
  GdkEvent* pending = pacing->pending_motion;
  if (pending != nullptr && (pending->motion.window != event->motion.window ||
                             pending->motion.device != event->motion.device)) {
    deliver_pending();
  }
  gint64 now = g_get_monotonic_time();
  if (pacing->pending_motion == nullptr && pacing->baton.load() == 0 &&
      now - pacing->last_motion_us >= kMotionGapUs) {
    pacing->last_motion_us = now;
    gtk_main_do_event(event);
    return;
  }
  if (pacing->pending_motion != nullptr) {
    gdk_event_free(pacing->pending_motion);
  }
  pacing->pending_motion = gdk_event_copy(event);
  if (pacing->motion_timer == 0) {
    gint64 due = MAX(pacing->last_motion_us + kMotionGapUs - now, 1000);
    pacing->motion_timer = g_timeout_add(
        static_cast<guint>((due + 999) / 1000), motion_timer_cb, nullptr);
  }
}

// GDK holds motion back for its frame clock and merges what piled up;
// pacing does that now, with the newest motion.
void no_compression(GdkWindow* window) {
  if (window == nullptr) return;
  gdk_window_set_event_compression(window, FALSE);
  for (GList* l = gdk_window_peek_children(window); l != nullptr;
       l = l->next) {
    no_compression(GDK_WINDOW(l->data));
  }
}

// ---- Handing frames out -------------------------------------------------

void log_stats(gint64 now) {
  Stats& s = pacing->stats;
  if (s.since_us == 0) {
    s.since_us = now;
    return;
  }
  if (now - s.since_us < 5000000) return;
  double secs = (now - s.since_us) / 1e6;
  // Late: shown a refresh or more after the quickest frame of the window.
  gint64 best = G_MAXINT64, sum = 0;
  for (gint64 l : s.latencies) best = MIN(best, l);
  int late = 0;
  for (gint64 l : s.latencies) {
    sum += l;
    if (l > best + pacing->interval_us / 2) late++;
  }
  size_t shown = s.latencies.size();
  char line[512];
  snprintf(line, sizeof(line),
           "%.1f s: %d vsyncs, running frames 1/2/3+ refreshes apart "
           "%d/%d/%d, shown %d/%d/%d; %d paints, %d shown (%zu timed: best %.1f ms, avg "
           "%.1f, %d a refresh or more later), %d discarded, %d zero-copy; "
           "ms avg (max): start to raster done %.1f (%.1f), to GTK draw "
           "%.1f (%.1f), paint %.1f (%.1f) of which view %.1f (%.1f)",
           secs, s.vsyncs, s.gap[0], s.gap[1], s.gap[2], s.shown_gap[0],
           s.shown_gap[1], s.shown_gap[2], s.paints,
           s.presented, shown, shown > 0 ? best / 1000.0 : 0.0,
           shown > 0 ? sum / 1000.0 / shown : 0.0, late, s.discarded,
           s.zero_copy, s.to_present.avg_ms(), s.to_present.max_ms(),
           s.to_draw.avg_ms(), s.to_draw.max_ms(), s.paint.avg_ms(),
           s.paint.max_ms(), s.view.avg_ms(), s.view.max_ms());
  log_line(line);
  s = Stats();
  s.since_us = now;
}

// Hands the engine its frame, started at frame_us (monotonic, as GLib's).
void fire(gint64 frame_us) {
  if (pacing->fallback_id != 0) {
    g_source_remove(pacing->fallback_id);
    pacing->fallback_id = 0;
  }
  if (pacing->baton.load() == 0 || pacing->engine == nullptr) return;
  // The newest motion first, so this frame lays out where the pointer is.
  deliver_pending();
  intptr_t baton = pacing->baton.exchange(0);
  if (baton == 0) return;
  pacing->in_flight = true;
  if (pacing->log) {
    Stats& s = pacing->stats;
    s.vsyncs++;
    gint64 gap = frame_us - pacing->frame_start_us;
    gint64 r = pacing->interval_us;
    if (gap > 0 && gap < 4 * r) {
      s.gap[gap < 3 * r / 2 ? 0 : gap < 5 * r / 2 ? 1 : 2]++;
    }
    log_stats(g_get_monotonic_time());
  }
  pacing->frame_start_us = frame_us;
  uint64_t start = static_cast<uint64_t>(frame_us) * 1000;
  pacing->api.OnVsync(
      pacing->engine, baton, start,
      start + static_cast<uint64_t>(pacing->interval_us) * 1000);
}

gboolean fallback_cb(gpointer) {
  pacing->fallback_id = 0;
  fire(g_get_monotonic_time());
  return G_SOURCE_REMOVE;
}

// A frame even when no tick comes (window hidden, compositor idle).
void arm_fallback(gint64 after_us) {
  if (pacing->fallback_id != 0) return;
  pacing->fallback_id = g_timeout_add(
      static_cast<guint>((after_us + 999) / 1000), fallback_cb, nullptr);
}

#ifdef GDK_WINDOWING_WAYLAND
gboolean callback_fire_cb(gpointer) {
  fire(g_get_monotonic_time());
  return G_SOURCE_REMOVE;
}

void grid_note_callback(gint64 t);

void frame_done_cb(void* data, struct wl_callback* callback, uint32_t time) {
  wl_callback_destroy(callback);
  if (pacing->frame_callback == callback) pacing->frame_callback = nullptr;
  if (pacing->source == Source::kGrid) {
    grid_note_callback(g_get_monotonic_time());
    return;
  }
  if (pacing->source != Source::kCallback) return;
  // Not inside Wayland's dispatch: firing hands a motion event to GTK.
  g_idle_add_full(G_PRIORITY_HIGH, callback_fire_cb, nullptr, nullptr);
}

const struct wl_callback_listener frame_listener = {frame_done_cb};

// Grid: the newest vblank at or before t, and the one after.
gint64 vblank_at_or_before(gint64 t) {
  gint64 r = pacing->refresh_us;
  gint64 n = t >= pacing->vblank_us ? (t - pacing->vblank_us) / r
                                    : -((pacing->vblank_us - t + r - 1) / r);
  return pacing->vblank_us + n * r;
}

// The compositor sent a frame callback at t: follow its phase (a slow
// average; a wrap-around near the vblank counts as near, not far).
void grid_note_callback(gint64 t) {
  gint64 r = pacing->refresh_us;
  if (r <= 0 || pacing->vblank_us == 0) return;
  gint64 off = t - vblank_at_or_before(t);
  if (!pacing->phase_known) {
    pacing->phase_us = off;
    pacing->phase_known = true;
    return;
  }
  gint64 d = off - pacing->phase_us;
  if (d > r / 2) d -= r;
  if (d < -r / 2) d += r;
  pacing->phase_us += d / 8;
  if (pacing->phase_us < 0) pacing->phase_us += r;
  if (pacing->phase_us >= r) pacing->phase_us -= r;
}

gboolean grid_dispatch(GSource* source, GSourceFunc, gpointer);
GSourceFuncs grid_funcs = {nullptr, nullptr, grid_dispatch, nullptr,
                           nullptr, nullptr};

// Starts a frame on the grid: on the vblank just passed when that is
// recent and unused, otherwise on the next one.
void grid_schedule() {
  if (pacing->baton.load() == 0) return;
  if (pacing->awaiting >= kGridDepth) {
    arm_fallback(3 * pacing->interval_us);  // feedback reschedules
    return;
  }
  gint64 now = g_get_monotonic_time();
  gint64 r = pacing->refresh_us;
  gint64 prev = vblank_at_or_before(now - pacing->phase_us) + pacing->phase_us;
  if (prev - pacing->started_vblank_us > r / 2 &&
      now - prev <= static_cast<gint64>(r * kGridLateStart)) {
    g_source_set_ready_time(pacing->grid_timer, -1);
    pacing->started_vblank_us = prev;
    fire(prev);
    return;
  }
  gint64 next = prev + r;
  if (next - pacing->started_vblank_us < r / 2) next += r;
  g_source_set_ready_time(pacing->grid_timer, next);
}

gboolean grid_dispatch(GSource* source, GSourceFunc, gpointer) {
  gint64 at = g_source_get_ready_time(source);
  g_source_set_ready_time(source, -1);
  if (pacing->baton.load() == 0) return G_SOURCE_CONTINUE;
  if (pacing->awaiting >= kGridDepth) {
    arm_fallback(3 * pacing->interval_us);
    return G_SOURCE_CONTINUE;
  }
  pacing->started_vblank_us = at;
  fire(at);
  return G_SOURCE_CONTINUE;
}

guint grid_kick_id = 0;

gboolean grid_kick_cb(gpointer) {
  grid_kick_id = 0;
  grid_schedule();
  return G_SOURCE_REMOVE;
}

// From Wayland's dispatch: schedule from the main loop instead, as firing
// hands a motion event to GTK.
void grid_kick() {
  if (grid_kick_id != 0) return;
  grid_kick_id =
      g_idle_add_full(G_PRIORITY_HIGH, grid_kick_cb, nullptr, nullptr);
}

void feedback_done(struct wp_presentation_feedback* feedback) {
  wp_presentation_feedback_destroy(feedback);
  if (pacing->awaiting > 0) pacing->awaiting--;
  if (pacing->source == Source::kGrid) grid_kick();
}

void feedback_sync_output(void*, struct wp_presentation_feedback*,
                          struct wl_output*) {}

void feedback_presented(void* data,
                        struct wp_presentation_feedback* feedback,
                        uint32_t tv_sec_hi,
                        uint32_t tv_sec_lo,
                        uint32_t tv_nsec,
                        uint32_t refresh,
                        uint32_t seq_hi,
                        uint32_t seq_lo,
                        uint32_t flags) {
  gint64 start_us = static_cast<gint64>(reinterpret_cast<intptr_t>(data));
  gint64 secs = (static_cast<gint64>(tv_sec_hi) << 32) | tv_sec_lo;
  gint64 at_us = secs * 1000000 + tv_nsec / 1000;
  if (pacing->monotonic && refresh > 0) {
    pacing->vblank_us = MAX(pacing->vblank_us, at_us);
    pacing->refresh_us = refresh / 1000;
    if (pacing->want_grid && pacing->source == Source::kCallback &&
        pacing->refresh_us > 1000) {
      pacing->source = Source::kGrid;
      if (pacing->frame_callback != nullptr) {
        wl_callback_destroy(pacing->frame_callback);
        pacing->frame_callback = nullptr;
      }
      pacing->in_flight = false;
      log_line("on the presented vblank grid");
    }
  }
  if (pacing->log) {
    Stats& s = pacing->stats;
    s.presented++;
    gint64 r = pacing->interval_us;
    gint64 gap = at_us - pacing->last_shown_us;
    if (gap > 0 && gap < 4 * r) {
      s.shown_gap[gap < 3 * r / 2 ? 0 : gap < 5 * r / 2 ? 1 : 2]++;
    }
    pacing->last_shown_us = at_us;
    if (flags & WP_PRESENTATION_FEEDBACK_KIND_ZERO_COPY) s.zero_copy++;
    if (start_us > 0 && pacing->monotonic) {
      gint64 latency = at_us - start_us;
      if (latency > 0 && latency < 1000000) s.latencies.push_back(latency);
    }
  }
  feedback_done(feedback);
}

void feedback_discarded(void*, struct wp_presentation_feedback* feedback) {
  if (pacing->log) pacing->stats.discarded++;
  feedback_done(feedback);
}

const struct wp_presentation_feedback_listener feedback_listener = {
    feedback_sync_output, feedback_presented, feedback_discarded};

void presentation_clock_id(void*, struct wp_presentation*, uint32_t clk_id) {
  pacing->monotonic = clk_id == CLOCK_MONOTONIC;
}

const struct wp_presentation_listener presentation_listener = {
    presentation_clock_id};

void registry_global(void* data,
                     struct wl_registry* registry,
                     uint32_t name,
                     const char* interface,
                     uint32_t version) {
  if (strcmp(interface, wp_presentation_interface.name) == 0) {
    pacing->presentation = static_cast<struct wp_presentation*>(
        wl_registry_bind(registry, name, &wp_presentation_interface, 1));
  }
}

void registry_global_remove(void*, struct wl_registry*, uint32_t) {}

const struct wl_registry_listener registry_listener = {
    registry_global, registry_global_remove};

// wp_presentation from GDK's connection, on a queue of its own while
// binding (GDK's queue is GDK's to dispatch), then on the default queue so
// feedback arrives with GDK's other events.
void bind_presentation(struct wl_display* display) {
  struct wl_event_queue* queue = wl_display_create_queue(display);
  auto* wrapper = static_cast<struct wl_display*>(wl_proxy_create_wrapper(display));
  wl_proxy_set_queue(reinterpret_cast<struct wl_proxy*>(wrapper), queue);
  struct wl_registry* registry = wl_display_get_registry(wrapper);
  wl_registry_add_listener(registry, &registry_listener, nullptr);
  wl_display_roundtrip_queue(display, queue);
  if (pacing->presentation != nullptr) {
    wp_presentation_add_listener(pacing->presentation, &presentation_listener,
                                 nullptr);
    wl_display_roundtrip_queue(display, queue);  // clock_id
    wl_proxy_set_queue(reinterpret_cast<struct wl_proxy*>(pacing->presentation),
                       nullptr);
  }
  wl_registry_destroy(registry);
  wl_proxy_wrapper_destroy(wrapper);
  wl_event_queue_destroy(queue);
}
#endif

// Main thread: the engine wants a frame.
gboolean request_tick(gpointer) {
  if (pacing->baton.load() == 0) return G_SOURCE_REMOVE;
#ifdef GDK_WINDOWING_WAYLAND
  if (pacing->source == Source::kGrid) {
    grid_schedule();
    arm_fallback(3 * pacing->interval_us);
    return G_SOURCE_REMOVE;
  }
#endif
  // The last paint's frame callback brings it; with none out, the next
  // frame clock tick (a timer before the window is up).
  if (frame_callback_pending()) {
    arm_fallback(3 * pacing->interval_us);
  } else if (pacing->clock != nullptr &&
             gtk_widget_get_mapped(pacing->toplevel)) {
    gdk_frame_clock_request_phase(pacing->clock, GDK_FRAME_CLOCK_PHASE_UPDATE);
    arm_fallback(3 * pacing->interval_us);
  } else {
    arm_fallback(pacing->interval_us);
  }
  return G_SOURCE_REMOVE;
}

// Engine thread.
void vsync_cb(void* user_data, intptr_t baton) {
  pacing->baton.store(baton);
  g_main_context_invoke(nullptr, request_tick, nullptr);
}

void update_cb(GdkFrameClock* clock, gpointer) {
  pace_gtk(clock);
  update_interval();
  if (frame_callback_pending() || pacing->source == Source::kGrid) return;
  fire(MIN(gdk_frame_clock_get_frame_time(clock), g_get_monotonic_time()));
}

void before_paint_cb(GdkFrameClock* clock, gpointer) {
  pace_gtk(clock);
}

// The window is being drawn: this cycle ends in a commit (eglSwapBuffers),
// which carries the frame and feedback requests. A cycle that draws
// nothing commits nothing, so the requests are only made here.
gboolean draw_cb(GtkWidget* widget, cairo_t* cr, gpointer) {
  pacing->in_flight = false;
  if (pacing->coalesce) no_compression(gtk_widget_get_window(widget));
  if (pacing->log) {
    Stats& s = pacing->stats;
    pacing->draw_us = g_get_monotonic_time();
    s.paints++;
    gint64 raster = presented_us.exchange(0);
    if (raster >= pacing->frame_start_us && raster <= pacing->draw_us) {
      s.to_present.add(raster - pacing->frame_start_us);
      s.to_draw.add(pacing->draw_us - raster);
    }
  }
#ifdef GDK_WINDOWING_WAYLAND
  if (pacing->source != Source::kTimer && pacing->frame_callback == nullptr) {
    pacing->frame_callback = wl_surface_frame(pacing->surface);
    wl_callback_add_listener(pacing->frame_callback, &frame_listener, nullptr);
  }
  if (pacing->presentation != nullptr &&
      (pacing->want_grid || pacing->log)) {
    struct wp_presentation_feedback* feedback =
        wp_presentation_feedback(pacing->presentation, pacing->surface);
    wp_presentation_feedback_add_listener(
        feedback, &feedback_listener,
        reinterpret_cast<void*>(static_cast<intptr_t>(pacing->frame_start_us)));
    pacing->awaiting++;
  }
#endif
  return FALSE;
}

gboolean view_draw_cb(GtkWidget*, cairo_t*, gpointer) {
  pacing->view_us = g_get_monotonic_time();
  return FALSE;
}

gboolean view_drawn_cb(GtkWidget*, cairo_t*, gpointer) {
  if (pacing->view_us != 0) {
    pacing->stats.view.add(g_get_monotonic_time() - pacing->view_us);
    pacing->view_us = 0;
  }
  return FALSE;
}

void after_paint_cb(GdkFrameClock* clock, gpointer) {
  pace_gtk(clock);
  if (pacing->log && pacing->draw_us != 0) {
    pacing->stats.paint.add(g_get_monotonic_time() - pacing->draw_us);
    pacing->draw_us = 0;
  }
}

FlutterPresentViewCallback present_view = nullptr;

// Raster thread.
bool present_view_cb(const FlutterPresentViewInfo* info) {
  bool result = present_view(info);
  presented_us.store(g_get_monotonic_time());
  return result;
}

FlutterEngineResult initialize_cb(
    size_t version,
    const FlutterRendererConfig* config,
    const FlutterProjectArgs* args,
    void* user_data,
    FLUTTER_API_SYMBOL(FlutterEngine) * engine_out) {
  if (args == nullptr || args->struct_size != sizeof(FlutterProjectArgs) ||
      args->vsync_callback != nullptr) {
    log_line("project args differ from the expected ones: no vsync");
    return pacing->api.Initialize(version, config, args, user_data,
                                  engine_out);
  }
  FlutterProjectArgs with_vsync = *args;
  with_vsync.vsync_callback = vsync_cb;
  // Statistics: when the raster thread hands a frame over (the engine reads
  // the compositor's callbacks during Initialize; the copy outlives it).
  static FlutterCompositor compositor;
  if (pacing->log && args->compositor != nullptr &&
      args->compositor->struct_size == sizeof(FlutterCompositor) &&
      args->compositor->present_view_callback != nullptr) {
    compositor = *args->compositor;
    present_view = compositor.present_view_callback;
    compositor.present_view_callback = present_view_cb;
    with_vsync.compositor = &compositor;
  }
  FlutterEngineResult result = pacing->api.Initialize(
      version, config, &with_vsync, user_data, engine_out);
  if (result == kSuccess) pacing->engine = *engine_out;
  return result;
}

}  // namespace

void frame_pacing_install(FlView* view, FlDartProject* project) {
  if (g_strcmp0(g_getenv("STARSYNC_FRAME_PACING"), "off") == 0) {
    log_line("off (STARSYNC_FRAME_PACING=off)");
    return;
  }
  FlEngine* engine = fl_view_get_engine(view);
  auto* head = reinterpret_cast<FlEngineHead*>(engine);
  if (head->project != project ||
      head->binary_messenger != fl_engine_get_binary_messenger(engine) ||
      head->texture_registrar != fl_engine_get_texture_registrar(engine) ||
      head->engine != nullptr ||
      head->embedder_api.struct_size != sizeof(FlutterEngineProcTable) ||
      head->embedder_api.Initialize == nullptr ||
      head->embedder_api.OnVsync == nullptr) {
    log_line("FlEngine layout unknown: stock 60 Hz pacing");
    return;
  }
  pacing = new Pacing();
  pacing->api = head->embedder_api;
  pacing->view = GTK_WIDGET(view);
  pacing->log = g_getenv("STARSYNC_FRAME_PACING_LOG") != nullptr;
  head->embedder_api.Initialize = initialize_cb;
  log_line("installed");
}

void frame_pacing_attach(GtkWidget* toplevel) {
  if (pacing == nullptr || pacing->clock != nullptr) return;
  GdkFrameClock* clock = gtk_widget_get_frame_clock(toplevel);
  if (clock == nullptr) return;
  pacing->toplevel = toplevel;
  pacing->clock = clock;
  update_interval();
  const char* mode = g_getenv("STARSYNC_FRAME_PACING");
#ifdef GDK_WINDOWING_WAYLAND
  GdkWindow* window = gtk_widget_get_window(toplevel);
  if (window != nullptr && GDK_IS_WAYLAND_WINDOW(window) &&
      g_strcmp0(mode, "timer") != 0) {
    pacing->surface = gdk_wayland_window_get_wl_surface(window);
    if (pacing->surface != nullptr) {
      pacing->source = Source::kCallback;
      pacing->want_grid = g_strcmp0(mode, "callback") != 0;
      if (pacing->want_grid || pacing->log) {
        bind_presentation(gdk_wayland_display_get_wl_display(
            gdk_window_get_display(window)));
        if (pacing->presentation == nullptr || !pacing->monotonic) {
          pacing->want_grid = false;
        }
      }
      pacing->grid_timer = g_source_new(&grid_funcs, sizeof(GSource));
      g_source_set_priority(pacing->grid_timer, G_PRIORITY_HIGH);
      g_source_set_ready_time(pacing->grid_timer, -1);
      g_source_attach(pacing->grid_timer, nullptr);
    }
  }
#endif
  g_signal_connect(clock, "update", G_CALLBACK(update_cb), nullptr);
  g_signal_connect(clock, "before-paint", G_CALLBACK(before_paint_cb),
                   nullptr);
  g_signal_connect(clock, "after-paint", G_CALLBACK(after_paint_cb), nullptr);
  g_signal_connect(toplevel, "draw", G_CALLBACK(draw_cb), nullptr);
  if (pacing->log) {
    g_signal_connect(pacing->view, "draw", G_CALLBACK(view_draw_cb), nullptr);
    g_signal_connect_after(pacing->view, "draw", G_CALLBACK(view_drawn_cb),
                           nullptr);
  }
  pacing->coalesce = g_strcmp0(g_getenv("STARSYNC_POINTER"), "direct") != 0;
  if (pacing->coalesce) {
    no_compression(gtk_widget_get_window(toplevel));
    gdk_event_handler_set(event_handler, nullptr, nullptr);
  }
  char line[128];
  snprintf(line, sizeof(line), "%s, %ld us%s",
           pacing->source == Source::kTimer ? "on the frame clock"
           : pacing->want_grid ? "on the compositor's cycle (grid)"
                               : "on compositor frame callbacks",
           static_cast<long>(pacing->interval_us),
           pacing->coalesce ? ", pointer at vsync" : "");
  log_line(line);
}
