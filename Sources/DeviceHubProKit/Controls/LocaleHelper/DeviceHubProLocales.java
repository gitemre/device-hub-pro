import android.content.res.Configuration;
import android.content.res.Resources;
import android.os.LocaleList;

/**
 * Device Hub Pro's device-language helper. Device Hub Pro pushes the compiled dex to
 * /data/local/tmp, runs it as the shell user and deletes it again:
 *
 *   CLASSPATH=/data/local/tmp/devicehubpro-locales.dex app_process / DeviceHubProLocales COMMAND [TAGS]
 *
 * the way scrcpy runs its server. The shell user holds CHANGE_CONFIGURATION and
 * WRITE_SETTINGS on Android 8.0 (API 26) and newer, which is all
 * IActivityManager.updatePersistentConfiguration checks, so the helper changes the
 * system language list exactly as Settings' LocalePicker.updateLocales does: the
 * global configuration, persist.sys.locale and the system_locales setting.
 *
 * Commands (one line per result on stdout):
 *   get          "current TAGS": the global configuration's language list
 *   set TAGS...  replaces the list with TAGS (comma-separated BCP 47 tags, -u-
 *                extensions kept); prints "current OLD" then "applied NEW". With
 *                several lists it pushes each in turn, SETTLE_MILLIS apart: a
 *                second list that keeps the new primary language gives SystemUI's
 *                status-bar clock a configuration change it reads in the settled
 *                language (it can miss the first one and keep the previous
 *                language's time pattern)
 *   repush       pushes the current list again, so the configuration recomputes
 *                its layout direction from debug.force_rtl (what Developer
 *                options' Force RTL switch does); prints "current" and "applied"
 *   supported    the framework's supported_locales, one tag per line (the list
 *                Settings' language picker starts from)
 *
 * Exit status: 0 on success, 2 for a usage error, 3 for an empty language list;
 * an exception from the framework ends the process with its stack trace (status 1).
 * Source of the vendored devicehubpro-locales.dex; rebuild with
 * Scripts/build-locale-helper.sh.
 */
public final class DeviceHubProLocales {
    /** The pause between the pushes of a multi-list `set`. */
    private static final long SETTLE_MILLIS = 1000;

    private DeviceHubProLocales() {
    }

    public static void main(String[] args) throws Exception {
        if (args.length == 0) {
            usage();
            return;
        }
        switch (args[0]) {
            case "get":
                System.out.println("current " + currentLocales(activityManager()).toLanguageTags());
                break;
            case "set":
                if (args.length < 2) {
                    usage();
                    return;
                }
                LocaleList[] lists = new LocaleList[args.length - 1];
                for (int index = 1; index < args.length; index++) {
                    lists[index - 1] = LocaleList.forLanguageTags(args[index]);
                    if (lists[index - 1].isEmpty()) {
                        System.err.println("error: empty language list");
                        System.exit(3);
                        return;
                    }
                }
                Object target = activityManager();
                for (int index = 0; index < lists.length; index++) {
                    if (index > 0) {
                        Thread.sleep(SETTLE_MILLIS);
                    }
                    update(target, lists[index]);
                }
                break;
            case "repush":
                Object manager = activityManager();
                update(manager, currentLocales(manager));
                break;
            case "supported":
                printSupportedLocales();
                break;
            default:
                usage();
        }
    }

    private static void usage() {
        System.err.println("usage: DeviceHubProLocales get | set TAGS [TAGS...] | repush | supported");
        System.exit(2);
    }

    /** IActivityManager, through the hidden ActivityManager.getService() (API 26+). */
    private static Object activityManager() throws Exception {
        return Class.forName("android.app.ActivityManager").getMethod("getService").invoke(null);
    }

    private static LocaleList currentLocales(Object manager) throws Exception {
        Configuration configuration =
            (Configuration) manager.getClass().getMethod("getConfiguration").invoke(manager);
        return configuration.getLocales();
    }

    /**
     * LocalePicker.updateLocales: a configuration carrying only the locales, marked as
     * the user's choice so the system persists it.
     */
    private static void update(Object manager, LocaleList locales) throws Exception {
        System.out.println("current " + currentLocales(manager).toLanguageTags());
        Configuration configuration = new Configuration();
        configuration.setLocales(locales);
        Configuration.class.getField("userSetLocale").setBoolean(configuration, true);
        manager.getClass()
            .getMethod("updatePersistentConfiguration", Configuration.class)
            .invoke(manager, configuration);
        System.out.println("applied " + currentLocales(manager).toLanguageTags());
    }

    private static void printSupportedLocales() {
        Resources resources = Resources.getSystem();
        int id = resources.getIdentifier("supported_locales", "array", "android");
        if (id == 0) {
            System.err.println("error: no supported_locales array");
            System.exit(3);
            return;
        }
        for (String tag : resources.getStringArray(id)) {
            System.out.println(tag);
        }
    }
}
