const std = @import("std");

const stdout = std.io.getStdOut().writer();

const Command = enum {
    exit,
    echo,
    type,
    pwd,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    while (true) {
        try stdout.print("$ ", .{});

        const stdin = std.io.getStdIn().reader();
        var buffer: [1024]u8 = undefined;
        const user_input = try stdin.readUntilDelimiterOrEof(&buffer, '\n') orelse {
            return stdout.print("\n", .{});
        };

        var args = parse_args(allocator, user_input) catch |err| {
            if (err == error.UnclosedQuote) {
                try stdout.print("error: unclosed quote\n", .{});
            } else {
                try stdout.print("error: {s}\n", .{@errorName(err)});
            }
            continue;
        };

        if (args.len == 0) {
            continue;
        }

        const command = args[0];
        args = args[1..];

        if (std.mem.eql(u8, command, "exit")) {
            const exit_code = if (args.len != 0)
                try std.fmt.parseInt(u8, args[0], 10)
            else
                0;
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, command, "echo")) {
            for (args) |arg| {
                try stdout.print("{s} ", .{arg});
            }
            try stdout.print("\n", .{});
        } else if (std.mem.eql(u8, command, "type")) {
            try handle_type(allocator, args);
        } else if (std.mem.eql(u8, command, "pwd")) {
            const pwd = try std.process.getCwdAlloc(allocator);
            defer allocator.free(pwd);
            try stdout.print("{s}\n", .{pwd});
        } else if (std.mem.eql(u8, command, "cd")) {
            var path = if (args.len != 0) args[0] else "~";

            // this is a bit better than what is in the task, so it behaves more like a real shell
            if (path[0] == '~') {
                const home = std.posix.getenv("HOME") orelse "";
                var list = try std.ArrayList(u8).initCapacity(allocator, home.len + path.len - 1);
                defer list.deinit();
                try list.appendSlice(home);
                try list.appendSlice(path[1..]);
                path = list.items;
                std.process.changeCurDir(path) catch {
                    try stdout.print("cd: {s}: No such file or directory\n", .{path});
                };
            } else {
                std.process.changeCurDir(path) catch {
                    try stdout.print("cd: {s}: No such file or directory\n", .{path});
                };
            }
        } else {
            if (find_exec(allocator, command)) |full_path| {
                defer allocator.free(full_path);

                var argv = std.ArrayList([]const u8).init(allocator);
                defer argv.deinit();

                try argv.append(full_path);

                for (args) |arg| {
                    try argv.append(arg);
                }

                var child = std.process.Child.init(argv.items, allocator);
                _ = try child.spawnAndWait();
            } else {
                try stdout.print("{s}: command not found\n", .{command});
            }
        }
    }
}

fn parse_args(allocator: std.mem.Allocator, input: []u8) ![][]u8 {
    var args_list = std.ArrayList([]u8).init(allocator);
    var arg_builder = std.ArrayList(u8).init(allocator);

    var in_single_quote = false;
    var in_double_quote = false;
    var escape_next = false;

    for (input) |char| {
        if (in_single_quote) {
            if (char == '\'') {
                in_single_quote = false;
                continue;
            }
            try arg_builder.append(char);
        } else if (in_double_quote) {
            if (escape_next) {
                switch (char) {
                    '\\', '$', '"' => {
                        try arg_builder.append(char);
                    },
                    else => {
                        try arg_builder.appendSlice(&[_]u8{ '\\', char });
                    },
                }
                escape_next = false;
            } else if (char == '"') {
                in_double_quote = false;
            } else if (char == '\\') {
                escape_next = true;
            } else {
                try arg_builder.append(char);
            }
        } else if (escape_next) {
            try arg_builder.append(char);
            escape_next = false;
        } else {
            if (char == '\\') {
                escape_next = true;
            } else if (char == '\'') {
                in_single_quote = true;
            } else if (char == '"') {
                in_double_quote = true;
            } else if (char == ' ' and arg_builder.items.len != 0) {
                try args_list.append(try arg_builder.toOwnedSlice());
            } else if (char != ' ') {
                try arg_builder.append(char);
            }
        }
    }
    if (in_single_quote or in_double_quote) {
        return error.UnclosedQuote;
    }

    if (arg_builder.items.len != 0) {
        try args_list.append(try arg_builder.toOwnedSlice());
    }

    return args_list.toOwnedSlice();
}

fn handle_type(allocator: std.mem.Allocator, args: [][]u8) !void {
    for (args) |arg| {
        if (std.meta.stringToEnum(Command, arg) != null) {
            try stdout.print("{s} is a shell builtin\n", .{arg});
        } else {
            if (find_exec(allocator, arg)) |full_path| {
                defer allocator.free(full_path);
                try stdout.print("{s} is {s}\n", .{ arg, full_path });
            } else {
                try stdout.print("{s}: not found\n", .{arg});
            }
        }
    }
}

/// result is heap allocated, free it after using
fn find_exec(allocator: std.mem.Allocator, cmd: []const u8) ?[]const u8 {
    const path_env = std.posix.getenv("PATH") orelse "";
    var iter = std.mem.tokenizeScalar(u8, path_env, ':');
    while (iter.next()) |dir| {
        const full_path = std.fs.path.join(allocator, &[_][]const u8{ dir, cmd }) catch {
            continue;
        };
        defer allocator.free(full_path);

        const file = std.fs.openFileAbsolute(full_path, .{ .mode = .read_only }) catch {
            continue;
        };
        defer file.close();

        const mode = file.mode() catch {
            continue;
        };

        // check if not executable
        if (mode & 0b111 == 0) {
            continue;
        }

        var list = std.ArrayList(u8).initCapacity(allocator, full_path.len) catch {
            continue;
        };

        list.appendSlice(full_path) catch {
            continue;
        };

        const ownedFullPath = list.toOwnedSlice() catch {
            continue;
        };
        return ownedFullPath;
    }
    return null;
}
