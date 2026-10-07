package com.devicehubpro.verifier.ui

import android.animation.ValueAnimator
import android.graphics.Color
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView
import com.devicehubpro.verifier.R
import com.devicehubpro.verifier.Reading
import com.devicehubpro.verifier.RowAction
import com.devicehubpro.verifier.RowKind
import com.devicehubpro.verifier.VerifierRow
import com.devicehubpro.verifier.formatTime
import com.devicehubpro.verifier.readingMuted
import com.devicehubpro.verifier.readingText

class RowsAdapter(
    private val onAction: (RowAction) -> Unit,
    private val onRowClick: (VerifierRow) -> Unit,
    private val flashDurationMillis: () -> Long,
) : RecyclerView.Adapter<RecyclerView.ViewHolder>() {

    sealed interface Item {
        data class Header(val title: String) : Item
        data class Row(
            val row: VerifierRow,
            val reading: Reading,
            val lastChangedAt: Long?,
            val flash: Boolean,
        ) : Item
    }

    var items: List<Item> = emptyList()
        set(value) {
            field = value
            notifyDataSetChanged()
        }

    override fun getItemViewType(position: Int): Int =
        if (items[position] is Item.Header) TYPE_HEADER else TYPE_ROW

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder {
        val inflater = LayoutInflater.from(parent.context)
        return if (viewType == TYPE_HEADER) {
            HeaderHolder(inflater.inflate(R.layout.item_section, parent, false))
        } else {
            RowHolder(
                inflater.inflate(R.layout.item_row, parent, false),
                onAction,
                onRowClick,
                flashDurationMillis,
            )
        }
    }

    override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
        when (val item = items[position]) {
            is Item.Header -> (holder as HeaderHolder).bind(item.title)
            is Item.Row -> (holder as RowHolder).bind(item)
        }
    }

    override fun getItemCount(): Int = items.size

    private class HeaderHolder(view: View) : RecyclerView.ViewHolder(view) {
        private val title: TextView = view.findViewById(R.id.section_title)
        fun bind(text: String) {
            title.text = text
        }
    }

    private class RowHolder(
        view: View,
        private val onAction: (RowAction) -> Unit,
        private val onRowClick: (VerifierRow) -> Unit,
        private val flashDurationMillis: () -> Long,
    ) : RecyclerView.ViewHolder(view) {
        private val title: TextView = view.findViewById(R.id.row_title)
        private val value: TextView = view.findViewById(R.id.row_value)
        private val detail: TextView = view.findViewById(R.id.row_detail)
        private val action: Button = view.findViewById(R.id.row_action)

        private var flashAnimator: ValueAnimator? = null
        private var flashRowId: String? = null

        fun bind(item: Item.Row) {
            val row = item.row
            title.text = row.title
            value.text = readingText(item.reading)
            value.alpha = if (readingMuted(item.reading)) 0.6f else 1f

            val badge = when (row.kind) {
                RowKind.KEY -> "Key value · "
                RowKind.NOTE -> "Note · "
                RowKind.INTERACTIVE -> "Interactive · "
                RowKind.DIRECT -> ""
            }
            val changed = item.lastChangedAt?.let { "Last change ${formatTime(it)}" }
            detail.text = listOfNotNull(
                (badge + (row.detail ?: row.source)),
                changed,
            ).joinToString("\n")

            itemView.setOnClickListener { onRowClick(row) }
            renderFlash(item)

            val rowAction = row.actions.firstOrNull()
            if (rowAction == null) {
                action.visibility = View.GONE
            } else {
                action.visibility = View.VISIBLE
                action.text = rowAction.label
                action.setOnClickListener { onAction(rowAction) }
            }
        }

        /**
         * The highlight fades through the platform animator, so Reduce Motion's animator
         * scale is observable: at scale 0 the colour appears with no fade at all.
         */
        private fun renderFlash(item: Item.Row) {
            if (!item.flash) {
                flashAnimator?.cancel()
                flashAnimator = null
                flashRowId = null
                itemView.setBackgroundColor(Color.TRANSPARENT)
                return
            }
            if (flashRowId == item.row.id && flashAnimator?.isRunning == true) return
            flashAnimator?.cancel()
            flashRowId = item.row.id
            val duration = flashDurationMillis()
            if (duration <= 0L) {
                flashAnimator = null
                itemView.setBackgroundColor(FLASH)
                return
            }
            val animator = ValueAnimator.ofArgb(FLASH, Color.TRANSPARENT).apply {
                this.duration = duration
                addUpdateListener { itemView.setBackgroundColor(it.animatedValue as Int) }
            }
            flashAnimator = animator
            animator.start()
        }
    }

    private companion object {
        const val TYPE_HEADER = 0
        const val TYPE_ROW = 1
        const val FLASH = 0x33FFC107
    }
}
