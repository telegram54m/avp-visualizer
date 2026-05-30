//
//  GzipCompression.swift — gzip wrap / unwrap for the SQLite stem
//  cache blob, bit-compatible with Python's gzip.compress (which the
//  sidecar.py uses).
//
//  We need real gzip (1f 8b 08 00 header + crc32 trailer), not the raw
//  deflate that Foundation's Compression framework produces with .zlib.
//  zlib's libz supports gzip via windowBits=31 on (de)flateInit2 —
//  that's what we use here.
//
//  Phase 2 / [[swift-sidecar-port-spec]] cleanup:
//  before this file, my Swift backend wrote raw HVSF blobs straight to
//  SQLite. That diverged from the existing Python sidecar's gzipped
//  format, breaking cross-backend interop. With this in place, Swift
//  writes are byte-identical to Python writes, and Swift reads
//  transparently handle both gzipped (Python or post-fix Swift) and
//  raw (pre-fix Swift) blobs.
//

import Foundation
import zlib

enum GzipError: Error {
    case deflateInitFailed(Int32)
    case deflateFailed(Int32)
    case inflateInitFailed(Int32)
    case inflateFailed(Int32)
}

enum GzipCompression {
    /// `gzip.compress(data, compresslevel=6)` — exactly what Python
    /// sidecar's `_cache_store` produces. windowBits = 15 + 16 = 31
    /// asks libz to produce a gzip wrapper instead of a zlib wrapper.
    static func compress(_ data: Data, level: Int32 = 6) throws -> Data {
        if data.isEmpty { return Data() }

        var stream = z_stream()
        stream.zalloc = nil
        stream.zfree = nil
        stream.opaque = nil

        // windowBits = 31 → gzip wrapper.
        // memLevel = 8 (libz default).
        // strategy = Z_DEFAULT_STRATEGY.
        let initRet = deflateInit2_(
            &stream,
            level,
            Z_DEFLATED,
            31,                           // windowBits: 15 + 16 = gzip
            8,                            // memLevel
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initRet == Z_OK else {
            throw GzipError.deflateInitFailed(initRet)
        }
        defer { deflateEnd(&stream) }

        var output = Data(capacity: data.count / 2 + 64)
        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        try data.withUnsafeBytes { (rawIn: UnsafeRawBufferPointer) in
            let inputPtr = rawIn.bindMemory(to: UInt8.self).baseAddress!
            stream.next_in = UnsafeMutablePointer(mutating: inputPtr)
            stream.avail_in = uInt(data.count)

            while true {
                try buffer.withUnsafeMutableBufferPointer { bufPtr in
                    stream.next_out = bufPtr.baseAddress
                    stream.avail_out = uInt(bufferSize)

                    let flush: Int32 = Z_FINISH
                    let ret = deflate(&stream, flush)
                    if ret < 0 {
                        throw GzipError.deflateFailed(ret)
                    }

                    let written = bufferSize - Int(stream.avail_out)
                    output.append(bufPtr.baseAddress!, count: written)
                }
                if stream.avail_out != 0 {
                    // Z_FINISH consumed everything that fit in this round.
                    break
                }
            }
        }
        return output
    }

    /// `gzip.decompress(data)` — handles Python sidecar's blobs and
    /// any future Swift gzip writes.
    static func decompress(_ data: Data) throws -> Data {
        if data.isEmpty { return Data() }

        var stream = z_stream()
        stream.zalloc = nil
        stream.zfree = nil
        stream.opaque = nil

        // windowBits = 31 → expect gzip wrapper.
        let initRet = inflateInit2_(
            &stream,
            31,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initRet == Z_OK else {
            throw GzipError.inflateInitFailed(initRet)
        }
        defer { inflateEnd(&stream) }

        // Inflated output is ~10× input in the worst case for gzipped
        // chromagram data; pre-allocate to avoid early reallocs.
        var output = Data(capacity: data.count * 4)
        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        try data.withUnsafeBytes { (rawIn: UnsafeRawBufferPointer) in
            let inputPtr = rawIn.bindMemory(to: UInt8.self).baseAddress!
            stream.next_in = UnsafeMutablePointer(mutating: inputPtr)
            stream.avail_in = uInt(data.count)

            while true {
                let ret: Int32 = try buffer.withUnsafeMutableBufferPointer { bufPtr in
                    stream.next_out = bufPtr.baseAddress
                    stream.avail_out = uInt(bufferSize)
                    let r = inflate(&stream, Z_NO_FLUSH)
                    if r < 0 && r != Z_BUF_ERROR {
                        throw GzipError.inflateFailed(r)
                    }
                    let written = bufferSize - Int(stream.avail_out)
                    output.append(bufPtr.baseAddress!, count: written)
                    return r
                }
                if ret == Z_STREAM_END { break }
                if stream.avail_in == 0 && stream.avail_out != 0 {
                    // Ran out of input without seeing END — truncated blob.
                    throw GzipError.inflateFailed(Z_DATA_ERROR)
                }
            }
        }
        return output
    }

    /// True iff `data` starts with the gzip magic bytes `1f 8b`. Used
    /// by the cache read path to transparently handle both old raw
    /// HVSF blobs (pre-fix Swift writes) and gzipped blobs (Python
    /// + post-fix Swift writes).
    @inline(__always)
    static func isGzipped(_ data: Data) -> Bool {
        return data.count >= 2 && data[0] == 0x1f && data[1] == 0x8b
    }
}
