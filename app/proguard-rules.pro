-dontwarn android.media.audiofx.**

# The privileged half is never called from this app's own code — app_process
# loads it by name out of the APK. To the shrinker it looks like dead code, and
# it is right about everything except that it is the point of the feature.
-keep class com.btjuicer.priv.** { *; }

# The ADB library reflects on its own protocol classes.
-keep class io.github.muntashirakon.adb.** { *; }
-dontwarn io.github.muntashirakon.adb.**
-dontwarn sun.security.**
