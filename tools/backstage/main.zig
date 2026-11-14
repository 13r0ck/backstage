//! backstage: builds the site and deploys it to Cloudflare Workers.
//!
//!   backstage build            compile site/ with idris2
//!   backstage dev              build, then run `wrangler dev` (dev shell only)
//!   backstage deploy <branch>  build and upload the branch's Worker
//!   backstage delete <branch>  delete a preview Worker
//!   backstage pre-push         Git pre-push hook: deploy pushed dev branches
//!                              from this machine (see .githooks/pre-push)
//!
//! Production and previews live in separate Cloudflare accounts; whichever
//! account CLOUDFLARE_API_TOKEN / CLOUDFLARE_ACCOUNT_ID point at is deployed to.
//! CI uses the production account for `main` and the dev account otherwise;
//! developer machines only hold the dev account's token.
//!
//! Worker names, served at <name>.<account subdomain>.workers.dev:
//!   main          -> backstage   (production account: backstage.regal.workers.dev)
//!   other branch  -> <slug>      (dev account: <slug>.jumble-bust-nugget.workers.dev)
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
    \\       backstage pre-push   (reads git's pre-push input on stdin)
    \\
;

/// The Worker's ES modules, named by their path under site/ so the imports
/// in worker.js resolve the same way on Cloudflare as they do locally.
const site_dir = "site/";
const main_module = "worker.js";
const modules = [_][]const u8{ main_module, "build/exec/site.js" };

const default_api = "https://api.cloudflare.com/client/v4";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) fail(usage, .{});
    const command = args[1];

    if (std.mem.eql(u8, command, "build")) {
        try build(arena, io);
    } else if (std.mem.eql(u8, command, "dev")) {
        try build(arena, io);
        try run(io, &.{ "wrangler", "dev" }, .inherit);
    } else if (std.mem.eql(u8, command, "deploy") or std.mem.eql(u8, command, "delete")) {
        if (args.len != 3) fail(usage, .{});
        const name = try workerName(arena, args[2]);
        const env = init.environ_map;
        var cf = try Cloudflare.init(
            arena,
            io,
            env,
            env.get("CLOUDFLARE_API_TOKEN") orelse fail("CLOUDFLARE_API_TOKEN is not set\n", .{}),
            env.get("CLOUDFLARE_ACCOUNT_ID") orelse fail("CLOUDFLARE_ACCOUNT_ID is not set\n", .{}),
        );
        if (std.mem.eql(u8, command, "deploy")) {
            try build(arena, io);
            try cf.deploy(name);
            std.debug.print("deployed {s}\n", .{name});
        } else {
            if (isProduction(name)) fail("refusing to delete production\n", .{});
            try cf.delete(name);
            std.debug.print("deleted {s}\n", .{name});
        }
    } else if (std.mem.eql(u8, command, "pre-push")) {
        try prePush(arena, io, init.environ_map);
    } else {
        fail(usage, .{});
    }
}

fn isProduction(worker: []const u8) bool {
    return std.mem.eql(u8, worker, "backstage");
}

