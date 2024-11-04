const std = @import("std");
const darwin = std.os.darwin;
const Event = @import("interfaces.zig").Event;
const Callback = @import("interfaces.zig").Callback;
const c = @cImport({
    @cInclude("CoreServices/CoreServices.h");
});

pub const MacosWatcher = struct {
    allocator: std.mem.Allocator,
    // XXX hold the files as []u8 so we don't need to convert twice?
    files: std.ArrayList(c.CFStringRef),
    stream: c.FSEventStreamRef,
    callback: ?*const Callback,
    running: bool,

    pub fn init(allocator: std.mem.Allocator) !MacosWatcher {
        return MacosWatcher{
            .allocator = allocator,
            .files = std.ArrayList(c.CFStringRef).init(allocator),
            .stream = null,
            .callback = null,
            .running = false,
        };
    }

    pub fn deinit(self: *MacosWatcher) void {
        if (self.stream != null) try self.stop();
        for (self.files.items) |file| {
            c.CFRelease(file);
        }
        self.files.deinit();
    }

    pub fn addFile(self: *MacosWatcher, path: []const u8) !void {
        const file = c.CFStringCreateWithBytes(
            null,
            path.ptr,
            @as(c_long, @intCast(path.len)),
            c.kCFStringEncodingUTF8,
            0,
        );

        try self.files.append(file);
    }

    pub fn removeFile(self: *MacosWatcher, path: []const u8) !void {
        const target = c.CFStringCreateWithBytes(
            null,
            path.ptr,
            @as(c_long, @intCast(path.len)),
            c.kCFStringEncodingUTF8,
            0,
        );
        defer c.CFRelease(target);

        for (self.files.items, 0..) |file, index| {
            if (c.CFStringCompare(file, target, 0) == 0) {
                c.CFRelease(file);
                _ = self.files.orderedRemove(index);
                break;
            }
        }
    }

    pub fn setCallback(self: *MacosWatcher, callback: Callback) void {
        self.callback = callback;
    }

    fn fsEventsCallback(
        stream: c.ConstFSEventStreamRef,
        info: ?*anyopaque,
        numEvents: usize,
        eventPaths: ?*anyopaque,
        eventFlags: [*c]const c.FSEventStreamEventFlags,
        eventIds: [*c]const c.FSEventStreamEventId,
    ) callconv(.C) void {
        _ = stream;
        _ = eventPaths;
        _ = eventIds;

        const self = @as(*MacosWatcher, @ptrCast(@alignCast(info.?)));

        var i: usize = 0;
        while (i < numEvents) : (i += 1) {
            const flags = eventFlags[i];
            if (flags & c.kFSEventStreamEventFlagItemModified != 0) {
                self.callback.?(Event.modified);
            }
        }
    }

    pub fn start(self: *MacosWatcher) !void {
        if (self.files.items.len == 0) return error.NoFilesToWatch;

        const files = c.CFArrayCreate(
            null,
            @as([*c]?*const anyopaque, @ptrCast(self.files.items.ptr)),
            @as(c_long, @intCast(self.files.items.len)),
            &c.kCFTypeArrayCallBacks,
        );
        defer c.CFRelease(files);

        const latency: c.CFAbsoluteTime = 1.0;
        var context = c.FSEventStreamContext{
            .version = 0,
            .info = self,
            .retain = null,
            .release = null,
            .copyDescription = null,
        };

        self.stream = c.FSEventStreamCreate(
            null,
            fsEventsCallback,
            &context,
            files,
            c.kFSEventStreamEventIdSinceNow,
            latency,
            c.kFSEventStreamCreateFlagFileEvents,
        );

        if (self.stream == null) return error.StreamCreateFailed;

        c.FSEventStreamScheduleWithRunLoop(
            self.stream.?,
            c.CFRunLoopGetCurrent(),
            c.kCFRunLoopDefaultMode,
        );

        if (c.FSEventStreamStart(self.stream.?) == 0) {
            try self.stop();
            return error.StreamStartFailed;
        }

        self.running = true;

        while (self.running) {
            _ = c.CFRunLoopRunInMode(c.kCFRunLoopDefaultMode, 0.5, 1);
        }
    }

    pub fn stop(self: *MacosWatcher) !void {
        self.running = false;
        if (self.stream) |stream| {
            c.FSEventStreamStop(stream);
            c.FSEventStreamInvalidate(stream);
            c.FSEventStreamRelease(stream);
            self.stream = null;
        }
    }
};