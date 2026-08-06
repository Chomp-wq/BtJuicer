# Nothing here is reached reflectively, so the defaults are enough.
-dontwarn android.media.audiofx.**

# The ADB library reflects on its own protocol classes.
-keep class io.github.muntashirakon.adb.** { *; }
-dontwarn io.github.muntashirakon.adb.**
-dontwarn sun.security.**
