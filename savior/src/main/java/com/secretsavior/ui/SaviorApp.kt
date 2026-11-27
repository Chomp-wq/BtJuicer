package com.secretsavior.ui

import android.content.Context
import android.os.Build
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.secretsavior.data.Store
import com.secretsavior.guard.Status
import com.secretsavior.provision.ProvisionState
import com.secretsavior.provision.Provisioner
import com.secretsavior.provision.ShellVerdict
import com.secretsavior.vpn.SaviorVpnService
import kotlinx.coroutines.delay
import java.text.DateFormat
import java.util.Date

/** Lo que la pantalla puede pedirle a la actividad. Nótese lo que no hay: ninguna acción de apagar. */
interface Actions {
    fun enableVpn()
    fun openAccessibility()
    fun openAppInfo()
    fun enableAdmin()
    fun openNetworkSettings()
    fun exemptBattery()
    fun openAutostart()
    fun openNotificationAccess()
    fun openVpnSettings()
    fun openAutoRevoke()
    fun openDevOptions()
    fun copy(text: String)
    fun harden(kind: Hardening)
    fun commit()

    /** «Activar con blindaje total»: se marca el compromiso pendiente; lo bloquea AdminReceiver.onEnabled. */
    fun beginOwnerCommit()

    /** Se abandonó el camino de propietaria del dispositivo antes de terminarlo. */
    fun cancelCommit()
}

/** Endurecimientos que se resuelven con un interruptor propio (los demás pasan por ADB). */
enum class Hardening { DEV_OPTIONS, ADB }

private data class Snapshot(
    val locked: Boolean,
    val vpn: Boolean,
    val guard: Boolean,
    val admin: Boolean,
    val notif: Boolean,
    val dnsStrict: Boolean,
    val battery: Boolean,
    /** Xiaomi/Redmi/POCO: el autoencendido de la app se vio activado. En otras marcas no se pide. */
    val autostart: Boolean,
    /** null = no se sabe (no bloquea). */
    val alwaysOn: Boolean?,
    val lockdown: Boolean?,
    val autoRevoke: Boolean,
    val secure: Boolean,
    val owner: Boolean,
    val devBlocked: Boolean,
    val adbBlocked: Boolean,
    val pending: Boolean,
    val days: Long,
    val since: Long,
    val blocked: Int,
    val dns: SaviorVpnService.Companion.DnsHealth?,
) {
    /** Pasos 1–8; lo desconocido (null) no bloquea. */
    val ready get() = vpn && guard && notif && battery && !dnsStrict && autostart && alwaysOn != false && autoRevoke
}

private fun <T> safe(default: T, f: () -> T): T = try { f() } catch (e: Throwable) { default }

private fun read(c: Context) = Snapshot(
    locked = Store.isLocked(c),
    vpn = Status.isVpnRunning(),
    guard = Status.isGuardEnabled(c),
    admin = Status.isAdminActive(c),
    notif = safe(false) { Status.isReviveEnabled(c) },
    dnsStrict = Status.isPrivateDnsStrict(c),
    battery = Status.isBatteryExempt(c),
    autostart = !isXiaomiFamily() || Store.autostartSeen(c),
    alwaysOn = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) safe(null) { Status.isAlwaysOnVpn() } else true,
    lockdown = SaviorVpnService.lockdown,
    autoRevoke = safe(true) { Status.isAutoRevokeExempt(c) },
    secure = safe(false) { Status.hasSecureSettings(c) },
    owner = safe(false) { Status.isDeviceOwner(c) },
    devBlocked = Store.devOptionsBlocked(c),
    adbBlocked = Store.adbBlocked(c),
    pending = Store.pendingCommit(c),
    days = Store.daysLocked(c),
    since = Store.lockedAt(c),
    blocked = Store.blockedCount(c),
    dns = SaviorVpnService.dnsHealth,
)

private fun isXiaomiFamily() = Build.MANUFACTURER.lowercase() in setOf("xiaomi", "redmi", "poco")

