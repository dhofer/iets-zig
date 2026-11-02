const std = @import("std");
const iets = @import("iets");

pub fn main(init: std.process.Init) !u8 {
    return iets.cli.run.main(&init);
}
