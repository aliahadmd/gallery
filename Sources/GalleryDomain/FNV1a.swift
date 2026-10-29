/// FNV-1a over a byte sequence. Chosen because it is tiny, deterministic across Swift versions and
/// platforms, and needs no dependency — the identifiers built from it (album identity, event identity,
/// file change detection) have to be reproducible years later, on a different machine, from stored data.
public func fnv1a(_ bytes: some Sequence<UInt8>) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in bytes {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return hash
}

/// Folded into a positive `Int64` so a derived identifier can never collide with a rowid sign or a `-1`.
public func fnv1aID(_ bytes: some Sequence<UInt8>) -> Int64 {
    Int64(truncatingIfNeeded: fnv1a(bytes) & 0x7fff_ffff_ffff_ffff)
}

public func fnv1a(_ string: String) -> UInt64 { fnv1a(string.utf8) }
public func fnv1aID(_ string: String) -> Int64 { fnv1aID(string.utf8) }
