package com.btjuicer.priv;

import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;
import android.content.AttributionSource;
import android.content.Context;
import android.content.ContextWrapper;
import android.content.pm.ApplicationInfo;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.Process;
import android.util.Log;

import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.List;

/**
 * The part of BT Juicer that runs as the shell user.
 *
 * <h2>Why this exists</h2>
 *
 * Setting the Bluetooth codec needs {@code BLUETOOTH_PRIVILEGED}, which is a
 * signature permission no installable app can hold — and there is no shell
 * command for it either, so the ADB connection alone is not enough. What the ADB
 * connection *can* do is start a process:
 *
 * <pre>CLASSPATH=&lt;our apk&gt; app_process /system/bin com.btjuicer.priv.Main …</pre>
 *
 * That process runs as uid 2000, the shell user, which does hold the permission.
 * This is exactly the trick Shizuku performs; doing it here keeps it to one app.
 *
 * <h2>Why it is written like this</h2>
 *
 * Plain Java, no Kotlin, no library: this class is loaded by a bare
 * {@code app_process} with only the framework and this APK on its classpath, and
 * every extra class on the load path is another thing that can fail there rather
 * than in the app, where a failure would at least be visible.
 *
 * Every Bluetooth call goes through reflection, not because the classes are
 * hidden from *this* process — {@code app_process} has no hidden-API
 * enforcement — but because they are absent from the public SDK the app is
 * compiled against, and because their shape has changed across releases.
 * Reflection by name and arity survives that; direct calls would not compile at
 * all.
 *
 * <h2>The protocol</h2>
 *
 * One line per fact on stdout, each prefixed {@code BTJ:} so the app can ignore
 * whatever else the runtime decides to print. Exit code 0 means the command ran;
 * it does not mean the codec changed, which is reported separately and verified
 * by reading the codec back rather than assumed.
 */
public final class Main {

    private static final String TAG = "BTJuicerPriv";

    /** uid 2000 owns this package, so an attribution source naming it validates. */
    private static final String SHELL_PACKAGE = "com.android.shell";

    private static final int PROFILE_A2DP = BluetoothProfile.A2DP;

    /** {@code BluetoothCodecConfig.CODEC_PRIORITY_HIGHEST}. */
    private static final int PRIORITY_HIGHEST = 1_000_000;

    /** {@code BluetoothA2dp.OPTIONAL_CODECS_PREF_ENABLED}. */
    private static final int OPTIONAL_CODECS_ENABLED = 1;

    private static final long OVERALL_TIMEOUT_MS = 15_000L;

    /** How long to let the stack renegotiate before reading the result back. */
    private static final long SETTLE_MS = 2_000L;

    private static Handler handler;
    private static String command = "probe";
    private static String wantedAddress = "";
    private static int wantedCodec = -1;
    private static long wantedSpecific1 = -1L;

    public static void main(String[] args) {
        if (args.length > 0) command = args[0];
        if (args.length > 1) wantedAddress = args[1];
        if (args.length > 2) wantedCodec = parseInt(args[2], -1);
        if (args.length > 3) wantedSpecific1 = parseLong(args[3], -1L);

        Looper.prepareMainLooper();
        handler = new Handler(Looper.getMainLooper());

        handler.postDelayed(new Runnable() {
            @Override
            public void run() {
                fail("timeout: el sistema no respondió a tiempo");
            }
        }, OVERALL_TIMEOUT_MS);

        handler.post(new Runnable() {
            @Override
            public void run() {
                try {
                    start();
                } catch (Throwable t) {
                    fail(describe(t));
                }
            }
        });

        Looper.loop();
    }

    // ------------------------------------------------------------------ flujo

    private static void start() throws Exception {
        out("uid", Process.myUid());
        out("sdk", Build.VERSION.SDK_INT);

        Context context = buildContext();
        out("package", context.getPackageName());

        BluetoothAdapter adapter = adapterOf(context);
        if (adapter == null) {
            fail("no se pudo obtener el adaptador Bluetooth");
            return;
        }
        out("bt_enabled", adapter.isEnabled());

        // Order matters: the profile proxy copies the adapter's attribution
        // source when it is built, so the adapter has to be corrected first.
        patchAttribution(adapter);

        boolean requested = adapter.getProfileProxy(context, new BluetoothProfile.ServiceListener() {
            @Override
            public void onServiceConnected(int profile, BluetoothProfile proxy) {
                if (profile != PROFILE_A2DP) return;
                patchAttribution(proxy);
                try {
                    onA2dp(proxy);
                } catch (Throwable t) {
                    fail(describe(t));
                }
            }

            @Override
            public void onServiceDisconnected(int profile) {
            }
        }, PROFILE_A2DP);

        if (!requested) fail("el sistema rechazó la petición del perfil A2DP");
    }

