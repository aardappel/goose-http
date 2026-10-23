// Fuzz targets for the package's parsers of what a client sends, for libFuzzer
// through fuzz/build.sh, which compiles this file's C with a C entry point for
// each target (targets.c). Each target takes the fuzzer's bytes:
//
//   fuzz_request    an HTTP/1.1 request: its head through parse, its fields,
//                   query, and target through the handler's helpers, and a
//                   chunked body through chunked_len, dechunk, and read_body
//                   fed in pieces whose sizes the first bytes choose, which
//                   must agree
//   fuzz_hpack      field blocks through one connection's decoding table, a
//                   2-byte length before each, the first byte its limit; each
//                   block's fields encoded again and decoded by a second pair
//                   of tables, which must give them back
//   fuzz_h2frame    frames through h2_parse, and SETTINGS' parameters through
//                   h2_apply_settings
//   fuzz_multipart  a multipart/form-data body through each_part, whole and
//                   in pieces whose sizes the first bytes choose, which must
//                   give the same parts, and through find_part
//
// A crash, a sanitizer report, or a failed assert is a finding.
import std;
import http from "../";

fn main() {}

export fn fuzz_request(data: const u8[:]) -> i64 {
    guard data.len >= 2 else { return 0; }
    var r = rng { (data[0] as u64) << 8 | data[1] | 1 };
    let buf = data[2..];
    let req, status = http::parse(buf);
    guard status == 200 else { return status; }

    // An accepted head is still INCOMPLETE without its last bytes, or the
    // server would answer a request before it had all arrived.
    let cut = r.rand_int(req.len);
    let _, early = http::parse(buf[..cut]);
    assert(early == http::INCOMPLETE);

    var count = 0;
    http::each_field(req) { n, v =>
        let first, found = http::field_of(req, n);
        assert(found);
        count++;
    };
    var out: u8[>..] = [];
    http::decode(http::path_of(req.target), out);
    http::each_query(req.target) { k, v =>
        out.clear();
        http::decode(v, out, true);
    };
    http::query_int(req.target, "n");
    http::authority(req);
    http::upgrade_of(req);

    guard req.chunked else { return count; }
    let rest = buf[req.len..];
    let wire, framed = http::chunked_len(rest);
    var data_in_pieces: u8[>..] = [];
    var trailers_in_pieces: u8[>..] = [];
    var reader = http::BodyReader.ChunkSize;
    // What has arrived, of which read_body has used held[..used].
    var held: u8[>..] = [];
    var used = 0;
    var at = 0;
    var read = http::INCOMPLETE;
    while at < rest.len {
        let n = min(rest.len - at, 1 + r.rand_int(64));
        held.append(rest[at..at + n]);
        at += n;
        // read_body as a loop calls it: until it waits for more bytes.
        loop {
            let piece = held[used..];
            let d0, d1, s = http::read_body(piece, reader);
            read = s;
            guard s == 200 else { break; }
            let ended = match reader { None => true, _ => false };
            if ended { trailers_in_pieces.append(piece[d0..d1]); }
            else { data_in_pieces.append(piece[d0..d1]); }
            used += d1;
            guard !ended && d1 > 0 else { break; }
        }
        guard read != 400 else { break; }
        guard match reader { None => false, _ => true } else { break; }
    }
    let ended = match reader { None => true, _ => false };
    if framed == 200 {
        assert(ended);
        var copy: u8[>..] = [];
        copy.append(rest[..wire]);
        let n, t = http::dechunk(copy);
        assert(copy[..n] == data_in_pieces);
        assert(copy[t..wire] == trailers_in_pieces);
    } else if framed == 400 {
        assert(read == 400);
    } else {
        assert(!ended);
    }
    return count;
}

