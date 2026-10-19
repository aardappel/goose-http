// http::restart_after (http.goose), the policy http::run restarts a worker
// by: a wait that doubles, none while stopping, and the end of the process,
// with exit code 1, at the abort after limit restarts in a row.
import std;
import http from "../../";

fn main() {
    var r = http::Restarts { limit: 3, started: clock_ns(), .. };
    print("while stopping: ", http::restart_after(r, "lane 0", "asked to fail", true));
    print("first: ", http::restart_after(r, "lane 0", "asked to fail", false));
    print("second: ", http::restart_after(r, "lane 0", "asked to fail", false));
    print("aborts: ", r.aborts);
    http::restart_after(r, "lane 0", "asked to fail", false);
    print("not reached");
}
