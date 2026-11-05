#ifndef RUNNER_FRAME_PACING_H_
#define RUNNER_FRAME_PACING_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// Frames at the monitor's refresh rate instead of a fixed 60 Hz (see
// frame_pacing.cc). Call right after fl_view_new(), before the view is
// realized (the engine starts on realize). Does nothing, and logs why,
// when this Flutter engine's layout is not the one it was written for.
void frame_pacing_install(FlView* view, FlDartProject* project);

// The view's toplevel exists: pace on its frame clock from now on.
void frame_pacing_attach(GtkWidget* toplevel);

#endif  // RUNNER_FRAME_PACING_H_
