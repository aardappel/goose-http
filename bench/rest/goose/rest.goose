// The REST benchmark's Goose server (task 021): each tier's routes, answered
// from the generator's dataset files (bench/rest/gen.goose), which it loads at
// startup. Tier A is HttpArena's production-stack application layer:
//
//   GET  /api/items/:id    the item, and servedAt, the time in seconds
//   GET  /api/me           the user X-User-Id names, and servedAt
//   POST /api/items/:id    a body of name, price, and quantity, each optional:
//                          204, or 422 for a body that isn't one; the data
//                          doesn't change, so every server serves the same
//
// Tier B is snowtime's k6 hot path, answered as snowtime's Hono routes answer:
//
//   GET   /api/v1/session                        the session, or null
//   GET   /api/v1/timer                          the running timer, or null
//   GET   /api/v1/organizations/:org/entries     ?from=&to=&userId=
//   GET   /api/v1/organizations/:org/projects    ?includeArchived=
//   PATCH /api/v1/organizations/:org/entries/:id {"description"}
//   POST  /api/v1/organizations/:org/timer/start {"id","description",...}
//   POST  /api/v1/timer/stop                     {"id"}
//
// Tier C is a clinic's schedule and records, synthetic, behind a bearer JWT:
//
//   GET   /api/v2/schedule/version               ?since=, the schedule's poll
//   GET   /api/v2/schedule/bookings              ?start=&end=&staff=1,2,...
//   GET   /api/v2/schedule/shifts                ?start=&end=&staff=1,2,...
//   GET   /api/v2/encounters/:id                 the visit, and its case's notes
//   GET   /api/v2/clients/:id/encounters         ?limit=, the past visits
//   GET   /api/v2/clients/:id                    the client
//
// Tier D is writes with large bodies, answered from the body alone, beside
// tier C's routes, behind the same token:
//
//   POST  /api/v3/imports                        a CSV: its rows, and each column's count and sum
//   POST  /api/v3/attachments                    multipart: the fields, the file's size and Adler-32
//   POST  /api/v3/bookings/batch                 JSON: each booking's id, or 422 with the errors
//   POST  /api/v3/forms                          a form: its fields, decoded
//
//   REST_DATA=DIR TIER=a|b|c|d WORKERS=n [LOOP=epoll] [JSON=template] rest [port]
//
// TIER picks the dataset to load, tier A's by default. JSON=template answers
// from each record's JSON, written once at startup, with the per-request
// values added, where the default writes each response's JSON from the
// records. Tier D's answers are written the one way, as each is new.
//
// The records, their JSON, and tier D's work on a body are app.goose's, which
// Plod's server imports too; this file is what the benchmark compares:
// the routes, a request's parameters and headers, the errors, the loader,
// the workers, and main.
import std;
import os;
import json;
import http from "../../../";
import http.store;
import .app;

// The record's JSON, and servedAt, the time in seconds, into body.
fn served(body: u8[>..]&) {
    body.append(",\"servedAt\":");
    format(body, http::net_time_s());
    body.push('}');
}

// id as a record's index, or -1 when it isn't one of n.
fn index_of(id: const u8[:], n: i64) -> i64 {
    let v, ok = parse_int(id);
    return if ok && v >= 1 && v <= n { v - 1 } else { -1 };
}

// A write's body: an object of name (a string), price, and quantity
// (integers), each optional. Whether it's one.
fn valid_write(body: const u8[:]) -> bool {
    var scratch: u8[>..] = [];
    var r = json::reader(body);
    guard json::peek(r) == '{' else { return false; }
    json::each_member(r) { key =>
        if key == "name" { json::read_string(r, scratch); }
        else if key == "price" || key == "quantity" { json::read_int(r); }
        else { json::skip(r); }
    };
    return json::finish(r);
}

// Tier B, snowtime's k6 hot path, under /api/v1. A session cookie names the
// user, by its token; a write needs Origin to be the app's. The data doesn't
// change: a PATCH answers the entry with the description it was sent, and
// timer start and stop answer as of now, as if the timer had started.

let SESSION_COOKIE = "__Secure-better-auth.session_token";

fn is_lower_hex(c: u8) -> bool { c >= '0' && c <= '9' || c >= 'a' && c <= 'f' }

// snowtime's Uuidv7: 8-4-4-4-12 lower-case hex digits, version 7, variant 8
// to b.
fn is_uuid7(s: const u8[:]) -> bool {
    guard s.len == 36 && s[14] == '7' && (s[19] == '8' || s[19] == '9' || s[19] == 'a' || s[19] == 'b')
        else { return false; }
    for c, i in s {
        if i == 8 || i == 13 || i == 18 || i == 23 { if c != '-' { return false; } }
        else if !is_lower_hex(c) { return false; }
    }
    return true;
}