    private static void onA2dp(BluetoothProfile proxy) throws Exception {
        BluetoothDevice device = pickDevice(proxy);
        if (device == null) {
            fail("no hay ningún dispositivo A2DP conectado");
            return;
        }
        out("device", device.getAddress());
        out("device_name", safeName(device));

        Object status = codecStatus(proxy, device);
        if (status == null) {
            // getCodecStatus is the permission gate: it is the first call that
            // demands BLUETOOTH_PRIVILEGED, so failing here means the shell user
            // does not have it on this ROM and nothing further will work.
            out("privileged", false);
            fail("el usuario shell no pudo leer el códec: sin BLUETOOTH_PRIVILEGED en esta ROM");
            return;
        }
        out("privileged", true);
        reportConfig("current", call(status, "getCodecConfig"));
        reportSelectable(status);

        if (!"set".equals(command)) {
            finish(0);
            return;
        }
        applyAndVerify(proxy, device);
    }

    private static void applyAndVerify(final BluetoothProfile proxy, final BluetoothDevice device)
            throws Exception {
        if (wantedCodec < 0) {
            fail("falta el códec a fijar");
            return;
        }

        // Without this the stack is free to ignore every codec but SBC, and the
        // preference below would be accepted and then quietly not applied.
        if (wantedCodec != 0) {
            Boolean enabled = tryCall(
                    proxy, "setOptionalCodecsEnabled", 2, device, OPTIONAL_CODECS_ENABLED);
            out("optional_codecs", enabled != null);
        }

        Object config = buildConfig(wantedCodec, wantedSpecific1);
        out("requested_codec", wantedCodec);
        if (wantedSpecific1 >= 0) out("requested_specific1", wantedSpecific1);

        Method setter = findSetter(proxy.getClass());
        if (setter == null) {
            fail("setCodecConfigPreference no existe en esta versión de Android");
            return;
        }
        if (setter.getParameterTypes().length == 2) {
            setter.invoke(proxy, device, config);
        } else {
            setter.invoke(proxy, config);
        }
        out("submitted", true);

        // The stack renegotiates the link asynchronously, so the only honest way
        // to report the outcome is to wait and read it back.
        handler.postDelayed(new Runnable() {
            @Override
            public void run() {
                try {
                    Object status = codecStatus(proxy, device);
                    if (status == null) {
                        fail("no se pudo releer el códec tras aplicarlo");
                        return;
                    }
                    reportConfig("applied", call(status, "getCodecConfig"));
                    finish(0);
                } catch (Throwable t) {
                    fail(describe(t));
                }
            }
        }, SETTLE_MS);
    }

    // ------------------------------------------------------------- bluetooth

    /**
     * A context that speaks as {@code com.android.shell}.
     *
     * Since Android 12 every Bluetooth call carries an {@link AttributionSource},
     * and the system rejects one whose package does not belong to the calling
     * uid. A bare system context claims to be "android", which is uid 1000, so
     * it is refused out of hand when the caller is uid 2000. Naming
     * {@code com.android.shell} — which uid 2000 does own — is what makes the
     * call legitimate.
     *
     * <p>The {@link android.app.ActivityThread} is built through its own
     * constructor rather than {@code systemMain()} on purpose.
     * {@code systemMain()} calls {@code attach()}, which builds an
     * {@code Application} through {@code LoadedApk.makeApplication} — and that
     * is precisely where an earlier attempt at this died on this phone, with a
     * {@code NullPointerException} thrown from inside the framework. The plain
     * constructor sets up the resources manager and nothing else, which is all
     * {@code getSystemContext()} needs. {@code systemMain()} is kept only as a
     * fallback, so a ROM that breaks the quiet path still has somewhere to go.
     */
    private static Context buildContext() throws Exception {
        Class<?> activityThread = Class.forName("android.app.ActivityThread");
        Object thread;
        try {
            Constructor<?> ctor = activityThread.getDeclaredConstructor();
            ctor.setAccessible(true);
            thread = ctor.newInstance();

            Field current = activityThread.getDeclaredField("sCurrentActivityThread");
            current.setAccessible(true);
            current.set(null, thread);

            fillBoundApplication(activityThread, thread);
            out("thread", "constructed");
        } catch (Throwable t) {
            out("thread_warn", describe(t));
            thread = activityThread.getMethod("systemMain").invoke(null);
            out("thread", "systemMain");
        }

        Method getSystemContext = activityThread.getDeclaredMethod("getSystemContext");
        getSystemContext.setAccessible(true);
        return new ShellContext((Context) getSystemContext.invoke(thread));
    }

