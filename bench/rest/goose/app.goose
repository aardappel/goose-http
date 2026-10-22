// The REST benchmark's application (task 031): each tier's records, loaded
// from the generator's dataset files (bench/rest/gen.goose), the JSON
// writers and JSON=template's prebuilt records, and tier D's work on a body.
// It has no routes and no main: rest.goose serves it, from its own routes,
// loader thread, and workers.
//
// Plod's benchmark server imports this file too, as
// `import http.bench.rest.goose.app;`, and serves it from its own routes.
// Renaming or changing a declaration here is a breaking change for
// Plod's next pin move.
//
// The importer imports http.store too, which the templates use: imported from
// a package, this file can't name its own package's modules (Goose v2026.2
// looks for http/store.goose under the package, not the package's
// store.goose).
import std;
import os;
import json;
import http;

// A record's string, text[at..at + len]. A string many records share, such
// as a status, is a word instead: a u8 naming one of words, of which 0, a
// word field's default, is the empty string.
struct Str { at: u32, len: u32 }

// Loaded on the server's loader thread, which hands each worker a copy.
var text: u8[>..];
var words: Str[>..];

fn keep(s: const u8[:]) -> Str {
    let at = text.len;
    guard at + s.len <= 4294967295 else { abort("more than 4 GB of strings"); }
    text.append(s);
    return Str { at: at as u32, len: s.len as u32 };
}

fn view(s: Str) -> const u8[:] { text[s.at..s.at + s.len] }

fn intern(s: const u8[:]) -> u8 {
    for w, i in words { if view(w) == s { return i as u8; } }
    guard words.len < 256 else { abort("more than 256 distinct words"); }
    words.push(keep(s));
    return (words.len - 1) as u8;
}

fn word(w: u8) -> const u8[:] { view(words[w]) }

struct Item {
    id: i64,
    name: Str,
    category: u8,
    price: i64,
    quantity: i64,
    active: bool,
    tags: u8[..4],
    score: i64,
    count: i64,
}

struct User { id: i64, name: Str, email: Str, plan: u8 }

var items: Item[>..];
var users: User[>..];
var template: bool;

// The prebuilt JSON of each record type, in the store.
struct Templates {
    item: http::Blob = http::Blob { .. },
    user: http::Blob = http::Blob { .. },
    session: http::Blob = http::Blob { .. },
    project: http::Blob = http::Blob { .. },
    entry: http::Blob = http::Blob { .. },
    timer: http::Blob = http::Blob { .. },
    booking: http::Blob = http::Blob { .. },
    shift: http::Blob = http::Blob { .. },
    client: http::Blob = http::Blob { .. },
    visit: http::Blob = http::Blob { .. },
    note: http::Blob = http::Blob { .. },
}
var tpl: Templates;
// JSON=template's prebuilt records, without their closing brace: item i's
// is item_json[item_at[i]..item_at[i + 1]]. The loader builds them, and puts
// each *_json in the store (share_templates), where every worker
// reads the one copy: item i's is then tpl.item's bytes item_at[i] to
// item_at[i + 1].
var item_json: u8[>..];
var item_at: i64[>..];
var user_json: u8[>..];
var user_at: i64[>..];

fn load(dir: const u8[:], name: const u8[:], file: u8[>..]&) {
    let path = str(dir, "/", name);
    guard read_file(path, file) else { abort(str("can't read ", path, "; run bench/rest/gen.goose")); }
}

// The string at r's cursor, at most cap bytes, which a field of that capacity
// appends: a field given here as an untyped parameter would be a copy.
fn string_of(r: json::Reader&, scratch: u8[>..]&, cap: i64) -> const u8[:] {
    scratch.clear();
    let s = json::read_string(r, scratch);
    guard s.len <= cap else { abort(str("a string longer than ", cap, ": ", s)); }
    return s;
}

// The string at r's cursor, kept in text.
fn kept(r: json::Reader&, scratch: u8[>..]&) -> Str {
    scratch.clear();
    return keep(json::read_string(r, scratch));
}

// The string at r's cursor as a word.
fn word_at(r: json::Reader&, scratch: u8[>..]&) -> u8 {
    scratch.clear();
    return intern(json::read_string(r, scratch));
}

fn load_items(dir: const u8[:]) {
    var file: u8[>..] = [];
    load(dir, "arena-items.json", file);
    var scratch: u8[>..] = [];
    var r = json::reader(file);
    json::each_element(r) {
        var it = Item { .. };
        json::each_member(r) { key =>
            if key == "id" { it.id = json::read_int(r); }
            else if key == "name" { it.name = kept(r, scratch); }
            else if key == "category" { it.category = word_at(r, scratch); }
            else if key == "price" { it.price = json::read_int(r); }
            else if key == "quantity" { it.quantity = json::read_int(r); }
            else if key == "active" { it.active = json::read_bool(r); }
            else if key == "tags" {
                json::each_element(r) {
                    guard it.tags.len < it.tags.cap else { abort("more than 4 tags"); }
                    it.tags.push(word_at(r, scratch));
                };
            } else if key == "rating" {
                json::each_member(r) { k =>
                    if k == "score" { it.score = json::read_int(r); }
                    else if k == "count" { it.count = json::read_int(r); }
                    else { json::skip(r); }
                };
            } else { json::skip(r); }
        };
        guard it.id == items.len + 1 else { abort("arena-items.json's ids aren't 1, 2, ..."); }
        items.push(it);
    };
    guard json::finish(r) else { abort(json::message(r)); }
}

fn load_users(dir: const u8[:]) {
    var file: u8[>..] = [];
    load(dir, "arena-users.json", file);
    var scratch: u8[>..] = [];
    var r = json::reader(file);
    json::each_element(r) {
        var u = User { .. };
        json::each_member(r) { key =>
            if key == "id" { u.id = json::read_int(r); }
            else if key == "name" { u.name = kept(r, scratch); }
            else if key == "email" { u.email = kept(r, scratch); }
            else if key == "plan" { u.plan = word_at(r, scratch); }
            else { json::skip(r); }
        };
        guard u.id == users.len + 1 else { abort("arena-users.json's ids aren't 1, 2, ..."); }
        users.push(u);
    };
    guard json::finish(r) else { abort(json::message(r)); }
}

// An item's JSON without its closing brace.
fn item_open(out: u8[>..]&, it: Item) {
    out.append("{\"id\":");
    format(out, it.id);
    out.append(",\"name\":");
    http::json_string(out, view(it.name));
    out.append(",\"category\":");
    http::json_string(out, word(it.category));
    out.append(",\"price\":");
    format(out, it.price);
    out.append(",\"quantity\":");
    format(out, it.quantity);
    out.append(if it.active { ",\"active\":true,\"tags\":[" } else { ",\"active\":false,\"tags\":[" });
    for t, i in it.tags {
        if i > 0 { out.push(','); }
        http::json_string(out, word(t));
    }
    out.append("],\"rating\":{\"score\":");
    format(out, it.score);
    out.append(",\"count\":");
    format(out, it.count);
    out.push('}');
}

fn user_open(out: u8[>..]&, u: User) {
    out.append("{\"id\":");
    format(out, u.id);
    out.append(",\"name\":");
    http::json_string(out, view(u.name));
    out.append(",\"email\":");
    http::json_string(out, view(u.email));
    out.append(",\"plan\":");
    http::json_string(out, word(u.plan));
}

fn prebuild() {
    for it in items {
        item_at.push(item_json.len);
        item_open(item_json, it);
    }
    item_at.push(item_json.len);
    for u in users {
        user_at.push(user_json.len);
        user_open(user_json, u);
    }
    user_at.push(user_json.len);
}

fn item_count() -> i64 { if template { item_at.len - 1 } else { items.len } }

fn user_count() -> i64 { if template { user_at.len - 1 } else { users.len } }

// Tier B, snowtime's: organizations, their projects, users with their
// sessions, and time entries.

let APP_URL = "https://time.bench.example.com";

let DAY: i64 = 86400000;
let MINUTE: i64 = 60000;

// A nullable string is empty for null.
struct Org { id: u8[..36], name: Str, slug: Str, links: Str, first: i64, count: i64 }

struct Project {
    id: u8[..36],
    name: Str,
    color: u8,              // a word, empty for null
    archived: i64,          // ms, -1 for null
    has_entries: bool,
    teams: u8[..36][..2],
}

struct Member { org: i64, role: u8 }

// Each string a word, empty for null.
struct Settings {
    time_zone: u8,
    week_start: u8,
    locale: u8,
    theme: u8,
    timer_layout: u8,
    show_summary: bool,
    compact_rows: bool,
    wide_timer: bool,
    timer_view: u8,
    calendar_weekend: bool,
    app_icon: u8,
    scene_collection: u8,
    scene_pin: u8,
    scene_background: bool,
    scene_strength: u8,
    surfaces: u8,
    scene_weather: bool,
    scene_intro: bool,
    scene_tagline: bool,
    duration_format: u8,
    date_format: u8,
    time_format: u8,
    copy_pattern: u8,
    copy_control: u8,
    country: u8,
}

struct Fill {
    date: u8,               // a word
    timer_started: i64,     // -1 for null
    today: u8,              // a word
    last_day: u8,           // a word, empty for null
    last_day_filled: bool,
    last_week: i64,         // 0, 1, or -1 for null
    last_month: i64,
    caught_up: bool,
    empty_days: i64,
    streak: i64,
}

struct Person {
    id: u8[..36],
    name: Str,
    email: Str,
    image: Str,
    token: u8[..64],
    signed_in: i64,
    orgs: Member[..6],      // as the session lists them
    active: i64,
    teams: u8[..36][..2],   // in the active organization
    settings: Settings,
    fill: Fill,
    first: i64,             // the person's entries, entries[first..first + count]
    count: i64,
    running: i64,           // an entry, or -1
}

struct Entry {
    id: u8[..36],
    user: i32,
    org: i32,
    project: i32,           // -1 for null
    description: Str,
    ticket: Str,            // empty for null
    started: i64,
    stopped: i64,           // -1 for null
}

var orgs: Org[>..];
var projects: Project[>..];
var people: Person[>..];
var entries: Entry[>..];        // by person, then by start
var by_token: i64[>..];         // people, by token
var by_person_id: i64[>..];     // people, by id
var by_entry_id: i64[>..];      // entries, by id
// JSON=template's: each session, each project, and each entry whole; each
// running timer as GET /timer answers it; and where in each entry the
// description's value starts and ends, for a PATCH to put another there.
var session_json: u8[>..];
var session_at: i64[>..];
var project_json: u8[>..];
var project_at: i64[>..];
var entry_json: u8[>..];
var entry_at: i64[>..];
var entry_desc: i64[>..];
var entry_tail: i64[>..];
var timer_json: u8[>..];
var timer_at: i64[>..];

