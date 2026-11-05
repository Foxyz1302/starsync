#include "clipboard_image.h"

#include <gtk/gtk.h>

// The PNG on offer goes out as is whenever an app pastes; it is held
// until another owner takes the clipboard (then [clear_png] frees it).
static void get_png(GtkClipboard* clipboard, GtkSelectionData* selection,
                    guint info, gpointer owner) {
  GBytes* png = static_cast<GBytes*>(owner);
  gsize size = 0;
  const guchar* data =
      static_cast<const guchar*>(g_bytes_get_data(png, &size));
  gtk_selection_data_set(selection, gdk_atom_intern_static_string("image/png"),
                         8, data, static_cast<gint>(size));
}

static void clear_png(GtkClipboard* clipboard, gpointer owner) {
  g_bytes_unref(static_cast<GBytes*>(owner));
}

static void clipboard_method_cb(FlMethodChannel* channel, FlMethodCall* call,
                                gpointer user_data) {
  g_autoptr(FlMethodResponse) response = nullptr;
  const gchar* method = fl_method_call_get_name(call);
  if (g_strcmp0(method, "copyImage") == 0) {
    FlValue* args = fl_method_call_get_args(call);
    if (args == nullptr ||
        fl_value_get_type(args) != FL_VALUE_TYPE_UINT8_LIST) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "bad-args", "copyImage takes the PNG bytes", nullptr));
    } else {
      GBytes* png = g_bytes_new(fl_value_get_uint8_list(args),
                                fl_value_get_length(args));
      static GtkTargetEntry targets[] = {
          {const_cast<gchar*>("image/png"), 0, 0}};
      GtkClipboard* clipboard =
          gtk_clipboard_get_default(gdk_display_get_default());
      gboolean ok = gtk_clipboard_set_with_data(clipboard, targets, 1,
                                                get_png, clear_png, png);
      if (ok) {
        // A clipboard manager (X11) may keep it after the app quits.
        gtk_clipboard_set_can_store(clipboard, targets, 1);
      } else {
        g_bytes_unref(png);  // the callbacks are dropped when it fails
      }
      g_autoptr(FlValue) result = fl_value_new_bool(ok);
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
    }
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

FlMethodChannel* clipboard_image_channel_new(FlBinaryMessenger* messenger) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(
      messenger, "starsync/clipboard", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, clipboard_method_cb,
                                            nullptr, nullptr);
  return channel;
}
