// A device's HTTP API, for an embedded Linux board such as an i.MX 8: the
// SoC's temperature and an LED, read and written through sysfs in Goose, a
// GPIO line through board.c, and the temperature as Server-Sent Events. The
// page at / shows all three. docs/embedded.md builds it for a board.
//
//   curl localhost:8080/api/status
//   curl -X PUT localhost:8080/api/led/on
//   curl -X PUT localhost:8080/api/gpio/off
//   curl -N 'localhost:8080/api/events?n=5'
//
// The environment names the hardware, and the example runs without any:
//
//   THERMAL  a thermal zone's directory, /sys/class/thermal/thermal_zone0 by default
//   LED      an LED's directory, such as /sys/class/leds/user-led; without it, 404
//   GPIO     a chip and a line, such as /dev/gpiochip0:17; without it, simulated
//   LOOP     uring, the default, or epoll
//   WORKERS  how many workers; one per core by default
import std;
import json;
import http from "../../";

// What every worker needs to reach the hardware. Flat, so it crosses to the
// worker threads.
struct Board {
    thermal: u8[..128] = "/sys/class/thermal/thermal_zone0",
    led: u8[..128] = "",
    epoll: bool = false,
}

// One stream of temperatures: how many events are left, -1 for no end, and how
// far apart they are, in milliseconds.
struct Watch { left: i64 = 0, ms: i64 = 1000 }

// The C side keeps the line it opens, for every worker to set and read.
extern fn board_gpio_open(chip: const u8[:], line: i32) -> i32;
extern fn board_gpio_simulated() -> bool;
extern fn board_gpio_set(on: bool) -> i32;
extern fn board_gpio_get() -> i32;

let PAGE = embed_file("index.html");

// A loop that fails ends the process. One that a stop ended returns, and the
// process ends once every worker has.
thread_fn worker(cfg: http::Config, b: Board) {
    http::exit_on_error(http::serve(cfg, Watch { .. }) { ev, st, out => handle(ev, st, out, b); });
}

thread_fn worker_epoll(cfg: http::Config, b: Board) {
    http::exit_on_error(http::serve_epoll(cfg, Watch { .. }) { ev, st, out => handle(ev, st, out, b); });
}

fn handle(ev: http::Event, st: Watch&, out: http::Reply, b: const Board&) {
    if ev.kind == http::REQUEST {
        answer(ev.req, st, out, b);
    } else if ev.kind == http::TIMEOUT {
        // No room for another exchange to wait (Config.max_waiting).
        guard ev.tag != http::NO_ROOM else { http::end(out); return; }
        reading(st, out, b);
    }
}

fn answer(req: const http::Request&, st: Watch&, out: http::Reply, b: const Board&) {
    var r = http::router(req);
    if http::on(r, "GET", "/") {
        http::respond(out, 200, "text/html; charset=utf-8", PAGE);
    } else if http::on(r, "GET", "/api/status") {
        status(out, b);
    } else if http::on(r, "PUT", "/api/led/:state") {
        led(http::param(r, "state"), out, b);
    } else if http::on(r, "PUT", "/api/gpio/:state") {
        gpio(http::param(r, "state"), out);
    } else if http::on(r, "GET", "/api/events") {
        watch(req, st, out, b);
    } else {
        http::otherwise(r, out);
    }
}

fn status(out: http::Reply, b: const Board&) {
    let temp, has_temp = read_value(str(b.thermal, "/temp"));
    let level, has_led = read_value(str(b.led, "/brightness"));
    let line = board_gpio_get();
    http::respond_json(out, 200) { j =>
        j.push('{');
        json::format_key(j, "temp_mc");
        if has_temp { json::format_int(j, temp); } else { j.append("null"); }
        j.push(',');
        json::format_key(j, "led");
        if has_led && b.led.len > 0 { json::format_bool(j, level > 0); } else { j.append("null"); }
        j.push(',');
        json::format_key(j, "gpio");
        if line >= 0 { json::format_bool(j, line == 1); } else { j.append("null"); }
        j.push(',');
        json::format_key(j, "gpio_simulated");
        json::format_bool(j, board_gpio_simulated());
        j.push(',');
        json::format_key(j, "loop");
        http::json_string(j, if b.epoll { "epoll" } else { "uring" });
        j.push('}');
    };
}

fn led(state: const u8[:], out: http::Reply, b: const Board&) {
    let on, ok = on_off(state);
    guard ok else { http::respond(out, 400, "text/plain", "on or off\n"); return; }
    guard b.led.len > 0 else {
        http::respond(out, 404, "text/plain", "no LED: set LED to its directory\n");
        return;
    }
    // On is the LED's max_brightness, which is 1 for an LED on a GPIO line and
    // more for one on PWM.
    let most, has = read_value(str(b.led, "/max_brightness"));
    var level: u8[..24] = [];
    format(level, if !on { 0 } else if has && most > 0 { most } else { 1 });
    guard write_file(str(b.led, "/brightness"), level) else {
        http::respond(out, 500, "text/plain", "can't write the LED's brightness\n");
        return;
    }
    http::respond(out, 204, "", "");
}

