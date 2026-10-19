// Mail between threads: a box has a fixed number of slots of a fixed size, allocated
// when it opens, and one owner, the thread that takes from it. Any thread
// sends to it by address, and the send says at once whether the message
// went in: SENT, FULL (no slot free, which may pass), TOO_LONG (the message
// longer than a slot, which never will), or STALE (the box is closed, or
// opened again since the address was taken, or its tracked key isn't live).
// mail_slot_size gives a sender
// the slot size from the address alone. A send never blocks or grows the
// box. An address is the box's handle and a
// 64-bit key, which comes back with each message sent to it. A box may track
// keys the owner marks live; the owner gives them their meaning.
//
// The queue and the wakeup are C (shim/mail.c, and each platform's net_waker),
// since Goose has neither atomics nor a wait another thread can end. Nothing
// here knows HTTP: this file imports nothing of the package's HTTP side, so
// that it can move to a package of its own unchanged. So mail_open_code
// returns an error code, and http.goose's mail_open an Error.
//
//   let b, err = http::mail_open(256, 512);
//   http::exit_on_error(err);
//   http::mail_send(http::address(b, key), tag, bytes);   // from any thread
//   http::mail_wait(b, 1000);                             // in b's owner
//   http::mail_take(b) { key, tag, bytes => ... };
namespace http;

import std;
import handle;

// The owner's handle to its box. Flat, so it crosses thread_spawn and
// queues, but only the owner takes, waits, or closes.
struct Box { handle: Handle = Handle { .. } }

// Where a message goes: a box, and the key it comes with.
struct MailAddress { box: Handle = Handle { .. }, key: u64 = 0 }

// What mail_send returns.
let SENT: i32 = 0;
let FULL: i32 = 1;
let STALE: i32 = 2;
let TOO_LONG: i32 = 3;

// The shim's calls, on a box's key (key_of its handle). shim/mail.c says
// what each does. mail_take_one writes up to out.len bytes into out and 2
// values into head.
extern "mail_open" fn mail_open_c(slots: i32, size: i32, waker: i64, live_keys: i32, key_shift: i32) -> i64;
extern "mail_close" fn mail_close_c(box: u64);
extern "mail_mark" fn mail_mark_c(box: u64, key: u64, live: i32);
extern "mail_live" fn mail_live_c(box: u64, key: u64) -> i32;
extern "mail_send" fn mail_send_c(to: u64, key: u64, tag: i32, data: const u8[:]) -> i32;
extern "mail_pending" fn mail_pending_c(box: u64) -> i64;
extern "mail_size" fn mail_size_c(box: u64) -> i32;
extern "mail_slot_size" fn mail_slot_size_c(to: u64, key: u64) -> i32;
extern "mail_take_one" fn mail_take_one_c(box: u64, out: u8[:], head: i64[:]) -> i64;
extern "mail_settle" fn mail_settle_c(box: u64, n: i64) -> i32;
extern "mail_adopt" fn mail_adopt_c(box: u64) -> i32;
extern "mail_wait" fn mail_wait_c(box: u64, ms: i32) -> i32;
extern "mail_stop" fn mail_stop_c(to: u64);
extern "mail_queued" fn mail_queued_c(to: u64, key: u64) -> i64;
extern "mail_stopped" fn mail_stopped_c(box: u64) -> i32;

// A waker for a loop's epoll or kqueue instance ep: each wake makes the
// loop's wait report tag as readable. Returns it, or -code. A box opened
// with it owns it, and the box is closed before ep.
extern fn net_waker(ep: i32, tag: u64) -> i64;

// Opens a box of slots messages, a power of two of at least 2, of up to size
// bytes each.
// waker is a loop's (net_waker, ring_waker), which the box then owns, or 0
// for one the box makes for mail_wait. With live_keys > 0, sends require a
// nonzero key marked live in entry key >> key_shift (0..63). The table has
// live_keys entries of 8 bytes, initially empty. With 0, any key is accepted.
// Returns the box, and 0 or -code.
fn mail_open_code(slots: i32, size: i32, waker: i64 = 0, live_keys: i32 = 0, key_shift: i32 = 0) -> Box, i64 {
    let k = mail_open_c(slots, size, waker, live_keys, key_shift);
    guard k >= 0 else { return Box { .. }, k; }
    return Box { handle: handle_of(k as u64) }, 0;
}

// Closes b, and drops what it holds: sends to it return STALE from then on.
fn mail_close(b: Box) { mail_close_c(key_of(b.handle)); }

// The address of b with key.
fn address(b: Box, key: u64) -> MailAddress { MailAddress { box: b.handle, key: key } }