// The time a uuidv7 was made, from its first 48 bits.
fn uuid_ms(s: const u8[:]) -> i64 {
    var v = 0;
    for c, i in s[..13] {
        if i == 8 { continue; }
        v = v * 16 + (if c <= '9' { c - '0' } else { c - 'a' + 10 });
    }
    return v;
}

// snowtime's ticket key: [A-Z][A-Z0-9]{1,9}-[1-9][0-9]{0,6}.
fn is_ticket(s: const u8[:]) -> bool {
    let dash = position(s, '-');
    guard dash >= 2 && dash <= 10 && s[0] >= 'A' && s[0] <= 'Z' else { return false; }
    for c in s[1..dash] { if !(c >= 'A' && c <= 'Z' || c >= '0' && c <= '9') { return false; } }
    let n = s[dash + 1..];
    guard n.len >= 1 && n.len <= 7 && n[0] >= '1' && n[0] <= '9' else { return false; }
    for c in n { if c < '0' || c > '9' { return false; } }
    return true;
}

fn now_ms() -> i64 { time_ns() / 1000000 }

// The person the session cookie names, or -1.
fn person_of(req: http::Request) -> i64 {
    let v, has = http::cookie_of(req, SESSION_COOKIE);
    guard has && v.len > 65 && v[64] == '.' else { return -1; }
    let token = v[..64];
    let k = lower_bound(by_token) { compare(people[it].token, token) < 0 };
    return if k < by_token.len && people[by_token[k]].token == token { by_token[k] } else { -1 };
}

fn error(out: http::Reply, status: i32, body: const u8[:]) { http::respond(out, status, "application/json", body); }

fn coded(out: http::Reply, status: i32, code: const u8[:], key: const u8[:]) {
    var b: u8[>..] = [];
    format(b, "{\"error\":{\"code\":\"", code, "\",\"key\":\"", key, "\"}}");
    http::respond(out, status, "application/json", b);
}

fn invalid(out: http::Reply) { error(out, 400, "{\"error\":{\"message\":\"Invalid input.\"}}"); }

fn not_json(out: http::Reply) { error(out, 400, "{\"error\":{\"message\":\"The body is not JSON.\"}}"); }

// A query value, percent-decoded into scratch.
fn query(req: http::Request, key: const u8[:], scratch: u8[>..]&) -> const u8[:], bool {
    let v, has = http::query_of(req.target, key);
    guard has else { return "", false; }
    scratch.clear();
    guard http::decode(v, scratch) else { return "", false; }
    return scratch, true;
}

// GET .../entries: the entries of userId, or of the caller, that overlap
// [from, to), newest first, as listEntries selects them.
fn list_entries(req: http::Request, p: Person, m: Member, buf: u8[>..]&, out: http::Reply) {
    var scratch: u8[>..] = [];
    let fs, has_from = query(req, "from", scratch);
    let from, from_ok = parse_iso(fs);
    let ts, has_to = query(req, "to", scratch);
    let to, to_ok = parse_iso(ts);
    guard has_from && from_ok && has_to && to_ok && to > from && to - from <= 93 * DAY else { invalid(out); return; }
    var who = person_index(p.id);
    let uid, has_user = query(req, "userId", scratch);
    if has_user {
        guard is_uuid7(uid) else { invalid(out); return; }
        if uid != p.id {
            guard is_admin(m) else { coded(out, 403, "FORBIDDEN", "entries_forbidden"); return; }
            who = person_index(uid);
        }
    }
    buf.push('[');
    if who >= 0 && people[who].active == m.org {
        let u = people[who];
        let mine = entries[u.first..u.first + u.count];
        var i = lower_bound(mine) { it.started < to } - 1;
        var n = 0;
        while i >= 0 && mine[i].started > from - DAY {
            if mine[i].stopped < 0 || mine[i].stopped > from {
                if n > 0 { buf.push(','); }
                snow_entry(buf, u.first + i);
                n++;
            }
            i--;
        }
    }
    buf.push(']');
    http::respond(out, 200, "application/json", buf);
}

fn list_projects(req: http::Request, p: Person, m: Member, buf: u8[>..]&, out: http::Reply) {
    let v, has = http::query_of(req.target, "includeArchived");
    guard !has || v == "true" || v == "false" else { invalid(out); return; }
    let archived = has && v == "true";
    let o = orgs[m.org];
    buf.push('[');
    var n = 0;
    for i in o.first..o.first + o.count {
        let j = projects[i];
        if (archived || j.archived < 0) && sees(p, m, j) {
            if n > 0 { buf.push(','); }
            if template { http::store_append(tpl.project, project_at[i], project_at[i + 1], buf); } else { project_full(buf, j); }
            n++;
        }
    }
    buf.push(']');
    http::respond(out, 200, "application/json", buf);
}