fn digits(out: u8[>..]&, v: i64, n: i64) {
    var div = 1;
    for i in n - 1 { div *= 10; }
    while div > 0 {
        out.push(('0' + v / div % 10) as u8);
        div /= 10;
    }
}

// ms since the epoch as JavaScript's toISOString writes it, from Howard
// Hinnant's civil_from_days.
fn format_iso(out: u8[>..]&, ms: i64) {
    let day = ms / DAY;
    let t = ms - day * DAY;
    let z = day + 719468;
    let era = (if z >= 0 { z } else { z - 146096 }) / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    digits(out, yoe + era * 400 + (if m <= 2 { 1 } else { 0 }), 4);
    out.push('-');
    digits(out, m, 2);
    out.push('-');
    digits(out, doy - (153 * mp + 2) / 5 + 1, 2);
    out.push('T');
    digits(out, t / 3600000, 2);
    out.push(':');
    digits(out, t / MINUTE % 60, 2);
    out.push(':');
    digits(out, t / 1000 % 60, 2);
    out.push('.');
    digits(out, t % 1000, 3);
    out.push('Z');
}

fn number_at(s: const u8[:], at: i64, n: i64) -> i64 {
    var v = 0;
    for i in at..at + n {
        guard s[i] >= '0' && s[i] <= '9' else { return -1; }
        v = v * 10 + (s[i] - '0');
    }
    return v;
}

// "YYYY-MM-DDTHH:MM:SS.sssZ", or without the milliseconds, as ms since the
// epoch (days_from_civil); false for anything else.
fn parse_iso(s: const u8[:]) -> i64, bool {
    guard (s.len == 24 || s.len == 20) && s[4] == '-' && s[7] == '-' && s[10] == 'T' && s[13] == ':' &&
          s[16] == ':' && s[s.len - 1] == 'Z' else { return 0, false; }
    let y = number_at(s, 0, 4);
    let m = number_at(s, 5, 2);
    let d = number_at(s, 8, 2);
    let h = number_at(s, 11, 2);
    let mi = number_at(s, 14, 2);
    let sec = number_at(s, 17, 2);
    let ms = if s.len == 24 && s[19] == '.' { number_at(s, 20, 3) } else if s.len == 20 { 0 } else { -1 };
    guard y >= 0 && m >= 1 && m <= 12 && d >= 1 && d <= 31 && h >= 0 && h < 24 && mi >= 0 && mi < 60 &&
          sec >= 0 && sec < 60 && ms >= 0 else { return 0, false; }
    return days_from(y, m, d) * DAY + ((h * 60 + mi) * 60 + sec) * 1000 + ms, true;
}

// "YYYY-MM-DD" as ms since the epoch at its midnight in UTC.
fn parse_day(s: const u8[:]) -> i64, bool {
    guard s.len == 10 && s[4] == '-' && s[7] == '-' else { return 0, false; }
    let y = number_at(s, 0, 4);
    let m = number_at(s, 5, 2);
    let d = number_at(s, 8, 2);
    guard y >= 0 && m >= 1 && m <= 12 && d >= 1 && d <= 31 else { return 0, false; }
    return days_from(y, m, d) * DAY, true;
}

// Howard Hinnant's days_from_civil.
fn days_from(y: i64, m: i64, d: i64) -> i64 {
    let yy = if m <= 2 { y - 1 } else { y };
    let era = (if yy >= 0 { yy } else { yy - 399 }) / 400;
    let yoe = yy - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    return era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468;
}

fn iso_or_null(out: u8[>..]&, ms: i64) {
    if ms < 0 { out.append("null"); return; }
    out.push('"');
    format_iso(out, ms);
    out.push('"');
}

fn string_or_null(out: u8[>..]&, s: const u8[:]) {
    if s.len == 0 { out.append("null"); } else { http::json_string(out, s); }
}

// A string member, or null as empty.
fn read_nullable(r: json::Reader&, scratch: u8[>..]&, cap: i64) -> const u8[:] {
    if json::peek(r) == 'n' { json::skip(r); return ""; }
    return string_of(r, scratch, cap);
}

fn kept_nullable(r: json::Reader&, scratch: u8[>..]&) -> Str {
    if json::peek(r) == 'n' { json::skip(r); return Str { at: 0, len: 0 }; }
    return kept(r, scratch);
}

fn word_nullable(r: json::Reader&, scratch: u8[>..]&) -> u8 {
    if json::peek(r) == 'n' { json::skip(r); return 0; }
    return word_at(r, scratch);
}

fn read_time(r: json::Reader&, scratch: u8[>..]&) -> i64 {
    if json::peek(r) == 'n' { json::skip(r); return -1; }
    let v, ok = parse_iso(string_of(r, scratch, 24));
    guard ok else { abort("a time that isn't toISOString's"); }
    return v;
}

fn read_flag(r: json::Reader&) -> i64 {
    if json::peek(r) == 'n' { json::skip(r); return -1; }
    return if json::read_bool(r) { 1 } else { 0 };
}

fn org_index(id: const u8[:]) -> i64 {
    for o, i in orgs { if o.id == id { return i; } }
    return -1;
}

fn project_index(id: const u8[:], org: i64) -> i64 {
    let o = orgs[org];
    for i in o.first..o.first + o.count { if projects[i].id == id { return i; } }
    return -1;
}

fn person_index(id: const u8[:]) -> i64 {
    let k = lower_bound(by_person_id) { compare(people[it].id, id) < 0 };
    return if k < by_person_id.len && people[by_person_id[k]].id == id { by_person_id[k] } else { -1 };
}

fn entry_index(id: const u8[:]) -> i64 {
    let k = lower_bound(by_entry_id) { compare(entries[it].id, id) < 0 };
    return if k < by_entry_id.len && entries[by_entry_id[k]].id == id { by_entry_id[k] } else { -1 };
}

fn load_orgs(dir: const u8[:]) {
    var file: u8[>..] = [];
    load(dir, "snow-orgs.json", file);
    var scratch: u8[>..] = [];
    var r = json::reader(file);
    json::each_element(r) {
        var o = Org { .. };
        json::each_member(r) { key =>
            if key == "id" { o.id.append(string_of(r, scratch, o.id.cap)); }
            else if key == "name" { o.name = kept(r, scratch); }
            else if key == "slug" { o.slug = kept(r, scratch); }
            else if key == "issueLinks" { o.links = kept_nullable(r, scratch); }
            else if key == "projects" {
                o.first = projects.len;
                json::each_element(r) {
                    var p = Project { archived: -1, .. };
                    json::each_member(r) { k =>
                        if k == "id" { p.id.append(string_of(r, scratch, p.id.cap)); }
                        else if k == "name" { p.name = kept(r, scratch); }
                        else if k == "color" { p.color = word_nullable(r, scratch); }
                        else if k == "archivedAt" { p.archived = read_time(r, scratch); }
                        else if k == "hasEntries" { p.has_entries = json::read_bool(r); }
                        else if k == "teamIds" {
                            json::each_element(r) {
                                guard p.teams.len < p.teams.cap else { abort("more than 2 teams"); }
                                let t .= p.teams.push("");
                                t.append(string_of(r, scratch, t.cap));
                            };
                        } else { json::skip(r); }
                    };
                    projects.push(p);
                };
                o.count = projects.len - o.first;
            } else { json::skip(r); }
        };
        orgs.push(o);
    };
    guard json::finish(r) else { abort(json::message(r)); }
}

fn load_settings(r: json::Reader&, scratch: u8[>..]&, s: Settings&) {
    json::each_member(r) { k =>
        if k == "timeZone" { s.time_zone = word_at(r, scratch); }
        else if k == "weekStart" { s.week_start = word_at(r, scratch); }
        else if k == "locale" { s.locale = word_at(r, scratch); }
        else if k == "theme" { s.theme = word_at(r, scratch); }
        else if k == "timerLayout" { s.timer_layout = word_at(r, scratch); }
        else if k == "showSummary" { s.show_summary = json::read_bool(r); }
        else if k == "compactRows" { s.compact_rows = json::read_bool(r); }
        else if k == "wideTimer" { s.wide_timer = json::read_bool(r); }
        else if k == "timerView" { s.timer_view = word_at(r, scratch); }
        else if k == "calendarWeekend" { s.calendar_weekend = json::read_bool(r); }
        else if k == "appIcon" { s.app_icon = word_at(r, scratch); }
        else if k == "sceneCollection" { s.scene_collection = word_at(r, scratch); }
        else if k == "scenePin" { s.scene_pin = word_nullable(r, scratch); }
        else if k == "sceneBackground" { s.scene_background = json::read_bool(r); }
        else if k == "sceneStrength" { s.scene_strength = word_at(r, scratch); }
        else if k == "surfaces" { s.surfaces = word_at(r, scratch); }
        else if k == "sceneWeather" { s.scene_weather = json::read_bool(r); }
        else if k == "sceneIntro" { s.scene_intro = json::read_bool(r); }
        else if k == "sceneTagline" { s.scene_tagline = json::read_bool(r); }
        else if k == "durationFormat" { s.duration_format = word_at(r, scratch); }
        else if k == "dateFormat" { s.date_format = word_at(r, scratch); }
        else if k == "timeFormat" { s.time_format = word_at(r, scratch); }
        else if k == "copyDurationPattern" { s.copy_pattern = word_at(r, scratch); }
        else if k == "copyDurationControl" { s.copy_control = word_at(r, scratch); }
        else if k == "country" { s.country = word_nullable(r, scratch); }
        else { json::skip(r); }
    };
}

fn load_fill(r: json::Reader&, scratch: u8[>..]&, f: Fill&) {
    json::each_member(r) { k =>
        if k == "date" { f.date = word_at(r, scratch); }
        else if k == "timerStartedAt" {
            f.timer_started = if json::peek(r) == 'n' { json::skip(r); -1 } else { json::read_int(r) };
        } else if k == "today" { f.today = word_at(r, scratch); }
        else if k == "lastWorkingDay" {
            if json::peek(r) == 'n' { json::skip(r); }
            else {
                json::each_member(r) { kk =>
                    if kk == "date" { f.last_day = word_at(r, scratch); }
                    else if kk == "filled" { f.last_day_filled = json::read_bool(r); }
                    else { json::skip(r); }
                };
            }
        } else if k == "lastWeek" { f.last_week = read_flag(r); }
        else if k == "lastMonth" { f.last_month = read_flag(r); }
        else if k == "caughtUp" { f.caught_up = json::read_bool(r); }
        else if k == "emptyDays" { f.empty_days = json::read_int(r); }
        else if k == "streak" { f.streak = json::read_int(r); }
        else { json::skip(r); }
    };
}

