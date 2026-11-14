//! backstage: builds the site and deploys it to Cloudflare Workers.
//!
//!   backstage build            compile site/ with idris2
//!   backstage dev              build, then run `wrangler dev` (dev shell only)
//!   backstage deploy <branch>  build and upload the branch's Worker
//!   backstage delete <branch>  delete a preview Worker
//!
//! Worker names, served at <name>.<account subdomain>.workers.dev:
//!   main          -> backstage
//!   other branch  -> <slug>-backstage
//!
//! Run from the repository root. Deploy and delete read CLOUDFLARE_API_TOKEN
//! and CLOUDFLARE_ACCOUNT_ID from the environment. BACKSTAGE_API_URL
//! overrides the API base, for testing against a fake server.
//!
//! Memory: everything goes into the process arena and is never freed. The
//! process is short-lived, so exiting is the cleanup.

const std = @import("std");

const usage =
    \\usage: backstage build
    \\       backstage dev
    \\       backstage deploy <branch>
    \\       backstage delete <branch>
    \\
;

/// The Worker's ES modules: `main_module` imports the compiled Idris output.
const main_module = "worker.js";
const modules = [_]struct { name: []const u8, path: []const u8 }{
    .{ .name = main_module, .path = "site/worker.js" },
    .{ .name = "site.js", .path = "site/build/exec/site.js" },
};

const default_api = "https://api.cloudflare.com/client/v4";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) fail(usage, .{});
    const command = args[1];

    if (std.mem.eql(u8, command, "build")) {
        try build(io);
    } else if (std.mem.eql(u8, command, "dev")) {
        try build(io);
        try run(io, &.{ "wrangler", "dev" }, .inherit);
    } else if (std.mem.eql(u8, command, "deploy") or std.mem.eql(u8, command, "delete")) {
        if (args.len != 3) fail(usage, .{});
        const name = try workerName(arena, args[2]);
        var cf = try Cloudflare.init(arena, io, init.environ_map);
        if (std.mem.eql(u8, command, "deploy")) {
            try build(io);
            try cf.deploy(name);
            std.debug.print("deployed {s}\n", .{name});
        } else {
            if (std.mem.eql(u8, name, "backstage")) fail("refusing to delete production\n", .{});
            try cf.delete(name);
            std.debug.print("deleted {s}\n", .{name});
        }
    } else {
        fail(usage, .{});
    }
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}

fn build(io: std.Io) !void {
    try run(io, &.{ "idris2", "--build", "site.ipkg" }, .{ .path = "site" });
}

fn run(io: std.Io, argv: []const []const u8, cwd: std.process.Child.Cwd) !void {
    var child = std.process.spawn(io, .{ .argv = argv, .cwd = cwd }) catch |err|
        fail("could not run {s}: {t}\n", .{ argv[0], err });
    const term = try child.wait(io);
    if (!term.success()) fail("{s} failed\n", .{argv[0]});
}

/// `main` is production; any other branch becomes a DNS-safe `<slug>-backstage`.
fn workerName(arena: std.mem.Allocator, branch: []const u8) ![]const u8 {
    if (std.mem.eql(u8, branch, "main")) return "backstage";

    // Lowercase alphanumerics; every other run of characters becomes one '-'.
    var slug: std.ArrayList(u8) = .empty;
    for (branch) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try slug.append(arena, std.ascii.toLower(c));
        } else if (slug.items.len > 0 and slug.items[slug.items.len - 1] != '-') {
            try slug.append(arena, '-');
        }
    }
    // 53 characters keeps the name within the 63-character DNS label limit.
    const trimmed = std.mem.trim(u8, slug.items[0..@min(slug.items.len, 53)], "-");
    if (trimmed.len == 0) fail("branch '{s}' has no usable characters\n", .{branch});
    return std.fmt.allocPrint(arena, "{s}-backstage", .{trimmed});
}