// Whether body is one JSON value.
fn is_json(body: const u8[:]) -> bool {
    var r = json::reader(body);
    json::skip(r);
    return json::finish(r);
}

// The trimmed string member, at most 500 bytes: false for another type or a
// longer one.
fn description_of(r: json::Reader&, scratch: u8[>..]&) -> const u8[:], bool {
    guard json::peek(r) == '"' else { json::skip(r); return "", false; }
    let s = trim(json::read_string(r, scratch));
    return s, s.len <= 500;
}

fn patch_entry(id: const u8[:], body: const u8[:], p: Person, m: Member, buf: u8[>..]&, out: http::Reply) {
    guard is_uuid7(id) else { invalid(out); return; }
    guard is_json(body) else { not_json(out); return; }
    var scratch: u8[>..] = [];
    var r = json::reader(body);
    var description: u8[>..] = [];
    var has = false;
    var ok = json::peek(r) == '{';
    if ok {
        json::each_member(r) { key =>
            if key == "description" {
                let d, fits = description_of(r, scratch);
                description.append(d);
                ok = ok && fits;
                has = true;
            } else { json::skip(r); }
        };
    }
    guard ok && json::finish(r) else { invalid(out); return; }
    let i = entry_index(id);
    guard i >= 0 && entries[i].org == m.org else { coded(out, 404, "NOT_FOUND", "entry_not_found"); return; }
    guard people[entries[i].user].id == p.id || is_admin(m) else { coded(out, 403, "FORBIDDEN", "entry_forbidden"); return; }
    if has { snow_entry_as(buf, i, description); } else { snow_entry(buf, i); }
    http::respond(out, 200, "application/json", buf);
}

// POST .../timer/start: the new entry, started now, and the timer it
// stopped, the caller's running one, or null.
fn start_timer(body: const u8[:], u: i64, m: Member, buf: u8[>..]&, out: http::Reply) {
    guard is_json(body) else { not_json(out); return; }
    var scratch: u8[>..] = [];
    var r = json::reader(body);
    var id: u8[..36] = "";
    var description: u8[>..] = [];
    var ticket: u8[..18] = "";
    var project: u8[..36] = "";
    var ok = json::peek(r) == '{';
    if ok {
        json::each_member(r) { key =>
            let c = json::peek(r);
            if key == "description" {
                let d, fits = description_of(r, scratch);
                description.append(d);
                ok = ok && fits;
            } else if c == 'n' && (key == "ticket" || key == "projectId") {
                json::skip(r);
            } else if key == "id" || key == "ticket" || key == "projectId" {
                let s = if c == '"' { json::read_string(r, scratch) } else { "" };
                if s.len == 0 { ok = false; json::skip(r); }
                else if key == "id" && s.len <= id.cap { id.append(s); }
                else if key == "ticket" && s.len <= ticket.cap && is_ticket(s) { ticket.append(s); }
                else if key == "projectId" && is_uuid7(s) { project.append(s); }
                else { ok = false; }
            } else { json::skip(r); }
        };
    }
    guard ok && json::finish(r) && is_uuid7(id) else { invalid(out); return; }
    let p = people[u];
    if project.len > 0 {
        let j = project_index(project, m.org);
        guard j >= 0 && sees(p, m, projects[j]) else { coded(out, 404, "NOT_FOUND", "project_not_found"); return; }
        guard projects[j].archived < 0 else { coded(out, 409, "CONFLICT", "project_archived"); return; }
    }
    guard entry_index(id) < 0 else { coded(out, 409, "CONFLICT", "entry_id_taken"); return; }
    let now = now_ms();
    buf.append("{\"started\":{\"id\":");
    http::json_string(buf, id);
    buf.append(",\"organizationId\":");
    http::json_string(buf, orgs[m.org].id);
    buf.append(",\"userId\":");
    http::json_string(buf, p.id);
    buf.append(",\"projectId\":");
    string_or_null(buf, project);
    buf.append(",\"description\":");
    http::json_string(buf, description);
    buf.append(",\"ticket\":");
    string_or_null(buf, ticket);
    buf.append(",\"startedAt\":");
    iso_or_null(buf, now);
    buf.append(",\"stoppedAt\":null},\"stopped\":");
    if p.running >= 0 { snow_stopped(buf, p.running, now); } else { buf.append("null"); }
    buf.push('}');
    http::respond(out, 200, "application/json", buf);
}

