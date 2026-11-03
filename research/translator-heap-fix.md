# translator64: "Corrupt heap detected in: mspace_malloc" (2026-10-19)

Symptom on 0.71: random SIGABRT on the `wst-relay-conn` thread (`Abort message: 'Corrupt heap
detected in: mspace_malloc'`) or SIGSEGV in `HeapTaskDaemon`. Most launches died within a
minute of reaching the map.

Cause: the message is ART's (`libart.so`), not bionic's. ART keeps `ByteBuffer.allocateDirect`
memory as a non-movable byte[] in its DlMalloc ("mspace") space. In
`work/translator64/src/jni_real.cpp`, `GetDirectBufferAddress` hands the guest a shadow copy
of a Java direct buffer, cached by host address, and `dbuf_writeback` copied the shadow back
at frame leave using the CACHED capacity (`d.cap`). The cache keeps the biggest capacity it
has seen at that address, so when ART freed a big buffer and reused the address for a smaller
one, the write-back ran past the new buffer into ART's heap.

Fix (in `jni_real.cpp`; `work/` is git-ignored in the old project, so it is recorded here):

```cpp
static thread_local std::vector<std::pair<void*, u32>> t_dirty;   // was std::vector<void*>
...
    if (t_depth > 0) t_dirty.emplace_back(host, cap);                // was push_back(host)
...
    for (auto& [host, cap] : t_dirty) {
        ...
        memcpy(host, H(d.g), cap < d.cap ? cap : d.cap);             // was d.cap
    }
```

Also added (defensive, never fired): `array_region` (Get/Set<T>ArrayRegion) clamps an
out-of-range start/len and logs `[jni] ...ArrayRegion out of bounds` instead of a raw memcpy
past the Java array.

Result: 0.71 ran the whole gym flow (map, gym, battle prep) without the abort after the fix.