const Cloudflare = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    client: std.http.Client,
    api: []const u8,
    account: []const u8,
    auth: []const u8,

    fn init(arena: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) !Cloudflare {
        const token = env.get("CLOUDFLARE_API_TOKEN") orelse fail("CLOUDFLARE_API_TOKEN is not set\n", .{});
        const account = env.get("CLOUDFLARE_ACCOUNT_ID") orelse fail("CLOUDFLARE_ACCOUNT_ID is not set\n", .{});
        return .{
            .arena = arena,
            .io = io,
            .client = .{ .allocator = arena, .io = io },
            .api = env.get("BACKSTAGE_API_URL") orelse default_api,
            .account = account,
            .auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{token}),
        };
    }

    /// Uploads the modules as the Worker's new version, then serves it on workers.dev.
    fn deploy(cf: *Cloudflare, name: []const u8) !void {
        const boundary = "backstage-module-boundary-5f0c2e";
        var body: std.ArrayList(u8) = .empty;

        const metadata = try std.fmt.allocPrint(cf.arena,
            \\{{"main_module":"{s}","compatibility_date":"{s}"}}
        , .{ main_module, try compatibilityDate(cf.arena, cf.io) });
        try appendPart(cf.arena, &body, boundary, "metadata", null, "application/json", metadata);

        for (modules) |m| {
            const source = std.Io.Dir.cwd().readFileAlloc(cf.io, m.path, cf.arena, .unlimited) catch |err|
                fail("could not read {s}: {t}\n", .{ m.path, err });
            if (std.mem.find(u8, source, boundary) != null) fail("{s} contains the multipart boundary\n", .{m.path});
            try appendPart(cf.arena, &body, boundary, m.name, m.name, "application/javascript+module", source);
        }
        try body.appendSlice(cf.arena, "--" ++ boundary ++ "--\r\n");

        _ = try cf.call(.PUT, name, "", "multipart/form-data; boundary=" ++ boundary, body.items);
        _ = try cf.call(.POST, name, "/subdomain", "application/json", "{\"enabled\":true}");
    }

    fn delete(cf: *Cloudflare, name: []const u8) !void {
        _ = try cf.call(.DELETE, name, "?force=true", null, null);
    }

    /// One Workers API request for `name`; exits with Cloudflare's response on failure.
    fn call(
        cf: *Cloudflare,
        method: std.http.Method,
        name: []const u8,
        suffix: []const u8,
        content_type: ?[]const u8,
        payload: ?[]const u8,
    ) ![]const u8 {
        const url = try std.fmt.allocPrint(cf.arena, "{s}/accounts/{s}/workers/scripts/{s}{s}", .{ cf.api, cf.account, name, suffix });
        var response: std.Io.Writer.Allocating = .init(cf.arena);
        const result = try cf.client.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = payload,
            .headers = .{
                .authorization = .{ .override = cf.auth },
                .content_type = if (content_type) |ct| .{ .override = ct } else .default,
            },
            .response_writer = &response.writer,
        });
        if (result.status.class() != .success) {
            fail("{t} {s}{s}: HTTP {d}\n{s}\n", .{ method, name, suffix, @backingInt(result.status), response.written() });
        }
        return response.written();
    }
};

fn appendPart(
    arena: std.mem.Allocator,
    body: *std.ArrayList(u8),
    comptime boundary: []const u8,
    name: []const u8,
    filename: ?[]const u8,
    content_type: []const u8,
    content: []const u8,
) !void {
    try body.appendSlice(arena, "--" ++ boundary ++ "\r\n");
    if (filename) |f| {
        try body.print(arena, "Content-Disposition: form-data; name=\"{s}\"; filename=\"{s}\"\r\n", .{ name, f });
    } else {
        try body.print(arena, "Content-Disposition: form-data; name=\"{s}\"\r\n", .{name});
    }
    try body.print(arena, "Content-Type: {s}\r\n\r\n", .{content_type});
    try body.appendSlice(arena, content);
    try body.appendSlice(arena, "\r\n");
}

/// `compatibility_date` from wrangler.toml, so `wrangler dev` and deploys agree.
fn compatibilityDate(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    const toml = std.Io.Dir.cwd().readFileAlloc(io, "wrangler.toml", arena, .limited(64 * 1024)) catch |err|
        fail("could not read wrangler.toml: {t}\n", .{err});
    var lines = std.mem.splitScalar(u8, toml, '\n');
    while (lines.next()) |line| {
        const l = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, l, "compatibility_date")) continue;
        var quoted = std.mem.splitScalar(u8, l, '"');
        _ = quoted.next();
        if (quoted.next()) |date| return date;
    }
    fail("wrangler.toml has no compatibility_date\n", .{});
}

test workerName {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("backstage", try workerName(a, "main"));
    try std.testing.expectEqualStrings("feature-add-login-backstage", try workerName(a, "Feature/Add_Login"));
    try std.testing.expectEqualStrings("weird-branch-backstage", try workerName(a, "-weird--Branch-"));
}
