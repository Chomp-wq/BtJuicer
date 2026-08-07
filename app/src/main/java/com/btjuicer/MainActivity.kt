package com.btjuicer

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material.icons.filled.Equalizer
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.MenuBook
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.btjuicer.ui.BTJuicerTheme
import com.btjuicer.ui.CodecScreen
import com.btjuicer.ui.EqScreen
import com.btjuicer.ui.GuideScreen
import com.btjuicer.ui.LinkScreen
import com.btjuicer.ui.MainViewModel
import kotlinx.coroutines.flow.collectLatest

class MainActivity : ComponentActivity() {

    private val viewModel: MainViewModel by viewModels()

    private val requestPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { viewModel.refreshLink() }

    /**
     * Storage Access Framework: the user picks the AutoEq file and the system
     * hands us that one document. No storage permission, no browsing their
     * files — the app only ever sees what they chose.
     */
    private val pickProfile =
        registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
            if (uri == null) return@registerForActivityResult
            val text = runCatching {
                contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() }
            }.getOrNull()
            if (text.isNullOrBlank()) {
                viewModel.notify("No se pudo leer ese archivo")
            } else {
                viewModel.importAutoEq(text)
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Juicer.init(this)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            requestPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }

        // If the EQ was left on, put it back before the first frame so the app
        // never shows "on" while nothing is actually applied.
        if (Juicer.prefs.current.eq.enabled) {
            Juicer.engine.apply(Juicer.prefs.current.eq)
            runCatching { com.btjuicer.service.JuicerService.start(this) }
        }

        setContent {
            BTJuicerTheme {
                Root(viewModel)
            }
        }
    }

    override fun onResume() {
        super.onResume()
        viewModel.refreshLink()
    }

    fun requestBluetooth() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            requestPermission.launch(Manifest.permission.BLUETOOTH_CONNECT)
        }
    }

    fun pickProfileFile() {
        // AutoEq ships .txt, but plenty of file providers report octet-stream.
        runCatching { pickProfile.launch(arrayOf("text/plain", "application/octet-stream", "*/*")) }
            .onFailure { viewModel.notify("No hay ningún selector de archivos disponible") }
    }

    fun openDeveloperOptions() = safeStart(Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS))

    fun openBluetoothSettings() = safeStart(Intent(Settings.ACTION_BLUETOOTH_SETTINGS))

    fun openBatteryOptimization() = safeStart(
        Intent(
            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            Uri.parse("package:$packageName"),
        ),
    )

    private fun safeStart(intent: Intent) {
        runCatching { startActivity(intent) }
            .onFailure {
                // Some ROMs hide these screens; there is nothing to do but say so.
                viewModel.notify("Este teléfono no expone esa pantalla directamente")
            }
    }
}

private enum class Tab(val label: String, val icon: ImageVector) {
    EQ("Ecualizador", Icons.Filled.Equalizer),
    LINK("Salida", Icons.Filled.Bluetooth),
    CODEC("Códec", Icons.Filled.GraphicEq),
    GUIDE("Guía", Icons.Filled.MenuBook),
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Root(viewModel: MainViewModel) {
    var tab by rememberSaveable { mutableIntStateOf(0) }
    val snackbar = remember { SnackbarHostState() }

    val settings by viewModel.settings.collectAsStateWithLifecycle()
    val engine by viewModel.engine.collectAsStateWithLifecycle()
    val link by viewModel.link.collectAsStateWithLifecycle()
    val adb by viewModel.adb.collectAsStateWithLifecycle()
    val codec by viewModel.codec.collectAsStateWithLifecycle()
    val codecError by viewModel.codecError.collectAsStateWithLifecycle()
    val codecWrite by viewModel.codecWrite.collectAsStateWithLifecycle()
    val codecBusy by viewModel.codecBusy.collectAsStateWithLifecycle()
    val profiles by viewModel.profiles.collectAsStateWithLifecycle()

    LaunchedEffect(Unit) {
        viewModel.messages.collectLatest { snackbar.showSnackbar(it) }
    }

    val activity = androidx.compose.ui.platform.LocalContext.current as? MainActivity

    Scaffold(
        topBar = { TopAppBar(title = { Text("BT Juicer") }) },
        snackbarHost = { SnackbarHost(snackbar) },
        bottomBar = {
            NavigationBar {
                Tab.entries.forEachIndexed { index, entry ->
                    NavigationBarItem(
                        selected = tab == index,
                        onClick = { tab = index },
                        icon = { Icon(entry.icon, contentDescription = entry.label) },
                        label = { Text(entry.label) },
                    )
                }
            }
        },
    ) { insets ->
        Box(Modifier.padding(insets)) {
            when (Tab.entries[tab]) {
                Tab.EQ -> EqScreen(
                    settings = settings,
                    engine = engine,
                    profiles = profiles,
                    connectedDeviceName = link.btDeviceName,
                    viewModel = viewModel,
                    onPickFile = { activity?.pickProfileFile() },
                )

                Tab.LINK -> LinkScreen(
                    link = link,
                    onRefresh = viewModel::refreshLink,
                    onRequestBluetooth = { activity?.requestBluetooth() },
                )

                Tab.CODEC -> CodecScreen(
                    settings = settings,
                    adb = adb,
                    codec = codec,
                    codecError = codecError,
                    writeSupport = codecWrite,
                    busy = codecBusy,
                    onPair = viewModel::pairAdb,
                    onConnect = viewModel::connectAdb,
                    onDisconnect = viewModel::disconnectAdb,
                    onForget = viewModel::forgetAdb,
                    onRefresh = viewModel::refreshCodec,
                    onPollChange = viewModel::setPollCodec,
                    onApplyCodec = viewModel::applyCodec,
                    onAutoForceChange = viewModel::setAutoForceCodec,
                    onOpenDeveloperOptions = { activity?.openDeveloperOptions() },
                )

                Tab.GUIDE -> GuideScreen(
                    settings = settings,
                    onRemindChange = viewModel::setRemindOnConnect,
                    onChecklistDone = viewModel::setChecklistDone,
                    onOpenDeveloperOptions = { activity?.openDeveloperOptions() },
                    onOpenBluetooth = { activity?.openBluetoothSettings() },
                    onOpenBattery = { activity?.openBatteryOptimization() },
                )
            }
        }
    }
}
