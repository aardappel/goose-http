// Accept-Encoding weights (coding_q), and precompressed copies of a file
// (open_precompressed). Writes files into the working directory, and deletes
// them.
import std;
import http from "../../";
import check from "../";

// Accept-Encoding fields, and the weight coding_q gives coding by them.
struct Coded { fields: const u8[:], coding: const u8[:], q: i64 }

fn main() {
    let mixed = "Accept-Encoding: gzip;q=2, br;level=1, zstd\r\n";
    let cases = [
        Coded { fields: "", coding: "gzip", q: 0 },
        Coded { fields: "Accept-Encoding: gzip, br\r\n", coding: "br", q: 1000 },
        Coded { fields: "Accept-Encoding: br;q=1, gzip;q=0.8\r\n", coding: "gzip", q: 800 },
        Coded { fields: "Accept-Encoding: x-gzip\r\n", coding: "gzip", q: 1000 },
        Coded { fields: "Accept-Encoding: GZIP ; Q=0.3\r\n", coding: "gzip", q: 300 },
        Coded { fields: "Accept-Encoding: *;q=0.5, gzip;q=0\r\n", coding: "gzip", q: 0 },
        Coded { fields: "Accept-Encoding: *;q=0.5, gzip;q=0\r\n", coding: "br", q: 500 },
        Coded { fields: "Accept-Encoding: identity\r\n", coding: "gzip", q: 0 },
        Coded { fields: "Accept-Encoding:\r\n", coding: "gzip", q: 0 },
        Coded { fields: "Accept-Encoding: deflate\r\nAccept-Encoding: gzip;q=0.1\r\n", coding: "gzip", q: 100 },
        Coded { fields: mixed, coding: "gzip", q: 0 },
        Coded { fields: mixed, coding: "br", q: 0 },
        Coded { fields: mixed, coding: "zstd", q: 1000 },
    ];
    for c in cases {
        var rb: u8[>..] = [];
        let r = check::request("GET", c.fields, rb);
        let q = http::coding_q(r, c.coding);
        if q != c.q { print("coding_q: ", c.fields, c.coding, " got ", q, ", want ", c.q); }
        assert(q == c.q);
    }
    print("coding_q: ", cases.len, " cases");

    // A file with a gzip and a br copy, none older than it.
    let name = "test_codings.tmp";
    assert(write_file(name, "plain"));
    assert(write_file(str(name, ".gz"), "gz"));
    assert(write_file(str(name, ".br"), "br"));
    let picks = [
        Coded { fields: "", coding: "", q: 5 },
        Coded { fields: "Accept-Encoding: gzip, br\r\n", coding: "br", q: 2 },
        Coded { fields: "Accept-Encoding: br;q=0.4, gzip;q=0.5\r\n", coding: "gzip", q: 2 },
        Coded { fields: "Accept-Encoding: zstd, gzip;q=0.1\r\n", coding: "gzip", q: 2 },
        Coded { fields: "Accept-Encoding: zstd\r\n", coding: "", q: 5 },
    ];
    for p in picks {
        var rb: u8[>..] = [];
        let req = check::request("GET", p.fields, rb);
        let f, s = http::open_precompressed(req, name);
        assert(s == 200 && f.coding == p.coding && f.size == p.q && f.vary);
        var out: u8[>..] = [];
        var keep = true;
        var st = http::Stream { .. };
        var body = http::FileBody { .. };
        let reply = http::Reply { buf: out, common: check::COMMON, keep_alive: keep, minor: 1, head: false, stream: st };
        http::serve_file(req, reply, f, "text/plain", body);
        while http::send_file(reply, body) {}
        http::end(reply);
        assert(find(out, "Vary: Accept-Encoding\r\n") >= 0);
        assert((find(out, "Content-Encoding: ") >= 0) == (p.coding.len > 0));
        if p.coding.len > 0 {
            assert(find(out, str("Content-Encoding: ", p.coding, "\r\n")) >= 0);
            assert(find(out, str("-", p.coding, "\"\r\n")) >= 0);
        }
        print("copy picked: '", f.coding, "', ", f.size, " bytes");
    }
    var rb: u8[>..] = [];
    let asked = check::request("GET", "Accept-Encoding: gzip\r\n", rb);
    let none, missing = http::open_precompressed(asked, "no such file here");
    assert(missing == 404 && none.fd < 0);
    http::close_file(none);

    // open_precompressed's choice from its parts: coding_q, open_file, the
    // fresher by modified, and close_file for the file passed over.
    let plain, ps = http::open_file(name);
    let gz, gs = http::open_file(str(name, ".gz"));
    assert(ps == 200 && gs == 200 && http::coding_q(asked, "gzip") > 0 && gz.modified >= plain.modified);
    http::close_file(plain);
    let own = http::File { fd: gz.fd, size: gz.size, modified: gz.modified, coding: "gzip", vary: true };
    let picked, s = http::open_precompressed(asked, name);
    assert(s == 200 && http::file_tag(own) == http::file_tag(picked));
    http::close_file(own);
    http::close_file(picked);
    print("the same copy from the parts, closed with close_file");
    for suffix in ["", ".gz", ".br"] { assert(delete_file(str(name, suffix))); }
    print("a missing file: ", missing);
}