// POST /timer/stop: the caller's running entry, stopped now. An id the
// dataset doesn't have is taken for a timer started with it, as timer start
// answered it: a uuidv7 made in the last day.
fn stop_timer(body: const u8[:], u: i64, buf: u8[>..]&, out: http::Reply) {
    guard is_json(body) else { not_json(out); return; }
    var scratch: u8[>..] = [];
    var r = json::reader(body);
    var id: u8[..36] = "";
    var ok = json::peek(r) == '{';
    if ok {
        json::each_member(r) { key =>
            if key == "id" && json::peek(r) == '"' {
                let s = json::read_string(r, scratch);
                if s.len <= id.cap { id.append(s); } else { ok = false; }
            } else { json::skip(r); }
        };
    }
    guard ok && json::finish(r) && is_uuid7(id) else { invalid(out); return; }
    let p = people[u];
    let now = now_ms();
    if p.running >= 0 && entries[p.running].id == id {
        snow_stopped(buf, p.running, now);
    } else {
        let started = uuid_ms(id);
        guard started > now - DAY && started <= now + MINUTE && entry_index(id) < 0
            else { coded(out, 404, "NOT_FOUND", "timer_not_running"); return; }
        buf.append("{\"id\":");
        http::json_string(buf, id);
        buf.append(",\"organizationId\":");
        http::json_string(buf, orgs[p.active].id);
        buf.append(",\"userId\":");
        http::json_string(buf, p.id);
        buf.append(",\"projectId\":null,\"description\":\"\",\"ticket\":null,\"startedAt\":");
        iso_or_null(buf, started);
        buf.append(",\"stoppedAt\":");
        iso_or_null(buf, min(max(now, started + 1), started + DAY));
        buf.push('}');
    }
    http::respond(out, 200, "application/json", buf);
}

// Tier B's routes, checked in snowtime's order: an unknown call, a write
// from another origin, GET /session, which answers null to no one, the
// sign-in, and the organization's membership.
fn snow(req: http::Request, body: const u8[:], buf: u8[>..]&, out: http::Reply) {
    var r = http::router(req);
    var route = 0;
    if http::on(r, "GET", "/api/v1/session") { route = 1; }
    else if http::on(r, "GET", "/api/v1/timer") { route = 2; }
    else if http::on(r, "POST", "/api/v1/timer/stop") { route = 3; }
    else if http::on(r, "GET", "/api/v1/organizations/:org/entries") { route = 4; }
    else if http::on(r, "GET", "/api/v1/organizations/:org/projects") { route = 5; }
    else if http::on(r, "PATCH", "/api/v1/organizations/:org/entries/:id") { route = 6; }
    else if http::on(r, "POST", "/api/v1/organizations/:org/timer/start") { route = 7; }
    guard route > 0 else { error(out, 404, "{\"error\":{\"message\":\"No such call.\"}}"); return; }
    if req.method != "GET" && req.method != "HEAD" {
        let origin, has = http::field_of(req, "origin");
        guard has && origin == APP_URL
            else { error(out, 403, "{\"error\":{\"message\":\"Cross-origin request refused.\"}}"); return; }
    }
    let u = person_of(req);
    if route == 1 {
        if u < 0 { buf.append("null"); }
        else if template { http::store_append(tpl.session, session_at[u], session_at[u + 1], buf); }
        else { session_open(buf, people[u]); }
        http::respond(out, 200, "application/json", buf);
        return;
    }
    guard u >= 0 else { coded(out, 401, "UNAUTHENTICATED", "sign_in_required"); return; }
    let p = people[u];
    if route == 2 {
        if template { http::store_append(tpl.timer, timer_at[u], timer_at[u + 1], buf); }
        else if p.running >= 0 { timer_full(buf, entries[p.running]); }
        else { buf.append("null"); }
        http::respond(out, 200, "application/json", buf);
        return;
    }
    if route == 3 { stop_timer(body, u, buf, out); return; }
    let k = membership(p, http::param(r, "org"));
    guard k >= 0 else { coded(out, 403, "FORBIDDEN", "not_organization_member"); return; }
    let m = p.orgs[k];
    if route == 4 { list_entries(req, p, m, buf, out); }
    else if route == 5 { list_projects(req, p, m, buf, out); }
    else if route == 6 { patch_entry(http::param(r, "id"), body, p, m, buf, out); }
    else { start_timer(body, u, m, buf, out); }
}

// Tier C, a clinic's schedule and records, under /api/v2. A request needs a
// bearer token shaped as a JWT, which isn't verified. Ids are 1, 2, ... in
// each file, and the schedule's days are UTC's.

fn heavy_error(out: http::Reply, status: i32) {
    let body = if status == 400 { "{\"error\":\"bad_request\",\"status\":400}" }
               else if status == 401 { "{\"error\":\"unauthorized\",\"status\":401}" }
               else if status == 415 { "{\"error\":\"unsupported_media_type\",\"status\":415}" }
               else { "{\"error\":\"not_found\",\"status\":404}" };
    http::respond(out, status, "application/json", body);
}

// A byte that is neither base64url nor '.', and '.', for find_any, which
// scans 16 bytes at a time, as Plod's server checks the token: a byte
// loop over tier C's 560-byte tokens took over a quarter of a request's cycles.
let NOT_JWT = not_jwt_set();
let DOT = byte_set(".");