/// Deploys each pushed dev branch from this checkout, before the push is sent.
/// Git passes one line per ref: `<local ref> <local sha> <remote ref> <remote sha>`.
/// Only deploys when the working tree is exactly the pushed commit, so what
/// goes live is what's being pushed. CI deploys the same commit afterwards.
fn prePush(arena: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) !void {
    var buffer: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &buffer);
    const input = try stdin.interface.allocRemaining(arena, .limited(1 << 20));

    const head = std.mem.trim(u8, try git(arena, io, &.{ "git", "rev-parse", "HEAD" }), "\n");
    const dirty = (try git(arena, io, &.{ "git", "status", "--porcelain", "--untracked-files=no" })).len > 0;

    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next() orelse continue; // local ref
        const sha = fields.next() orelse continue;
        const remote_ref = fields.next() orelse continue;
        if (!std.mem.startsWith(u8, remote_ref, "refs/heads/")) continue;
        if (std.mem.allEqual(u8, sha, '0')) continue; // branch deletion
        const branch = remote_ref["refs/heads/".len..];

        const name = try workerName(arena, branch);
        if (isProduction(name)) {
            std.debug.print("backstage: {s} deploys from CI after the push\n", .{branch});
            continue;
        }
        if (!std.mem.eql(u8, sha, head) or dirty) {
            std.debug.print("backstage: not deploying {s} locally: the working tree isn't the pushed commit; CI will deploy it\n", .{branch});
            continue;
        }
        // Only the dev account's credentials, never CLOUDFLARE_API_TOKEN, so a
        // production token in the shell can't be used by a push.
        const token = try devSetting(arena, io, env, "CLOUDFLARE_DEV_API_TOKEN");
        const account = try devSetting(arena, io, env, "CLOUDFLARE_DEV_ACCOUNT_ID");
        if (token == null or account == null) {
            std.debug.print("backstage: put CLOUDFLARE_DEV_API_TOKEN and CLOUDFLARE_DEV_ACCOUNT_ID in .env to deploy previews on push; CI will deploy {s}\n", .{branch});
            return;
        }

        var cf = try Cloudflare.init(arena, io, env, token.?, account.?);
        cf.commit = sha;
        try buildFor(arena, io, sha);
        try cf.deploy(name);
        std.debug.print("backstage: deployed {s} from this machine\n", .{name});
    }
}

/// A dev-account setting from the environment, else from the first env file
/// that exists: the repo's gitignored .env, then ~/.config/backstage/.env
/// (`KEY=value` lines; `#` comments; optional `export` and quotes).
fn devSetting(arena: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, key: []const u8) !?[]const u8 {
    if (env.get(key)) |v| return v;
    const home_env = if (env.get("HOME")) |home| try std.fmt.allocPrint(arena, "{s}/.config/backstage/.env", .{home}) else null;
    for ([_]?[]const u8{ ".env", home_env }) |candidate| {
        const path = candidate orelse continue;
        const file = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => fail("could not read {s}: {t}\n", .{ path, err }),
        };
        return lookupEnvFile(file, key);
    }
    return null;
}

fn lookupEnvFile(file: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, file, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "export ")) line = line["export ".len..];
        const eq = std.mem.findScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), key)) continue;
        return std.mem.trim(u8, std.mem.trim(u8, line[eq + 1 ..], " \t"), "\"'");
    }
    return null;
}

/// Runs a git command and returns its stdout.
fn git(arena: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]const u8 {
    const result = std.process.run(arena, io, .{ .argv = argv }) catch |err|
        fail("could not run git: {t}\n", .{err});
    if (!result.term.success()) fail("{s} failed: {s}\n", .{ argv[1], result.stderr });
    return result.stdout;
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}

/// Records which commit site.js was built from, when the build ran on a clean
/// checkout. pre-push skips compiling if it matches the pushed commit, so a
/// build done right after committing (.githooks/post-commit) makes the push
/// upload-only.
const build_stamp = "site/build/exec/site.commit";

fn build(arena: std.mem.Allocator, io: std.Io) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.deleteFile(io, build_stamp) catch {};
    const before = try cleanHead(arena, io);
    try run(io, &.{ "idris2", "--build", "site.ipkg" }, .{ .path = "site" });
    const commit = before orelse return;
    const after = try cleanHead(arena, io) orelse return;
    if (!std.mem.eql(u8, commit, after)) return; // checkout changed mid-build
    cwd.writeFile(io, .{ .sub_path = build_stamp, .data = commit }) catch {};
}

/// Builds unless site.js is already a clean build of `commit`.
fn buildFor(arena: std.mem.Allocator, io: std.Io, commit: []const u8) !void {
    const stamp = std.Io.Dir.cwd().readFileAlloc(io, build_stamp, arena, .limited(64)) catch "";
    if (std.mem.eql(u8, stamp, commit)) return;
    try build(arena, io);
}

/// HEAD's commit, or null when tracked files have uncommitted changes (or
/// this isn't a git checkout).
fn cleanHead(arena: std.mem.Allocator, io: std.Io) !?[]const u8 {
    const status = std.process.run(arena, io, .{ .argv = &.{ "git", "status", "--porcelain", "--untracked-files=no" } }) catch return null;
    if (!status.term.success() or status.stdout.len > 0) return null;
    const head = std.process.run(arena, io, .{ .argv = &.{ "git", "rev-parse", "HEAD" } }) catch return null;
    if (!head.term.success()) return null;
    return std.mem.trim(u8, head.stdout, "\n");
}