@Composable
fun SaviorApp(actions: Actions) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var snap by remember { mutableStateOf(read(context)) }
    // Sólo mientras la pantalla se ve: el estado cambia al volver de Ajustes.
    LaunchedEffect(lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                snap = read(context)
                delay(1000)
            }
        }
    }
    Surface(Modifier.fillMaxSize()) {
        Box(Modifier.safeDrawingPadding()) {
            if (snap.locked) LockedScreen(snap, actions) else SetupScreen(snap, actions)
        }
    }
}

// --- Antes de activar ---------------------------------------------------------------

private const val PHRASE = "ME COMPROMETO"

@Composable
private fun SetupScreen(s: Snapshot, a: Actions) {
    val context = LocalContext.current
    var phrase by rememberSaveable { mutableStateOf("") }
    var understood by rememberSaveable { mutableStateOf(false) }
    var confirm by remember { mutableStateOf(false) }
    var confirmOwner by remember { mutableStateOf(false) }
    var ownerFlow by remember { mutableStateOf(false) }
    var wireless by remember { mutableStateOf<ShellVerdict.Goal?>(null) }
    val canLock = s.ready && understood && phrase.trim().equals(PHRASE, ignoreCase = true)
    var n = 0

    Column(
        Modifier.verticalScroll(rememberScrollState()).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Text("Secret Savior", style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold)
        Text(
            "Un bloqueo de pornografía que, una vez activado, no se puede apagar desde el " +
                "teléfono. Para quien ya decidió dejarlo y sabe que la fuerza de voluntad a las " +
                "tres de la madrugada no es fiable: la decisión se toma ahora, con la cabeza fría.",
            style = MaterialTheme.typography.bodyLarge,
        )

        Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer)) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Lo que tienes que saber", fontWeight = FontWeight.Bold)
                Text("• No habrá botón de desactivar. Ni con contraseña, ni con espera, ni para quien la escribió.")
                Text("• Para quitarla habría que restablecer el teléfono de fábrica, arrancar en modo seguro o usar un ordenador (ADB). Es a propósito: hace falta querer de verdad, no un impulso.")
                Text("• Ningún filtro es perfecto. Esto sube mucho el esfuerzo, no lo hace imposible. Cuéntaselo a alguien de confianza: es la mitad del método.")
                Text("• Nada de lo que escribes o ves sale del teléfono. Sólo las consultas DNS viajan, a un resolutor con filtro familiar.")
            }
        }

        Text("Permisos", style = MaterialTheme.typography.titleLarge)

        Step(
            "${++n}. Filtro de sitios (VPN local)", s.vpn,
            "Intercepta únicamente las consultas DNS: los sitios para adultos no llegan a resolver. " +
                "No pasa tu tráfico por ningún servidor.",
        ) { Button(onClick = a::enableVpn) { Text("Permitir y arrancar") } }

        Step(
            "${++n}. Guardián (Accesibilidad)", s.guard,
            "Cierra las pantallas de Ajustes desde las que se podría apagar todo, y el texto " +
                "explícito. Si Android 13+ lo muestra en gris porque instalaste el APK a mano: " +
                "abre «Información de la app», menú ⋮ y «Permitir ajustes restringidos».",
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = a::openAccessibility) { Text("Abrir accesibilidad") }
                OutlinedButton(onClick = a::openAppInfo) { Text("Info de la app") }
            }
        }

        Step(
            "${++n}. Resurrección (acceso a notificaciones)", s.notif,
            "Si alguien fuerza la detención de la app, Android la vuelve a levantar a los pocos " +
                "segundos gracias a este permiso. No se lee ninguna notificación: ni su contenido " +
                "ni cuáles llegan.",
        ) { Button(onClick = a::openNotificationAccess) { Text("Abrir acceso a notificaciones") } }

        Step(
            "${++n}. Batería sin restricciones", s.battery,
            "Obligatorio: sin esto, Android 12 o superior no deja que la app reinicie el filtro " +
                "desde segundo plano, y muchos fabricantes lo matan para ahorrar batería.",
        ) { Button(onClick = a::exemptBattery) { Text("Excluir de ahorro") } }

        Step(
            "${++n}. Sin DNS privado estricto", !s.dnsStrict,
            if (s.dnsStrict) {
                "Tienes un DNS privado con nombre de host: cifra las consultas y se salta el filtro. " +
                    "Ponlo en «Automático» o «Desactivado» (Ajustes → Red → DNS privado)."
            } else {
                "Todo en orden: el DNS privado no esquiva el filtro."
            },
        ) { if (s.dnsStrict) Button(onClick = a::openNetworkSettings) { Text("Abrir ajustes de red") } }

        if (isXiaomiFamily()) {
            Step(
                "${++n}. Autoencendido (Xiaomi)", s.autostart,
                "Abre la pantalla y comprueba que Secret Savior está activado: la app lo detecta " +
                    "sola (necesita el paso 2). Una vez bloqueado, esa pantalla se cierra para " +
                    "siempre, así que cambia antes el autoencendido de tus otras apps.",
            ) { Button(onClick = a::openAutostart) { Text("Abrir autoencendido") } }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            Step(
                "${++n}. VPN siempre activa", s.alwaysOn == true,
                "En la pantalla de VPN, toca el engranaje junto a Secret Savior y activa «VPN siempre " +
                    "activa». NO actives «Bloquear conexiones sin VPN»: el filtro sólo lleva el DNS y " +
                    "el teléfono podría quedarse sin internet." +
                    if (s.alwaysOn == null) " (Ahora mismo no se puede comprobar: no impide continuar.)" else "",
            ) { Button(onClick = a::openVpnSettings) { Text("Abrir ajustes de VPN") } }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Step(
                "${++n}. Pausar actividad si no se usa", s.autoRevoke,
                "Apaga «Pausar la actividad de la app si no se usa» (o «Quitar permisos si no se usa»). " +
                    "Si no, Android puede detener la app por su cuenta tras semanas sin abrirla.",
            ) { Button(onClick = a::openAutoRevoke) { Text("Abrir permisos de la app") } }
        }

        Step(
            "Opcional, recomendado: autocuración", s.secure,
            "Con un permiso que se da una sola vez por ADB, la app vuelve a encender su propio " +
                "guardián si alguien lo apaga. Desde un ordenador: ${ShellVerdict.pcCommand(ShellVerdict.Goal.SECURE_SETTINGS)}",
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { a.copy(ShellVerdict.pcCommand(ShellVerdict.Goal.SECURE_SETTINGS)) }) { Text("Copiar comando") }
                OutlinedButton(onClick = { wireless = ShellVerdict.Goal.SECURE_SETTINGS }) { Text("Sin ordenador") }
            }
        }

        Card {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("Activar para siempre", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                Text(
                    "Lo último: Android te pedirá que la app sea administradora del dispositivo, y eso " +
                        "es lo que la protege de desinstalarse. Hasta ese momento nada queda fijo.",
                    style = MaterialTheme.typography.bodySmall,
                )
                OutlinedTextField(
                    value = phrase,
                    onValueChange = { phrase = it },
                    label = { Text("Escribe: $PHRASE") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = understood, onCheckedChange = { understood = it })
                    Text("Entiendo que no podré desactivarlo desde el teléfono.", Modifier.weight(1f))
                }
                Button(onClick = { confirm = true }, enabled = canLock, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Filled.Lock, null)
                    Spacer(Modifier.size(8.dp))
                    Text("Activar y bloquear")
                }
                OutlinedButton(onClick = { confirmOwner = true }, enabled = canLock, modifier = Modifier.fillMaxWidth()) {
                    Text("Activar con blindaje total")
                }
                Text(
                    "Igual que lo anterior pero haciendo a la app propietaria del dispositivo (sin forzar " +
                        "detención, sin modo seguro). Pide quitar antes las cuentas y el Segundo espacio.",
                    style = MaterialTheme.typography.bodySmall,
                )
                if (!s.ready) {
                    Text(
                        "Faltan permisos por conceder arriba.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error,
                    )
                }
                if (s.pending) {
                    Text(
                        "Esperando la confirmación de Android para el administrador…",
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
        }
    }

    if (confirm) {
        AlertDialog(
            onDismissRequest = { confirm = false },
            title = { Text("¿Seguro?") },
            text = {
                Text(
                    "Después de esto no hay marcha atrás desde la app. Si ahora mismo dudas, " +
                        "espera: nada se pierde por activarlo mañana.",
                )
            },
            confirmButton = {
                Button(onClick = { confirm = false; a.commit() }) { Text("Sí, activar") }
            },
            dismissButton = { TextButton(onClick = { confirm = false }) { Text("Todavía no") } },
        )
    }
    if (confirmOwner) {
        AlertDialog(
            onDismissRequest = { confirmOwner = false },
            title = { Text("¿Seguro?") },
            text = {
                Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(
                        "Después de esto no hay marcha atrás desde la app. Si ahora mismo dudas, " +
                            "espera: nada se pierde por activarlo mañana.",
                    )
                    Text(
                        "Para ser propietaria del dispositivo Android exige que no haya NINGUNA cuenta ni " +
                            "«Segundo espacio» / «Apps duales» / otros usuarios: quítalos antes (con el bloqueo " +
                            "activo esas pantallas se cierran y ya no se podrá). Después puedes volver a añadir " +
                            "tus cuentas y apps duales. El bloqueo empieza en cuanto lo sea.",
                    )
                }
            },
            confirmButton = {
                Button(onClick = { confirmOwner = false; a.beginOwnerCommit(); ownerFlow = true }) {
                    Text("Sí, activar")
                }
            },
            dismissButton = { TextButton(onClick = { confirmOwner = false }) { Text("Todavía no") } },
        )
    }
    if (ownerFlow) {
        val goal = ShellVerdict.Goal.DEVICE_OWNER
        AlertDialog(
            onDismissRequest = { ownerFlow = false; a.cancelCommit() },
            title = { Text("Activar con blindaje total") },
            text = {
                Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("Con ordenador:", fontWeight = FontWeight.Bold)
                    Text(ShellVerdict.pcCommand(goal), style = MaterialTheme.typography.bodySmall)
                    Text(
                        if (isXiaomiFamily()) {
                            "En Xiaomi, activa antes «Depuración USB (ajustes de seguridad)» en Opciones de desarrollador."
                        } else {
                            "Sin cuentas ni Segundo espacio, o Android lo rechazará."
                        },
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            },
            confirmButton = {
                Row {
                    TextButton(onClick = { a.copy(ShellVerdict.pcCommand(goal)) }) { Text("Copiar comando") }
                    TextButton(onClick = { ownerFlow = false; wireless = goal }) { Text("Sin ordenador") }
                }
            },
            dismissButton = { TextButton(onClick = { ownerFlow = false; a.cancelCommit() }) { Text("Cancelar") } },
        )
    }
    wireless?.let { goal ->
        WirelessDialog(goal, s.devBlocked, a) {
            wireless = null
            Provisioner.reset(context)
            if (goal == ShellVerdict.Goal.DEVICE_OWNER) a.cancelCommit()
        }
    }
}