fn not_jwt_set() -> ByteSet {
    var m = [true; 256];
    for c in 256 {
        if c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-' || c == '_' ||
           c == '.' {
            m[c] = false;
        }
    }
    return byte_set(m);
}

// Whether Authorization is a bearer token of three base64url segments.
fn has_bearer(req: http::Request) -> bool {
    let v, has = http::field_of(req, "authorization");
    guard has && v.len > 7 && v[..7] == "Bearer " else { return false; }
    let t = v[7..];
    guard find_any(t, NOT_JWT) < 0 else { return false; }
    let a = find_any(t, DOT);
    guard a > 0 else { return false; }
    let rest = t[a + 1..];
    let b = find_any(rest, DOT);
    return b > 0 && b + 1 < rest.len && find_any(rest[b + 1..], DOT) < 0;
}

// A start and an end day, end after start and at most 31 days on, and the
// staff of a list of their ids as bits: false for anything else.
fn range_of(req: http::Request) -> i64, i64, i64, bool {
    let s, has_start = http::query_of(req.target, "start");
    let e, has_end = http::query_of(req.target, "end");
    let ids, has_staff = http::query_of(req.target, "staff");
    guard has_start && has_end && has_staff else { return 0, 0, 0, false; }
    let start, start_ok = parse_day(s);
    let end, end_ok = parse_day(e);
    guard start_ok && end_ok && end > start && end - start <= 31 * DAY else { return 0, 0, 0, false; }
    var list: u8[>..] = [];
    guard http::decode(ids, list) else { return 0, 0, 0, false; }
    var mask = 0;
    var ok = list.len > 0;
    each_split(list, ',') {
        let n, num = parse_int(it);
        if num && n >= 1 && n <= staffers.len { mask |= 1 << (n - 1); } else { ok = false; }
    };
    return start, end, mask, ok;
}

fn list_bookings(req: http::Request, buf: u8[>..]&, out: http::Reply) {
    let start, end, mask, ok = range_of(req);
    guard ok else { heavy_error(out, 400); return; }
    buf.append("{\"bookings\":[");
    var n = 0;
    var i = lower_bound(bookings) { it.start < start };
    while i < bookings.len && bookings[i].start < end {
        if (mask >> bookings[i].staff) & 1 != 0 {
            if n > 0 { buf.push(','); }
            if template { http::store_append(tpl.booking, booking_at[i], booking_at[i + 1], buf); } else { booking_full(buf, i); }
            n++;
        }
        i++;
    }
    buf.append("],\"count\":");
    format(buf, n);
    buf.push('}');
    http::respond(out, 200, "application/json", buf);
}

fn list_shifts(req: http::Request, buf: u8[>..]&, out: http::Reply) {
    let start, end, mask, ok = range_of(req);
    guard ok else { heavy_error(out, 400); return; }
    buf.append("{\"shifts\":[");
    var n = 0;
    var i = lower_bound(shifts) { it.start < start };
    while i < shifts.len && shifts[i].start < end {
        if (mask >> shifts[i].staff) & 1 != 0 {
            if n > 0 { buf.push(','); }
            if template { http::store_append(tpl.shift, shift_at[i], shift_at[i + 1], buf); } else { shift_full(buf, i); }
            n++;
        }
        i++;
    }
    buf.append("],\"count\":");
    format(buf, n);
    buf.push('}');
    http::respond(out, 200, "application/json", buf);
}

// The encounter, and the notes of every visit of its case, oldest first.
fn show_encounter(i: i64, buf: u8[>..]&, out: http::Reply) {
    let v = visits[i];
    visit_into(buf, i);
    buf.append(",\"caseNotes\":[");
    var n = 0;
    for c in v.case_first..v.case_first + v.case_count {
        let w = visits[c];
        for j in w.first_note..w.first_note + w.notes {
            if n > 0 { buf.push(','); }
            if template { http::store_append(tpl.note, note_at[j], note_at[j + 1], buf); } else { case_note_full(buf, notes[j]); }
            n++;
        }
    }
    buf.append("]}");
    http::respond(out, 200, "application/json", buf);
}

// The client's completed visits, newest first, up to limit, and how many
// there are.
fn client_history(req: http::Request, c: i64, buf: u8[>..]&, out: http::Reply) {
    var limit = 20;
    let v, has = http::query_of(req.target, "limit");
    if has {
        let n, ok = parse_int(v);
        guard ok && n >= 1 && n <= 50 else { heavy_error(out, 400); return; }
        limit = n;
    }
    let cl = clients[c];
    buf.append("{\"items\":[");
    for k in min(limit, cl.count) {
        if k > 0 { buf.push(','); }
        visit_into(buf, past[cl.first + k]);
        buf.push('}');
    }
    buf.append("],\"total\":");
    format(buf, cl.count);
    buf.push('}');
    http::respond(out, 200, "application/json", buf);
}