fn load_people(dir: const u8[:]) {
    var file: u8[>..] = [];
    load(dir, "snow-users.json", file);
    var scratch: u8[>..] = [];
    var r = json::reader(file);
    json::each_element(r) {
        var p = Person { active: -1, running: -1, .. };
        json::each_member(r) { key =>
            if key == "id" { p.id.append(string_of(r, scratch, p.id.cap)); }
            else if key == "name" { p.name = kept(r, scratch); }
            else if key == "email" { p.email = kept(r, scratch); }
            else if key == "image" { p.image = kept_nullable(r, scratch); }
            else if key == "token" { p.token.append(string_of(r, scratch, p.token.cap)); }
            else if key == "signedInAt" { p.signed_in = read_time(r, scratch); }
            else if key == "organizations" {
                json::each_element(r) {
                    guard p.orgs.len < p.orgs.cap else { abort("more than 6 organizations"); }
                    let m .= p.orgs.push(Member { org: -1, .. });
                    json::each_member(r) { k =>
                        if k == "id" { m.org = org_index(string_of(r, scratch, 36)); }
                        else if k == "role" { m.role = word_at(r, scratch); }
                        else { json::skip(r); }
                    };
                    guard m.org >= 0 else { abort("a member of an organization snow-orgs.json lacks"); }
                };
            } else if key == "activeOrganizationId" { p.active = org_index(string_of(r, scratch, 36)); }
            else if key == "teamIds" {
                json::each_element(r) {
                    guard p.teams.len < p.teams.cap else { abort("more than 2 teams"); }
                    let t .= p.teams.push("");
                    t.append(string_of(r, scratch, t.cap));
                };
            } else if key == "settings" { load_settings(r, scratch, p.settings); }
            else if key == "fill" { load_fill(r, scratch, p.fill); }
            else { json::skip(r); }
        };
        guard p.active >= 0 && p.token.len == 64 else { abort("a user without an organization or a token"); }
        people.push(p);
    };
    guard json::finish(r) else { abort(json::message(r)); }
    for i in people.len { by_token.push(i); by_person_id.push(i); }
    sort(by_token) { a, b => compare(people[a].token, people[b].token) < 0 };
    sort(by_person_id) { a, b => compare(people[a].id, people[b].id) < 0 };
}

fn load_entries(dir: const u8[:]) {
    var file: u8[>..] = [];
    load(dir, "snow-entries.json", file);
    var scratch: u8[>..] = [];
    var r = json::reader(file);
    json::each_element(r) {
        var e = Entry { user: -1, org: -1, project: -1, .. };
        var project: u8[..36] = "";
        json::each_member(r) { key =>
            if key == "id" { e.id.append(string_of(r, scratch, e.id.cap)); }
            else if key == "organizationId" { e.org = org_index(string_of(r, scratch, 36)) as i32; }
            else if key == "userId" {
                let id = string_of(r, scratch, 36);
                // The file has each user's entries together.
                e.user = if entries.len > 0 && people[last(entries).user].id == id { last(entries).user }
                         else { person_index(id) as i32 };
            } else if key == "projectId" { project.append(read_nullable(r, scratch, project.cap)); }
            else if key == "description" { e.description = kept(r, scratch); }
            else if key == "ticket" { e.ticket = kept_nullable(r, scratch); }
            else if key == "startedAt" { e.started = read_time(r, scratch); }
            else if key == "stoppedAt" { e.stopped = read_time(r, scratch); }
            else { json::skip(r); }
        };
        guard e.user >= 0 && e.org >= 0 else { abort("an entry of a user or organization the files lack"); }
        if project.len > 0 {
            e.project = project_index(project, e.org) as i32;
            guard e.project >= 0 else { abort("an entry of a project snow-orgs.json lacks"); }
        }
        let p .= people[e.user];
        if p.count == 0 { p.first = entries.len; }
        guard p.first + p.count == entries.len else { abort("snow-entries.json doesn't have each user's entries together"); }
        guard p.count == 0 || last(entries).started < e.started else { abort("a user's entries out of order"); }
        p.count++;
        if e.stopped < 0 { p.running = entries.len; }
        entries.push(e);
    };
    guard json::finish(r) else { abort(json::message(r)); }
    for i in entries.len { by_entry_id.push(i); }
    sort(by_entry_id) { a, b => compare(entries[a].id, entries[b].id) < 0 };
}

fn session_open(out: u8[>..]&, p: Person) {
    out.append("{\"user\":{\"id\":");
    http::json_string(out, p.id);
    out.append(",\"name\":");
    http::json_string(out, view(p.name));
    out.append(",\"email\":");
    http::json_string(out, view(p.email));
    out.append(",\"image\":");
    string_or_null(out, view(p.image));
    out.append("},\"signedInAt\":");
    iso_or_null(out, p.signed_in);
    out.append(",\"organizations\":[");
    for m, i in p.orgs {
        let o = orgs[m.org];
        if i > 0 { out.push(','); }
        out.append("{\"id\":");
        http::json_string(out, o.id);
        out.append(",\"name\":");
        http::json_string(out, view(o.name));
        out.append(",\"slug\":");
        http::json_string(out, view(o.slug));
        out.append(",\"issueLinks\":");
        string_or_null(out, view(o.links));
        out.append(",\"role\":");
        http::json_string(out, word(m.role));
        out.push('}');
    }
    out.append("],\"activeOrganizationId\":");
    http::json_string(out, orgs[p.active].id);
    let s = p.settings;
    out.append(",\"settings\":{\"timeZone\":");
    http::json_string(out, word(s.time_zone));
    out.append(",\"weekStart\":");
    http::json_string(out, word(s.week_start));
    out.append(",\"locale\":");
    http::json_string(out, word(s.locale));
    out.append(",\"theme\":");
    http::json_string(out, word(s.theme));
    out.append(",\"timerLayout\":");
    http::json_string(out, word(s.timer_layout));
    out.append(",\"showSummary\":");
    json::format_bool(out, s.show_summary);
    out.append(",\"compactRows\":");
    json::format_bool(out, s.compact_rows);
    out.append(",\"wideTimer\":");
    json::format_bool(out, s.wide_timer);
    out.append(",\"timerView\":");
    http::json_string(out, word(s.timer_view));
    out.append(",\"calendarWeekend\":");
    json::format_bool(out, s.calendar_weekend);
    out.append(",\"appIcon\":");
    http::json_string(out, word(s.app_icon));
    out.append(",\"sceneCollection\":");
    http::json_string(out, word(s.scene_collection));
    out.append(",\"scenePin\":");
    string_or_null(out, word(s.scene_pin));
    out.append(",\"sceneBackground\":");
    json::format_bool(out, s.scene_background);
    out.append(",\"sceneStrength\":");
    http::json_string(out, word(s.scene_strength));
    out.append(",\"surfaces\":");
    http::json_string(out, word(s.surfaces));
    out.append(",\"sceneWeather\":");
    json::format_bool(out, s.scene_weather);
    out.append(",\"sceneIntro\":");
    json::format_bool(out, s.scene_intro);
    out.append(",\"sceneTagline\":");
    json::format_bool(out, s.scene_tagline);
    out.append(",\"durationFormat\":");
    http::json_string(out, word(s.duration_format));
    out.append(",\"dateFormat\":");
    http::json_string(out, word(s.date_format));
    out.append(",\"timeFormat\":");
    http::json_string(out, word(s.time_format));
    out.append(",\"copyDurationPattern\":");
    http::json_string(out, word(s.copy_pattern));
    out.append(",\"copyDurationControl\":");
    http::json_string(out, word(s.copy_control));
    out.append(",\"country\":");
    string_or_null(out, word(s.country));
    let f = p.fill;
    out.append("},\"fill\":{\"date\":");
    http::json_string(out, word(f.date));
    out.append(",\"timerStartedAt\":");
    if f.timer_started >= 0 { format(out, f.timer_started); } else { out.append("null"); }
    out.append(",\"today\":");
    http::json_string(out, word(f.today));
    out.append(",\"lastWorkingDay\":");
    if f.last_day == 0 { out.append("null"); }
    else {
        out.append("{\"date\":");
        http::json_string(out, word(f.last_day));
        out.append(",\"filled\":");
        json::format_bool(out, f.last_day_filled);
        out.push('}');
    }
    out.append(",\"lastWeek\":");
    out.append(if f.last_week < 0 { "null" } else if f.last_week > 0 { "true" } else { "false" });
    out.append(",\"lastMonth\":");
    out.append(if f.last_month < 0 { "null" } else if f.last_month > 0 { "true" } else { "false" });
    out.append(",\"caughtUp\":");
    json::format_bool(out, f.caught_up);
    out.append(",\"emptyDays\":");
    format(out, f.empty_days);
    out.append(",\"streak\":");
    format(out, f.streak);
    out.append("},\"invitationId\":null,\"appUrl\":\"");
    out.append(APP_URL);
    out.append("\"}");
}

// An entry up to its description's value, and from the member after it, so
// that a PATCH writes another description between the two.
fn entry_head(out: u8[>..]&, e: Entry) {
    out.append("{\"id\":");
    http::json_string(out, e.id);
    out.append(",\"organizationId\":");
    http::json_string(out, orgs[e.org].id);
    out.append(",\"userId\":");
    http::json_string(out, people[e.user].id);
    out.append(",\"projectId\":");
    string_or_null(out, if e.project >= 0 { projects[e.project].id } else { "" });
    out.append(",\"description\":");
}

// The members after the description, without stoppedAt's value and the
// closing brace.
fn entry_tail_open(out: u8[>..]&, e: Entry) {
    out.append(",\"ticket\":");
    string_or_null(out, view(e.ticket));
    out.append(",\"startedAt\":");
    iso_or_null(out, e.started);
    out.append(",\"stoppedAt\":");
}

fn entry_full(out: u8[>..]&, e: Entry, description: const u8[:], stopped: i64) {
    entry_head(out, e);
    http::json_string(out, description);
    entry_tail_open(out, e);
    iso_or_null(out, stopped);
    out.push('}');
}

fn project_full(out: u8[>..]&, p: Project) {
    out.append("{\"id\":");
    http::json_string(out, p.id);
    out.append(",\"name\":");
    http::json_string(out, view(p.name));
    out.append(",\"color\":");
    string_or_null(out, word(p.color));
    out.append(",\"archivedAt\":");
    iso_or_null(out, p.archived);
    out.append(if p.has_entries { ",\"hasEntries\":true,\"teamIds\":[" } else { ",\"hasEntries\":false,\"teamIds\":[" });
    for t, i in p.teams {
        if i > 0 { out.push(','); }
        http::json_string(out, t);
    }
    out.append("]}");
}

