const std = @import("std");

const Delegate = *const fn () void;
const noCommandFound = "parzer-command-not-found";

pub const Options = struct {};

pub const ConfigError = error{
    InvalidType,
    ShortsNotFound,
};

pub const ParseError = error{
    ShortHandNotLastElementWhenGrouped,
    ValueNotFound,
    InvalidFlag,
};

pub fn Result(comptime flags: type) type {
    return struct {
        allocator: std.mem.Allocator,
        flags: flags,
        arguments: std.ArrayListUnmanaged([]const u8),
        _args: [][:0]u8 = undefined,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .flags = std.mem.zeroInit(flags, .{}),
                .arguments = std.ArrayListUnmanaged([]const u8){},
            };
        }

        pub fn deinit(self: *Self) void {
            std.process.argsFree(self.allocator, self._args);
            self.arguments.deinit(self.allocator);
        }
    };
}

pub const Parser = struct {
    allocator: std.mem.Allocator,
    middlewares: std.StringHashMapUnmanaged(Delegate),
    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .middlewares = std.StringHashMapUnmanaged(Delegate){},
        };
    }

    pub fn deinit(self: *Self) void {
        self.middlewares.deinit(self.allocator);
    }

    pub fn onCommand(self: *Self, cmd: []const u8, on: Delegate) !void {
        try self.middlewares.put(self.allocator, cmd, on);
    }

    pub fn onDefault(self: *Self, on: Delegate) !void {
        try self.middlewares.put(self.allocator, noCommandFound, on);
    }

    // support parsing flags with = and Space delimiter.
    // -a index.js , -a=index.js, --append=index.js, --append index.js
    pub fn parse(self: Self, comptime flags: type, opts: Options) !Result(flags) {
        _ = opts;

        var i: usize = 1; // ignore the first exe argument
        var result = Result(flags).init(self.allocator);
        result._args = try std.process.argsAlloc(self.allocator);
        errdefer result.deinit();

        while (i < result._args.len) : (i += 1) {
            const arg = result._args[i];

            if (std.mem.startsWith(u8, arg, "--")) {
                // long flags

                // anything after -- is regarded as the arguments
                if (arg.len == 2) {
                    if (i + 1 < result._args.len) {
                        try result.arguments.appendSlice(result.allocator, result._args[(i + 1)..]);
                    }
                    break;
                }

                const whereEql = std.mem.indexOf(u8, arg, "=");
                const prefix = if (whereEql) |eql| arg[2..eql] else arg[2..];

                inline for (@typeInfo(flags).Struct.fields) |field| {
                    if (std.mem.eql(u8, prefix, field.name)) {
                        switch (@TypeOf(@field(result.flags, field.name))) {
                            bool => @field(result.flags, field.name) = true,

                            usize, []const u8 => |dtype| {
                                if (i >= result._args.len - 1 and whereEql == null) {
                                    // last element
                                    return ParseError.ValueNotFound;
                                }

                                @field(result.flags, field.name) = switch (dtype) {
                                    usize => try std.fmt.parseInt(
                                        usize,
                                        if (whereEql) |pos| arg[(pos + 1)..] else result._args[i + 1],
                                        10,
                                    ),
                                    else => if (whereEql) |pos| arg[(pos + 1)..] else result._args[i + 1],
                                };

                                if (whereEql == null) {
                                    i += 1;
                                }
                            },

                            else => return ConfigError.InvalidType,
                        }
                    }
                }
            } else if (std.mem.startsWith(u8, arg, "-")) {
                // short flags can be merged together like -abc
                // these can also contain values
                const whereEql = std.mem.indexOf(u8, arg, "=");
                const prefix = if (whereEql) |eql| arg[1..eql] else arg[1..];

                for (prefix) |short, index| {
                    inline for (@typeInfo(flags).Struct.fields) |field| {
                        const flag = try extractFlag(short, flags);

                        if (flag == null) {
                            return ParseError.InvalidFlag;
                        }

                        if (std.mem.eql(u8, field.name, flag.?)) {
                            switch (@TypeOf(@field(result.flags, field.name))) {
                                bool => @field(result.flags, field.name) = true,
                                u64, []const u8 => |dtype| {
                                    // it should absolutely be the last short to hold a non-boolean value
                                    if (index != prefix.len - 1) {
                                        return ParseError.ValueNotFound;
                                    }

                                    if (i >= result._args.len - 1 and whereEql == null) {
                                        return ParseError.ValueNotFound;
                                    }

                                    @field(result.flags, field.name) = switch (dtype) {
                                        u64 => try std.fmt.parseInt(
                                            u64,
                                            if (whereEql) |eql| arg[(eql + 1)..] else result._args[i + 1],
                                            10,
                                        ),
                                        else => if (whereEql) |eql| arg[(eql + 1)..] else result._args[i + 1],
                                    };

                                    // only move when its space delimited
                                    if (whereEql == null) {
                                        i += 1;
                                    }
                                },
                                else => return ConfigError.InvalidType,
                            }
                        }
                    }
                }
            } else {
                try result.arguments.append(result.allocator, arg);
                // no flags
            }
        }

        return result;
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

// aliases type would be of the format
//  {
//    .help = .{"h", "hel"}
//  }
fn extractFlag(flag: u8, comptime flags: type) !?[]const u8 {
    if (!@hasDecl(flags, "shorts")) {
        return ConfigError.ShortsNotFound;
    }

    inline for (flags.shorts.kvs) |kv| {
        if (kv.value == flag) {
            return kv.key;
        }
    }

    return null;
}
