import android.content.ClipData;
import android.content.ClipDescription;
import android.os.IBinder;
import android.os.PersistableBundle;
import android.os.SystemClock;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.KeyCharacterMap;
import android.view.KeyEvent;
import android.view.MotionEvent;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.Base64;

// karagoz's text helper. karagoz pushes it to /data/local/tmp and runs it as the shell user:
//   CLASSPATH=<jar> app_process / TextHelper <base64 of the UTF-8 text>
// It saves the primary clip, pastes the text with Ctrl+V (newline and tab as Enter and Tab keys) and puts the saved
// clip back, all in one VM: each app_process start costs 1-2 s. On failure it exits 1 and prints its error on stderr,
// then one line on the clipboard: "clip: kept" (never changed), "clip: restored" or "clip: lost: <error>".
//   CLASSPATH=<jar> app_process / TextHelper double-tap <x> <y> <holdMs> <gapMs>
// plays two touches at one point from this one process, so the gap between them is its own and not a process start's.
// On failure it exits 1 and prints "double-tap: <error>" on stderr. Base64 has no "-", so no text reads as double-tap.
public final class TextHelper {
  private static final String SHELL = "com.android.shell";
  // SystemUI shows no "copied" overlay for a shell clip carrying this extra (Android 13+).
  private static final String SUPPRESS = "com.android.systemui.SUPPRESS_CLIPBOARD_OVERLAY";
  // InputManager.INJECT_INPUT_EVENT_MODE_WAIT_FOR_FINISH: the call returns once the app has handled the key.
  private static final int WAIT_FOR_FINISH = 2;
  // Compose reads the clip after the paste key has returned: with no wait the last piece pasted the restored clip in 4
  // of 5 runs on an API 37 emulator, with 100 ms in none. Twice that, before the clipboard changes again.
  // ponytail: a fixed wait; a device slower than that emulator under load may need more.
  private static final long SETTLE_MS = 200;

  private static Object clipboard;
  private static Object input;
  private static Method inject;

  public static void main(String[] args) {
    if (args.length == 5 && args[0].equals("double-tap")) {
      try {
        resolveInput();
        doubleTap(Float.parseFloat(args[1]), Float.parseFloat(args[2]), Long.parseLong(args[3]), Long.parseLong(args[4]));
      } catch (Throwable t) {
        System.err.println("double-tap: " + describe(t));
        System.exit(1);
      }
      System.exit(0);
    }
    String text;
    ClipData saved;
    try {
      text = new String(Base64.getDecoder().decode(args[0]), StandardCharsets.UTF_8);
      Object binder = Class.forName("android.os.ServiceManager")
          .getMethod("getService", String.class)
          .invoke(null, "clipboard");
      clipboard = Class.forName("android.content.IClipboard$Stub")
          .getMethod("asInterface", IBinder.class)
          .invoke(null, binder);
      resolveInput();
      saved = (ClipData) call("getPrimaryClip", null);
    } catch (Throwable t) {
      fail(describe(t), "kept");
      return;
    }
    String error = null;
    try {
      type(text);
    } catch (Throwable t) {
      error = describe(t);
    }
    String clip = "restored";
    try {
      restore(saved);
    } catch (Throwable t) {
      clip = "lost: " + describe(t);
      // The pasted text must not stay as the clip: an empty clipboard is the next best thing to the old clip.
      try {
        restore(null);
      } catch (Throwable ignored) {
        // Nothing more to try; the clip line already says the old clip is lost.
      }
    }
    if (error != null || !clip.equals("restored")) fail(error, clip);
    System.exit(0);
  }

  // InputManagerGlobal from Android 14; InputManager.getInstance() is gone by Android 17.
  private static void resolveInput() throws Exception {
    Class<?> manager;
    try {
      manager = Class.forName("android.hardware.input.InputManagerGlobal");
    } catch (ClassNotFoundException e) {
      manager = Class.forName("android.hardware.input.InputManager");
    }
    input = manager.getMethod("getInstance").invoke(null);
    inject = manager.getMethod("injectInputEvent", InputEvent.class, int.class);
  }

  // Down, hold, up, gap, down, hold, up, each stamped with the real time, built as the input command builds a tap.
  private static void doubleTap(float x, float y, long hold, long gap) throws Exception {
    for (int i = 0; i < 2; i++) {
      if (i > 0) Thread.sleep(gap);
      long down = SystemClock.uptimeMillis();
      touch(down, down, MotionEvent.ACTION_DOWN, x, y);
      Thread.sleep(hold);
      touch(down, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, x, y);
    }
  }

