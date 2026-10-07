package com.devicehubpro.verifier

/**
 * The URL row, observed by the verifier about itself. [MainActivity] handles five VIEW
 * filters: `devicehubpro-verifier://link/…` (BROWSABLE), `devicehubpro-verifier://internal/…` (no
 * BROWSABLE: Device Hub Pro always sends it, so it is not reached from the app any more),
 * `https://verifier.devicehubpro.test/…` (an App Link that can never verify: `.test` is reserved,
 * RFC 6761), `devicehubpro-verifier://nodefault/…` (no DEFAULT: never reached, so it never shows
 * here) and `https://devicehubpro-verifier/…` (a single-label host App Links never applies to). It
 * is singleTop, so a link opened while it is on top, or while its task is in the background,
 * arrives in onNewIntent.
 */
fun linksSection(): RowSection = RowSection(
    id = "links",
    title = "Links",
    rows = listOf(
        VerifierRow(
            id = "links.lastLink",
            title = "Last link",
            source = "Links ▸ URL · am start -W -a android.intent.action.VIEW -c android.intent.category.BROWSABLE -d",
            kind = RowKind.DIRECT,
            detail = "The last VIEW intent this activity received (at launch or in onNewIntent): " +
                "getDataString() verbatim, its categories and getReferrer(). Open " +
                "devicehubpro-verifier://link/… from Device Hub Pro's URL row (it always sends BROWSABLE).",
            read = { _ -> lastLinkText(LinkLog.last) },
        ),
    ),
)

// MARK: - Last link

/** One VIEW intent the activity received, apart from the framework classes (unit-testable). */
data class LinkRecord(
    val data: String?,
    val categories: List<String>,
    val referrer: String?,
    val at: Long,
    val viaNewIntent: Boolean,
)

/** The last VIEW intent [MainActivity] received in this process. */
object LinkLog {
    @Volatile var last: LinkRecord? = null
}

/** The logcat tag the live test reads (`DeviceHubProVerifierLink`, 20 characters). */
const val LINK_LOG_TAG = "DeviceHubProVerifierLink"

fun lastLinkText(record: LinkRecord?): Reading {
    if (record == null) return Reading.Value("No link received in this process", muted = true)
    val categories = if (record.categories.isEmpty()) {
        "no category"
    } else {
        record.categories.joinToString(", ") { it.substringAfterLast('.') }
    }
    val parts = mutableListOf(record.data ?: "no data", categories)
    referrerName(record.referrer)?.let { parts += "from $it" }
    parts += formatTime(record.at)
    if (record.viaNewIntent) parts += "onNewIntent"
    return Reading.Value(parts.joinToString(" · "))
}

/** `android-app://com.android.shell` → `com.android.shell`; other referrers verbatim. */
fun referrerName(referrer: String?): String? {
    if (referrer.isNullOrEmpty()) return null
    val prefix = "android-app://"
    return if (referrer.startsWith(prefix)) {
        referrer.removePrefix(prefix).substringBefore('/')
    } else {
        referrer
    }
}