// GET /schedule/version: the schedule's version, the minutes since
// version_epoch, and when it changed to it.
fn schedule_version(req: http::Request, buf: u8[>..]&, out: http::Reply) {
    let since, has = http::query_of(req.target, "since");
    let n, ok = parse_int(since);
    guard has && ok && n >= 0 else { heavy_error(out, 400); return; }
    let version = (now_ms() - version_epoch) / MINUTE;
    buf.append("{\"version\":");
    format(buf, version);
    buf.append(",\"changedAt\":");
    iso_or_null(buf, version_epoch + version * MINUTE);
    buf.push('}');
    http::respond(out, 200, "application/json", buf);
}

fn heavy(req: http::Request, buf: u8[>..]&, out: http::Reply) {
    var r = http::router(req);
    var route = 0;
    if http::on(r, "GET", "/api/v2/schedule/version") { route = 1; }
    else if http::on(r, "GET", "/api/v2/schedule/bookings") { route = 2; }
    else if http::on(r, "GET", "/api/v2/schedule/shifts") { route = 3; }
    else if http::on(r, "GET", "/api/v2/encounters/:id") { route = 4; }
    else if http::on(r, "GET", "/api/v2/clients/:id/encounters") { route = 5; }
    else if http::on(r, "GET", "/api/v2/clients/:id") { route = 6; }
    guard route > 0 else { heavy_error(out, 404); return; }
    guard has_bearer(req) else { heavy_error(out, 401); return; }
    if route == 1 { schedule_version(req, buf, out); }
    else if route == 2 { list_bookings(req, buf, out); }
    else if route == 3 { list_shifts(req, buf, out); }
    else if route == 4 {
        let i = index_of(http::param(r, "id"), visits.len);
        guard i >= 0 else { heavy_error(out, 404); return; }
        show_encounter(i, buf, out);
    } else {
        let c = index_of(http::param(r, "id"), clients.len);
        guard c >= 0 else { heavy_error(out, 404); return; }
        if route == 5 { client_history(req, c, buf, out); }
        else {
            if template { http::store_append(tpl.client, client_at[c], client_at[c + 1], buf); } else { client_full(buf, c); }
            http::respond(out, 200, "application/json", buf);
        }
    }
}

// Tier D, writes with large bodies, under /api/v3, served beside tier C's
// reads for the mixed run. Each answer is computed from the body alone
// (app.goose), and the data doesn't change.

let IMPORT_LIMIT: i64 = 16777216;
let BATCH_LIMIT: i64 = 1048576;
let FORM_LIMIT: i64 = 65536;

let NO_WRITE: u8 = 0;
let IMPORT: u8 = 1;
let ATTACH: u8 = 2;
let BATCH: u8 = 3;
let FORM: u8 = 4;

// A request's state between the handler's calls: its route, its body's bytes
// so far, and the spool it reads into, or -1.
struct Upload { route: u8 = 0, taken: i64 = 0, spool: i64 = -1 }

fn write_limit(route: u8) -> i64 {
    if route == IMPORT || route == ATTACH { IMPORT_LIMIT } else if route == BATCH { BATCH_LIMIT } else { FORM_LIMIT }
}

fn release(st: Upload&) {
    guard st.spool >= 0 else { return; }
    let sp .= spools[st.spool];
    if sp.cap > 0 { spill.free_slice(spill[sp.at..sp.at + sp.cap]); }
    spools.free(st.spool);
    st.spool = -1;
}

fn write_piece(st: Upload&, data: const u8[:]) {
    let sp .= spools[st.spool];
    if st.route == IMPORT { csv_piece(sp.csv, data); }
    else if st.route == ATTACH { attach_piece(sp, data); }
    else { join(sp, data); }
}

// A write's answer, from its status and JSON: 0 for a body that isn't one.
fn answer(status: i32, buf: const u8[:], out: http::Reply) {
    if status == 0 { heavy_error(out, 400); } else { http::respond(out, status, "application/json", buf); }
}

fn write_end(st: Upload&, out: http::Reply) {
    var buf: u8[>..] = [];
    let sp .= spools[st.spool];
    let status = if st.route == IMPORT { import_answer(sp.csv, buf) }
                 else if st.route == ATTACH { attach_answer(sp, buf) }
                 else if st.route == BATCH { bookings_batch(joined(sp), buf) }
                 else { form_answer(joined(sp), buf) };
    answer(status, buf, out);
    release(st);
}