  private static void touch(long down, long time, int action, float x, float y) throws Exception {
    MotionEvent.PointerProperties properties = new MotionEvent.PointerProperties();
    properties.id = 0;
    properties.toolType = MotionEvent.TOOL_TYPE_FINGER;
    MotionEvent.PointerCoords coords = new MotionEvent.PointerCoords();
    coords.x = x;
    coords.y = y;
    coords.pressure = action == MotionEvent.ACTION_DOWN ? 1 : 0;
    coords.size = 1;
    MotionEvent event = MotionEvent.obtain(down, time, action, 1, new MotionEvent.PointerProperties[] {properties},
        new MotionEvent.PointerCoords[] {coords}, 0, 0, 1, 1, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0);
    try {
      if (!Boolean.TRUE.equals(inject.invoke(input, event, WAIT_FOR_FINISH)))
        throw new IllegalStateException("the device did not take the touch");
    } finally {
      event.recycle();
    }
  }

  private static void fail(String error, String clip) {
    if (error != null) System.err.println(error);
    System.err.println("clip: " + clip);
    System.exit(1);
  }

  // One line: the exception a reflected call threw, not the wrapper around it.
  private static String describe(Throwable t) {
    while (t instanceof InvocationTargetException && t.getCause() != null) t = t.getCause();
    return t.toString().replace('\n', ' ');
  }

  private static void type(String text) throws Exception {
    int start = 0;
    for (int i = 0; i <= text.length(); i++) {
      boolean end = i == text.length();
      char c = end ? 0 : text.charAt(i);
      if (!end && c != '\n' && c != '\t') continue;
      if (i > start) {
        call("setPrimaryClip", plain(text.substring(start, i)));
        paste();
      }
      if (!end) press(c == '\n' ? KeyEvent.KEYCODE_ENTER : KeyEvent.KEYCODE_TAB, 0);
      start = i + 1;
    }
  }

  // The saved clip as it was read; with none, an empty clipboard (clearPrimaryClip exists from Android 9).
  private static void restore(ClipData saved) throws Exception {
    if (saved != null) {
      call("setPrimaryClip", suppressed(saved));
      return;
    }
    try {
      call("clearPrimaryClip", null);
    } catch (NoSuchMethodException e) {
      call("setPrimaryClip", plain(""));
    }
  }

  private static ClipData plain(String text) {
    return suppressed(ClipData.newPlainText("karagoz", text));
  }

  private static ClipData suppressed(ClipData clip) {
    ClipDescription description = clip.getDescription();
    PersistableBundle extras = description.getExtras();
    extras = extras == null ? new PersistableBundle() : new PersistableBundle(extras);
    extras.putBoolean(SUPPRESS, true);
    description.setExtras(extras);
    return clip;
  }

  // IClipboard's parameters change with the Android version (29 and 34 add some) and with OEM builds, so a method is
  // found by name and filled by type: the clip, the shell package for the first String, null for later ones, 0, false.
  private static Object call(String name, ClipData clip) throws Exception {
    for (Method method : clipboard.getClass().getMethods()) {
      if (!method.getName().equals(name)) continue;
      Class<?>[] types = method.getParameterTypes();
      Object[] values = new Object[types.length];
      boolean named = false;
      boolean fits = true;
      for (int i = 0; i < types.length && fits; i++) {
        if (types[i] == ClipData.class) {
          values[i] = clip;
        } else if (types[i] == String.class) {
          values[i] = named ? null : SHELL;
          named = true;
        } else if (types[i] == int.class) {
          values[i] = 0;
        } else if (types[i] == boolean.class) {
          values[i] = false;
        } else {
          fits = false;
        }
      }
      if (fits) return method.invoke(clipboard, values);
    }
    throw new NoSuchMethodException("IClipboard." + name);
  }

  private static void paste() throws Exception {
    int ctrl = KeyEvent.META_CTRL_ON | KeyEvent.META_CTRL_LEFT_ON;
    key(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_CTRL_LEFT, ctrl);
    press(KeyEvent.KEYCODE_V, ctrl);
    key(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_CTRL_LEFT, 0);
    Thread.sleep(SETTLE_MS);
  }

  private static void press(int code, int meta) throws Exception {
    key(KeyEvent.ACTION_DOWN, code, meta);
    key(KeyEvent.ACTION_UP, code, meta);
  }

  private static void key(int action, int code, int meta) throws Exception {
    long now = SystemClock.uptimeMillis();
    KeyEvent event = new KeyEvent(
        now, now, action, code, 0, meta, KeyCharacterMap.VIRTUAL_KEYBOARD, 0, 0, InputDevice.SOURCE_KEYBOARD);
    if (!Boolean.TRUE.equals(inject.invoke(input, event, WAIT_FOR_FINISH)))
      throw new IllegalStateException("the device did not take " + KeyEvent.keyCodeToString(code));
  }
}
