# Starsync's copy of media_kit_video

Upstream: `media_kit_video` 2.0.1 from pub.dev (media-kit/media-kit, MIT,
see ../LICENSE), vendored because upstream has not released since
December 2025. The `example/` folder is left out.

Patches (apply with `patch -p7` from the package root, as recorded):
- `egl-platform-display.patch`: Flutter >= 3.38 keeps its EGL contexts on
  the raster thread, so nothing is current on the platform thread where
  the video output is created and media_kit fell back to software
  rendering (no shaders, slow). The output now opens Flutter's EGL display
  itself (eglGetPlatformDisplayEXT on the GDK X11/Wayland display) with
  Flutter's config attributes; on X11 it steps GDK's GLX context aside
  while its EGL context is in use (libglvnd refuses EGL on a thread
  holding GLX), and releases its context instead of leaving it current.
  Written by a friend's agent from a real X11 failure.

To update: copy the new upstream version over this folder (minus
`example/`), re-apply the patches, run the app under X11
(`GDK_BACKEND=x11`) and Wayland.
