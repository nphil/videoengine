package android.util;

import java.util.Map;
import java.util.TreeMap;

/**
 * A JVM stand-in for the framework class, which unit tests only get as a stub that stores nothing. Media3's Matroska
 * extractor keeps its tracks in one. Lookups are linear; the arrays here hold a handful of entries.
 */
public class SparseArray<E> {
    private final TreeMap<Integer, E> map = new TreeMap<>();

    public SparseArray() {}

    public SparseArray(int initialCapacity) {}

    public void put(int key, E value) {
        map.put(key, value);
    }

    public void append(int key, E value) {
        map.put(key, value);
    }

    public E get(int key) {
        return map.get(key);
    }

    public E get(int key, E valueIfKeyNotFound) {
        return map.containsKey(key) ? map.get(key) : valueIfKeyNotFound;
    }

    public void remove(int key) {
        map.remove(key);
    }

    public void delete(int key) {
        map.remove(key);
    }

    public boolean contains(int key) {
        return map.containsKey(key);
    }

    public int size() {
        return map.size();
    }

    public void clear() {
        map.clear();
    }

    public int keyAt(int index) {
        return entryAt(index).getKey();
    }

    public E valueAt(int index) {
        return entryAt(index).getValue();
    }

    public int indexOfKey(int key) {
        int i = 0;
        for (int existing : map.keySet()) {
            if (existing == key) return i;
            i++;
        }
        return -1;
    }

    private Map.Entry<Integer, E> entryAt(int index) {
        int i = 0;
        for (Map.Entry<Integer, E> entry : map.entrySet()) {
            if (i++ == index) return entry;
        }
        throw new ArrayIndexOutOfBoundsException(index);
    }
}
