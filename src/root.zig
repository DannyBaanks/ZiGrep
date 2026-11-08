//! Module root for the `zgrep` test build.
//!
//! The executable is built from `src/main.zig`; this file exists so that
//! `zig build test` reaches every implementation file and runs its tests.
const std = @import("std");

test {
    _ = @import("main.zig");
    _ = @import("search.zig");
    _ = @import("regex.zig");
    _ = @import("walk.zig");
    _ = @import("scan.zig");
    _ = @import("kamikaze.zig");
}