fn gpio(state: const u8[:], out: http::Reply) {
    let on, ok = on_off(state);
    guard ok else { http::respond(out, 400, "text/plain", "on or off\n"); return; }
    guard board_gpio_set(on) == 0 else {
        http::respond(out, 500, "text/plain", "can't set the GPIO line\n");
        return;
    }
    http::respond(out, 204, "", "");
}

// /api/events?n=N&ms=MS: the temperature as Server-Sent Events, MS
// milliseconds apart, 1000 by default; N of them, or without N until the
// client goes.
fn watch(req: const http::Request&, st: Watch&, out: http::Reply, b: const Board&) {
    let n = query_or(req.target, "n", 0);
    st.left = if n > 0 { n } else { -1 };
    st.ms = min(max(query_or(req.target, "ms", 1000), 100), 60000);
    http::begin(out, 200, -1);
    http::field(out, "Content-Type", "text/event-stream");
    http::field(out, "Cache-Control", "no-cache");
    reading(st, out, b);
}

// Sends one temperature, then waits for the next or ends the stream.
fn reading(st: Watch&, out: http::Reply, b: const Board&) {
    let temp, has = read_value(str(b.thermal, "/temp"));
    var text: u8[>..] = [];
    text.append("data: {\"temp_mc\":");
    if has { format(text, temp); } else { text.append("null"); }
    text.append("}\n\n");
    http::send(out, text);
    if st.left > 0 { st.left--; }
    guard st.left != 0 else { http::end(out); return; }
    http::later(out, st.ms);
}

// The number in the sysfs file at path. A sysfs read doesn't block, so a
// worker can make it between requests.
fn read_value(path: const u8[:]) -> i64, bool {
    var text: u8[>..] = [];
    guard read_file(path, text) else { return 0, false; }
    return parse_int(trim(text));
}

fn on_off(s: const u8[:]) -> bool, bool {
    if s == "on" { return true, true; }
    return false, s == "off";
}

fn query_or(target: const u8[:], key: const u8[:], otherwise: i64) -> i64 {
    let v, has = http::query_of(target, key);
    guard has else { return otherwise; }
    let n, ok = parse_int(v);
    return if ok { n } else { otherwise };
}

// The environment variable name into to, which it must fit.
fn setting(name: const u8[:], to: u8[..128]&) {
    var v: u8[>..] = [];
    guard env(name, v) else { return; }
    guard v.len <= 128 else { write_stderr(str(name, " is too long\n")); exit(2); }
    to.clear();
    to.append(v);
}

fn main() {
    http::exit_on_error(http::stop_on_signals());
    var b = Board { .. };
    setting("THERMAL", b.thermal);
    setting("LED", b.led);
    var name: u8[>..] = [];
    if !env("LOOP", name) { name.append("uring"); }
    guard name == "uring" || name == "epoll" else { write_stderr("LOOP must be uring or epoll\n"); exit(2); }
    b.epoll = name == "epoll";

    var line: u8[>..] = [];
    if env("GPIO", line) {
        var at = line.len - 1;
        while at >= 0 && line[at] != ':' { at--; }
        let n, ok = parse_int(line[at + 1..]);
        guard at > 0 && ok && n >= 0 && n < 1 << 31 else {
            write_stderr("GPIO must be CHIP:LINE, such as /dev/gpiochip0:17\n");
            exit(2);
        }
        let e = board_gpio_open(line[..at], n as i32);
        http::exit_on_error(http::Error { call: "GPIO", code: -e });
    }

    // A stream's timer needs waiting on, though no thread mails the workers.
    var cfg = http::Config { port: 8080, mail_slots: 4, max_waiting: 64, .. };
    var workers: u8[>..] = [];
    if env("WORKERS", workers) {
        let n, ok = parse_int(workers);
        guard ok && n > 0 else { write_stderr("WORKERS must be a positive number\n"); exit(2); }
        cfg.workers = n;
    }

    // Where io_uring is blocked or too old, the uring loop runs over an
    // emulation on epoll, and says so.
    var ring: u8[>..] = [];
    let probe = if b.epoll { 0 } else { http::ring_probe() };
    if probe < 0 {
        var text: u8[128] = [0; 128];
        let k = http::net_strerror(-probe, text);
        format(ring, " on an emulated ring (io_uring_setup: ", text[..k], ")");
    }
    let n = http::worker_count(cfg);
    print("listening on port ", cfg.port, ", ", n, if n == 1 { " worker" } else { " workers" }, ", ",
          name, " loop", ring, if board_gpio_simulated() { ", GPIO simulated" } else { "" });
    if b.epoll { http::run(cfg, b, worker_epoll) } else { http::run(cfg, b, worker) }
}
