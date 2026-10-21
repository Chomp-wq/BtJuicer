package com.secretsavior.vpn

/**
 * Decide si un nombre de dominio se bloquea. Sin Android a propósito: es lógica
 * pura y se puede probar suelta.
 *
 * Es la primera de dos capas. La segunda es el resolutor aguas arriba (ver
 * [SaviorVpnService.UPSTREAMS]), que ya filtra millones de dominios; esta lista
 * local existe para lo que se le escape y para que el bloqueo siga siendo
 * inmediato aunque el resolutor no conteste.
 */
object DnsFilter {

    /** Dominios que el usuario añade él mismo. Sólo se pueden añadir, nunca quitar. */
    @Volatile
    var extra: Set<String> = emptySet()

    private val blockedTlds = setOf("xxx", "porn", "sex", "adult")

    private val blockedDomains = listOf(
        "xvideos.com", "xvideos2.com", "xvideos-cdn.com", "xnxx.com", "xnxx-cdn.com",
        "xhamster.com", "xhamster2.com", "xhamster3.com", "xhcdn.com", "xhpingcdn.com",
        "redtube.com", "rdtcdn.com", "ypncdn.com", "phncdn.com", "brazzers.com",
        "bangbros.com", "chaturbate.com", "stripchat.com", "livejasmin.com", "onlyfans.com",
        "fansly.com", "cam4.com", "myfreecams.com", "spankbang.com", "eporner.com", "xtube.com",
        "tube8.com", "thumbzilla.com", "rule34.xxx", "rule34.paheal.net", "e621.net", "hanime.tv",
        "motherless.com", "erome.com", "tnaflix.com", "nudevista.com", "camsoda.com",
        "bongacams.com", "redgifs.com", "fapello.com", "beeg.com", "pichunter.com",
        "hclips.com", "txxx.com", "hotmovs.com", "daftsex.com", "sxyprn.com", "nuvid.com",
        "drtuber.com", "ixxx.com", "xvideos.es", "xnxx.es", "playboy.com", "penthouse.com",
        "naughtyamerica.com", "realitykings.com", "mofos.com", "vporn.com", "4tube.com",
        "fapster.xxx", "sex.com", "efukt.com", "heavy-r.com", "exoclick.com", "juicyads.com",
        "trafficjunky.net", "ero-advertising.com", "adultfriendfinder.com", "literotica.com",
    )

    /**
     * X (antes Twitter): mucho contenido para adultos sin ningún filtro, y no hay
     * forma de usarla sin verlo. Se bloquea entera, con sus dominios de medios y
     * acortador, para que tampoco funcione desde el navegador.
     */
    private val socialBlocked = listOf(
        "twitter.com", "x.com", "t.co", "twimg.com", "twttr.com", "twitter.map.fastly.net",
        "pscp.tv", "periscope.tv", "vine.co",
    )

    /** Palabras sueltas (separadas por . o -) que sólo aparecen en sitios para adultos. */
    private val blockedTokens = setOf(
        "sex", "sexo", "xxx", "porno", "nude", "nudes", "nsfw", "milf", "camgirls", "sexcams",
    )

    /** Fragmentos que, estén donde estén dentro del nombre, delatan el sitio. */
    private val blockedFragments = listOf(
        "porn", "hentai", "xvideo", "xnxx", "xhamster", "redtube", "brazzers", "bangbros",
        "chaturbate", "stripchat", "livejasmin", "onlyfans", "spankbang", "nudevista",
        "camgirl", "sexcam", "sexchat", "sextube", "fuckbook",
    )

    /** Recursos contra la adicción y similares que contienen esas palabras. */
    private val allowed = listOf(
        "pornharms.com", "fightthenewdrug.org", "yourbrainonporn.com", "covenanteyes.com",
        "nofap.com", "rebootnation.org", "fortify.net", "ceasing.org",
    )

    /**
     * DNS cifrado (DoH): un navegador que lo use se salta el filtro. Si estos
     * nombres no resuelven, Chrome y Firefox vuelven al DNS del sistema.
     */
    private val encryptedDns = listOf(
        "dns.google", "dns.google.com", "cloudflare-dns.com", "one.one.one.one",
        "dns.quad9.net", "dns11.quad9.net", "doh.opendns.com", "dns.nextdns.io",
        "doh.dns.sb", "dns.adguard.com", "dns.adguard-dns.com", "doh.cleanbrowsing.org",
        "doh.mullvad.net", "dns.alidns.com", "doh.pub", "dns.twnic.tw", "doh.li",
        "dns.switch.ch", "doh.centraleu.pi-dns.com", "doh.libredns.gr",
    )

    fun isBlocked(rawName: String): Boolean {
        val name = rawName.trim().trimEnd('.').lowercase()
        if (name.isEmpty()) return false
        if (matches(name, allowed)) return false
        if (matches(name, extra)) return true
        if (matches(name, blockedDomains)) return true
        if (matches(name, socialBlocked)) return true
        if (matches(name, encryptedDns)) return true
        if (name.substringAfterLast('.') in blockedTlds) return true
        val tokens = name.split('.', '-')
        if (tokens.any { it in blockedTokens }) return true
        return blockedFragments.any { name.contains(it) }
    }

    private fun matches(name: String, domains: Collection<String>): Boolean =
        domains.any { name == it || name.endsWith(".$it") }

    /** Un dominio que el usuario añade debe ser eso y no otra cosa. */
    fun normalize(input: String): String? {
        val cleaned = input.trim().lowercase()
            .removePrefix("https://").removePrefix("http://")
            .substringBefore('/').substringBefore(':').trimEnd('.')
        return cleaned.takeIf { DOMAIN.matches(it) }
    }

    private val DOMAIN = Regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$")
}
