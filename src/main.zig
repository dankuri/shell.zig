const std = @import("std");

const stdout = std.io.getStdOut().writer();

const Command = enum {
    exit,
    echo,
    type,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    while (true) {
        try stdout.print("$ ", .{});

        const stdin = std.io.getStdIn().reader();
        var buffer: [1024]u8 = undefined;
        const user_input = try stdin.readUntilDelimiter(&buffer, '\n');

        var iter = std.mem.tokenizeScalar(u8, user_input, ' ');
        const command = iter.next();

        if (command) |c| {
            if (std.mem.eql(u8, c, "exit")) {
                const exit_code = try std.fmt.parseInt(u8, iter.next() orelse "0", 10);
                std.process.exit(exit_code);
            } else if (std.mem.eql(u8, c, "echo")) {
                while (iter.next()) |arg| {
                    try stdout.print("{s} ", .{arg});
                }
                try stdout.print("\n", .{});
            } else if (std.mem.eql(u8, c, "type")) {
                try handle_type(allocator, &iter);
            } else {
                try stdout.print("{s}: command not found\n", .{c});
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
