// error: http needs the package tls
// A program that imports http.client must declare goose-tls in its root file.
import std;
import http from "../../";
import http.client;

fn main() {}