// In the owner only: marks key live, replacing its entry, or clears it if
// it still matches. Does nothing for an untracked box or an invalid key.
fn mail_mark(b: Box, key: u64, live: bool) { mail_mark_c(key_of(b.handle), key, if live { 1 } else { 0 }); }

// Any thread: whether the box is open, not stopped, and accepts this key now. A snapshot:
// the owner may clear it before a following send, which then returns STALE.
// A send already in flight or queued may still arrive after a clear.
fn mail_live(to: MailAddress) -> bool { mail_live_c(key_of(to.box), to.key) != 0 }

// Sends data with tag to to's box, at once. Any thread may call it.
fn mail_send(to: MailAddress, tag: i32, data: const u8[:]) -> i32 {
    return mail_send_c(key_of(to.box), to.key, tag, data);
}

// The most bytes a message to to's box may have, or -1 for an address that's
// STALE, including a stopped box. Any thread may call it.
fn mail_slot_size(to: MailAddress) -> i32 { mail_slot_size_c(key_of(to.box), to.key) }

// How many messages to's box holds, or -1 for an address that's STALE or a
// box that's stopped. Those its owner's mail_take has taken stay counted
// until it settles them, after each run of the box's messages it finds, so
// the job in progress may be counted too. Any thread may call it: a snapshot, for picking the least
// busy of several boxes.
fn mail_queued(to: MailAddress) -> i64 { mail_queued_c(key_of(to.box), to.key) }

// Sends v, a flat value, with tag to to's box, as mail_send does: the image
// to_bytes writes of a one-element array, which mail_value reads back. A
// limited array's image takes its whole capacity, so the box's size must
// hold that.
fn mail_send_value(to: MailAddress, tag: i32, v) -> i32 {
    var one = [v];
    var image: u8[>..] = [];
    one.to_bytes(image);
    return mail_send(to, tag, image);
}

// Reads into out the value mail_send_value sent as bytes, verified by
// from_bytes. False, with out as it was, for bytes that aren't such an image.
fn mail_value<T>(bytes: const u8[:], out: T&) -> bool {
    let a, ok = from_bytes<T[>..]>(bytes);
    guard ok && a.len == 1 else { return false; }
    out = a[0];
    return true;
}

// Whether b holds messages it hasn't taken: one atomic load.
fn mail_pending(b: Box) -> bool { mail_pending_c(key_of(b.handle)) > 0 }

// Waits up to ms milliseconds (-1: no limit) for a message, in b's owner when
// b has no loop's waker. Returns whether one is pending: false at the time
// limit, or after a wake whose message was taken already. Once b is stopped,
// it returns at once on every call, false when nothing is pending, so a loop
// that waits checks mail_stopped.
fn mail_wait(b: Box, ms: i32) -> bool { mail_wait_c(key_of(b.handle), ms) > 0 }

// Stops b, from any thread: sends to it return STALE from then on, and a
// mail_wait in its owner returns. A flag in the box, not a message, so a full
// box can't refuse it. What b holds already is still taken.
fn mail_stop(b: Box) { mail_stop_c(key_of(b.handle)); }

// In b's owner: whether b is stopped and holds nothing more, which ends a
// lane's loop:
//
//   while !http::mail_stopped(b) { http::mail_wait(b, -1); http::mail_take(b) { ... }; }
//   http::mail_close(b);
fn mail_stopped(b: Box) -> bool { mail_stopped_c(key_of(b.handle)) != 0 }

// Calls F with each message b holds, in the order sent: the key of the
// address it was sent to, its tag, and its bytes, valid until F returns.
// Returns how many it took. Messages that come while it runs are taken too.
fn mail_take<F>(b: Box) -> i64 {
    let k = key_of(b.handle);
    var buf: u8[>..] = [];
    buf.resize(mail_size_c(k), 0);
    var head: i64[2] = [0; 2];
    var total = 0;
    loop {
        var n = 0;
        loop {
            let len = mail_take_one_c(k, buf, head);
            guard len >= 0 else { break; }
            F(head[0] as! u64, head[1] as! i32, buf[..len]);
            n++;
        }
        total += n;
        guard mail_settle_c(k, n) != 0 else { break; }
    }
    return total;
}

// For a thread that takes b over after its owner ended without settling, as
// an abort in mail_take's F does: settles what that owner took, so that b's
// count holds only what's still in it. Call it once thread_wait has returned
// for the old owner, before taking. Returns whether b holds messages.
fn mail_adopt(b: Box) -> bool { mail_adopt_c(key_of(b.handle)) != 0 }
