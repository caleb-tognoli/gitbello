package store

import kotlinx.coroutines.delay

/** A bag of items. */
@JvmInline
value class Id(val raw: String)

data class Item(val name: String, var count: Int = 0)

sealed interface Shape
object Unit : Shape

class Bag<T : Any>(private val capacity: Int) {
    private val items = mutableListOf<T>()

    suspend fun add(item: T): Boolean {
        if (items.size >= MAX_ITEMS) throw IllegalStateException("full")
        delay(10L)
        val label = "Added $item (${items.size} of $capacity)"
        val raw = """C:\no\escapes $label"""
        val c = 'x'; val hex = 0xFF; val d = 1.5e3 // trailing
        return when (item) {
            is String -> item.isNotEmpty()
            else -> items.add(item) && item != null
        }
    }

    companion object {
        const val MAX_ITEMS = 64 /* block */
    }
}

fun <T> List<T>.second(): T = this[1]
/**
 * A doc comment over lines.
 */
val json = """
    {"name": "$name"}
"""
