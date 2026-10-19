// Taking a box over after its owner aborts: mail_take settles a round's
// messages after its callback, so an abort inside it leaves them counted,
// and mail_adopt in the next owner settles them. Without it, the count
// stays above what the box holds, and mail_stopped never comes true. The
// package is declared by mail.goose alone; the sidecar beside it names the C.
import std;
import os;
import mail from "../../";

let FAIL: i32 = 2;

// Takes jobs, and aborts at the one tagged FAIL.
thread_fn owner(box: http::Box) {
    http::mail_take(box) { key, tag, bytes => if tag == FAIL { abort("asked to fail"); } };
}

// Aborts before taking anything.
thread_fn owner_early(box: http::Box) { abort("fails before its first take"); }

// The rest of the box, taken by this thread, the new owner, then a stop.
fn take_rest(b: http::Box) {
    var tags: i64[>..] = [];
    http::mail_take(b) { key, tag, bytes => tags.push(tag); };
    print("  took the rest: ", tags);
    print("  pending after: ", http::mail_pending(b));
    http::mail_stop(b);
    print("  stopped: ", http::mail_stopped(b));
    http::mail_close(b);
}

// Four jobs, the second of which aborts its owner: the first two stay
// counted until the new owner adopts the box.
fn test_abort_in_take() {
    let b, err = http::mail_open_code(8, 8);
    assert(err == 0);
    let to = http::address(b, 0);
    for tag in 1..5 { assert(http::mail_send(to, tag as i32, "") == http::SENT); }
    print("abort in mail_take:");
    print("  returned: ", thread_wait(thread_spawn_contained(owner, b)));
    print("  queued before adopt: ", http::mail_queued(to));
    print("  adopt: ", http::mail_adopt(b));
    print("  queued after adopt: ", http::mail_queued(to));
    take_rest(b);
}

// An owner that aborts before it takes anything: adopt changes nothing.
fn test_abort_before_take() {
    let b, err = http::mail_open_code(8, 8);
    assert(err == 0);
    let to = http::address(b, 0);
    for tag in 1..3 { assert(http::mail_send(to, tag as i32, "") == http::SENT); }
    print("abort before a take:");
    print("  returned: ", thread_wait(thread_spawn_contained(owner_early, b)));
    print("  adopt: ", http::mail_adopt(b));
    print("  queued after adopt: ", http::mail_queued(to));
    take_rest(b);
}

fn main() {
    test_abort_in_take();
    test_abort_before_take();
}
