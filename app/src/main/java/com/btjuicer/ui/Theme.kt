package com.btjuicer.ui

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext

@Composable
fun BTJuicerTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val context = LocalContext.current
    val colors = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ->
            if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)

        dark -> darkColorScheme()
        else -> lightColorScheme()
    }
    MaterialTheme(colorScheme = colors, content = content)
}

/** Fixed, because these carry meaning a dynamic palette would happily destroy. */
fun okColor(dark: Boolean): Color = if (dark) Color(0xFF6FCF7C) else Color(0xFF2E7D32)

fun warnColor(dark: Boolean): Color = if (dark) Color(0xFFFFB74D) else Color(0xFFEF6C00)

fun badColor(dark: Boolean): Color = if (dark) Color(0xFFEF9A9A) else Color(0xFFC62828)

fun infoColor(dark: Boolean): Color = if (dark) Color(0xFF90CAF9) else Color(0xFF1565C0)