// A tier D request's head, and its body if it came whole.
fn write_begin(ev: http::Event, st: Upload&, out: http::Reply) {
    var r = http::router(ev.req);
    var route = NO_WRITE;
    if http::on(r, "POST", "/api/v3/imports") { route = IMPORT; }
    else if http::on(r, "POST", "/api/v3/attachments") { route = ATTACH; }
    else if http::on(r, "POST", "/api/v3/bookings/batch") { route = BATCH; }
    else if http::on(r, "POST", "/api/v3/forms") { route = FORM; }
    guard route != NO_WRITE else { heavy_error(out, 404); return; }
    guard has_bearer(ev.req) else { heavy_error(out, 401); return; }
    let want = if route == IMPORT { "text/csv" } else if route == ATTACH { "multipart/form-data" }
               else if route == BATCH { "application/json" } else { "application/x-www-form-urlencoded" };
    guard http::has_type(ev.req, want) else { heavy_error(out, 415); return; }
    guard http::body_within(st.taken, ev, out, write_limit(route)) else { return; }
    if ev.whole && (route == BATCH || route == FORM) {
        var buf: u8[>..] = [];
        let status = if route == BATCH { bookings_batch(ev.data, buf) } else { form_answer(ev.data, buf) };
        answer(status, buf, out);
        return;
    }
    st.route = route;
    st.spool = spools.alloc_index(Spool { .. });
    if route == ATTACH && !http::start_multipart(ev.req, spools[st.spool].parts) {
        release(st);
        heavy_error(out, 400);
        return;
    }
    if ev.whole {
        write_piece(st, ev.data);
        write_end(st, out);
    }
}

// TIER=d's handler: tier D's writes, in pieces, and the other tiers' routes,
// as serve(cfg) answers them.
inline fn handle_writes(ev: http::Event, st: Upload&, out: http::Reply) {
    if ev.kind == http::REQUEST {
        if starts_with(ev.req.target, "/api/v3/") { write_begin(ev, st, out); }
        else { http::whole(ev, out, handle); }
    } else if st.route != NO_WRITE {
        if ev.kind == http::BODY {
            if http::body_within(st.taken, ev, out, write_limit(st.route)) { write_piece(st, ev.data); } else { release(st); }
        } else if ev.kind == http::END {
            write_end(st, out);
        } else if ev.kind == http::CLOSED {
            release(st);
        }
    }
}

// Each response's JSON is built in a buffer of the request's own, which the
// data stack frees at the end of the request with one store: one kept in the
// worker and cleared per request is refused, the checker taking the loop's
// events for slices that may point into it.
inline fn handle(req: http::Request, body: const u8[:], out: http::Reply) {
    var buf: u8[>..] = [];
    if starts_with(req.target, "/api/v1/") { snow(req, body, buf, out); return; }
    if starts_with(req.target, "/api/v2/") { heavy(req, buf, out); return; }
    var r = http::router(req);
    if http::on(r, "GET", "/api/items/:id") {
        let i = index_of(http::param(r, "id"), item_count());
        guard i >= 0 else { http::respond(out, 404, "text/plain", ""); return; }
        if template { http::store_append(tpl.item, item_at[i], item_at[i + 1], buf); } else { item_open(buf, items[i]); }
        served(buf);
        http::respond(out, 200, "application/json", buf);
    } else if http::on(r, "GET", "/api/me") {
        let id, has = http::field_of(req, "x-user-id");
        let i = if has { index_of(id, user_count()) } else { -1 };
        guard i >= 0 else { http::respond(out, 401, "text/plain", ""); return; }
        if template { http::store_append(tpl.user, user_at[i], user_at[i + 1], buf); } else { user_open(buf, users[i]); }
        served(buf);
        http::respond(out, 200, "application/json", buf);
    } else if http::on(r, "POST", "/api/items/:id") {
        let i = index_of(http::param(r, "id"), item_count());
        guard i >= 0 else { http::respond(out, 404, "text/plain", ""); return; }
        guard valid_write(body) else { http::respond(out, 422, "text/plain", ""); return; }
        http::start(out, 204);
        http::finish(out, "", "");
    } else {
        http::otherwise(r, out);
    }
}

thread_fn worker(cfg: http::Config) {
    take_set();
    stopped(http::serve(cfg, handle));
}

thread_fn worker_epoll(cfg: http::Config) {
    take_set();
    stopped(http::serve_epoll(cfg, handle));
}

thread_fn worker_writes(cfg: http::Config) {
    take_set();
    stopped(http::serve(cfg, Upload { .. }, handle_writes));
}

thread_fn worker_writes_epoll(cfg: http::Config) {
    take_set();
    stopped(http::serve_epoll(cfg, Upload { .. }, handle_writes));
}

fn stopped(e: http::Error) {
    guard e.code != 0 else { return; }
    http::report(e);
    exit(1);
}