@Composable
private fun Step(title: String, done: Boolean, text: String, action: @Composable () -> Unit) {
    Card {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(
                    if (done) Icons.Filled.CheckCircle else Icons.Filled.Warning,
                    contentDescription = if (done) "Hecho" else "Pendiente",
                    tint = if (done) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline,
                )
                Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
            }
            Text(text, style = MaterialTheme.typography.bodyMedium)
            if (!done) action()
        }
    }
}

// --- Con el bloqueo activo ----------------------------------------------------------

private enum class Harden { SECURE, OWNER, DEV, ADB }

@Composable
private fun LockedScreen(s: Snapshot, a: Actions) {
    val context = LocalContext.current
    val isXiaomi = isXiaomiFamily()
    var urge by remember { mutableStateOf(false) }
    var reason by remember { mutableStateOf(Store.reason(context)) }
    var domain by remember { mutableStateOf("") }
    var domainMsg by remember { mutableStateOf<String?>(null) }
    var harden by remember { mutableStateOf<Harden?>(null) }

    Column(
        Modifier.verticalScroll(rememberScrollState()).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer)) {
            Column(Modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text("Protección activa", style = MaterialTheme.typography.titleMedium)
                Text("${s.days}", fontSize = 72.sp, fontWeight = FontWeight.Bold)
                Text(if (s.days == 1L) "día" else "días", style = MaterialTheme.typography.titleLarge)
                if (s.since > 0) {
                    Text(
                        "desde el ${DateFormat.getDateInstance().format(Date(s.since))}",
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
        }

        Button(onClick = { urge = true }, modifier = Modifier.fillMaxWidth().height(56.dp)) {
            Text("Tengo ganas ahora mismo", fontSize = 18.sp)
        }

        if (s.lockdown == true) {
            Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer)) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("«Bloquear conexiones sin VPN» está activado", fontWeight = FontWeight.Bold)
                    Text(
                        "El filtro sólo lleva el DNS: con esa opción el teléfono puede quedarse sin " +
                            "internet. Apágala en Ajustes → VPN → engranaje de Secret Savior (deja " +
                            "«VPN siempre activa» encendida).",
                        style = MaterialTheme.typography.bodySmall,
                    )
                    OutlinedButton(onClick = a::openVpnSettings) { Text("Abrir ajustes de VPN") }
                }
            }
        }

        Card {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Estado", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                StatusRow("Filtro de sitios", s.vpn, a::enableVpn)
                StatusRow("Guardián", s.guard, a::openAccessibility)
                StatusRow("Resurrección", s.notif, a::openNotificationAccess)
                StatusRow("Anti-desinstalación", s.admin, a::enableAdmin)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && s.alwaysOn != null) {
                    StatusRow("VPN siempre activa", s.alwaysOn, a::openVpnSettings)
                }
                StatusRow("Sin ahorro de batería", s.battery, a::exemptBattery)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    StatusRow("Sin pausa por inactividad", s.autoRevoke, a::openAutoRevoke)
                }
                StatusRow("Autocuración (opcional)", s.secure, { harden = Harden.SECURE }, optional = true)
                StatusRow("Propietario del dispositivo (opcional)", s.owner, { harden = Harden.OWNER }, optional = true)
                if (s.dnsStrict) StatusRow("DNS privado estricto (esquiva el filtro)", false, a::openNetworkSettings)
                Text("${s.blocked} sitios bloqueados hasta hoy", style = MaterialTheme.typography.bodySmall)
                s.dns?.let { dns ->
                    // Menos de ~80 ms no se nota; por encima de ~250 ms el resolutor está lejos o la red va mal.
                    val slow = dns.averageMs > 250
                    Text(
                        when {
                            dns.broken ->
                                "El DNS no responde (${dns.recentFailed} de las últimas ${dns.recentTotal} consultas). " +
                                    "Si pasa sólo en una red, esa red bloquea DNS externo (hoteles, trabajo, colegio); " +
                                    "si pasa en todas, comprueba que Secret Savior tenga acceso a datos y Wi-Fi en " +
                                    "Seguridad → Uso de datos."
                            dns.recentTotal == 0 -> "DNS: todo desde caché"
                            slow -> "DNS: ${dns.averageMs} ms de media (lento: puede ser la red)" + (dns.cachePercent?.let { " · $it % desde caché" } ?: "")
                            else -> "DNS: ${dns.averageMs} ms de media" + (dns.cachePercent?.let { " · $it % desde caché" } ?: "")
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = if (dns.broken || slow) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }

        Card {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Siempre activo", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                Text(
                    "El filtro sigue aunque cierres la app: va en primer plano con una notificación fija. " +
                        "Si alguien fuerza su detención, el acceso a notificaciones hace que Android la vuelva a levantar.",
                    style = MaterialTheme.typography.bodySmall,
                )
                if (isXiaomi) {
                    Text(
                        "Xiaomi / Redmi / POCO: el autoencendido de esta app queda fijado, y su pantalla " +
                            "de ajustes se cierra mientras dure el bloqueo.",
                        style = MaterialTheme.typography.bodySmall,
                    )
                    Text(
                        "Y en Recientes, mantén pulsada la tarjeta de la app y toca el candado: así " +
                            "«Limpiar» no la cierra.",
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
        }

        HardenCard(s) { harden = it }

        Card {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Mi razón", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                Text("La verás cuando pulses «Tengo ganas». Escríbela tú, con tus palabras.", style = MaterialTheme.typography.bodySmall)
                OutlinedTextField(
                    value = reason,
                    onValueChange = { reason = it.take(600); Store.setReason(context, reason) },
                    modifier = Modifier.fillMaxWidth(),
                    minLines = 2,
                )
            }
        }

        Card {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Bloquear otro sitio", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                Text("Se pueden añadir sitios, nunca quitarlos.", style = MaterialTheme.typography.bodySmall)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(
                        value = domain,
                        onValueChange = { domain = it; domainMsg = null },
                        placeholder = { Text("ejemplo.com") },
                        singleLine = true,
                        modifier = Modifier.weight(1f),
                    )
                    Button(onClick = {
                        domainMsg = if (Store.addDomain(context, domain)) {
                            domain = ""
                            "Añadido."
                        } else {
                            "Eso no parece un dominio."
                        }
                    }) { Text("Añadir") }
                }
                domainMsg?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
            }
        }

        Text(
            "No hay botón para desactivar esta protección. Es a propósito.",
            style = MaterialTheme.typography.bodySmall,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
    }

    if (urge) UrgeDialog(reason) { urge = false }
    harden?.let { HardenDialog(it, s, a) { harden = null } }
}

