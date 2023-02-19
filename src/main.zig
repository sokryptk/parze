const std = @import("std");

const delegate = *const fn () void;
const noCommandFound = "parzer-command-not-found";

pub const Options = struct {};

pub const ConfigError = error{
    UnassignedDefaultValues,
    InvalidType,
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
        arguments: std.ArrayList([]const u8),

        const Self = @This();

        pub fn deinit(self: Self) void {
            inline for (@typeInfo(flags).Struct.fields) |field| {
                if (field.type == []const u8) {
                    self.allocator.free(@field(self.flags, field.name));
                }
            }

            self.arguments.deinit();
        }
    };
}

pub const Parser = struct {
    allocator: std.mem.Allocator,
    middlewares: std.StringHashMap(delegate),
    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .middlewares = std.StringHashMap(delegate).init(allocator),
        };
    }

    pub fn deinit(self: Self) void {
        self.middlewares.deinit();
    }

    pub fn onCommand(self: *Self, cmd: []const u8, on: delegate) !void {
        try self.middlewares.put(cmd, on);
    }

    pub fn onDefault(self: *Self, on: delegate) !void {
        try self.middlewares.put(noCommandFound, on);
    }

    // support parsing flags with = and Space delimiter.
    // -a index.js , -a=index.js, --append=index.js, --append index.js
    pub fn parse(self: Self, comptime flags: type, opts: Options) !Result(flags) {
        _ = opts;

        if (!comptime isDefaulted(flags)) {
            return ConfigError.UnassignedDefaultValues;
        }

        const args = try std.process.argsAlloc(self.allocator);
        defer std.process.argsFree(self.allocator, args);

        var i: usize = 1; // ignore the first exe argument
        var res: flags = .{};
        var arguments: std.ArrayList([]const u8) = std.ArrayList([]const u8).init(self.allocator);

        while (i < args.len) : (i += 1) {
            const arg = args[i];

            if (std.mem.startsWith(u8, arg, "--")) {
                // long flags
                const prefix = arg[2..];

                inline for (@typeInfo(flags).Struct.fields) |field| {
                    if (std.mem.eql(u8, prefix, field.name)) {
                        switch (@TypeOf(@field(res, field.name))) {
                            bool => @field(res, field.name) = true,

                            usize, []const u8 => |dtype| {
                                if (i >= args.len - 1) {
                                    // last element
                                    return ParseError.ValueNotFound;
                                }

                                @field(res, field.name) = switch (dtype) {
                                    usize => try std.fmt.parseInt(
                                        usize,
                                        args[i + 1],
                                        10,
                                    ),
                                    else => try self.allocator.dupe(u8, args[i + 1]),
                                };
                            },

                            else => return ConfigError.InvalidType,
                        }

                        i += 1;
                    }
                }
            } else if (std.mem.startsWith(u8, arg, "-")) {
                // short flags can be merged together like -abc
                // these can also contain values
                const prefix = arg[1..];

                for (prefix) |short, index| {
                    inline for (@typeInfo(flags).Struct.fields) |field| {
                        const flag = extractFlag(short, flags);

                        if (flag == null) {
                            return ParseError.InvalidFlag;
                        }

                        if (std.mem.eql(u8, field.name, flag.?)) {
                            switch (@TypeOf(@field(res, field.name))) {
                                bool => @field(res, field.name) = true,
                                u64, []const u8 => |dtype| {
                                    // it should absolutely be the last short to hold a non-boolean value
                                    if (index != prefix.len - 1 or i >= args.len - 1) {
                                        return ParseError.ValueNotFound;
                                    }

                                    @field(res, field.name) = switch (dtype) {
                                        u64 => try std.fmt.parseInt(
                                            u64,
                                            args[i + 1],
                                            10,
                                        ),
                                        else => try self.allocator.dupe(u8, args[i + 1]),
                                    };
                                },
                                else => return ConfigError.InvalidType,
                            }
                            i += 1;
                        }
                    }
                }
            } else {
                try arguments.append(try self.allocator.dupe(u8, arg));
                // no flags
            }
        }

        return Result(flags){
            .allocator = self.allocator,
            .flags = res,
            .arguments = arguments,
        };
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
fn extractFlag(flag: u8, comptime flags: type) ?[]const u8 {
    inline for (flags.aliases.kvs) |kv| {
        if (kv.value == flag) {
            return kv.key;
        }
    }

    return null;
}

fn isDefaulted(comptime flags: type) bool {
    comptime for (@typeInfo(flags).Struct.fields) |field| {
        if (field.default_value == null) {
            return false;
        }
    } else {
        return true;
    };
}
