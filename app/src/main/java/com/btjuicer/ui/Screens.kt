package com.btjuicer.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.btjuicer.bt.LinkInfo
import com.btjuicer.bt.Route
import com.btjuicer.data.Settings

private val Padding = PaddingValues(16.dp)

// --------------------------------------------------------------------- link

@Composable
fun LinkScreen(link: LinkInfo, onRefresh: () -> Unit, onRequestBluetooth: () -> Unit) {
    val dark = isSystemInDarkTheme()

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = Padding,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        item {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp)) {
                    Text("Salida activa", style = MaterialTheme.typography.labelLarge)
                    Text(
                        link.route.label,
                        style = MaterialTheme.typography.headlineSmall,
                        fontFamily = FontFamily.Monospace,
                    )
                    val name = link.btDeviceName.ifEmpty { link.outputName }
                    if (name.isNotEmpty()) {
                        Text(
                            name,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    if (link.a2dpConnected) {
                        Spacer(Modifier.height(6.dp))
                        Text(
                            if (link.playing) "Reproduciendo" else "Conectado, en silencio",
                            style = MaterialTheme.typography.bodySmall,
                            color = if (link.playing) {
                                okColor(dark)
                            } else {
                                MaterialTheme.colorScheme.onSurfaceVariant
                            },
                        )
                    }
                    Spacer(Modifier.height(12.dp))
                    OutlinedButton(onClick = onRefresh) { Text("Actualizar") }
                }
            }
        }

        if (!link.hasBluetoothPermission) {
            item {
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(14.dp)) {
                        Text("Falta un permiso", style = MaterialTheme.typography.titleSmall)
                        Text(
                            "Sin el permiso de dispositivos cercanos no se puede leer el nombre de " +
                                "los audífonos ni asociarles un perfil. El ecualizador funciona igual.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Spacer(Modifier.height(6.dp))
                        Button(onClick = onRequestBluetooth) { Text("Conceder") }
                    }
                }
            }
        }

        item {
            InfoRows(
                listOf(
                    "Mezclador" to (
                        if (link.mixerSampleRateHz > 0) {
                            "%.1f kHz".format(link.mixerSampleRateHz / 1000.0)
                        } else {
                            "—"
                        }
                        ),
                    "Buffer" to (
                        if (link.framesPerBuffer > 0) "${link.framesPerBuffer} frames" else "—"
                        ),
                    "La salida acepta" to (
                        if (link.outputSampleRates.isEmpty()) {
                            "—"
                        } else {
                            link.outputSampleRates.joinToString(", ") {
                                "%.1f".format(it / 1000.0)
                            } + " kHz"
                        }
                        ),
                ),
            )
        }

        if (link.route == Route.BLUETOOTH_A2DP && link.mixerSampleRateHz > 48_000) {
            item {
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(14.dp)) {
                        Text(
                            "Remuestreo innecesario",
                            style = MaterialTheme.typography.titleSmall,
                            color = warnColor(dark),
                        )
                        Text(
                            "El mezclador va a ${"%.1f".format(link.mixerSampleRateHz / 1000.0)} kHz. " +
                                "Casi todo el catálogo de streaming es 44.1; forzar más alto sólo " +
                                "añade una conversión de más.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun InfoRows(rows: List<Pair<String, String>>) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(14.dp)) {
            rows.forEachIndexed { index, (label, value) ->
                if (index > 0) HorizontalDivider(Modifier.padding(vertical = 6.dp))
                Row {
                    Text(
                        label,
                        modifier = Modifier.weight(1f),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text(
                        value,
                        style = MaterialTheme.typography.bodyMedium,
                        fontFamily = FontFamily.Monospace,
                    )
                }
            }
        }
    }
}

// -------------------------------------------------------------------- guide

@Composable
fun GuideScreen(
    settings: Settings,
    onRemindChange: (Boolean) -> Unit,
    onChecklistDone: (Boolean) -> Unit,
    onOpenDeveloperOptions: () -> Unit,
    onOpenBluetooth: () -> Unit,
    onOpenBattery: () -> Unit,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = Padding,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        item {
            Column {
                Text(
                    "Lo que ninguna app puede hacer por ti",
                    style = MaterialTheme.typography.titleMedium,
                )
                Text(
                    "Estos cuatro ajustes son los que más cambian el sonido por Bluetooth, y todos " +
                        "viven fuera del alcance de una app normal. Los botones te dejan en la " +
                        "pantalla exacta.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        item {
            GuideStep(
                number = 1,
                title = "Activa LDAC en la app del fabricante",
                body = "En muchos audífonos —los Technics entre ellos— LDAC viene desactivado de " +
                    "fábrica y hay que encenderlo en su propia app. Si nunca lo tocaste, " +
                    "probablemente llevas tiempo escuchando AAC. Al activarlo se desactiva el " +
                    "multipunto: no caben los dos.",
                actionLabel = null,
                onAction = null,
            )
        }

        item {
            GuideStep(
                number = 2,
                title = "Códec LDAC y 990 kbps",
                body = "Opciones de desarrollador → Códec de audio Bluetooth = LDAC, y " +
                    "«Calidad de reproducción LDAC» = Optimizado para calidad de audio. Android " +
                    "revierte esto a modo adaptativo por su cuenta al reconectar; la pestaña " +
                    "Códec te deja comprobarlo sin adivinar.",
                actionLabel = "Opciones de desarrollador",
                onAction = onOpenDeveloperOptions,
            )
        }

        item {
            GuideStep(
                number = 3,
                title = "Frecuencia 44.1 kHz",
                body = "En la misma pantalla. Casi todo el catálogo lossless es 44.1 kHz; poner " +
                    "96 no añade información, sólo un remuestreo extra y menos margen para el " +
                    "códec. Y en la app de música, elige «Lossless» antes que «Hi-Res»: por " +
                    "Bluetooth el hi-res se va a reducir igualmente.",
                actionLabel = "Ajustes de Bluetooth",
                onAction = onOpenBluetooth,
            )
        }

        item {
            GuideStep(
                number = 4,
                title = "Deja vivir a BT Juicer",
                body = "Sin exención de la optimización de batería, el sistema puede matar el " +
                    "servicio y el ecualizador se desactiva solo.",
                actionLabel = "Eximir de la optimización",
                onAction = onOpenBattery,
            )
        }

        item { HorizontalDivider(Modifier.padding(vertical = 4.dp)) }

        item {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text("Recordar al conectar", style = MaterialTheme.typography.bodyLarge)
                    Text(
                        "Aviso cuando se conecten unos audífonos, con acceso directo a la pantalla " +
                            "del códec.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Spacer(Modifier.width(12.dp))
                Switch(checked = settings.remindOnConnect, onCheckedChange = onRemindChange)
            }
        }

        item {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text("Ya lo revisé", style = MaterialTheme.typography.bodyLarge)
                    Text(
                        "Sólo para tu propio registro.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Spacer(Modifier.width(12.dp))
                Switch(checked = settings.checklistDone, onCheckedChange = onChecklistDone)
            }
        }

        item {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(14.dp)) {
                    Text("Expectativa honesta", style = MaterialTheme.typography.titleSmall)
                    Spacer(Modifier.height(4.dp))
                    Text(
                        "Con LDAC estable a 990 kbps, la diferencia medible frente a un archivo " +
                            "sin pérdida es pequeña. Lo que de verdad domina lo que oyes son el " +
                            "sellado de las almohadillas y la curva del ecualizador. Por eso esta " +
                            "app pone el ecualizador delante y la lista de Bluetooth detrás.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

@Composable
private fun GuideStep(
    number: Int,
    title: String,
    body: String,
    actionLabel: String?,
    onAction: (() -> Unit)?,
) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(14.dp)) {
            Text(
                "$number. $title",
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.height(4.dp))
            Text(
                body,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (actionLabel != null && onAction != null) {
                Spacer(Modifier.height(8.dp))
                Button(onClick = onAction) { Text(actionLabel) }
            }
        }
    }
}