export fn fuzz_hpack(data: const u8[:]) -> i64 {
    guard data.len >= 1 else { return 0; }
    let limit = (data[0] as i64) * 32;
    var t = http::hpack_table(limit);
    var enc = http::hpack_table(limit);
    var dec = http::hpack_table(limit);
    var scratch: u8[>..] = [];
    // The block's names and values, one after another, and where each ends.
    var bytes: u8[>..] = [];
    var ends: i64[>..] = [];
    var encoded: u8[>..] = [];
    var at = 1;
    while at + 2 <= data.len {
        let len = min((data[at] as i64) << 8 | data[at + 1], data.len - at - 2);
        let fb = data[at + 2..at + 2 + len];
        at += 2 + len;
        scratch.clear();
        bytes.clear();
        ends.clear();
        var lower = true;
        let ok = http::hpack_decode(t, fb, scratch) { n, v =>
            // The encoder takes lowercase names only (RFC 9113 §8.2.1).
            for c in n { lower = lower && !(c >= 'A' && c <= 'Z'); }
            bytes.append(n);
            ends.push(bytes.len);
            bytes.append(v);
            ends.push(bytes.len);
        };
        // A failed block ends the connection.
        guard ok else { return 0; }
        guard lower else { continue; }

        fn item(k: i64) -> const u8[:] { bytes[if k == 0 { 0 } else { ends[k - 1] }..ends[k]] }
        encoded.clear();
        http::hpack_begin(enc, encoded);
        for i in ends.len / 2 {
            http::hpack_encode(enc, encoded, item(2 * i), item(2 * i + 1), i % 3);
        }
        scratch.clear();
        var k = 0;
        let again = http::hpack_decode(dec, encoded, scratch) { n, v =>
            assert(k < ends.len && item(k) == n && item(k + 1) == v);
            k += 2;
        };
        assert(again && k == ends.len);
    }
    return 0;
}

export fn fuzz_h2frame(data: const u8[:]) -> i64 {
    guard data.len >= 1 else { return 0; }
    let max = if data[0] & 1 != 0 { http::H2_MAX_FRAME_SIZE } else { http::H2_MIN_FRAME_SIZE };
    var settings = http::H2Settings { .. };
    var at = 1;
    var frames = 0;
    while at < data.len {
        let f, size, err = http::h2_parse(data[at..], max);
        guard size > 0 else { break; }
        assert(size <= data.len - at);
        at += size;
        frames++;
        guard err.code == 0 || err.stream != 0 else { break; }
        if f.kind == http::H2_SETTINGS && err.code == 0 {
            guard http::h2_apply_settings(settings, f.data) == http::H2_NO_ERROR else { break; }
        }
    }
    return frames;
}

let FORM_HEAD = "POST / HTTP/1.1\r\nHost: a\r\nContent-Type: multipart/form-data; boundary=XyZ\r\n\r\n";

// Each part event as bytes: a tag, then a head's fields or a piece of data.
// Pieces of data in a row join, so that the logs of the whole body and of its
// pieces compare.
fn log_part(log: u8[>..]&, part: http::Part) {
    match part {
        Head h => {
            log.push('H');
            log.append(h.fields);
            log.push(0);
        },
        Data d => {
            if log.len == 0 || log[log.len - 1] != 'D' {
                log.push(0);
                log.push('D');
            }
            // Data goes before its tag, so that the next piece still joins.
            log.pop();
            log.append(d.bytes);
            log.push('D');
        },
        End => { log.push('E'); },
    }
}

export fn fuzz_multipart(data: const u8[:]) -> i64 {
    guard data.len >= 2 else { return 0; }
    var r = rng { (data[0] as u64) << 8 | data[1] | 1 };
    let body = data[2..];
    let req, status = http::parse(FORM_HEAD);
    assert(status == 200);

    var whole = http::Multipart { .. };
    assert(http::start_multipart(req, whole));
    var whole_log: u8[>..] = [];
    let whole_ok = http::each_part(whole, body) { part => log_part(whole_log, part); };

    var split = http::Multipart { .. };
    assert(http::start_multipart(req, split));
    var split_log: u8[>..] = [];
    var split_ok = true;
    var at = 0;
    while at < body.len && split_ok {
        let n = min(body.len - at, 1 + r.rand_int(64));
        split_ok = http::each_part(split, body[at..at + n]) { part => log_part(split_log, part); };
        at += n;
    }
    assert(whole_ok == split_ok);
    if whole_ok {
        assert(http::multipart_done(whole) == http::multipart_done(split));
        if http::multipart_done(whole) { assert(whole_log == split_log); }
    }
    http::find_part(req, body, "a");
    return 0;
}
