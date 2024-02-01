const Async = @import("root").bun.Async;
const bun = @import("root").bun;

pub const PollOrFd = union(enum) {
    /// When it's a pipe/fifo
    poll: *Async.FilePoll,

    fd: bun.FileDescriptor,
    closed: void,

    pub fn getFd(this: *const PollOrFd) bun.FileDescriptor {
        return switch (this.*) {
            .closed => bun.invalid_fd,
            .fd => this.fd,
            .poll => this.poll.fd,
        };
    }

    pub fn getPoll(this: *const PollOrFd) ?*Async.FilePoll {
        return switch (this.*) {
            .closed => null,
            .fd => null,
            .poll => this.poll,
        };
    }

    pub fn close(this: *PollOrFd, ctx: ?*anyopaque, comptime onCloseFn: anytype) void {
        const fd = this.getFd();
        if (this.* == .poll) {
            this.poll.deinit();
            this.* = .{ .closed = {} };
        }

        if (fd != bun.invalid_fd) {
            this.handle = .{ .closed = {} };
            if (comptime onCloseFn != void)
                onCloseFn(@ptrCast(ctx.?));
        }
    }
};