// GET /timer's answer for a running entry: the entry and its project.
fn timer_full(out: u8[>..]&, e: Entry) {
    entry_head(out, e);
    http::json_string(out, view(e.description));
    entry_tail_open(out, e);
    out.append("null,\"project\":");
    if e.project < 0 { out.append("null}"); return; }
    let p = projects[e.project];
    out.append("{\"id\":");
    http::json_string(out, p.id);
    out.append(",\"name\":");
    http::json_string(out, view(p.name));
    out.append(",\"color\":");
    string_or_null(out, word(p.color));
    out.append("}}");
}

fn prebuild_snow() {
    for p in people {
        session_at.push(session_json.len);
        session_open(session_json, p);
        timer_at.push(timer_json.len);
        if p.running >= 0 { timer_full(timer_json, entries[p.running]); } else { timer_json.append("null"); }
    }
    session_at.push(session_json.len);
    timer_at.push(timer_json.len);
    for p in projects {
        project_at.push(project_json.len);
        project_full(project_json, p);
    }
    project_at.push(project_json.len);
    for e in entries {
        entry_at.push(entry_json.len);
        entry_head(entry_json, e);
        entry_desc.push(entry_json.len);
        http::json_string(entry_json, view(e.description));
        entry_tail.push(entry_json.len);
        entry_tail_open(entry_json, e);
        iso_or_null(entry_json, e.stopped);
        entry_json.push('}');
    }
    entry_at.push(entry_json.len);
}

fn snow_entry(out: u8[>..]&, i: i64) {
    if template { http::store_append(tpl.entry, entry_at[i], entry_at[i + 1], out); }
    else { let e = entries[i]; entry_full(out, e, view(e.description), e.stopped); }
}

// Entry i with another description.
fn snow_entry_as(out: u8[>..]&, i: i64, description: const u8[:]) {
    if template {
        http::store_append(tpl.entry, entry_at[i], entry_desc[i], out);
        http::json_string(out, description);
        http::store_append(tpl.entry, entry_tail[i], entry_at[i + 1], out);
    } else {
        let e = entries[i];
        entry_full(out, e, description, e.stopped);
    }
}

// Running entry i stopped at ms, as stopRunning stops it: after it started,
// and at most a day after.
fn snow_stopped(out: u8[>..]&, i: i64, now: i64) {
    let e = entries[i];
    let at = min(max(now, e.started + 1), e.started + DAY);
    if template {
        // A running entry's JSON ends in "null}".
        http::store_append(tpl.entry, entry_at[i], entry_at[i + 1] - 5, out);
        iso_or_null(out, at);
        out.push('}');
    } else {
        entry_full(out, e, view(e.description), at);
    }
}

// The person's membership of the organization the path names, or -1.
fn membership(p: Person, id: const u8[:]) -> i64 {
    for m, i in p.orgs { if orgs[m.org].id == id { return i; } }
    return -1;
}

fn is_admin(m: Member) -> bool { word(m.role) == "owner" || word(m.role) == "admin" }

// listProjects's visibility: an admin sees every project, a member those
// with no team and those of a team of theirs.
fn sees(p: Person, m: Member, j: Project) -> bool {
    if is_admin(m) || j.teams.len == 0 { return true; }
    if m.org != p.active { return false; }
    for t in j.teams { if contains(p.teams, t) { return true; } }
    return false;
}

// Tier C, a clinic's schedule and records. Ids are 1, 2, ... in each file.

struct Staffer { name: Str, title: Str }

struct Service { code: u8[..8], name: Str, minutes: i64, price: i64 }

// Strings of a few bytes each stay fixed, which a Str and its bytes in text
// would outgrow.
struct Client {
    name: Str,
    code: u8[..8],
    born: u8[..10],
    phone: u8[..16],
    email: Str,
    street: Str,
    city: u8,               // a word, as are channel, language, flags, and relation
    postcode: u8[..8],
    channel: u8,
    language: u8,
    flags: u8[..3],
    contact: Str,
    contact_phone: u8[..16],
    relation: u8,
    sms: bool,
    mail: bool,
    research: bool,
    created: i64,
    updated: i64,
    first: i64,             // the client's completed visits, newest first: past[first..first + count]
    count: i64,
}

struct Line { id: i32, service: u8 }

struct Note { id: i64, visit: i64, kind: u8, author: i64, at: i64, text: Str }

struct Visit {
    case_id: i64,
    client: i64,
    staff: i64,
    status: u8,             // a word, as are kind and priority
    kind: u8,
    priority: u8,
    start: i64,
    end: i64,
    lines: Line[..3],
    codes: u8[..8][..3],
    first_note: i64,        // notes[first_note..first_note + notes], by kind
    notes: i64,
    case_first: i64,        // the case's visits, visits[case_first..case_first + case_count]
    case_count: i64,
}

// Each string a word.
struct Reminder { channel: u8, kind: u8, status: u8, at: i64 }

struct Booking {
    start: i64,
    end: i64,
    client: i64,
    staff: i64,
    visit: i64,
    lines: Line[..3],
    reminders: Reminder[..3],
    status: u8,             // a word, as is source
    source: u8,
    noted: bool,            // false for a null note
    note: Str,
    created: i64,
    updated: i64,
}

// kind and room_name are words; note is empty for null.
struct Shift { staff: i64, start: i64, end: i64, kind: u8, room: i64, room_name: u8, note: Str }

var staffers: Staffer[>..];
var services: Service[>..];
var clients: Client[>..];
var visits: Visit[>..];
var notes: Note[>..];
var bookings: Booking[>..];     // by start
var shifts: Shift[>..];         // by start
var past: i64[>..];             // completed visits, by client, newest first
var version_epoch: i64;
// JSON=template's: each booking, shift, and client whole; each visit up to
// its notes; and each note as caseNotes lists it, of which a visit's notes
// take the id, up to note_mid, and the members from note_body_at on, so that
// the note's text is held once.
var booking_json: u8[>..];
var booking_at: i64[>..];
var shift_json: u8[>..];
var shift_at: i64[>..];
var client_json: u8[>..];
var client_at: i64[>..];
var visit_json: u8[>..];
var visit_at: i64[>..];
var note_json: u8[>..];
var note_at: i64[>..];
var note_mid: i64[>..];
var note_body_at: i64[>..];

fn note_kind(k: i64) -> const u8[:] {
    return if k == 0 { "intake" } else if k == 1 { "findings" } else if k == 2 { "plan" } else { "internal" };
}

// An id field: n of 1..n as an index, or abort.
fn id_in(r: json::Reader&, n: i64, what: const u8[:]) -> i64 {
    let id = json::read_int(r);
    guard id >= 1 && id <= n else { abort(str("a ", what, " id that isn't one of 1..", n, ": ", id)); }
    return id - 1;
}

// The id of an object such as {"id":3,"name":...}, as an index.
fn ref_in(r: json::Reader&, n: i64, what: const u8[:]) -> i64 {
    var i = -1;
    json::each_member(r) { k => if k == "id" { i = id_in(r, n, what); } else { json::skip(r); } };
    return i;
}

fn service_of(code: const u8[:]) -> u8 {
    for s, i in services { if s.code == code { return i as u8; } }
    abort(str("a service heavy-services.json lacks: ", code));
}

fn load_lines(r: json::Reader&, scratch: u8[>..]&, lines: Line[..3]&) {
    json::each_element(r) {
        guard lines.len < lines.cap else { abort("more than 3 items"); }
        let l .= lines.push(Line { .. });
        json::each_member(r) { k =>
            if k == "id" {
                let id = json::read_int(r);
                guard id >= 0 && id <= 2147483647 else { abort(str("an item id past 2^31: ", id)); }
                l.id = id as i32;
            } else if k == "code" { l.service = service_of(string_of(r, scratch, 8)); }
            else { json::skip(r); }
        };
    };
}

// The reader, for a block: its untyped parameter would be a copy.
struct Cursor { r: json::Reader& }

// A file's records, each read by F, which pushes it.
fn load_each<F>(dir: const u8[:], name: const u8[:]) {
    var file: u8[>..] = [];
    load(dir, name, file);
    var r = json::reader(file);
    json::each_element(r) { F(Cursor { r: r }); };
    guard json::finish(r) else { abort(str(name, ": ", json::message(r))); }
}

