#include <stdio.h>
#include <unistd.h>

#include "my_application.h"

int main(int argc, char** argv) {
  MyApplication* app = my_application_new();
  int status = g_application_run(G_APPLICATION(app), argc, argv);
  // The window is gone and the engine with it (the app disposed its mpv
  // players and left before closing the window). Skip exit(): its handlers
  // include NVIDIA's EGL teardown (libEGL_nvidia), which segfaults inside
  // exit() for Flutter apps. Nothing is left to flush but stdio.
  fflush(stdout);
  fflush(stderr);
  _exit(status);
}
