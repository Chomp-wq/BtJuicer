# Secret Savior

Bloqueo de pornografía para Android pensado para quien quiere dejarlo: **una vez
activado no se puede desactivar desde el teléfono.** La decisión se toma una vez,
con la cabeza fría, y deja de ser una decisión que haya que volver a ganar cada
noche.

Módulo `:savior` de este repositorio (`com.secretsavior`). Sin servidores propios,
sin cuentas, sin anuncios, sin telemetría.

## Cómo funciona

Cuatro capas, cada una cubre un hueco de la anterior.

| Capa | Qué hace |
|---|---|
| **Filtro DNS** (`VpnService` local) | Captura sólo las consultas DNS del teléfono. Los dominios de la lista local (palabras clave, TLD `.xxx/.porn/.sex/.adult`, ~90 sitios y CDN, redes de anuncios para adultos) reciben `0.0.0.0`. El resto se reenvía a **CleanBrowsing Adult Filter** (185.228.168.10), que bloquea adultos, proxies/VPN de evasión y sitios mixtos, y fuerza búsqueda segura en Google, Bing y YouTube; Cloudflare for Families (1.1.1.3) queda de reserva. Los proveedores de DNS cifrado (DoH) también se bloquean para que el navegador no se salte el filtro. No pasa tu tráfico por ningún servidor. |
| **Guardián** (`AccessibilityService`) | Manda al inicio cualquier pantalla de Ajustes/instalador/VPN que nombre a la app (ficha, desinstalar, administradores, accesibilidad, «Desconectar» VPN) y el campo de DNS privado. Cierra el navegador si apunta a un sitio bloqueado, y **falla cerrado**: si el filtro está caído, los navegadores no funcionan hasta repararlo. Cierra el texto explícito que se escribe. |
| **Administrador del dispositivo** | Mientras la app sea administradora, Android se niega a desinstalarla. Quitarla de la lista es la pantalla que el guardián cierra. |
| **Vigilante** | Cada 10 s, al arrancar y al caerse el filtro, levanta lo que falte. Si otra VPN le quita el permiso o se retira un permiso, trae la app al frente para repararlo. |

El bloqueo no se guarda sólo en las preferencias de la app: si alguien borra los
datos, el administrador sigue activo en el sistema y la app lo detecta como
«bloqueada».

**X / Twitter** se bloquea entera: sus dominios (`twitter.com`, `x.com`, `t.co`,
`twimg.com`…) en el filtro DNS, y la app (`com.twitter.android`) se cierra en cuanto
se abre.

Dentro de la app, con el bloqueo activo: contador de días, botón **«Tengo ganas
ahora mismo»** (respiración 4-7-8 y tu propia razón, escrita por ti), y añadir más
sitios a la lista (sólo se puede añadir, nunca quitar). No hay ninguna acción de
apagar en el código.

## Instalar

CI publica `Secret-Savior.apk` en la release `latest`. En Android 13+, si lo
instalas a mano: **Información de la app → ⋮ → Permitir ajustes restringidos**
antes de activar la accesibilidad. La app te guía en cuatro pasos y exige escribir
una frase de compromiso antes de activar.

## Lo que no hace (honestidad)

Ningún bloqueo en el propio teléfono es imposible de quitar, y esta app no finge
lo contrario:

- **Restablecer de fábrica**, arrancar en **modo seguro** y desinstalar desde un
  ordenador con **ADB** (`adb uninstall`, `dpm remove-active-admin`) lo quitan. Es
  deliberado: son rutas que exigen querer de verdad y no se hacen en un impulso.
- Otro navegador/app con **DNS-sobre-HTTPS por IP fija** o una **VPN** de terceros
  evita el filtro DNS. Una VPN ajena le quita el puesto a la nuestra y los
  navegadores se cierran hasta recuperarlo; una app con DoH propio por IP no se
  detecta.
- El filtro de URL del guardián sólo entiende las barras de direcciones de los
  navegadores conocidos; la lista de palabras es amplia pero no perfecta (puede
  bloquear algo inocente y dejar pasar algo).
- No filtra el contenido de imágenes o vídeo dentro de apps (redes sociales,
  etc.): bloquea sitios y búsquedas, no lo que una app decida mostrar.

Por eso el método real es **combinarlo con una persona**: cuéntaselo a alguien de
confianza. La app sube mucho el esfuerzo; la otra mitad es humana.

## Privacidad

- Salen del teléfono únicamente las consultas DNS que no están bloqueadas, hacia
  CleanBrowsing (o Cloudflare de reserva), como si las hiciera el teléfono sin VPN.
- El guardián lee las pantallas para detectar los casos de arriba. No guarda, no
  registra y no envía nada de lo que ve o escribe. Los campos de contraseña se
  ignoran.
- Lo único que guarda la app: fecha de activación, un contador de bloqueos, tus
  dominios añadidos y tu razón.

## Desarrollo

```
./gradlew :savior:assembleDebug
./gradlew :savior:testDebugUnitTest   # filtro, paquetes DNS/IP y reglas de texto
```

La lógica sin Android (`DnsFilter`, `DnsPacket`, `IpPacket`, `ContentRules`) está
aislada para poder probarla suelta.