fn load_heavy(dir: const u8[:]) {
    var meta: u8[>..] = [];
    load(dir, "heavy-meta.json", meta);
    var m = json::reader(meta);
    json::each_member(m) { k => if k == "versionEpoch" { version_epoch = json::read_int(m); } else { json::skip(m); } };
    guard json::finish(m) && version_epoch > 0 else { abort("heavy-meta.json has no versionEpoch"); }
    var scratch: u8[>..] = [];
    load_each(dir, "heavy-staff.json") { c =>
        let r .= c.r;
        let s .= staffers.push(Staffer { .. });
        json::each_member(r) { k =>
            if k == "name" { s.name = kept(r, scratch); }
            else if k == "title" { s.title = kept(r, scratch); }
            else if k == "id" { guard json::read_int(r) == staffers.len else { abort("heavy-staff.json's ids aren't 1, 2, ..."); } }
            else { json::skip(r); }
        };
    };
    load_each(dir, "heavy-services.json") { c =>
        let r .= c.r;
        guard services.len < 256 else { abort("more than 256 services"); }
        let s .= services.push(Service { .. });
        json::each_member(r) { k =>
            if k == "code" { s.code.append(string_of(r, scratch, s.code.cap)); }
            else if k == "name" { s.name = kept(r, scratch); }
            else if k == "minutes" { s.minutes = json::read_int(r); }
            else if k == "price" { s.price = json::read_int(r); }
            else { json::skip(r); }
        };
    };
    load_each(dir, "heavy-clients.json") { c =>
        let r .= c.r;
        let c .= clients.push(Client { .. });
        json::each_member(r) { k =>
            if k == "id" { guard json::read_int(r) == clients.len else { abort("heavy-clients.json's ids aren't 1, 2, ..."); } }
            else if k == "name" { c.name = kept(r, scratch); }
            else if k == "code" { c.code.append(string_of(r, scratch, c.code.cap)); }
            else if k == "born" { c.born.append(string_of(r, scratch, c.born.cap)); }
            else if k == "phone" { c.phone.append(string_of(r, scratch, c.phone.cap)); }
            else if k == "email" { c.email = kept(r, scratch); }
            else if k == "address" {
                json::each_member(r) { kk =>
                    if kk == "street" { c.street = kept(r, scratch); }
                    else if kk == "city" { c.city = word_at(r, scratch); }
                    else if kk == "postcode" { c.postcode.append(string_of(r, scratch, c.postcode.cap)); }
                    else { json::skip(r); }
                };
            } else if k == "preferences" {
                json::each_member(r) { kk =>
                    if kk == "channel" { c.channel = word_at(r, scratch); }
                    else if kk == "language" { c.language = word_at(r, scratch); }
                    else { json::skip(r); }
                };
            } else if k == "flags" {
                json::each_element(r) {
                    guard c.flags.len < c.flags.cap else { abort("more than 3 flags"); }
                    c.flags.push(word_at(r, scratch));
                };
            } else if k == "emergencyContact" {
                json::each_member(r) { kk =>
                    if kk == "name" { c.contact = kept(r, scratch); }
                    else if kk == "phone" { c.contact_phone.append(string_of(r, scratch, c.contact_phone.cap)); }
                    else if kk == "relation" { c.relation = word_at(r, scratch); }
                    else { json::skip(r); }
                };
            } else if k == "consents" {
                json::each_member(r) { kk =>
                    if kk == "sms" { c.sms = json::read_bool(r); }
                    else if kk == "email" { c.mail = json::read_bool(r); }
                    else if kk == "research" { c.research = json::read_bool(r); }
                    else { json::skip(r); }
                };
            } else if k == "createdAt" { c.created = read_time(r, scratch); }
            else if k == "updatedAt" { c.updated = read_time(r, scratch); }
            else { json::skip(r); }
        };
    };
    load_each(dir, "heavy-encounters.json") { c =>
        let r .= c.r;
        let v .= visits.push(Visit { client: -1, staff: -1, first_note: notes.len, .. });
        json::each_member(r) { k =>
            if k == "id" { guard json::read_int(r) == visits.len else { abort("heavy-encounters.json's ids aren't 1, 2, ..."); } }
            else if k == "caseId" { v.case_id = json::read_int(r); }
            else if k == "client" { v.client = ref_in(r, clients.len, "client"); }
            else if k == "staff" { v.staff = ref_in(r, staffers.len, "staff"); }
            else if k == "status" { v.status = word_at(r, scratch); }
            else if k == "kind" { v.kind = word_at(r, scratch); }
            else if k == "priority" { v.priority = word_at(r, scratch); }
            else if k == "start" { v.start = read_time(r, scratch); }
            else if k == "end" { v.end = read_time(r, scratch); }
            else if k == "items" { load_lines(r, scratch, v.lines); }
            else if k == "codes" {
                json::each_element(r) {
                    guard v.codes.len < v.codes.cap else { abort("more than 3 codes"); }
                    let c .= v.codes.push("");
                    c.append(string_of(r, scratch, c.cap));
                };
            } else if k == "notes" {
                var kind = 0;
                json::each_member(r) { kk =>
                    guard kk == note_kind(kind) else { abort(str("notes out of order: ", kk)); }
                    json::each_element(r) {
                        let n .= notes.push(Note { visit: visits.len - 1, kind: kind as u8, author: -1, .. });
                        json::each_member(r) { nk =>
                            if nk == "id" { n.id = json::read_int(r); }
                            else if nk == "author" { n.author = ref_in(r, staffers.len, "staff"); }
                            else if nk == "text" { n.text = kept(r, scratch); }
                            else if nk == "at" { n.at = read_time(r, scratch); }
                            else { json::skip(r); }
                        };
                    };
                    kind++;
                };
            } else { json::skip(r); }
        };
        v.notes = notes.len - v.first_note;
        guard v.client >= 0 && v.staff >= 0 else { abort("an encounter without a client or staff"); }
        // A case's visits are together in the file.
        if visits.len > 1 && visits[visits.len - 2].case_id == v.case_id {
            let first = visits[visits.len - 2].case_first;
            v.case_first = first;
            for i in first..visits.len { visits[i].case_count = visits.len - first; }
        } else {
            guard visits.len == 1 || visits[visits.len - 2].case_id < v.case_id else { abort("a case's encounters apart"); }
            v.case_first = visits.len - 1;
            v.case_count = 1;
        }
    };
    load_each(dir, "heavy-bookings.json") { c =>
        let r .= c.r;
        let b .= bookings.push(Booking { client: -1, staff: -1, visit: -1, .. });
        json::each_member(r) { k =>
            if k == "id" { guard json::read_int(r) == bookings.len else { abort("heavy-bookings.json's ids aren't 1, 2, ..."); } }
            else if k == "slot" {
                json::each_member(r) { kk =>
                    if kk == "start" { b.start = read_time(r, scratch); }
                    else if kk == "end" { b.end = read_time(r, scratch); }
                    else { json::skip(r); }
                };
            } else if k == "client" { b.client = ref_in(r, clients.len, "client"); }
            else if k == "staff" { b.staff = ref_in(r, staffers.len, "staff"); }
            else if k == "encounter" { b.visit = ref_in(r, visits.len, "encounter"); }
            else if k == "items" { load_lines(r, scratch, b.lines); }
            else if k == "reminders" {
                json::each_element(r) {
                    guard b.reminders.len < b.reminders.cap else { abort("more than 3 reminders"); }
                    let m .= b.reminders.push(Reminder { .. });
                    json::each_member(r) { kk =>
                        if kk == "channel" { m.channel = word_at(r, scratch); }
                        else if kk == "kind" { m.kind = word_at(r, scratch); }
                        else if kk == "status" { m.status = word_at(r, scratch); }
                        else if kk == "at" { m.at = read_time(r, scratch); }
                        else { json::skip(r); }
                    };
                };
            } else if k == "status" { b.status = word_at(r, scratch); }
            else if k == "source" { b.source = word_at(r, scratch); }
            else if k == "note" {
                if json::peek(r) == 'n' { json::skip(r); }
                else {
                    b.noted = true;
                    b.note = kept(r, scratch);
                }
            } else if k == "createdAt" { b.created = read_time(r, scratch); }
            else if k == "updatedAt" { b.updated = read_time(r, scratch); }
            else { json::skip(r); }
        };
        guard b.client >= 0 && b.staff >= 0 && b.visit >= 0 else { abort("a booking without a client, staff, or encounter"); }
        guard bookings.len == 1 || bookings[bookings.len - 2].start <= b.start else { abort("bookings out of order"); }
    };
    load_each(dir, "heavy-shifts.json") { c =>
        let r .= c.r;
        let s .= shifts.push(Shift { staff: -1, .. });
        json::each_member(r) { k =>
            if k == "id" { guard json::read_int(r) == shifts.len else { abort("heavy-shifts.json's ids aren't 1, 2, ..."); } }
            else if k == "staff" { s.staff = ref_in(r, staffers.len, "staff"); }
            else if k == "start" { s.start = read_time(r, scratch); }
            else if k == "end" { s.end = read_time(r, scratch); }
            else if k == "kind" { s.kind = word_at(r, scratch); }
            else if k == "room" {
                json::each_member(r) { kk =>
                    if kk == "id" { s.room = json::read_int(r); }
                    else if kk == "name" { s.room_name = word_at(r, scratch); }
                    else { json::skip(r); }
                };
            } else if k == "note" { s.note = kept_nullable(r, scratch); }
            else { json::skip(r); }
        };
        guard s.staff >= 0 else { abort("a shift without staff"); }
        guard shifts.len == 1 || shifts[shifts.len - 2].start <= s.start else { abort("shifts out of order"); }
    };
    for v, i in visits { if word(v.status) == "completed" { past.push(i); } }
    // Newest first, and of two at once the later id first.
    sort(past) { a, b =>
        let va = visits[a];
        let vb = visits[b];
        va.client < vb.client || va.client == vb.client && (va.start > vb.start || va.start == vb.start && a > b)
    };
    for i, k in past {
        let c .= clients[visits[i].client];
        if c.count == 0 { c.first = k; }
        c.count++;
    }
}

fn staff_ref(out: u8[>..]&, s: i64, title: bool) {
    out.append("{\"id\":");
    format(out, s + 1);
    out.append(",\"name\":");
    http::json_string(out, view(staffers[s].name));
    if title {
        out.append(",\"title\":");
        http::json_string(out, view(staffers[s].title));
    }
    out.push('}');
}

fn client_ref(out: u8[>..]&, c: i64) {
    out.append("{\"id\":");
    format(out, c + 1);
    out.append(",\"name\":");
    http::json_string(out, view(clients[c].name));
    out.append(",\"code\":");
    http::json_string(out, clients[c].code);
    out.push('}');
}

fn lines_full(out: u8[>..]&, lines: Line[:]) {
    out.push('[');
    for l, k in lines {
        let s = services[l.service];
        if k > 0 { out.push(','); }
        out.append("{\"id\":");
        format(out, l.id);
        out.append(",\"code\":");
        http::json_string(out, s.code);
        out.append(",\"name\":");
        http::json_string(out, view(s.name));
        out.append(",\"minutes\":");
        format(out, s.minutes);
        out.append(",\"price\":");
        format(out, s.price);
        out.push('}');
    }
    out.push(']');
}

fn booking_full(out: u8[>..]&, i: i64) {
    let b = bookings[i];
    let v = visits[b.visit];
    out.append("{\"id\":");
    format(out, i + 1);
    out.append(",\"slot\":{\"start\":");
    iso_or_null(out, b.start);
    out.append(",\"end\":");
    iso_or_null(out, b.end);
    out.append("},\"client\":");
    client_ref(out, b.client);
    out.append(",\"staff\":");
    staff_ref(out, b.staff, false);
    out.append(",\"encounter\":{\"id\":");
    format(out, b.visit + 1);
    out.append(",\"status\":");
    http::json_string(out, word(v.status));
    out.append(",\"start\":");
    iso_or_null(out, v.start);
    out.append(",\"end\":");
    iso_or_null(out, v.end);
    out.append("},\"items\":");
    lines_full(out, b.lines);
    out.append(",\"reminders\":[");
    for m, k in b.reminders {
        if k > 0 { out.push(','); }
        out.append("{\"channel\":");
        http::json_string(out, word(m.channel));
        out.append(",\"kind\":");
        http::json_string(out, word(m.kind));
        out.append(",\"status\":");
        http::json_string(out, word(m.status));
        out.append(",\"at\":");
        iso_or_null(out, m.at);
        out.push('}');
    }
    out.append("],\"status\":");
    http::json_string(out, word(b.status));
    out.append(",\"source\":");
    http::json_string(out, word(b.source));
    out.append(",\"note\":");
    if b.noted { http::json_string(out, view(b.note)); } else { out.append("null"); }
    out.append(",\"createdAt\":");
    iso_or_null(out, b.created);
    out.append(",\"updatedAt\":");
    iso_or_null(out, b.updated);
    out.push('}');
}

