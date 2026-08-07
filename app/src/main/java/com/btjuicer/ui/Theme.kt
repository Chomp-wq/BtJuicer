package com.btjuicer.ui

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp

/**
 * Rounder than Material's defaults, across the board.
 *
 * One shape set changes every card, button, chip and field at once, which is
 * most of what makes an app look current or dated — and it does it without
 * touching a single screen.
 */
private val JuicerShapes = Shapes(
    extraSmall = RoundedCornerShape(8.dp),
    small = RoundedCornerShape(12.dp),
    medium = RoundedCornerShape(18.dp),
    large = RoundedCornerShape(24.dp),
    extraLarge = RoundedCornerShape(32.dp),
)

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
    MaterialTheme(colorScheme = colors, shapes = JuicerShapes, content = content)
}

/** The one card that should catch the eye on a screen; everything else is plain. */
@Composable
fun heroCardColors() = CardDefaults.cardColors(
    containerColor = MaterialTheme.colorScheme.primaryContainer,
    contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
)

/** Fixed, because these carry meaning a dynamic palette would happily destroy. */
fun okColor(dark: Boolean): Color = if (dark) Color(0xFF6FCF7C) else Color(0xFF2E7D32)

fun warnColor(dark: Boolean): Color = if (dark) Color(0xFFFFB74D) else Color(0xFFEF6C00)

fun badColor(dark: Boolean): Color = if (dark) Color(0xFFEF9A9A) else Color(0xFFC62828)

fun infoColor(dark: Boolean): Color = if (dark) Color(0xFF90CAF9) else Color(0xFF1565C0)