/** «Endurecer más»: cada botón es de ida y antes pide confirmación que lo dice. */
@Composable
private fun HardenCard(s: Snapshot, open: (Harden) -> Unit) {
    if (s.secure && s.owner && s.devBlocked && s.adbBlocked) return
    Card {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Endurecer más", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
            Text(
                "Cada una de estas medidas sólo se puede encender, nunca apagar. Antes se explica lo que no se puede deshacer.",
                style = MaterialTheme.typography.bodySmall,
            )
            if (!s.secure) OutlinedButton(onClick = { open(Harden.SECURE) }, Modifier.fillMaxWidth()) { Text("Autocuración") }
            if (!s.owner) OutlinedButton(onClick = { open(Harden.OWNER) }, Modifier.fillMaxWidth()) { Text("Blindaje total (propietaria del dispositivo)") }
            if (!s.devBlocked) OutlinedButton(onClick = { open(Harden.DEV) }, Modifier.fillMaxWidth()) { Text("Cerrar opciones de desarrollador") }
            if (s.owner && !s.adbBlocked) OutlinedButton(onClick = { open(Harden.ADB) }, Modifier.fillMaxWidth()) { Text("Prohibir ADB para siempre") }
        }
    }
}

@Composable
private fun HardenDialog(kind: Harden, s: Snapshot, a: Actions, close: () -> Unit) {
    val context = LocalContext.current
    var wireless by remember { mutableStateOf<ShellVerdict.Goal?>(null) }
    var confirmWireless by remember { mutableStateOf(false) }
    val goal = if (kind == Harden.SECURE) ShellVerdict.Goal.SECURE_SETTINGS else ShellVerdict.Goal.DEVICE_OWNER

    wireless?.let { g ->
        WirelessDialog(g, s.devBlocked, a) {
            wireless = null
            Provisioner.reset(context)
            close()
        }
        return
    }

    when (kind) {
        Harden.SECURE, Harden.OWNER -> AlertDialog(
            onDismissRequest = close,
            title = { Text(if (kind == Harden.SECURE) "Autocuración" else "Blindaje total") },
            text = {
                Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    if (kind == Harden.SECURE) {
                        Text(
                            "Un permiso que se concede una vez por ADB. Con él, si alguien apaga el guardián, " +
                                "la app lo vuelve a encender sola.",
                        )
                    } else {
                        Text(
                            "Secret Savior pasa a ser propietaria del dispositivo. Eso impide: forzar la " +
                                "detención o borrar los datos de la app, el modo seguro, restablecer desde " +
                                "Ajustes, crear otros usuarios y cambiar la VPN.",
                        )
                        Text("Antes de empezar:", fontWeight = FontWeight.Bold)
                        Text(
                            "• Quita temporalmente TODAS las cuentas (Ajustes → Cuentas: Google, Xiaomi y las " +
                                "de apps como WhatsApp o Telegram).\n" +
                                "• Sin «Segundo espacio» ni «Apps duales» ni otros usuarios: bórralos antes de bloquear. " +
                                "Una vez bloqueado, esa pantalla ya no se puede abrir (se cierra a propósito), así que " +
                                "si existe uno, no podrás hacerla propietaria desde aquí.\n" +
                                (if (isXiaomiFamily()) "• En Xiaomi, activa «Depuración USB (ajustes de seguridad)» en Opciones de desarrollador.\n" else "") +
                                "• Después vuelve a añadir tus cuentas.",
                        )
                        Text(
                            "No se puede deshacer: después, la única salida es restablecer el teléfono de fábrica " +
                                "desde el modo recovery, y eso borra todo.",
                            fontWeight = FontWeight.Bold,
                            color = MaterialTheme.colorScheme.error,
                        )
                    }
                    Text("Con ordenador:", fontWeight = FontWeight.Bold)
                    Text(ShellVerdict.pcCommand(goal), style = MaterialTheme.typography.bodySmall)
                }
            },
            confirmButton = {
                Row {
                    TextButton(onClick = { a.copy(ShellVerdict.pcCommand(goal)) }) { Text("Copiar comando") }
                    TextButton(
                        onClick = { if (kind == Harden.OWNER) confirmWireless = true else wireless = goal },
                    ) { Text("Sin ordenador") }
                }
            },
            dismissButton = { TextButton(onClick = close) { Text("Cancelar") } },
        )

        Harden.DEV -> ConfirmOneWay(
            "¿Cerrar las opciones de desarrollador?",
            "Mientras dure el bloqueo, Opciones de desarrollador se cierra en cuanto se abre. Es la vía " +
                "para usar ADB, así que no se podrá deshacer.\n\nTen en cuenta que también corta la " +
                "depuración inalámbrica de BT Juicer (sus funciones de códec la necesitan) y el vinculado " +
                "sin ordenador de esta app. Si aún quieres usar cualquiera de las dos, hazlo antes.",
            "Sí, cerrarlas", { a.harden(Hardening.DEV_OPTIONS); close() }, close,
        )

        Harden.ADB -> ConfirmOneWay(
            "¿Prohibir ADB para siempre?",
            "Como propietaria del dispositivo, Android deja de permitir la depuración USB e inalámbrica. " +
                "No se podrá deshacer: ni tú ni BT Juicer ni esta app podréis usar ADB nunca más, salvo " +
                "restableciendo el teléfono de fábrica.",
            "Sí, prohibirlo", { a.harden(Hardening.ADB); close() }, close,
        )
    }

    if (confirmWireless) {
        ConfirmOneWay(
            "¿Hacerla propietaria ahora?",
            "No se puede deshacer. Después, la única salida es restablecer el teléfono de fábrica " +
                "(modo recovery), que borra todo. ¿Has quitado ya todas las cuentas?",
            "Sí, continuar", { confirmWireless = false; wireless = goal }, { confirmWireless = false },
        )
    }
}

