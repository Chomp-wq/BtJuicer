# Los componentes del manifiesto (servicios, receptores, actividad) los conserva aapt solo.

# La biblioteca ADB se mira a sí misma por reflexión.
-keep class io.github.muntashirakon.adb.** { *; }
-dontwarn io.github.muntashirakon.adb.**
-dontwarn sun.security.**

# provision/AdbBridge.kt busca por reflexión setApi() en la clase base de la biblioteca (ya conservada arriba).
