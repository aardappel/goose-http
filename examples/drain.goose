// One bounded batch in flight. A broker can release the next batch at DRAINED.
import std;
import os;
import http from "../";
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import http.websocket;

struct State { ws: http::WebSocket = http::WebSocket { .. }, next: i64 = 0 }
struct Credit { to: http::MailAddress, sequence: i64 }

thread_fn publisher() {
    loop {
        let credit = qget<Credit>();
        var data: u8[8192] = ['x'; 8192];
        for i in 8 { data[i] = (credit.sequence >> (8 * i)) as! u8; }
        loop {
            let result = http::mail_send(credit.to, 1, data);
            if result != http::FULL { break; }
            sleep_ms(1);
        }
    }
}

fn handle(ev: http::Event, state: State&, out: http::Reply) {
    if ev.kind == http::REQUEST {
        guard http::ws_upgrade(ev.req, state.ws, out) else { return; }
    } else if ev.kind == http::WAKE {
        http::ws_send(out, http::WS_BINARY, ev.data);
        assert(http::after_drain(out));
        http::later(out, 60000);
        state.next++;
        return;
    } else if ev.kind != http::DRAINED {
        http::ws_read(ev, state.ws, out) { op, data, reply => };
        return;
    }
    if state.next == 4096 {
        write_stderr("Delivered 32 MiB\n");
        return;
    }
    assert(qput(Credit { to: http::later(out, 60000), sequence: state.next }));
}

thread_fn worker(cfg: http::Config) {
    var loop_name: u8[>..] = [];
    let error = if env("LOOP", loop_name) && loop_name == "epoll" {
        http::serve_epoll(cfg, State { .. }) { ev, state, out => handle(ev, state, out); }
    } else {
        http::serve(cfg, State { .. }) { ev, state, out => handle(ev, state, out); }
    };
    http::report(error);
}

fn main() {
    qlimit<Credit>(128);
    thread_spawn(publisher);
    http::run(http::Config { address: "127.0.0.1", port: 27893, workers: 1,
        max_conns: 8, max_queued: 4096, write_ms: 60000,
        mail_slots: 8, mail_size: 8192, max_waiting: 8, .. }, worker);
}
