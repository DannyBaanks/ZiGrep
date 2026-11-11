//! Module root for the `zgrep` test build.
//!
//! The executable is built from `src/main.zig`; this file exists so that
//! `zig build test` reaches every implementation file and runs its tests,
//! and so external scripts (like fuzzer swarms) can access internal modules.
const std = @import("std");

pub const main_mod = @import("main.zig");
pub const search = @import("search.zig");
pub const regex = @import("regex.zig");
pub const walk = @import("walk.zig");
pub const scan = @import("scan.zig");
pub const kamikaze = @import("kamikaze.zig");
pub const filter = @import("filter.zig");
pub const vfs = @import("vfs.zig");
pub const nav = @import("nav.zig");
pub const io_engine = @import("io_engine.zig");
pub const clean = @import("clean.zig");
pub const out_json = @import("out_json.zig");
pub const uring = @import("uring.zig");

test {
    _ = main_mod;
    _ = search;
    _ = regex;
    _ = walk;
    _ = scan;
    _ = kamikaze;
    _ = filter;
    _ = vfs;
    _ = nav;
    _ = io_engine;
    _ = clean;
    _ = out_json;
    _ = uring;
}
