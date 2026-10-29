import Foundation

/// Replaces a file's bytes without replacing its inode.
///
/// `replaceItemAt` and write-then-rename both put a *new* inode at the path, which loses `doc_id`/`res_id`,
/// favorites, Finder tags and the creation date. Writing over the descriptor keeps all of it; the price is a
/// crash window between truncate and the last chunk, which is what the backup ledger and the retained temp
/// file exist to recover from.
public enum InPlaceWriter {
    public enum Failure: Error, CustomStringConvertible {
        case openFailed(Int32)
        case writeFailed(Int32)
        case flushFailed(Int32)
        case setTimeFailed(Int32)

        public var description: String {
            switch self {
            case .openFailed(let code): "could not open the file for writing (errno \(code))"
            case .writeFailed(let code): "could not write the file (errno \(code))"
            case .flushFailed(let code): "could not flush the file (errno \(code))"
            case .setTimeFailed(let code): "could not restore the modification date (errno \(code))"
            }
        }
    }

    public static func overwrite(_ url: URL, with temp: URL, modificationDate: Date?) throws {
        let descriptor = open(url.path, O_WRONLY)
        guard descriptor >= 0 else { throw Failure.openFailed(errno) }
        defer { close(descriptor) }

        var info = stat()
        let previousAccess = fstat(descriptor, &info) == 0 ? info.st_atimespec : timespec(tv_sec: 0, tv_nsec: 0)

        guard ftruncate(descriptor, 0) == 0 else { throw Failure.writeFailed(errno) }
        let input = try FileHandle(forReadingFrom: temp)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            let written = chunk.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                var offset = 0
                while offset < buffer.count {
                    let count = write(descriptor, base.advanced(by: offset), buffer.count - offset)
                    if count <= 0 { return -1 }
                    offset += count
                }
                return offset
            }
            guard written == chunk.count else { throw Failure.writeFailed(errno) }
        }
        guard fsync(descriptor) == 0 else { throw Failure.flushFailed(errno) }

        if let modificationDate {
            let seconds = modificationDate.timeIntervalSince1970
            var times = [previousAccess, timespec(tv_sec: 0, tv_nsec: 0)]
            times[1].tv_sec = Int(seconds.rounded(.down))
            times[1].tv_nsec = Int(((seconds - seconds.rounded(.down)) * 1_000_000_000).rounded())
            guard utimensat(AT_FDCWD, url.path, &times, 0) == 0 else {
                throw Failure.setTimeFailed(errno)
            }
        }
    }
}