fn shift_full(out: u8[>..]&, i: i64) {
    let s = shifts[i];
    out.append("{\"id\":");
    format(out, i + 1);
    out.append(",\"staff\":");
    staff_ref(out, s.staff, false);
    out.append(",\"start\":");
    iso_or_null(out, s.start);
    out.append(",\"end\":");
    iso_or_null(out, s.end);
    out.append(",\"kind\":");
    http::json_string(out, word(s.kind));
    out.append(",\"room\":{\"id\":");
    format(out, s.room);
    out.append(",\"name\":");
    http::json_string(out, word(s.room_name));
    out.append("},\"note\":");
    string_or_null(out, view(s.note));
    out.push('}');
}

fn client_full(out: u8[>..]&, i: i64) {
    let c = clients[i];
    out.append("{\"id\":");
    format(out, i + 1);
    out.append(",\"name\":");
    http::json_string(out, view(c.name));
    out.append(",\"code\":");
    http::json_string(out, c.code);
    out.append(",\"born\":");
    http::json_string(out, c.born);
    out.append(",\"phone\":");
    http::json_string(out, c.phone);
    out.append(",\"email\":");
    http::json_string(out, view(c.email));
    out.append(",\"address\":{\"street\":");
    http::json_string(out, view(c.street));
    out.append(",\"city\":");
    http::json_string(out, word(c.city));
    out.append(",\"postcode\":");
    http::json_string(out, c.postcode);
    out.append("},\"preferences\":{\"channel\":");
    http::json_string(out, word(c.channel));
    out.append(",\"language\":");
    http::json_string(out, word(c.language));
    out.append("},\"flags\":[");
    for f, k in c.flags {
        if k > 0 { out.push(','); }
        http::json_string(out, word(f));
    }
    out.append("],\"emergencyContact\":{\"name\":");
    http::json_string(out, view(c.contact));
    out.append(",\"phone\":");
    http::json_string(out, c.contact_phone);
    out.append(",\"relation\":");
    http::json_string(out, word(c.relation));
    out.append("},\"consents\":{\"sms\":");
    json::format_bool(out, c.sms);
    out.append(",\"email\":");
    json::format_bool(out, c.mail);
    out.append(",\"research\":");
    json::format_bool(out, c.research);
    out.append("},\"createdAt\":");
    iso_or_null(out, c.created);
    out.append(",\"updatedAt\":");
    iso_or_null(out, c.updated);
    out.push('}');
}

// A note's members after its id: as a visit's notes list it, the author,
// text, and time; as caseNotes lists it, its encounter and kind before.
fn note_body(out: u8[>..]&, n: Note) {
    out.append(",\"author\":");
    staff_ref(out, n.author, true);
    out.append(",\"text\":");
    http::json_string(out, view(n.text));
    out.append(",\"at\":");
    iso_or_null(out, n.at);
    out.push('}');
}

fn note_id(out: u8[>..]&, n: Note) {
    out.append("{\"id\":");
    format(out, n.id);
}

fn note_case(out: u8[>..]&, n: Note) {
    out.append(",\"encounterId\":");
    format(out, n.visit + 1);
    out.append(",\"kind\":\"");
    out.append(note_kind(n.kind));
    out.push('"');
}

fn case_note_full(out: u8[>..]&, n: Note) {
    note_id(out, n);
    note_case(out, n);
    note_body(out, n);
}

// A visit up to its notes' members.
fn visit_head(out: u8[>..]&, i: i64) {
    let v = visits[i];
    out.append("{\"id\":");
    format(out, i + 1);
    out.append(",\"caseId\":");
    format(out, v.case_id);
    out.append(",\"client\":");
    client_ref(out, v.client);
    out.append(",\"staff\":");
    staff_ref(out, v.staff, true);
    out.append(",\"status\":");
    http::json_string(out, word(v.status));
    out.append(",\"kind\":");
    http::json_string(out, word(v.kind));
    out.append(",\"priority\":");
    http::json_string(out, word(v.priority));
    out.append(",\"start\":");
    iso_or_null(out, v.start);
    out.append(",\"end\":");
    iso_or_null(out, v.end);
    out.append(",\"items\":");
    lines_full(out, v.lines);
    out.append(",\"codes\":[");
    for c, k in v.codes {
        if k > 0 { out.push(','); }
        http::json_string(out, c);
    }
    out.append("],\"notes\":{");
}

// A visit's notes by kind, and the brace that closes them.
fn visit_notes(out: u8[>..]&, i: i64) {
    let v = visits[i];
    var j = v.first_note;
    for kind in 4 {
        if kind > 0 { out.push(','); }
        out.push('"');
        out.append(note_kind(kind));
        out.append("\":[");
        var n = 0;
        while j < v.first_note + v.notes && notes[j].kind == kind {
            if n > 0 { out.push(','); }
            if template {
                http::store_append(tpl.note, note_at[j], note_mid[j], out);
                http::store_append(tpl.note, note_body_at[j], note_at[j + 1], out);
            } else {
                note_id(out, notes[j]);
                note_body(out, notes[j]);
            }
            n++;
            j++;
        }
        out.push(']');
    }
    out.push('}');
}

fn prebuild_heavy() {
    for i in bookings.len {
        booking_at.push(booking_json.len);
        booking_full(booking_json, i);
    }
    booking_at.push(booking_json.len);
    for i in shifts.len {
        shift_at.push(shift_json.len);
        shift_full(shift_json, i);
    }
    shift_at.push(shift_json.len);
    for i in clients.len {
        client_at.push(client_json.len);
        client_full(client_json, i);
    }
    client_at.push(client_json.len);
    for i in visits.len {
        visit_at.push(visit_json.len);
        visit_head(visit_json, i);
    }
    visit_at.push(visit_json.len);
    for n in notes {
        note_at.push(note_json.len);
        note_id(note_json, n);
        note_mid.push(note_json.len);
        note_case(note_json, n);
        note_body_at.push(note_json.len);
        note_body(note_json, n);
    }
    note_at.push(note_json.len);
}

// A visit with its notes by kind, without the closing brace.
fn visit_into(buf: u8[>..]&, i: i64) {
    if template { http::store_append(tpl.visit, visit_at[i], visit_at[i + 1], buf); } else { visit_head(buf, i); }
    visit_notes(buf, i);
}

// Tier D, writes with large bodies, each answered from the body alone. The
// CSV and the multipart body are read in pieces as they arrive; the batch and
// the form are joined first, as the JSON reader takes only a whole text.
// Each answer writes its JSON into buf and returns its status, or 0 for a
// body that isn't one, which the server answers as a bad request.

let MAX_TEXT = 1024;    // a multipart text field's value
let MAX_TEXTS = 8;

// An import's columns, of three kinds.
let COLUMNS = 6;
let TEXT: u8 = 0;
let INT: u8 = 1;
let DEC: u8 = 2;    // two decimal places

fn column_name(k: i64) -> const u8[:] { ["id", "date", "account", "description", "quantity", "amount"][k] }

fn column_kind(k: i64) -> u8 { if k == 0 || k == 4 { INT } else if k == 5 { DEC } else { TEXT } }

// Where a CSV reader is in a field (Csv.quote).
let OUTSIDE: u8 = 0;
let INSIDE: u8 = 1;     // in a quoted field
let AFTER: u8 = 2;      // past a quote in a quoted field: its end, or the first of two

// A CSV body (RFC 4180, with LF or CRLF line ends) read in pieces: where the
// reader is, the field it's in, and each column's count of non-empty cells
// and its sum, or its bytes for text.
struct Csv {
    record: i64 = 1,            // the header is the first
    column: i64 = 0,
    quote: u8 = OUTSIDE,
    closed: bool = false,       // the field's closing quote has passed
    cr: bool = false,           // a CR outside quotes, which only a LF may follow
    len: i64 = 0,               // the field's bytes
    value: i64 = 0,
    neg: bool = false,
    digits: i64 = 0,
    point: i64 = -1,            // the digits after a decimal point, or -1
    number: bool = true,        // the field is still a number of its column's kind
    header: u8[..16] = [],
    counts: i64[6] = [0; 6],
    sums: i64[6] = [0; 6],
    bad: i64 = 0,               // the first record that isn't one, or 0
}

fn csv_bad(c: Csv&) { if c.bad == 0 { c.bad = c.record; } }

fn csv_text(c: Csv&, s: const u8[:]) {
    c.len += s.len;
    if c.record == 1 {
        if c.header.len + s.len <= 16 { c.header.append(s); }
        return;
    }
    guard c.column < COLUMNS else { return; }
    let kind = column_kind(c.column);
    guard kind != TEXT else { return; }
    let before = c.len - s.len;
    for ch, i in s {
        if ch >= '0' && ch <= '9' {
            if c.digits < 18 { c.value = c.value * 10 + (ch - '0'); } else { c.number = false; }
            c.digits++;
            if c.point >= 0 { c.point++; }
        } else if ch == '-' && before + i == 0 {
            c.neg = true;
        } else if ch == '.' && kind == DEC && c.point < 0 && c.digits > 0 {
            c.point = 0;
        } else {
            c.number = false;
        }
    }
}

fn csv_field_end(c: Csv&) {
    let k = c.column;
    if k >= COLUMNS {
        csv_bad(c);
    } else if c.record == 1 {
        if c.len > 16 || c.header != column_name(k) { csv_bad(c); }
    } else if c.len > 0 {
        let kind = column_kind(k);
        if kind == TEXT {
            c.counts[k]++;
            c.sums[k] += c.len;
        } else if c.number && c.digits > 0 && (if kind == DEC { c.point == 2 } else { c.point < 0 }) {
            c.counts[k]++;
            c.sums[k] += if c.neg { -c.value } else { c.value };
        } else {
            csv_bad(c);
        }
    }
    c.column++;
    c.len = 0;
    c.value = 0;
    c.neg = false;
    c.digits = 0;
    c.point = -1;
    c.number = true;
    c.closed = false;
    c.header.clear();
}

fn csv_record_end(c: Csv&) {
    csv_field_end(c);
    if c.column != COLUMNS { csv_bad(c); }
    c.record++;
    c.column = 0;
}