    /**
     * Gives the thread an application info naming the shell package.
     *
     * {@code ActivityThread.currentOpPackageName()} reads it, and so — several
     * layers down — does {@code BluetoothAdapter.getDefaultAdapter()}, which
     * throws outright when it comes back null.
     */
    private static void fillBoundApplication(Class<?> activityThread, Object thread) {
        try {
            Class<?> bindData = Class.forName("android.app.ActivityThread$AppBindData");
            Constructor<?> ctor = bindData.getDeclaredConstructor();
            ctor.setAccessible(true);
            Object data = ctor.newInstance();

            ApplicationInfo info = new ApplicationInfo();
            info.packageName = SHELL_PACKAGE;
            Field appInfo = bindData.getDeclaredField("appInfo");
            appInfo.setAccessible(true);
            appInfo.set(data, info);

            Field bound = activityThread.getDeclaredField("mBoundApplication");
            bound.setAccessible(true);
            bound.set(thread, data);
        } catch (Throwable t) {
            out("bind_warn", describe(t));
        }
    }

    /**
     * The identity the system sees.
     *
     * {@code getOpPackageName} and {@code getAttributionSource} are deliberately
     * declared without {@code @Override}: they are absent from the public SDK
     * this app compiles against, so the annotation would not compile — but the
     * runtime binds by name and descriptor, so they override all the same.
     */
    private static final class ShellContext extends ContextWrapper {

        private AttributionSource source;

        ShellContext(Context base) {
            super(base);
        }

        @Override
        public String getPackageName() {
            return SHELL_PACKAGE;
        }

        public String getOpPackageName() {
            return SHELL_PACKAGE;
        }

        public AttributionSource getAttributionSource() {
            if (source == null) {
                source = new AttributionSource.Builder(Process.myUid())
                        .setPackageName(SHELL_PACKAGE)
                        .build();
            }
            return source;
        }
    }

    private static BluetoothAdapter adapterOf(Context context) {
        try {
            BluetoothManager manager =
                    (BluetoothManager) context.getSystemService(Context.BLUETOOTH_SERVICE);
            if (manager != null && manager.getAdapter() != null) return manager.getAdapter();
        } catch (Throwable t) {
            out("adapter_warn", describe(t));
        }
        try {
            return BluetoothAdapter.getDefaultAdapter();
        } catch (Throwable t) {
            out("adapter_warn", describe(t));
            return null;
        }
    }

