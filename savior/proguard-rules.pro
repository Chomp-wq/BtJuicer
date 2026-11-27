# El sistema instancia estos componentes por nombre desde el manifiesto.
-keep class com.secretsavior.guard.** { *; }
-keep class com.secretsavior.vpn.** { *; }

# La biblioteca ADB se mira a sí misma por reflexión.
-keep class io.github.muntashirakon.adb.** { *; }
-dontwarn io.github.muntashirakon.adb.**
-dontwarn sun.security.**
