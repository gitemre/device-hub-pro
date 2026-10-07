package com.devicehubpro.verifier

import android.app.Activity
import android.content.Context

enum class RowKind { DIRECT, KEY, INTERACTIVE, NOTE }

sealed interface Reading {
    data class Value(val text: String, val muted: Boolean = false) : Reading
    data object NeedsPermission : Reading
    data object Unsupported : Reading
    data class Failed(val text: String) : Reading
}

data class RowAction(val label: String, val invoke: (Activity) -> Unit)

data class VerifierRow(
    val id: String,
    val title: String,
    val source: String,
    val kind: RowKind,
    val detail: String? = null,
    val permission: String? = null,
    val actions: List<RowAction> = emptyList(),
    val read: (Context) -> Reading,
)

data class RowSection(
    val id: String,
    val title: String,
    val applicable: Boolean = true,
    val rows: List<VerifierRow>,
)
