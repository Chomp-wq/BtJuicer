package com.secretsavior.guard

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UrlBarTest {

    @Test
    fun recognisesCommonIds() {
        assertTrue(UrlBar.isUrlBarId("com.foo.browser:id/url_bar"))
        assertTrue(UrlBar.isUrlBarId("com.foo.browser:id/omnibox_text"))
        assertTrue(UrlBar.isUrlBarId("com.foo.browser:id/addressbar_edit"))
        assertTrue(UrlBar.isUrlBarId("com.foo.browser:id/location_bar_edit_text"))
        assertTrue(UrlBar.isUrlBarId("com.foo.browser:id/URLInput"))
    }

    @Test
    fun ignoresOthers() {
        assertFalse(UrlBar.isUrlBarId("com.foo.browser:id/menu_button"))
        assertFalse(UrlBar.isUrlBarId("com.foo.browser:id/tab_switcher"))
        assertFalse(UrlBar.isUrlBarId(null))
        assertFalse(UrlBar.isUrlBarId(""))
    }

    @Test
    fun onlyTheNameCounts_notThePackage() {
        // «url» o «address» en el nombre del paquete no hacen barra de direcciones a cualquier nodo.
        assertFalse(UrlBar.isUrlBarId("com.urlshortener.app:id/title"))
        assertFalse(UrlBar.isUrlBarId("com.address.book:id/button"))
    }
}
