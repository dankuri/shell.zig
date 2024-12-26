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

        var arg_iter = std.mem.tokenizeScalar(u8, user_input, ' ');
        const command = arg_iter.next();

        if (command) |c| {
            if (std.mem.eql(u8, c, "exit")) {
                const exit_code = try std.fmt.parseInt(u8, arg_iter.next() orelse "0", 10);
                std.process.exit(exit_code);
            } else if (std.mem.eql(u8, c, "echo")) {
                while (arg_iter.next()) |arg| {
                    try stdout.print("{s} ", .{arg});
                }
                try stdout.print("\n", .{});
            } else if (std.mem.eql(u8, c, "type")) {
                try handle_type(allocator, &arg_iter);
            } else if (std.mem.eql(u8, c, "pwd")) {
                const pwd = try std.process.getCwdAlloc(allocator);
                defer allocator.free(pwd);
                try stdout.print("{s}\n", .{pwd});
            } else if (std.mem.eql(u8, c, "cd")) {
                var path = arg_iter.next() orelse "~";

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
                if (find_exec(allocator, c)) |full_path| {
                    defer allocator.free(full_path);

                    var argv = std.ArrayList([]const u8).init(allocator);
                    defer argv.deinit();

                    try argv.append(full_path);

                    while (arg_iter.next()) |arg| {
                        try argv.append(arg);
                    }

                    var child = std.process.Child.init(argv.items, allocator);
                    _ = try child.spawnAndWait();
                } else {
                    try stdout.print("{s}: command not found\n", .{c});
                }
            }
        }
    }
}

fn handle_type(allocator: std.mem.Allocator, arg_iter: *std.mem.TokenIterator(u8, .scalar)) !void {
    while (arg_iter.next()) |arg| {
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
