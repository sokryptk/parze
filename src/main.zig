const std = @import("std");

const delegate = *const fn () void;
const noCommandFound = "parzer-command-not-found";

pub fn Parser() type {
    return struct {
        allocator: std.mem.Allocator,
        middlewares: std.StringHashMap(delegate),
        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .middlewares = std.StringHashMap(delegate).init(allocator),
            };
        }

        pub fn onCommand(self: *Self, cmd: []const u8, on: delegate) !void {
            try self.middlewares.put(cmd, on);
        }

        pub fn onDefault(self: *Self, on: delegate) !void {
            try self.middlewares.put(noCommandFound, on);
        }

        pub fn run(self: *Self) !void {
            const args = try std.process.argsAlloc(self.allocator);
            defer std.process.argsFree(self.allocator, args);

            for (args) |arg| {
                if (self.middlewares.get(arg)) |del| {
                    return del();
                }
            }

            // no args matched to command
            if (self.middlewares.get(noCommandFound)) |del| {
                del();
            }
        }
    };
}