// A worker takes its records over the typed queues, not through
// thread_spawn, which would hold them twice for the worker's life: in the
// packet it copies the globals through, and on the worker's stacks
// (docs/goose-findings.md). main spawns the workers, so the globals a spawn
// copies are main's, which are empty. The loader puts one set of the arrays
// and returns; the distributor takes it and puts one set per worker, which
// the worker takes into its globals: the runtime copies each straight onto
// its stack and frees the queue's copy. Arrays of one element type share a
// queue, so one thread takes at a time, a whole set: the distributor puts
// the next set only after a Taken. Ready tells main a set is on the queues.
// The templates themselves are in the store, never on the queues
// (app.goose's share_templates).

// glibc's: with M_MMAP_THRESHOLD set, malloc keeps serving each queue copy
// with its own mapping, which free unmaps. Left to adjust itself, glibc
// raises the threshold to the first such block freed, so the next sets come
// from an arena that keeps their pages: about one set more, 17 MB on tier C
// templated, measured with 2 and 4 workers.
extern fn mallopt(param: i32, value: i32) -> i32;
let M_MMAP_THRESHOLD: i32 = -3;
struct Ready { set: i64 }
struct Taken { set: i64 }

// A worker's: takes its set, and tells the distributor it may put the next.
fn take_set() {
    take_all();
    qput(Taken { set: 0 });
}

// Takes the set the loader put, and puts one copy of it for each worker main
// spawns, the next only once the last is taken. The loader has returned by
// then, so the files it read and parsed are unmapped, and startup's peak
// holds this set, one copy on the queues, and the workers'.
thread_fn distributor(count: i64) {
    take_all();
    for i in count {
        hand_over();
        qput(Ready { set: i });
        qget<Taken>();
    }
}

// Loads the records into this thread's globals and puts one set of them on
// the queues for the distributor (hand_over). The runtime never gives a data
// stack's pages back while its thread runs, so main would hold the records
// and the files they were read from for the program's life; a thread's
// return unmaps both.
thread_fn loader(cfg: http::Config, tier: u8[..1], count: i64, epoll: bool) {
    var dir: u8[>..] = [];
    if !env("REST_DATA", dir) { dir.append("build/rest"); }
    var mode: u8[>..] = [];
    template = env("JSON", mode) && mode == "template";
    intern("");
    if tier == "a" {
        load_items(dir);
        load_users(dir);
        if template { prebuild(); }
    } else if tier == "b" {
        load_orgs(dir);
        load_people(dir);
        load_entries(dir);
        if template { prebuild_snow(); }
    } else {
        load_heavy(dir);
        if template { prebuild_heavy(); }
    }
    print("rest: tier ", tier, ", ", items.len + entries.len + bookings.len + visits.len, " records, ", count, " workers on port ", cfg.port,
          if epoll { ", epoll" } else { ", uring" }, if template { ", template" } else { ", serialize" });
    // Each worker copies only what's left. Once the JSON is built, tiers A
    // and C read none of the strings, and tier A none of its records, whose
    // counts item_at and user_at keep; tier B's routes still compare ids.
    if template && tier != "b" {
        items.clear();
        users.clear();
        text.clear();
        words.clear();
    }
    share_templates();
    var lens: u8[>..] = [];
    if env("REST_LENS", lens) { print_lens(); }
    hand_over();
}

fn main() {
    let argv = args();
    var port: i32 = 8080;
    if argv.len > 1 {
        let p, ok = parse_int(argv[1]);
        guard ok && p > 0 && p < 65536 else { abort("usage: rest [port]"); }
        port = p as i32;
    }
    var name: u8[>..] = [];
    if !env("TIER", name) { name.append("a"); }
    guard name == "a" || name == "b" || name == "c" || name == "d" else { abort("TIER is a, b, c, or d"); }
    var tier: u8[..1] = "";
    tier.append(name);
    let writes = tier == "d";
    var workers: u8[>..] = [];
    var n: i64 = 0;
    if env("WORKERS", workers) {
        let w, ok = parse_int(workers);
        if ok && w > 0 { n = w; }
    }
    var loop_name: u8[>..] = [];
    let epoll = env("LOOP", loop_name) && loop_name == "epoll";
    let cfg = http::Config { port: port, workers: n, max_body: if writes { IMPORT_LIMIT } else { http::MAX_BODY }, .. };
    http::exit_on_error(http::stop_on_signals());
    let count = http::worker_count(cfg);
    mallopt(M_MMAP_THRESHOLD, 131072);
    // main's record globals stay empty, so each spawn copies nothing of them.
    thread_wait(thread_spawn(loader, cfg, tier, count, epoll));
    let giving = thread_spawn(distributor, count);
    var ids: i64[>..] = [];
    for i in count {
        qget<Ready>();
        ids.push(if writes && epoll { thread_spawn(worker_writes_epoll, cfg) }
                 else if writes { thread_spawn(worker_writes, cfg) }
                 else if epoll { thread_spawn(worker_epoll, cfg) }
                 else { thread_spawn(worker, cfg) });
    }
    thread_wait(giving);
    for id in ids { thread_wait(id); }
}