@Composable
private fun ConfirmOneWay(title: String, text: String, yes: String, onYes: () -> Unit, onNo: () -> Unit) {
    AlertDialog(
        onDismissRequest = onNo,
        title = { Text(title) },
        text = { Text(text, Modifier.verticalScroll(rememberScrollState())) },
        confirmButton = { Button(onClick = onYes) { Text(yes) } },
        dismissButton = { TextButton(onClick = onNo) { Text("Todavía no") } },
    )
}

/** Guía de la vinculación sin ordenador; el código se escribe en una notificación (ver Provisioner). */
@Composable
private fun WirelessDialog(goal: ShellVerdict.Goal, devBlocked: Boolean, a: Actions, close: () -> Unit) {
    val context = LocalContext.current
    val state by Provisioner.state.collectAsState()
    val paired = remember { Provisioner.alreadyPaired(context) }

    AlertDialog(
        onDismissRequest = { if (state !is ProvisionState.Working) close() },
        title = { Text("Sin ordenador") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                when (val st = state) {
                    is ProvisionState.Working -> Text("${st.step}\n\nNo cierres la app.")
                    is ProvisionState.Done -> Text(st.message)
                    else -> {
                        if (devBlocked) {
                            Text("Las opciones de desarrollador están cerradas: esto ya no es posible sin ordenador.")
                        } else {
                            Text(
                                "1. Abre Opciones de desarrollador y activa «Depuración inalámbrica» " +
                                    "(necesita Wi-Fi). Si no ves las opciones: Ajustes → Acerca del teléfono, " +
                                    "toca siete veces el número de compilación.",
                            )
                            OutlinedButton(onClick = a::openDevOptions) { Text("Abrir opciones de desarrollador") }
                            Text(
                                "2. Entra en «Depuración inalámbrica» y toca «Vincular dispositivo con código». " +
                                    "Esa ventana se cierra si sales de Ajustes: déjala abierta.",
                            )
                            Text(
                                "3. Pulsa «Preparar el código» aquí abajo, vuelve a Ajustes y, con la ventana " +
                                    "abierta, baja las notificaciones: toca «Escribir el código» y teclea las " +
                                    "6 cifras.",
                            )
                            if (state is ProvisionState.WaitingCode) {
                                Text("Esperando el código en la notificación…", fontWeight = FontWeight.Bold)
                            }
                            if (paired) {
                                Text("Este teléfono ya estaba vinculado: puedes probar sin código.", style = MaterialTheme.typography.bodySmall)
                            }
                        }
                    }
                }
            }
        },
        confirmButton = {
            when (state) {
                is ProvisionState.Working -> {}
                is ProvisionState.Done -> TextButton(onClick = close) { Text("Cerrar") }
                else -> if (!devBlocked) {
                    Row {
                        if (paired) TextButton(onClick = { Provisioner.runPaired(context, goal) }) { Text("Ya vinculado") }
                        Button(onClick = { Provisioner.begin(context, goal) }) { Text("Preparar el código") }
                    }
                }
            }
        },
        dismissButton = {
            if (state !is ProvisionState.Working && state !is ProvisionState.Done) {
                TextButton(onClick = close) { Text("Cancelar") }
            }
        },
    )
}

