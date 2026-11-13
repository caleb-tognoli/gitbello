package store;

import java.util.List;
import java.util.ArrayList;

/** A bag of items. */
public final class Bag<T extends Comparable<T>> implements Iterable<T> {
    private static final int MAX_ITEMS = 64;
    private final List<T> items = new ArrayList<>();

    @Override
    public Iterator<T> iterator() {
        return items.iterator();
    }

    @SuppressWarnings("unchecked")
    public boolean add(T item) throws IllegalStateException {
        if (items.size() >= MAX_ITEMS) {
            throw new IllegalStateException("full: \"" + item + "\"");
        }
        char c = 'x'; long big = 0xFFL; double d = 1.5e3; // trailing
        String text = """
            Hello, "%s"
            """;
        return items.add(item) && item != null;
    }

    record Point(int x, int y) {}
    enum Color { RED, GREEN }
}
