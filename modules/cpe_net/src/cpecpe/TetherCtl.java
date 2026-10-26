package cpecpe;

import android.content.Context;
import android.net.TetheringManager;

import java.lang.reflect.Method;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executor;
import java.util.concurrent.TimeUnit;

/**
 * 用 app_process 以 root 身份调 TetheringManager，拉起 / 停掉「以太网网络共享」。
 *
 * 背景：ColorOS 的以太网网络共享只能靠 UI 开关；`cmd tethering` / `cmd ethernet` 没有
 * shell 实现，`service call` 又传不了 Parcelable。所以这里直接走公开 API。
 *
 * 用法：app_process 跑本类，参数 start | stop
 * 输出：RESULT:... 一行，给 shell 判读
 */
public final class TetherCtl {

    /** 直接在当前线程跑回调，省掉 Handler/Looper */
    private static final Executor DIRECT = new Executor() {
        @Override public void execute(Runnable r) { r.run(); }
    };

    /**
     * TETHERING_ETHERNET 是 @SystemApi，公开 SDK 里被剥掉了，编译期拿不到。
     * 运行期框架里它是 public 字段，反射取真值；取不到就用 AOSP 里写死的 5。
     */
    private static int tetheringEthernet() {
        try {
            java.lang.reflect.Field f = TetheringManager.class.getField("TETHERING_ETHERNET");
            return f.getInt(null);
        } catch (Throwable ignored) {
            return 5;
        }
    }

    public static void main(String[] args) {
        String mode = (args != null && args.length > 0) ? args[0] : "start";
        try {
            // app_process 的主线程默认没有 Looper，ActivityThread / ContextImpl 建 Handler 会炸
            prepareLooper();

            Context ctx = obtainContext();
            if (ctx == null) {
                emit("ERR no-context");
                return;
            }

            TetheringManager tm = ctx.getSystemService(TetheringManager.class);
            if (tm == null) {
                emit("ERR no-tethering-service");
                return;
            }

            if ("stop".equals(mode)) {
                doStop(tm);
            } else if ("probe".equals(mode)) {
                doProbe(tm);
            } else {
                doStart(tm);
            }
        } catch (Throwable t) {
            emit("ERR " + t.getClass().getName() + ": " + t.getMessage());
        }
    }

    /** 把框架里的常量名和当前共享状态都读出来，用来对照错误码 */
    private static void doProbe(TetheringManager tm) {
        try {
            for (java.lang.reflect.Field f : TetheringManager.class.getFields()) {
                String n = f.getName();
                if (n.startsWith("TETHER_ERROR_") || n.startsWith("TETHERING_")) {
                    emit("CONST " + n + " = " + f.getInt(null));
                }
            }
        } catch (Throwable t) {
            emit("DBG consts: " + t);
        }

        try {
            Method m = TetheringManager.class.getMethod("getTetheredIfaces");
            Object r = m.invoke(tm);
            emit("TETHERED_IFACES " + java.util.Arrays.toString((Object[]) r));
        } catch (Throwable t) {
            emit("DBG getTetheredIfaces: " + t.getClass().getName() + ": " + t.getMessage());
        }

        try {
            Method m = TetheringManager.class.getMethod("getTetherableIfaces");
            Object r = m.invoke(tm);
            emit("TETHERABLE_IFACES " + java.util.Arrays.toString((Object[]) r));
        } catch (Throwable t) {
            emit("DBG getTetherableIfaces: " + t.getClass().getName() + ": " + t.getMessage());
        }

        emit("DONE");
    }

    private static void doStart(TetheringManager tm) throws Exception {
        final CountDownLatch latch = new CountDownLatch(1);
        final String[] result = {null};

        TetheringManager.StartTetheringCallback cb = new TetheringManager.StartTetheringCallback() {
            @Override public void onTetheringStarted() {
                result[0] = "STARTED";
                latch.countDown();
            }
            @Override public void onTetheringFailed(int error) {
                result[0] = "FAILED error=" + error;
                latch.countDown();
            }
        };

        TetheringManager.TetheringRequest req =
                new TetheringManager.TetheringRequest.Builder(tetheringEthernet())
                        .build();

        tm.startTethering(req, DIRECT, cb);

        if (latch.await(12, TimeUnit.SECONDS)) {
            emit(result[0] != null ? result[0] : "UNKNOWN");
        } else {
            // 没有回调：很可能本来就已经开着，状态没变化所以不通知
            emit("TIMEOUT");
        }
    }