// Reads the next piece of a CSV body into c.
fn csv_piece(c: Csv&, p: const u8[:]) {
    var i = 0;
    while i < p.len && c.bad == 0 {
        let ch = p[i];
        if c.quote == INSIDE {
            let q = position(p[i..], '"');
            if q < 0 {
                csv_text(c, p[i..]);
                return;
            }
            csv_text(c, p[i..i + q]);
            c.quote = AFTER;
            i += q + 1;
            continue;
        }
        if c.quote == AFTER {
            c.quote = OUTSIDE;
            if ch == '"' {
                csv_text(c, p[i..i + 1]);
                c.quote = INSIDE;
                i++;
                continue;
            }
            c.closed = true;
        }
        if c.cr {
            c.cr = false;
            if ch != '\n' {
                csv_bad(c);
                return;
            }
        }
        if ch == ',' {
            csv_field_end(c);
            i++;
        } else if ch == '\n' {
            csv_record_end(c);
            i++;
        } else if ch == '\r' {
            c.cr = true;
            i++;
        } else if c.closed || ch == '"' && c.len > 0 {
            csv_bad(c);
        } else if ch == '"' {
            c.quote = INSIDE;
            i++;
        } else {
            var j = i + 1;
            while j < p.len && p[j] != ',' && p[j] != '\n' && p[j] != '\r' && p[j] != '"' { j++; }
            csv_text(c, p[i..j]);
            i = j;
        }
    }
}

// Ends a CSV body: a last record without a line end ends with it.
fn csv_end(c: Csv&) {
    guard c.bad == 0 else { return; }
    if c.quote == INSIDE || c.cr {
        csv_bad(c);
        return;
    }
    if c.quote == AFTER || c.closed || c.column > 0 || c.len > 0 { csv_record_end(c); }
    if c.record == 1 { csv_bad(c); }
}

// Cents as a JSON number with two decimal places.
fn format_cents(out: u8[>..]&, v: i64) {
    if v < 0 { out.push('-'); }
    let a = if v < 0 { -v } else { v };
    format(out, a / 100, ".");
    digits(out, a % 100, 2);
}

fn import_answer(c: Csv&, buf: u8[>..]&) -> i32 {
    csv_end(c);
    guard c.bad == 0 else {
        format(buf, "{\"error\":\"bad_csv\",\"record\":", c.bad, "}");
        return 400;
    }
    format(buf, "{\"rows\":", c.record - 2, ",\"columns\":[");
    for k in COLUMNS {
        if k > 0 { buf.push(','); }
        format(buf, "{\"name\":\"", column_name(k), "\",\"count\":", c.counts[k]);
        let kind = column_kind(k);
        if kind == TEXT {
            format(buf, ",\"bytes\":", c.sums[k]);
        } else if kind == INT {
            format(buf, ",\"sum\":", c.sums[k]);
        } else {
            buf.append(",\"sum\":");
            format_cents(buf, c.sums[k]);
        }
        buf.push('}');
    }
    buf.append("]}");
    return 201;
}

// The part of a multipart body being read (Spool.part).
let NO_PART: u8 = 0;
let TEXT_PART: u8 = 1;
let FILE_PART: u8 = 2;

// What a write that comes in pieces keeps until its end: the CSV's reader,
// the multipart body's, with its text fields as JSON members and its file's
// size and Adler-32, and a run of the worker's spill (at, len, cap) for what
// it joins, the body or a text field's value.
struct Spool {
    parts: http::Multipart = http::Multipart { .. },
    csv: Csv = Csv { .. },
    at: i64 = 0,
    len: i64 = 0,
    cap: i64 = 0,
    failed: bool = false,
    part: u8 = NO_PART,
    name: u8[..64] = [],
    fields: u8[..8192] = [],
    texts: i64 = 0,
    files: i64 = 0,
    file_field: u8[..64] = [],
    filename: u8[..256] = [],
    file_type: u8[..128] = [],
    size: i64 = 0,
    adler_a: u64 = 1,
    adler_b: u64 = 0,
}

// Each worker's spools, and the runs they join into.
reusable var spools: Spool[>..] = [];
reusable[] var spill: u8[>..] = [];

fn joined(sp: const Spool&) -> const u8[:] { spill[sp.at..sp.at + sp.len] }

fn join(sp: Spool&, data: const u8[:]) {
    let n = sp.len + data.len;
    if n > sp.cap {
        let cap = max(max(n, sp.cap * 2), 16384);
        let run = spill.realloc_slice(spill[sp.at..sp.at + sp.cap], cap);
        sp.at = spill.index_of(run[0]);
        sp.cap = cap;
    }
    copy_into(spill[sp.at + sp.len..sp.at + n], data);
    sp.len = n;
}

fn part_head(sp: Spool&, fields: const u8[:]) {
    let name, filename, ok = http::disposition(fields);
    guard ok && name.len > 0 && name.len <= 64 else {
        sp.failed = true;
        return;
    }
    if filename.len > 0 {
        let t, typed = http::field_in(fields, "content-type");
        guard sp.files == 0 && filename.len <= 256 && t.len <= 128 else {
            sp.failed = true;
            return;
        }
        sp.files = 1;
        sp.part = FILE_PART;
        sp.file_field.append(name);
        sp.filename.append(filename);
        sp.file_type.append(if typed { t } else { "application/octet-stream" });
    } else {
        guard sp.texts < MAX_TEXTS else {
            sp.failed = true;
            return;
        }
        sp.part = TEXT_PART;
        sp.name.clear();
        sp.name.append(name);
        sp.len = 0;
    }
}

// Adler-32 (RFC 1950) over data, from where a and b are, deferring the modulo
// as zlib does: 5,552 bytes keep b within 32 bits.
fn adler(sp: Spool&, data: const u8[:]) {
    var a = sp.adler_a;
    var b = sp.adler_b;
    var i = 0;
    while i < data.len {
        let n = min(data.len - i, 5552);
        for c in data[i..i + n] {
            a += c;
            b += a;
        }
        a %= 65521;
        b %= 65521;
        i += n;
    }
    sp.adler_a = a;
    sp.adler_b = b;
}

fn part_data(sp: Spool&, data: const u8[:]) {
    if sp.part == FILE_PART {
        sp.size += data.len;
        adler(sp, data);
    } else if sp.len + data.len <= MAX_TEXT {
        join(sp, data);
    } else {
        sp.failed = true;
    }
}

fn part_end(sp: Spool&) {
    if sp.part == TEXT_PART {
        // Escaped, a byte takes at most 6.
        guard sp.fields.len + 6 * (sp.name.len + sp.len) + 8 <= 8192 else {
            sp.failed = true;
            return;
        }
        if sp.texts > 0 { sp.fields.push(','); }
        http::json_string(sp.fields, sp.name);
        sp.fields.push(':');
        http::json_string(sp.fields, joined(sp));
        sp.texts++;
    }
    sp.part = NO_PART;
}

fn attach_piece(sp: Spool&, data: const u8[:]) {
    guard !sp.failed else { return; }
    let ok = http::each_part(sp.parts, data) { part =>
        if !sp.failed {
            match part {
                Head h => part_head(sp, h.fields),
                Data d => part_data(sp, d.bytes),
                End => part_end(sp),
            }
        }
    };
    if !ok { sp.failed = true; }
}

fn attach_answer(sp: Spool&, buf: u8[>..]&) -> i32 {
    guard !sp.failed && http::multipart_done(sp.parts) else { return 0; }
    guard sp.files > 0 else {
        buf.append("{\"error\":\"invalid\",\"errors\":[{\"field\":\"file\",\"message\":\"is required\"}]}");
        return 422;
    }
    buf.append("{\"fields\":{");
    buf.append(sp.fields);
    buf.append("},\"file\":{\"field\":");
    http::json_string(buf, sp.file_field);
    buf.append(",\"filename\":");
    http::json_string(buf, sp.filename);
    buf.append(",\"contentType\":");
    http::json_string(buf, sp.file_type);
    format(buf, ",\"size\":", sp.size, ",\"adler32\":", (sp.adler_b << 16) | sp.adler_a, "}}");
    return 201;
}

// How a batch's booking's field read (BookingIn).
let ABSENT: u8 = 0;
let WRONG: u8 = 1;
let FINE: u8 = 2;

struct BookingIn {
    client: u8 = ABSENT,
    staff: u8 = ABSENT,
    service: u8 = ABSENT,
    start: u8 = ABSENT,
    end: u8 = ABSENT,
    room: u8 = ABSENT,
    note: u8 = FINE,
    from: i64 = 0,
    to: i64 = 0,
}

// Whether the member at r's cursor is an integer from lo to hi: a JSON
// number with no fraction.
fn int_member(r: json::Reader&, lo: i64, hi: i64) -> u8 {
    let c = json::peek(r);
    guard c == '-' || c >= '0' && c <= '9' else {
        json::skip(r);
        return WRONG;
    }
    let v = json::read_number(r);
    guard v >= lo && v <= hi && v == v as i64 else { return WRONG; }
    return FINE;
}

fn string_member(r: json::Reader&, scratch: u8[>..]&) -> const u8[:], bool {
    guard json::peek(r) == '"' else {
        json::skip(r);
        return "", false;
    }
    return json::read_string(r, scratch), true;
}

// Two to four capital letters, '-', and two digits.
fn is_service(s: const u8[:]) -> bool {
    let d = position(s, '-');
    guard d >= 2 && d <= 4 && s.len == d + 3 else { return false; }
    for c in s[..d] { if c < 'A' || c > 'Z' { return false; } }
    return s[d + 1] >= '0' && s[d + 1] <= '9' && s[d + 2] >= '0' && s[d + 2] <= '9';
}

fn booking_error(errors: u8[>..]&, k: i64, field: const u8[:], message: const u8[:]) {
    if errors.len > 0 { errors.push(','); }
    format(errors, "{\"index\":", k, ",\"field\":\"", field, "\",\"message\":\"", message, "\"}");
}

fn check_field(errors: u8[>..]&, k: i64, how: u8, field: const u8[:], message: const u8[:]) {
    if how == ABSENT { booking_error(errors, k, field, "is required"); }
    else if how == WRONG { booking_error(errors, k, field, message); }
}

