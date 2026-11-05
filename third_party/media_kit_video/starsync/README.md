# Starsync's copy of media_kit_video

Upstream: `media_kit_video` 2.0.1 from pub.dev (media-kit/media-kit, MIT,
see ../LICENSE), vendored because upstream has not released since
December 2025. The `example/` folder is left out.

Patches, in order from the package root (the first with `patch -p7`, as
recorded, the others with `patch -p1`):
- `egl-platform-display.patch`: Flutter >= 3.38 keeps its EGL contexts on
  the raster thread, so nothing is current on the platform thread where
  the video output is created and media_kit fell back to software
  rendering (no shaders, slow). The output now opens Flutter's EGL display
  itself (eglGetPlatformDisplayEXT on the GDK X11/Wayland display) with
  Flutter's config attributes; on X11 it steps GDK's GLX context aside
  while its EGL context is in use (libglvnd refuses EGL on a thread
  holding GLX), and releases its context instead of leaving it current.
  Written by a friend's agent from a real X11 failure.
- `video-controller-first-frame.patch`: a `VideoController` set itself up
  after the next frame (a post-frame callback). One made between frames
  (from async code while nothing animates: Up next's preload, a media
  switch's fresh player) waited until something else drew, and one made
  while the window was hidden (frames off; the app's close hides the
  window first) waited for good. media_kit's `NativePlayer.dispose` and
  its other calls wait for that setup under a lock all players share, so
  one such player kept every player from going (their mpv cores stayed
  up). It now waits only for the app's first frame.
- `texture-name-context.patch` (from the media_kit fork's integration
  branch): Flutter's texture name of an output was deleted on the platform
  thread, where Flutter's GL context is not current, so the name and the
  frame it holds through its EGLImage stayed in video memory, one per
  player (~10.5 MiB at 2560x1080). A name is now deleted in the context
  that made it: at once when it is current, else at the next populate of
  a texture there; the 1x1 placeholder before the first frame goes too.

To update: copy the new upstream version over this folder (minus
`example/`), re-apply the patches, run the app under X11
(`GDK_BACKEND=x11`) and Wayland.
