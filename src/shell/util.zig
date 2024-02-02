const IPC = @import("../bun.js/ipc.zig");
const Allocator = std.mem.Allocator;
const uws = bun.uws;
const std = @import("std");
const default_allocator = @import("root").bun.default_allocator;
const bun = @import("root").bun;
const Environment = bun.Environment;
const Async = bun.Async;
const JSC = @import("root").bun.JSC;
const JSValue = JSC.JSValue;
const JSGlobalObject = JSC.JSGlobalObject;
const Which = @import("../which.zig");
const Output = @import("root").bun.Output;
const PosixSpawn = @import("../bun.js/api/bun/spawn.zig").PosixSpawn;
const os = std.os;

pub const OutKind = enum { stdout, stderr };

pub const Stdio = union(enum) {
    inherit: void,
    capture: *bun.ByteList,
    ignore: void,
    fd: bun.FileDescriptor,
    path: JSC.Node.PathLike,
    blob: JSC.WebCore.AnyBlob,
    array_buffer: JSC.ArrayBuffer.Strong,
    memfd: bun.FileDescriptor,
    pipe: void,

    const log = bun.sys.syslog;

    pub fn deinit(this: *Stdio) void {
        switch (this.*) {
            .array_buffer => |*array_buffer| {
                array_buffer.deinit();
            },
            .blob => |*blob| {
                blob.detach();
            },
            .memfd => |fd| {
                _ = bun.sys.close(fd);
            },
            else => {},
        }
    }

    pub fn canUseMemfd(this: *const @This(), is_sync: bool) bool {
        if (comptime !Environment.isLinux) {
            return false;
        }

        return switch (this.*) {
            .blob => !this.blob.needsToReadFile(),
            .memfd, .array_buffer => true,
            .pipe => is_sync,
            else => false,
        };
    }

    pub fn useMemfd(this: *@This(), index: u32) void {
        const label = switch (index) {
            0 => "spawn_stdio_stdin",
            1 => "spawn_stdio_stdout",
            2 => "spawn_stdio_stderr",
            else => "spawn_stdio_memory_file",
        };

        // We use the linux syscall api because the glibc requirement is 2.27, which is a little close for comfort.
        const rc = std.os.linux.memfd_create(label, 0);

        log("memfd_create({s}) = {d}", .{ label, rc });

        switch (std.os.linux.getErrno(rc)) {
            .SUCCESS => {},
            else => |errno| {
                log("Failed to create memfd: {s}", .{@tagName(errno)});
                return;
            },
        }

        const fd = bun.toFD(rc);

        var remain = this.byteSlice();

        if (remain.len > 0)
            // Hint at the size of the file
            _ = bun.sys.ftruncate(fd, @intCast(remain.len));

        // Dump all the bytes in there
        var written: isize = 0;
        while (remain.len > 0) {
            switch (bun.sys.pwrite(fd, remain, written)) {
                .err => |err| {
                    if (err.getErrno() == .AGAIN) {
                        continue;
                    }

                    Output.debugWarn("Failed to write to memfd: {s}", .{@tagName(err.getErrno())});
                    _ = bun.sys.close(fd);
                    return;
                },
                .result => |result| {
                    if (result == 0) {
                        Output.debugWarn("Failed to write to memfd: EOF", .{});
                        _ = bun.sys.close(fd);
                        return;
                    }
                    written += @intCast(result);
                    remain = remain[result..];
                },
            }
        }

        switch (this.*) {
            .array_buffer => this.array_buffer.deinit(),
            .blob => this.blob.detach(),
            else => {},
        }

        this.* = .{ .memfd = fd };
    }

    fn toPosix(
        stdio: *@This(),
    ) bun.spawn.SpawnOptions.Stdio {
        return switch (stdio.*) {
            .capture, .pipe, .array_buffer, .blob => .{ .buffer = {} },
            .fd => |fd| .{ .pipe = fd },
            .memfd => |fd| .{ .pipe = fd },
            .path => |pathlike| .{ .path = pathlike.slice() },
            .inherit => .{ .inherit = {} },
            .ignore => .{ .ignore = {} },
        };
    }

    fn toWindows(
        stdio: *@This(),
    ) bun.spawn.SpawnOptions.Stdio {
        return switch (stdio.*) {
            .capture, .pipe, .array_buffer, .blob => .{ .buffer = {} },
            .fd => |fd| .{ .pipe = fd },
            .path => |pathlike| .{ .path = pathlike.slice() },
            .inherit => .{ .inherit = {} },
            .ignore => .{ .ignore = {} },

            .memfd => @panic("This should never happen"),
        };
    }

    pub fn asSpawnOption(
        stdio: *@This(),
    ) bun.spawn.SpawnOptions.Stdio {
        if (comptime Environment.isWindows) {
            return stdio.toWindows();
        } else {
            return stdio.toPosix();
        }
    }

    pub fn isPiped(self: Stdio) bool {
        return switch (self) {
            .capture, .array_buffer, .blob, .pipe => true,
            else => false,
        };
    }

    fn extractStdio(
        out_stdio: *Stdio,
        globalThis: *JSC.JSGlobalObject,
        i: u32,
        value: JSValue,
    ) bool {
        if (value.isEmptyOrUndefinedOrNull()) {
            return true;
        }

        if (value.isString()) {
            const str = value.getZigString(globalThis);
            if (str.eqlComptime("inherit")) {
                out_stdio.* = Stdio{ .inherit = {} };
            } else if (str.eqlComptime("ignore")) {
                out_stdio.* = Stdio{ .ignore = {} };
            } else if (str.eqlComptime("pipe") or str.eqlComptime("overlapped")) {
                out_stdio.* = Stdio{ .pipe = {} };
            } else if (str.eqlComptime("ipc")) {
                out_stdio.* = Stdio{ .pipe = {} }; // TODO:
            } else {
                globalThis.throwInvalidArguments("stdio must be an array of 'inherit', 'pipe', 'ignore', Bun.file(pathOrFd), number, or null", .{});
                return false;
            }

            return true;
        } else if (value.isNumber()) {
            const fd = value.asFileDescriptor();
            if (fd.int() < 0) {
                globalThis.throwInvalidArguments("file descriptor must be a positive integer", .{});
                return false;
            }

            if (fd.int() >= std.math.maxInt(i32)) {
                var formatter = JSC.ConsoleObject.Formatter{ .globalThis = globalThis };
                globalThis.throwInvalidArguments("file descriptor must be a valid integer, received: {}", .{
                    value.toFmt(globalThis, &formatter),
                });
                return false;
            }

            switch (bun.FDTag.get(fd)) {
                .stdin => {
                    if (i == 1 or i == 2) {
                        globalThis.throwInvalidArguments("stdin cannot be used for stdout or stderr", .{});
                        return false;
                    }

                    out_stdio.* = Stdio{ .inherit = {} };
                    return true;
                },

                .stdout, .stderr => |tag| {
                    if (i == 0) {
                        globalThis.throwInvalidArguments("stdout and stderr cannot be used for stdin", .{});
                        return false;
                    }

                    if (i == 1 and tag == .stdout) {
                        out_stdio.* = .{ .inherit = {} };
                        return true;
                    } else if (i == 2 and tag == .stderr) {
                        out_stdio.* = .{ .inherit = {} };
                        return true;
                    }
                },
                else => {},
            }

            out_stdio.* = Stdio{ .fd = fd };

            return true;
        } else if (value.as(JSC.WebCore.Blob)) |blob| {
            return extractStdioBlob(globalThis, .{ .Blob = blob.dupe() }, i, out_stdio);
        } else if (value.as(JSC.WebCore.Request)) |req| {
            req.getBodyValue().toBlobIfPossible();
            return extractStdioBlob(globalThis, req.getBodyValue().useAsAnyBlob(), i, out_stdio);
        } else if (value.as(JSC.WebCore.Response)) |req| {
            req.getBodyValue().toBlobIfPossible();
            return extractStdioBlob(globalThis, req.getBodyValue().useAsAnyBlob(), i, out_stdio);
        } else if (JSC.WebCore.ReadableStream.fromJS(value, globalThis)) |req_const| {
            var req = req_const;
            if (i == 0) {
                if (req.toAnyBlob(globalThis)) |blob| {
                    return extractStdioBlob(globalThis, blob, i, out_stdio);
                }

                switch (req.ptr) {
                    .File, .Blob => {
                        globalThis.throwTODO("Support fd/blob backed ReadableStream in spawn stdin. See https://github.com/oven-sh/bun/issues/8049");
                        return false;
                    },
                    .Direct, .JavaScript, .Bytes => {
                        // out_stdio.* = .{ .connect = req };
                        globalThis.throwTODO("Re-enable ReadableStream support in spawn stdin. ");
                        return false;
                    },
                    .Invalid => {
                        globalThis.throwInvalidArguments("ReadableStream is in invalid state.", .{});
                        return false;
                    },
                }
            }
        } else if (value.asArrayBuffer(globalThis)) |array_buffer| {
            if (array_buffer.slice().len == 0) {
                globalThis.throwInvalidArguments("ArrayBuffer cannot be empty", .{});
                return false;
            }

            out_stdio.* = .{
                .array_buffer = JSC.ArrayBuffer.Strong{
                    .array_buffer = array_buffer,
                    .held = JSC.Strong.create(array_buffer.value, globalThis),
                },
            };

            return true;
        }

        globalThis.throwInvalidArguments("stdio must be an array of 'inherit', 'ignore', or null", .{});
        return false;
    }

    pub fn extractStdioBlob(
        globalThis: *JSC.JSGlobalObject,
        blob: JSC.WebCore.AnyBlob,
        i: u32,
        stdio_array: []Stdio,
    ) bool {
        const fd = bun.stdio(i);

        if (blob.needsToReadFile()) {
            if (blob.store()) |store| {
                if (store.data.file.pathlike == .fd) {
                    if (store.data.file.pathlike.fd == fd) {
                        stdio_array[i] = Stdio{ .inherit = .{} };
                    } else {
                        switch (bun.FDTag.get(i)) {
                            .stdin => {
                                if (i == 1 or i == 2) {
                                    globalThis.throwInvalidArguments("stdin cannot be used for stdout or stderr", .{});
                                    return false;
                                }
                            },

                            .stdout, .stderr => {
                                if (i == 0) {
                                    globalThis.throwInvalidArguments("stdout and stderr cannot be used for stdin", .{});
                                    return false;
                                }
                            },
                            else => {},
                        }

                        stdio_array[i] = Stdio{ .fd = store.data.file.pathlike.fd };
                    }

                    return true;
                }

                stdio_array[i] = .{ .path = store.data.file.pathlike.path };
                return true;
            }
        }

        if (i == 1 or i == 2) {
            globalThis.throwInvalidArguments("Blobs are immutable, and cannot be used for stdout/stderr", .{});
            return false;
        }

        stdio_array[i] = .{ .blob = blob };
        return true;
    }
};

pub const WatchFd = if (Environment.isLinux) std.os.fd_t else i32;