    private static void doStop(TetheringManager tm) throws Exception {
        final CountDownLatch latch = new CountDownLatch(1);
        final String[] result = {null};

        TetheringManager.StopTetheringCallback cb = new TetheringManager.StopTetheringCallback() {
            @Override public void onStopTetheringSucceeded() {
                result[0] = "STOPPED";
                latch.countDown();
            }
            @Override public void onStopTetheringFailed(int error) {
                result[0] = "STOPFAILED error=" + error;
                latch.countDown();
            }
        };

        TetheringManager.TetheringRequest req =
                new TetheringManager.TetheringRequest.Builder(tetheringEthernet())
                        .build();

        tm.stopTethering(req, DIRECT, cb);

        if (latch.await(12, TimeUnit.SECONDS)) {
            emit(result[0] != null ? result[0] : "UNKNOWN");
        } else {
            emit("TIMEOUT");
        }
    }

    /**
     * 拿一个系统 Context。app_process 里没有 Application，标准做法是反射
     * ActivityThread.systemMain().getSystemContext()。
     */
    private static Context obtainContext() {
        // 路子 1：ActivityThread.systemMain().getSystemContext()
        try {
            Class<?> at = Class.forName("android.app.ActivityThread");
            Method systemMain = at.getDeclaredMethod("systemMain");
            systemMain.setAccessible(true);
            Object thread = systemMain.invoke(null);
            if (thread != null) {
                Method getSystemContext = at.getDeclaredMethod("getSystemContext");
                getSystemContext.setAccessible(true);
                Object c = getSystemContext.invoke(thread);
                if (c instanceof Context) return (Context) c;
                emit("DBG 1: getSystemContext 返回 " + (c == null ? "null" : c.getClass().getName()));
            } else {
                emit("DBG 1: systemMain 返回 null");
            }
        } catch (Throwable t) {
            Throwable cause = (t instanceof java.lang.reflect.InvocationTargetException && t.getCause() != null)
                    ? t.getCause() : t;
            emit("DBG 1 failed: " + cause.getClass().getName() + ": " + cause.getMessage());
        }

        // 路子 2：currentActivityThread().getSystemContext()
        try {
            Class<?> at = Class.forName("android.app.ActivityThread");
            Method current = at.getDeclaredMethod("currentActivityThread");
            current.setAccessible(true);
            Object thread = current.invoke(null);
            if (thread != null) {
                Method getSystemContext = at.getDeclaredMethod("getSystemContext");
                getSystemContext.setAccessible(true);
                Object c = getSystemContext.invoke(thread);
                if (c instanceof Context) return (Context) c;
            } else {
                emit("DBG 2: currentActivityThread 返回 null");
            }
        } catch (Throwable t) {
            emit("DBG 2 failed: " + t.getClass().getName() + ": " + t.getMessage());
        }

        // 路子 3：自己 new 一个 ActivityThread，再 ContextImpl.createSystemContext(thread)
        try {
            Class<?> at = Class.forName("android.app.ActivityThread");
            java.lang.reflect.Constructor<?> ctor = at.getDeclaredConstructor();
            ctor.setAccessible(true);
            Object thread = ctor.newInstance();

            Class<?> ci = Class.forName("android.app.ContextImpl");
            Method create = ci.getDeclaredMethod("createSystemContext", at);
            create.setAccessible(true);
            Object c = create.invoke(null, thread);
            if (c instanceof Context) return (Context) c;
            emit("DBG 3: createSystemContext 返回 " + (c == null ? "null" : c.getClass().getName()));
        } catch (Throwable t) {
            Throwable cause = (t instanceof java.lang.reflect.InvocationTargetException && t.getCause() != null)
                    ? t.getCause() : t;
            emit("DBG 3 failed: " + cause.getClass().getName() + ": " + cause.getMessage());
        }

        return null;
    }

    private static void prepareLooper() {
        try {
            Class<?> looper = Class.forName("android.os.Looper");
            Method myLooper = looper.getMethod("myLooper");
            if (myLooper.invoke(null) == null) {
                try {
                    looper.getMethod("prepareMainLooper").invoke(null);
                } catch (Throwable t) {
                    looper.getMethod("prepare").invoke(null);
                }
            }
        } catch (Throwable t) {
            emit("DBG looper: " + t.getClass().getName() + ": " + t.getMessage());
        }
    }

    private static void emit(String s) {
        System.out.println("RESULT:" + s);
        System.out.flush();
    }

    private TetherCtl() {}
}