// POST /bookings/batch: each booking's id, the batch's id and its number,
// and their minutes, or 422 with each field that doesn't validate.
fn bookings_batch(body: const u8[:], buf: u8[>..]&) -> i32 {
    var r = json::reader(body);
    var scratch: u8[>..] = [];
    var errors: u8[>..] = [];
    var batch_id: u8[..64] = [];
    var named = false;
    var listed = false;
    var count = 0;
    var minutes = 0;
    guard json::peek(r) == '{' else { return 0; }
    json::each_member(r) { key =>
        if key == "batchId" {
            let s, ok = string_member(r, scratch);
            if ok && s.len >= 1 && s.len <= 64 {
                batch_id.clear();
                batch_id.append(s);
                named = true;
            }
        } else if key == "bookings" && json::peek(r) == '[' {
            listed = true;
            count = 0;
            json::each_element(r) {
                if json::peek(r) != '{' {
                    json::skip(r);
                    booking_error(errors, count, "booking", "must be an object");
                } else {
                    var b = BookingIn { .. };
                    json::each_member(r) { name =>
                        if name == "clientId" {
                            b.client = int_member(r, 1, 1000000);
                        } else if name == "staffId" {
                            b.staff = int_member(r, 1, 10);
                        } else if name == "room" {
                            b.room = int_member(r, 1, 6);
                        } else if name == "service" {
                            let s, ok = string_member(r, scratch);
                            b.service = if ok && is_service(s) { FINE } else { WRONG };
                        } else if name == "start" || name == "end" {
                            let s, ok = string_member(r, scratch);
                            let t, valid = parse_iso(s);
                            let how = if ok && valid { FINE } else { WRONG };
                            if name == "start" {
                                b.start = how;
                                b.from = t;
                            } else {
                                b.end = how;
                                b.to = t;
                            }
                        } else if name == "note" {
                            if json::peek(r) == 'n' {
                                json::skip(r);
                                b.note = FINE;
                            } else {
                                let s, ok = string_member(r, scratch);
                                b.note = if ok && s.len <= 500 { FINE } else { WRONG };
                            }
                        } else {
                            json::skip(r);
                        }
                    };
                    check_field(errors, count, b.client, "clientId", "must be an integer from 1 to 1000000");
                    check_field(errors, count, b.staff, "staffId", "must be an integer from 1 to 10");
                    check_field(errors, count, b.service, "service", "must be a service code");
                    check_field(errors, count, b.start, "start", "must be an ISO 8601 time");
                    check_field(errors, count, b.end, "end", "must be an ISO 8601 time");
                    if b.start == FINE && b.end == FINE && (b.to <= b.from || b.to - b.from > 8 * 3600000) {
                        booking_error(errors, count, "end", "must be after start, by at most 8 hours");
                    }
                    check_field(errors, count, b.room, "room", "must be an integer from 1 to 6");
                    check_field(errors, count, b.note, "note", "must be a string of at most 500 bytes");
                    minutes += (b.to - b.from) / MINUTE;
                }
                count++;
            };
        } else {
            json::skip(r);
        }
    };
    guard json::finish(r) && named && listed else { return 0; }
    if errors.len > 0 {
        buf.append("{\"error\":\"invalid\",\"errors\":[");
        buf.append(errors);
        buf.append("]}");
        return 422;
    }
    buf.append("{\"batchId\":");
    http::json_string(buf, batch_id);
    format(buf, ",\"count\":", count, ",\"minutes\":", minutes, ",\"ids\":[");
    for k in count {
        if k > 0 { buf.push(','); }
        buf.push('"');
        buf.append(batch_id);
        format(buf, "-", k + 1, "\"");
    }
    buf.append("]}");
    return 201;
}

// POST /forms: the form's fields, decoded, in order.
fn form_answer(body: const u8[:], buf: u8[>..]&) -> i32 {
    var ok = true;
    var n = 0;
    var k: u8[>..] = [];
    var v: u8[>..] = [];
    buf.append("{\"fields\":{");
    http::each_form(body) { kraw, vraw =>
        k.clear();
        v.clear();
        if http::decode(kraw, k, true) && http::decode(vraw, v, true) {
            if n > 0 { buf.push(','); }
            http::json_string(buf, k);
            buf.push(':');
            http::json_string(buf, v);
            n++;
        } else {
            ok = false;
        }
    };
    guard ok else { return 0; }
    format(buf, "},\"count\":", n, "}");
    return 200;
}

// The length of each global array a worker copies, one "lens: kind name
// type length" line each, for bench/rest-memory.sh: kind is records or
// templates, and type the element's.
fn print_lens() {
    fn line(kind: const u8[:], name: const u8[:], elem: const u8[:], n: i64) {
        print("lens: ", kind, " ", name, " ", elem, " ", n);
    }
    line("records", "text", "u8", text.len);
    line("records", "words", "Str", words.len);
    line("records", "items", "Item", items.len);
    line("records", "users", "User", users.len);
    line("records", "orgs", "Org", orgs.len);
    line("records", "projects", "Project", projects.len);
    line("records", "people", "Person", people.len);
    line("records", "entries", "Entry", entries.len);
    line("records", "by_token", "i64", by_token.len);
    line("records", "by_person_id", "i64", by_person_id.len);
    line("records", "by_entry_id", "i64", by_entry_id.len);
    line("records", "staffers", "Staffer", staffers.len);
    line("records", "services", "Service", services.len);
    line("records", "clients", "Client", clients.len);
    line("records", "visits", "Visit", visits.len);
    line("records", "notes", "Note", notes.len);
    line("records", "bookings", "Booking", bookings.len);
    line("records", "shifts", "Shift", shifts.len);
    line("records", "past", "i64", past.len);
    line("templates", "item_json", "u8", item_json.len);
    line("templates", "item_at", "i64", item_at.len);
    line("templates", "user_json", "u8", user_json.len);
    line("templates", "user_at", "i64", user_at.len);
    line("templates", "session_json", "u8", session_json.len);
    line("templates", "session_at", "i64", session_at.len);
    line("templates", "project_json", "u8", project_json.len);
    line("templates", "project_at", "i64", project_at.len);
    line("templates", "entry_json", "u8", entry_json.len);
    line("templates", "entry_at", "i64", entry_at.len);
    line("templates", "entry_desc", "i64", entry_desc.len);
    line("templates", "entry_tail", "i64", entry_tail.len);
    line("templates", "timer_json", "u8", timer_json.len);
    line("templates", "timer_at", "i64", timer_at.len);
    line("templates", "booking_json", "u8", booking_json.len);
    line("templates", "booking_at", "i64", booking_at.len);
    line("templates", "shift_json", "u8", shift_json.len);
    line("templates", "shift_at", "i64", shift_at.len);
    line("templates", "client_json", "u8", client_json.len);
    line("templates", "client_at", "i64", client_at.len);
    line("templates", "visit_json", "u8", visit_json.len);
    line("templates", "visit_at", "i64", visit_at.len);
    line("templates", "note_json", "u8", note_json.len);
    line("templates", "note_at", "i64", note_at.len);
    line("templates", "note_mid", "i64", note_mid.len);
    line("templates", "note_body_at", "i64", note_body_at.len);
    // The process's one copy, which no worker holds: bench/rest-memory.sh
    // counts only records and templates.
    line("shared", "item", "u8", max(http::store_len(tpl.item), 0));
    line("shared", "user", "u8", max(http::store_len(tpl.user), 0));
    line("shared", "session", "u8", max(http::store_len(tpl.session), 0));
    line("shared", "project", "u8", max(http::store_len(tpl.project), 0));
    line("shared", "entry", "u8", max(http::store_len(tpl.entry), 0));
    line("shared", "timer", "u8", max(http::store_len(tpl.timer), 0));
    line("shared", "booking", "u8", max(http::store_len(tpl.booking), 0));
    line("shared", "shift", "u8", max(http::store_len(tpl.shift), 0));
    line("shared", "client", "u8", max(http::store_len(tpl.client), 0));
    line("shared", "visit", "u8", max(http::store_len(tpl.visit), 0));
    line("shared", "note", "u8", max(http::store_len(tpl.note), 0));
}

// One set of the records over the typed queues: hand_over puts this thread's
// arrays, and take_all takes them into its globals, both in the same order,
// with Flags carrying the scalar globals, the templates' blobs among them. A
// global array added above goes in both, and in print_lens. Arrays of one
// element type share a queue, so one thread takes at a time, a whole set
// (rest.goose says how its threads take turns).
struct Flags { template: bool, version_epoch: i64, tpl: Templates }

fn give<T>(a: T[>..]&) { qput(a); }

fn take<T>(a: T[>..]&) { a = qget<T[>..]>(); }

fn hand_over() {
    give(text);
    give(words);
    give(items);
    give(users);
    give(orgs);
    give(projects);
    give(people);
    give(entries);
    give(by_token);
    give(by_person_id);
    give(by_entry_id);
    give(staffers);
    give(services);
    give(clients);
    give(visits);
    give(notes);
    give(bookings);
    give(shifts);
    give(past);
    give(item_at);
    give(user_at);
    give(session_at);
    give(project_at);
    give(entry_at);
    give(entry_desc);
    give(entry_tail);
    give(timer_at);
    give(booking_at);
    give(shift_at);
    give(client_at);
    give(visit_at);
    give(note_at);
    give(note_mid);
    give(note_body_at);
    qput(Flags { template: template, version_epoch: version_epoch, tpl: tpl });
}

fn take_all() {
    take(text);
    take(words);
    take(items);
    take(users);
    take(orgs);
    take(projects);
    take(people);
    take(entries);
    take(by_token);
    take(by_person_id);
    take(by_entry_id);
    take(staffers);
    take(services);
    take(clients);
    take(visits);
    take(notes);
    take(bookings);
    take(shifts);
    take(past);
    take(item_at);
    take(user_at);
    take(session_at);
    take(project_at);
    take(entry_at);
    take(entry_desc);
    take(entry_tail);
    take(timer_at);
    take(booking_at);
    take(shift_at);
    take(client_at);
    take(visit_at);
    take(note_at);
    take(note_mid);
    take(note_body_at);
    let f = qget<Flags>();
    template = f.template;
    version_epoch = f.version_epoch;
    tpl = f.tpl;
}

// Puts the prebuilt JSON in the store, where every worker reads the
// one copy, empties the loader's own, and freezes the store. The workers get
// the blobs in Flags, through the queues, which order the store's writes
// before their reads (store.goose).
fn share_templates() {
    fn share(json: u8[>..]&) -> http::Blob {
        let b, err = http::store_put(json);
        guard err == 0 else { abort("rest: the store refused the templates"); }
        json.clear();
        return b;
    }
    tpl.item = share(item_json);
    tpl.user = share(user_json);
    tpl.session = share(session_json);
    tpl.project = share(project_json);
    tpl.entry = share(entry_json);
    tpl.timer = share(timer_json);
    tpl.booking = share(booking_json);
    tpl.shift = share(shift_json);
    tpl.client = share(client_json);
    tpl.visit = share(visit_json);
    tpl.note = share(note_json);
    http::store_freeze();
}