fn run(io: std.Io, argv: []const []const u8, cwd: std.process.Child.Cwd) !void {
    var child = std.process.spawn(io, .{ .argv = argv, .cwd = cwd }) catch |err|
        fail("could not run {s}: {t}\n", .{ argv[0], err });
    const term = try child.wait(io);
    if (!term.success()) fail("{s} failed\n", .{argv[0]});
}

/// `main` is production; any other branch becomes a DNS-safe `<slug>`.
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
    // The Worker name is the subdomain label, limited to 63 characters.
    const trimmed = std.mem.trim(u8, slug.items[0..@min(slug.items.len, 63)], "-");
    if (trimmed.len == 0) fail("branch '{s}' has no usable characters\n", .{branch});
    return trimmed;
}

const Cloudflare = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    client: std.http.Client,
    api: []const u8,
    account: []const u8,
    auth: []const u8,
    /// Bound as the Worker's COMMIT text binding; worker.js serves it as `x-commit`.
    commit: []const u8,

    fn init(arena: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, token: []const u8, account: []const u8) !Cloudflare {
        return .{
            .arena = arena,
            .io = io,
            .client = .{ .allocator = arena, .io = io },
            .api = env.get("BACKSTAGE_API_URL") orelse default_api,
            .account = account,
            .auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{token}),
            .commit = commit: {
                const c = env.get("BACKSTAGE_COMMIT") orelse break :commit "unknown";
                for (c) |ch| if (!std.ascii.isAlphanumeric(ch)) fail("BACKSTAGE_COMMIT must be alphanumeric\n", .{});
                break :commit c;
            },
        };
    }

    /// Uploads the modules as the Worker's new version, then serves it on workers.dev.
    fn deploy(cf: *Cloudflare, name: []const u8) !void {
        const boundary = "backstage-module-boundary-5f0c2e";
        var body: std.ArrayList(u8) = .empty;

        const metadata = try std.fmt.allocPrint(cf.arena,
            \\{{"main_module":"{s}","compatibility_date":"{s}","bindings":[{{"type":"plain_text","name":"COMMIT","text":"{s}"}}]}}
        , .{ main_module, try compatibilityDate(cf.arena, cf.io), cf.commit });
        try appendPart(cf.arena, &body, boundary, "metadata", null, "application/json", metadata);

        inline for (modules) |name_| {
            const path = site_dir ++ name_;
            const source = std.Io.Dir.cwd().readFileAlloc(cf.io, path, cf.arena, .unlimited) catch |err|
                fail("could not read {s}: {t}\n", .{ path, err });
            if (std.mem.find(u8, source, boundary) != null) fail("{s} contains the multipart boundary\n", .{path});
            try appendPart(cf.arena, &body, boundary, name_, name_, "application/javascript+module", source);
        }
        try body.appendSlice(cf.arena, "--" ++ boundary ++ "--\r\n");

        const uploaded = try cf.call(.PUT, name, "", "multipart/form-data; boundary=" ++ boundary, body.items);

        // workers.dev stays enabled once set, so only a newly created Worker
        // (created_on == modified_on) needs the extra round trip.
        const Upload = struct { result: struct { created_on: []const u8, modified_on: []const u8 } };
        const created = if (std.json.parseFromSliceLeaky(Upload, cf.arena, uploaded, .{ .ignore_unknown_fields = true })) |u|
            std.mem.eql(u8, u.result.created_on, u.result.modified_on)
        else |_|
            true; // unexpected response shape: enable to be safe
        if (created) _ = try cf.call(.POST, name, "/subdomain", "application/json", "{\"enabled\":true}");
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
    try std.testing.expectEqualStrings("feature-add-login", try workerName(a, "Feature/Add_Login"));
    try std.testing.expectEqualStrings("weird-branch", try workerName(a, "-weird--Branch-"));
}
