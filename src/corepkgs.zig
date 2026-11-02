//! The Nix sources embedded from Nix 2.34.8, addressed as `<nix/NAME>`.

const std = @import("std");

pub fn get(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "derivation.nix")) return @embedFile("corepkgs/derivation.nix");
    if (std.mem.eql(u8, name, "fetchurl.nix")) return @embedFile("corepkgs/fetchurl.nix");
    return null;
}