    /**
     * Overwrites the attribution source the object will send with the system
     * call, in case the context did not already produce a valid one. Belt and
     * braces: whichever of the two worked, the call goes out as shell.
     */
    private static void patchAttribution(Object target) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return;
        try {
            AttributionSource source = new AttributionSource.Builder(Process.myUid())
                    .setPackageName(SHELL_PACKAGE)
                    .build();
            for (Class<?> type = target.getClass(); type != null; type = type.getSuperclass()) {
                try {
                    Field field = type.getDeclaredField("mAttributionSource");
                    field.setAccessible(true);
                    field.set(target, source);
                    return;
                } catch (NoSuchFieldException ignored) {
                    // Keep walking up; the field moved between releases.
                }
            }
        } catch (Throwable t) {
            out("attribution_warn", describe(t));
        }
    }

    private static BluetoothDevice pickDevice(BluetoothProfile proxy) {
        List<BluetoothDevice> devices;
        try {
            devices = proxy.getConnectedDevices();
        } catch (Throwable t) {
            out("devices_warn", describe(t));
            return null;
        }
        if (devices == null || devices.isEmpty()) return null;
        if (wantedAddress != null && !wantedAddress.isEmpty() && !"-".equals(wantedAddress)) {
            for (BluetoothDevice device : devices) {
                if (wantedAddress.equalsIgnoreCase(device.getAddress())) return device;
            }
        }
        return devices.get(0);
    }

    private static Object codecStatus(BluetoothProfile proxy, BluetoothDevice device) {
        return tryCall(proxy, "getCodecStatus", 1, device);
    }

    private static Method findSetter(Class<?> type) {
        // Two arities exist in the wild: Android 11 added the device argument.
        Method two = method(type, "setCodecConfigPreference", 2);
        return two != null ? two : method(type, "setCodecConfigPreference", 1);
    }

    /**
     * Builds a codec preference that names the codec and nothing else.
     *
     * Sample rate, bit depth and channel mode are deliberately left at zero,
     * which the stack reads as "no preference" and resolves to the best the sink
     * advertises. Pinning them here is how you ask for a combination the
     * headphones cannot do and get silently dropped back to SBC.
     */
    private static Object buildConfig(int codecType, long specific1) throws Exception {
        try {
            Class<?> builderClass = Class.forName("android.bluetooth.BluetoothCodecConfig$Builder");
            Constructor<?> ctor = builderClass.getDeclaredConstructor();
            ctor.setAccessible(true);
            Object builder = ctor.newInstance();
            invokeOn(builderClass, builder, "setCodecType", int.class, codecType);
            invokeOn(builderClass, builder, "setCodecPriority", int.class, PRIORITY_HIGHEST);
            if (specific1 >= 0) {
                invokeOn(builderClass, builder, "setCodecSpecific1", long.class, specific1);
            }
            Method build = builderClass.getDeclaredMethod("build");
            build.setAccessible(true);
            return build.invoke(builder);
        } catch (Throwable t) {
            out("builder_warn", describe(t));
        }

        Class<?> configClass = Class.forName("android.bluetooth.BluetoothCodecConfig");
        Constructor<?> ctor = configClass.getDeclaredConstructor(
                int.class, int.class, int.class, int.class, int.class,
                long.class, long.class, long.class, long.class);
        ctor.setAccessible(true);
        return ctor.newInstance(
                codecType, PRIORITY_HIGHEST, 0, 0, 0,
                specific1 >= 0 ? specific1 : 0L, 0L, 0L, 0L);
    }

    // ------------------------------------------------------------- resultados

    private static void reportConfig(String prefix, Object config) {
        if (config == null) return;
        outIfPresent(prefix + "_codec", config, "getCodecType");
        outIfPresent(prefix + "_specific1", config, "getCodecSpecific1");
        outIfPresent(prefix + "_rate", config, "getSampleRate");
        outIfPresent(prefix + "_bits", config, "getBitsPerSample");
        outIfPresent(prefix + "_channels", config, "getChannelMode");
    }

    private static void reportSelectable(Object status) {
        Object list = tryCall(status, "getCodecsSelectableCapabilities", 0);
        if (!(list instanceof List)) return;
        StringBuilder types = new StringBuilder();
        for (Object entry : (List<?>) list) {
            Object type = tryCall(entry, "getCodecType", 0);
            if (type == null) continue;
            if (types.length() > 0) types.append(',');
            types.append(type);
        }
        out("selectable", types);
    }

    private static void outIfPresent(String key, Object target, String getter) {
        Object value = tryCall(target, getter, 0);
        if (value != null) out(key, value);
    }

    // --------------------------------------------------------------- utiles

    private static Object call(Object target, String name) throws Exception {
        Method m = method(target.getClass(), name, 0);
        if (m == null) throw new NoSuchMethodException(name);
        return m.invoke(target);
    }

    private static <T> T tryCall(Object target, String name, int arity, Object... args) {
        try {
            Method m = method(target.getClass(), name, arity);
            if (m == null) {
                out(name + "_warn", "no existe");
                return null;
            }
            @SuppressWarnings("unchecked")
            T result = (T) m.invoke(target, args);
            // A void method returns null; report the call itself as the success.
            return result == null && m.getReturnType() == void.class ? (T) Boolean.TRUE : result;
        } catch (Throwable t) {
            out(name + "_warn", describe(t));
            return null;
        }
    }

    private static void invokeOn(Class<?> type, Object target, String name, Class<?> arg, Object value)
            throws Exception {
        Method m = type.getDeclaredMethod(name, arg);
        m.setAccessible(true);
        m.invoke(target, value);
    }

    private static Method method(Class<?> type, String name, int arity) {
        for (Class<?> c = type; c != null; c = c.getSuperclass()) {
            for (Method m : c.getDeclaredMethods()) {
                if (m.getName().equals(name) && m.getParameterTypes().length == arity) {
                    m.setAccessible(true);
                    return m;
                }
            }
        }
        return null;
    }

    private static String safeName(BluetoothDevice device) {
        try {
            String name = device.getName();
            return name == null ? "" : name;
        } catch (Throwable t) {
            return "";
        }
    }

    private static int parseInt(String text, int fallback) {
        try {
            return Integer.parseInt(text.trim());
        } catch (Throwable t) {
            return fallback;
        }
    }

    private static long parseLong(String text, long fallback) {
        try {
            return Long.parseLong(text.trim());
        } catch (Throwable t) {
            return fallback;
        }
    }

    private static String describe(Throwable t) {
        Throwable cause = t.getCause() != null ? t.getCause() : t;
        String message = cause.getMessage();
        String name = cause.getClass().getSimpleName();
        return message == null || message.isEmpty() ? name : name + ": " + message;
    }

    private static void out(String key, Object value) {
        String line = "BTJ:" + key + "=" + value;
        System.out.println(line);
        System.out.flush();
        Log.i(TAG, line);
    }

    private static void fail(String message) {
        out("error", message);
        finish(1);
    }

    private static void finish(int code) {
        System.out.flush();
        // halt rather than exit: nothing here owns state worth unwinding, and a
        // stuck shutdown hook would hang the shell command that is waiting on us.
        Runtime.getRuntime().halt(code);
    }

    private Main() {
    }
}
