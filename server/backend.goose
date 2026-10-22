// The benchmark server's lane for /later and /events: its thread takes jobs
// from the HTTP workers, and answers each, after a delay its own timer table
// keeps, by mail to the exchange's address (http::later). A job asks for
// count replies, one every delay milliseconds: one for /later, as many as
// the events for /events.
import std;
import os;
import http;

// A job's tag: the kind of job. A reply's tag: whether more follow.
let JOB_LATER: i32 = 1;
let JOB_EVENTS: i32 = 2;
let REPLY_MORE: i32 = 1;
let REPLY_LAST: i32 = 2;

// A job as the backend keeps it, and as it crosses a box
// (http::lane_send_value).
struct Job { reply: http::MailAddress, delay: i64, count: i64, sent: i64, id: u8[..32] }

// The most bytes a job takes in a box: its image, which holds id's whole
// capacity, is 74 bytes.
let JOB_SIZE: i32 = 80;
// The most bytes a reply takes in a worker's box: the id and the reply's
// number.
let REPLY_SIZE: i32 = 64;

// Takes jobs from box until the lane is stopped and its box is empty,
// keeping up to capacity at once; a job past that is answered at once with
// "busy". It writes the loop http::lane is, since its wait ends at its next
// timer as well.
thread_fn backend(box: http::Box, capacity: i64) {
    var check: u8[>..] = [];
    let check_stale = env("MAIL_CHECK_STALE", check) && check == "1";
    var timers = http::timer_table(capacity);
    var jobs: Job[>..] = [];
    var free: i64[>..<] = [];
    for i in capacity {
        jobs.push(Job { .. });
        free.push(capacity - 1 - i);
    }
    var reply: u8[>..] = [];

    // Sends job i its next reply, and frees it after the last.
    fn answer(i: i64, now: i64) {
        let j .= jobs[i];
        j.sent++;
        reply.clear();
        reply.append(j.id);
        format(reply, " ", j.sent);
        let last = j.sent >= j.count;
        // A FULL box loses this reply, as STALE does for an exchange that's
        // gone: the exchange waits out its time limit. REPLY_SIZE holds any
        // reply, so none is TOO_LONG.
        var result = http::mail_send(j.reply, if last { REPLY_LAST } else { REPLY_MORE }, reply);
        if check_stale && (j.id == "gone" || j.id == "expired") {
            assert(result == http::STALE && !http::mail_live(j.reply));
            print("mail stale: ", j.id);
        }
        // A burst's pieces go back to back, retrying a full box as
        // Plod's plod::answer does: none may find the exchange stale
        // while it waits again for the next.
        if check_stale && j.id == "burst" {
            while result == http::FULL { result = http::mail_send(j.reply, if last { REPLY_LAST } else { REPLY_MORE }, reply); }
            assert(result == http::SENT);
        }
        if last { free.push(i); }
        else { http::arm(timers, i as u64, now + j.delay); }
    }

    while !http::mail_stopped(box) {
        let now = http::net_clock_ms();
        let due, any = http::next_due(timers);
        http::mail_wait(box, if any { min(max(due - now, 0), 1000) as i32 } else { 1000 });
        let t = http::net_clock_ms();
        http::mail_take(box) { key, tag, bytes =>
            var j = Job { .. };
            let ok = http::mail_value(bytes, j);
            j.delay = max(j.delay, 0);
            j.count = max(j.count, 1);
            j.sent = 0;
            if tag != JOB_LATER && tag != JOB_EVENTS || !ok {
                // Not a job: dropped.
            } else if free.len == 0 {
                http::mail_send(j.reply, REPLY_LAST, "busy");
            } else {
                let i = free.pop();
                jobs[i] = j;
                http::arm(timers, i as u64, t + j.delay);
            }
        };
        http::expire(timers, t) { key => answer(key as i64, t); };
    }
    http::mail_close(box);
}
