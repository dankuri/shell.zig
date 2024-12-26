const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

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
            } else {
                try stdout.print("{s}: command not found\n", .{c});
            }
        }
    }
}