@Composable
private fun StatusRow(label: String, ok: Boolean?, repair: () -> Unit, optional: Boolean = false) {
    val good = ok == true
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Icon(
            if (good) Icons.Filled.CheckCircle else Icons.Filled.Warning,
            contentDescription = if (good) "Activo" else "Caído",
            tint = when {
                good -> MaterialTheme.colorScheme.primary
                optional -> MaterialTheme.colorScheme.outline
                else -> MaterialTheme.colorScheme.error
            },
        )
        Spacer(Modifier.size(8.dp))
        Text(label, Modifier.weight(1f))
        // Reparar es volver a conceder lo que se cayó; nunca apagar.
        if (!good) TextButton(onClick = repair) { Text(if (optional) "Activar" else "Reparar") }
    }
}

/** Respiración 4-7-8, la razón propia y una lista corta de cosas que cambian de sitio el cuerpo. */
@Composable
private fun UrgeDialog(reason: String, onClose: () -> Unit) {
    var label by remember { mutableStateOf("Inhala") }
    var count by remember { mutableStateOf(4) }

    LaunchedEffect(Unit) {
        while (true) {
            for ((name, seconds) in listOf("Inhala" to 4, "Sostén" to 7, "Exhala" to 8)) {
                for (t in seconds downTo 1) {
                    label = name
                    count = t
                    delay(1000)
                }
            }
        }
    }
    val size by animateDpAsState(
        targetValue = if (label == "Exhala") 80.dp else 150.dp,
        animationSpec = tween(if (label == "Sostén") 300 else if (label == "Exhala") 8000 else 4000),
        label = "respiración",
    )

    AlertDialog(
        onDismissRequest = onClose,
        title = { Text("Esto pasa") },
        text = {
            Column(
                Modifier.verticalScroll(rememberScrollState()),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text("Una ola de ganas dura unos minutos y baja sola. No tienes que ganarle: sólo esperarla.")
                Box(Modifier.height(160.dp), contentAlignment = Alignment.Center) {
                    Column(
                        Modifier.size(size).clip(CircleShape).background(MaterialTheme.colorScheme.primaryContainer),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center,
                    ) {
                        Text(label, fontWeight = FontWeight.Bold)
                        Text("$count", fontSize = 28.sp)
                    }
                }
                if (reason.isNotBlank()) {
                    Card {
                        Column(Modifier.padding(12.dp)) {
                            Text("Tu razón", fontWeight = FontWeight.Bold)
                            Text(reason)
                        }
                    }
                }
                Text(
                    "Mientras tanto: levántate, sal de la habitación, deja el móvil lejos, bebe un vaso de " +
                        "agua, haz veinte flexiones o llama a alguien. Cambiar de sitio al cuerpo cambia el " +
                        "pensamiento.",
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
        },
        confirmButton = { Button(onClick = onClose) { Text("Ya pasó") } },
    )
}
