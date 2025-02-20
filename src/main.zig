const std = @import("std");

const Command = enum {
    exit,
    echo,
    type,
    pwd,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const stdin = std.io.getStdIn().reader();
    const stdout_writer = std.io.getStdOut().writer();
    const stderr_writer = std.io.getStdErr().writer();

    var buffer: [1024]u8 = undefined;

    while (true) {
        try stdout_writer.print("$ ", .{});

        const user_input = try stdin.readUntilDelimiterOrEof(&buffer, '\n') orelse {
            return stdout_writer.print("\n", .{});
        };

        const parsed_args = parse_args(allocator, user_input) catch |err| {
            if (err == error.UnclosedQuote) {
                try stderr_writer.print("error: unclosed quote\n", .{});
            } else {
                try stderr_writer.print("error: {s}\n", .{@errorName(err)});
            }
            continue;
        };

        var args = parsed_args.list;

        if (args.len == 0) {
            continue;
        }

        const command = args[0];
        args = args[1..];

        var stdout = stdout_writer.any();
        if (parsed_args.redirect_stdout) |f| {
            stdout = f.writer().any();
        }
        defer {
            if (parsed_args.redirect_stdout) |f| {
                f.close();
            }
        }

        var stderr = stderr_writer.any();
        if (parsed_args.redirect_stderr) |f| {
            stderr = f.writer().any();
        }
        defer {
            if (parsed_args.redirect_stderr) |f| {
                f.close();
            }
        }

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
            try handle_type(stdout, stderr, allocator, args);
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
                    try stderr.print("cd: {s}: No such file or directory\n", .{path});
                };
            } else {
                std.process.changeCurDir(path) catch {
                    try stderr.print("cd: {s}: No such file or directory\n", .{path});
                };
            }
        } else {
            if (find_exec(allocator, command)) |full_path| {
                defer allocator.free(full_path);

                var argv = std.ArrayList([]const u8).init(allocator);
                defer argv.deinit();

                try argv.append(command);

                try argv.appendSlice(args);

                var child = std.process.Child.init(argv.items, allocator);
                if (parsed_args.redirect_stdout != null) {
                    child.stdout_behavior = .Pipe;
                }
                if (parsed_args.redirect_stderr != null) {
                    child.stderr_behavior = .Pipe;
                }

                try child.spawn();
                if (parsed_args.redirect_stdout != null) {
                    try pipe(child.stdout.?.reader().any(), stdout);
                }
                if (parsed_args.redirect_stderr != null) {
                    try pipe(child.stderr.?.reader().any(), stderr);
                }
                _ = try child.wait();
            } else {
                try stderr.print("{s}: command not found\n", .{command});
            }
        }
    }
}

fn pipe(from: std.io.AnyReader, to: std.io.AnyWriter) !void {
    var buffer: [4096]u8 = undefined;

    while (true) {
        const bytes_read = try from.read(&buffer);
        if (bytes_read == 0) break;

        var bytes_written: usize = 0;
        while (bytes_written < bytes_read) {
            bytes_written += try to.write(buffer[bytes_written..bytes_read]);
        }
    }
}

const Args = struct {
    list: [][]u8 = undefined,
    redirect_stdout: ?std.fs.File = null,
    redirect_stderr: ?std.fs.File = null,
};

fn parse_args(allocator: std.mem.Allocator, input: []u8) !Args {
    var args_list = std.ArrayList([]u8).init(allocator);
    var arg_builder = std.ArrayList(u8).init(allocator);
    errdefer arg_builder.deinit();
    errdefer args_list.deinit();

    var in_single_quote = false;
    var in_double_quote = false;
    var escape_next = false;
    var need_redirect_stdout_path = false;
    var need_redirect_stderr_path = false;

    var redirect_stdout: ?std.fs.File = null;
    var redirect_stderr: ?std.fs.File = null;

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
                const arg = try arg_builder.toOwnedSlice();
                if (need_redirect_stdout_path) {
                    redirect_stdout = try std.fs.cwd().createFile(arg, .{});
                    need_redirect_stdout_path = false;
                } else if (need_redirect_stderr_path) {
                    redirect_stderr = try std.fs.cwd().createFile(arg, .{});
                    need_redirect_stderr_path = false;
                } else if (std.mem.eql(u8, arg, ">") or std.mem.eql(u8, arg, "1>")) {
                    need_redirect_stdout_path = true;
                } else if (std.mem.eql(u8, arg, "2>")) {
                    need_redirect_stderr_path = true;
                } else {
                    try args_list.append(arg);
                }
            } else if (char != ' ') {
                try arg_builder.append(char);
            }
        }
    }
    if (in_single_quote or in_double_quote) {
        return error.UnclosedQuote;
    }

    if (arg_builder.items.len != 0) {
        const arg = try arg_builder.toOwnedSlice();
        if (need_redirect_stdout_path) {
            redirect_stdout = try std.fs.cwd().createFile(arg, .{});
            need_redirect_stdout_path = false;
        } else if (need_redirect_stderr_path) {
            redirect_stderr = try std.fs.cwd().createFile(arg, .{});
            need_redirect_stderr_path = false;
        } else if (std.mem.eql(u8, arg, ">") or std.mem.eql(u8, arg, "1>") or std.mem.eql(u8, arg, "2>")) {
            return error.RedirectNoPath;
        } else {
            try args_list.append(arg);
        }
    }

    if (need_redirect_stdout_path or need_redirect_stderr_path) {
        return error.RedirectNoPath;
    }

    return Args{
        .list = try args_list.toOwnedSlice(),
        .redirect_stdout = redirect_stdout,
        .redirect_stderr = redirect_stderr,
    };
}

fn handle_type(stdout: std.io.AnyWriter, stderr: std.io.AnyWriter, allocator: std.mem.Allocator, args: [][]u8) !void {
    for (args) |arg| {
        if (std.meta.stringToEnum(Command, arg) != null) {
            try stdout.print("{s} is a shell builtin\n", .{arg});
        } else {
            if (find_exec(allocator, arg)) |full_path| {
                defer allocator.free(full_path);
                try stdout.print("{s} is {s}\n", .{ arg, full_path });
            } else {
                try stderr.print("{s}: not found\n", .{arg});
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
            list.deinit();
            continue;
        };

        const ownedFullPath = list.toOwnedSlice() catch {
            continue;
        };
        return ownedFullPath;
    }
    return null;
}
