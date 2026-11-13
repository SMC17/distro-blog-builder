// blog-build: CLI driver. Discovers posts under $BLOG_ROOT/content/posts/,
// renders them via the blog_builder library, and writes the public/ tree
// (per-post HTML, essays.html, feed.xml, sitemap.xml, *.crosspost.txt).

const std = @import("std");
const Io = std.Io;
const lib = @import("blog_builder");

const Allocator = std.mem.Allocator;
const default_site_url = "https://sunlitmoon.online";

const Args = struct {
    root: ?[]const u8 = null,
    site_url: ?[]const u8 = null,
    force: bool = false, // accepted for compatibility; this builder always rebuilds
    help: bool = false,
    // Preview mode renders future-dated posts into public/preview/ instead
    // of suppressing them. Used by the author to verify rendering, OG image,
    // and voice on upcoming posts before the public release date arrives.
    preview: bool = false,
};

fn parseArgs(raw_args: []const []const u8) !Args {
    var out: Args = .{};
    var i: usize = 1;
    while (i < raw_args.len) : (i += 1) {
        const a = raw_args[i];
        if (std.mem.eql(u8, a, "--root")) {
            i += 1;
            if (i >= raw_args.len) return error.MissingArg;
            out.root = raw_args[i];
        } else if (std.mem.eql(u8, a, "--site-url")) {
            i += 1;
            if (i >= raw_args.len) return error.MissingArg;
            out.site_url = raw_args[i];
        } else if (std.mem.eql(u8, a, "--force")) {
            out.force = true;
        } else if (std.mem.eql(u8, a, "--preview")) {
            out.preview = true;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            out.help = true;
        } else {
            std.debug.print("unknown argument: {s}\n", .{a});
            return error.UnknownArg;
        }
    }
    return out;
}

// Resolve "today" in UTC as YYYY-MM-DD. Honors BLOG_TODAY env-var override
// for testing (lets the author preview which posts will publish on a given
// future date without changing the system clock).
fn resolveToday(alloc: Allocator, env: *std.process.Environ.Map, io: Io) ![]const u8 {
    if (env.get("BLOG_TODAY")) |v| {
        const trimmed = std.mem.trim(u8, v, " \t\r\n");
        if (trimmed.len > 0) return alloc.dupe(u8, trimmed);
    }
    const epoch = std.time.epoch;
    const ts = Io.Clock.real.now(io);
    const ns: i96 = ts.nanoseconds;
    // Floor-divide nanoseconds to seconds, then to days. Saturate at 0 on
    // the impossible case of a pre-1970 wall clock so the date math stays
    // in u47 range.
    const secs_i96 = @divFloor(ns, std.time.ns_per_s);
    const now_secs: u64 = if (secs_i96 <= 0) 0 else @intCast(secs_i96);
    const day_secs: u64 = now_secs / epoch.secs_per_day;
    const epoch_day: epoch.EpochDay = .{ .day = @intCast(day_secs) };
    const yd = epoch_day.calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        yd.year,
        md.month.numeric(),
        @as(u16, md.day_index) + 1,
    });
}

fn printHelp() void {
    const msg =
        \\blog-build — render ~/blog
        \\
        \\Usage: blog-build [--root PATH] [--site-url URL] [--force] [--preview]
        \\
        \\Reads $BLOG_ROOT/content/posts/*.{md,html}, writes:
        \\  public/posts/<slug>.html
        \\  public/essays.html
        \\  public/feed.xml
        \\  public/sitemap.xml
        \\  public/posts/<slug>.crosspost.txt
        \\
        \\Posts with frontmatter `date:` in the future are skipped from the
        \\public artifact. They stay in content/posts/ and ship the day
        \\their date arrives via the GH Actions daily cron rebuild.
        \\
        \\Flags:
        \\  --preview    Render future-dated posts to public/preview/ instead
        \\               of suppressing them. The preview tree is its own
        \\               coherent site (own homepage, own feeds) so the
        \\               author can verify rendering before public release.
        \\
        \\Env:
        \\  BLOG_ROOT     defaults to $HOME/blog
        \\  BLOG_SITE_URL defaults to https://sunlitmoon.online
        \\  BLOG_TODAY    YYYY-MM-DD override for the publish-date gate;
        \\                useful for testing which posts go live on a
        \\                given future date without changing the clock.
        \\
    ;
    std.debug.print("{s}", .{msg});
}

fn resolveRoot(alloc: Allocator, env: *std.process.Environ.Map, cli: ?[]const u8) ![]const u8 {
    if (cli) |r| return r;
    if (env.get("BLOG_ROOT")) |v| return v;
    const home = env.get("HOME") orelse return error.NoHome;
    return std.fs.path.join(alloc, &.{ home, "blog" });
}

fn resolveSiteUrl(env: *std.process.Environ.Map, cli: ?[]const u8) []const u8 {
    if (cli) |s| return s;
    if (env.get("BLOG_SITE_URL")) |v| return v;
    return default_site_url;
}

fn readFileAll(arena: Allocator, io: Io, dir: Io.Dir, path: []const u8) ![]u8 {
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fr: Io.File.Reader = .init(file, io, &buf);
    return fr.interface.allocRemaining(arena, .unlimited);
}

fn slugFromName(alloc: Allocator, name: []const u8) ![]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse name.len;
    return alloc.dupe(u8, name[0..dot]);
}

fn lessThanByDateDesc(_: void, a: lib.Post, b: lib.Post) bool {
    return switch (std.mem.order(u8, a.fm.date, b.fm.date)) {
        .gt => true,
        .lt => false,
        // Same date: slug DESC so series-numbered posts (audit-06 > audit-05)
        // float to the top. For non-numbered posts the order is still
        // deterministic, just reverse-alphabetical.
        .eq => std.mem.order(u8, a.slug, b.slug) == .gt,
    };
}

// Workshop entries sort by `started` date desc. The frontmatter field is the
// start date, not the post date — falling back to fm.date if started is empty.
fn lessThanByStartedDesc(_: void, a: lib.Post, b: lib.Post) bool {
    const a_key = if (a.fm.started.len > 0) a.fm.started else a.fm.date;
    const b_key = if (b.fm.started.len > 0) b.fm.started else b.fm.date;
    return switch (std.mem.order(u8, a_key, b_key)) {
        .gt => true,
        .lt => false,
        .eq => std.mem.order(u8, a.slug, b.slug) == .gt,
    };
}

fn lessThanBySlugAsc(_: void, a: lib.Post, b: lib.Post) bool {
    return std.mem.lessThan(u8, a.slug, b.slug);
}

// Load every .md file in `dir_path` (relative to cwd) and return a list of
// rendered Posts. Returns empty list if the directory doesn't exist.
fn loadSectionEntries(
    arena: Allocator,
    io: Io,
    cwd: Io.Dir,
    dir_path: []const u8,
) !std.ArrayList(lib.Post) {
    var entries: std.ArrayList(lib.Post) = .empty;

    var section_dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return entries,
        else => return err,
    };
    defer section_dir.close(io);

    var it = section_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        const path = try std.fs.path.join(arena, &.{ dir_path, entry.name });
        const src = try readFileAll(arena, io, cwd, path);
        const slug = try slugFromName(arena, entry.name);
        const fp = try lib.parseMdFrontmatter(arena, src);
        const body_html = try lib.renderMarkdown(arena, io, fp.body);
        const body_text = try lib.stripTags(arena, body_html);
        try entries.append(arena, .{
            .slug = slug,
            .fm = fp.fm,
            .body_html = body_html,
            .body_text = body_text,
            .source_kind = .md,
        });
        std.debug.print("rendered {s}/{s}\n", .{ dir_path, entry.name });
    }
    return entries;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const raw_args = try init.minimal.args.toSlice(arena);

    const args = try parseArgs(raw_args);

    if (args.help) {
        printHelp();
        return;
    }

    const root = try resolveRoot(arena, init.environ_map, args.root);
    const site_url = resolveSiteUrl(init.environ_map, args.site_url);
    const today = try resolveToday(arena, init.environ_map, io);
    std.debug.print("publish gate: today (UTC) = {s}{s}\n", .{
        today,
        if (args.preview) "  [preview mode: future posts INCLUDED]" else "",
    });

    const content_dir_path = try std.fs.path.join(arena, &.{ root, "content", "posts" });
    // In preview mode the entire site is written under public/preview/ so
    // the live public/ tree is never touched by an author preview build.
    const public_dir_path = if (args.preview)
        try std.fs.path.join(arena, &.{ root, "public", "preview" })
    else
        try std.fs.path.join(arena, &.{ root, "public" });
    const public_posts_path = try std.fs.path.join(arena, &.{ public_dir_path, "posts" });

    const cwd = Io.Dir.cwd();
    cwd.createDirPath(io, public_posts_path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    var content_dir = try cwd.openDir(io, content_dir_path, .{ .iterate = true });
    defer content_dir.close(io);

    var posts: std.ArrayList(lib.Post) = .empty;
    defer posts.deinit(arena);

    // Track future-dated posts that were filtered out of the public build
    // so the build log surfaces the calendar state on every run.
    var future_skipped: usize = 0;

    var it = content_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const is_md = std.mem.endsWith(u8, entry.name, ".md");
        const is_html = std.mem.endsWith(u8, entry.name, ".html");
        if (!is_md and !is_html) continue;

        const path = try std.fs.path.join(arena, &.{ content_dir_path, entry.name });
        const src = try readFileAll(arena, io, cwd, path);

        const slug = try slugFromName(arena, entry.name);

        const fp: lib.FmParse = if (is_md)
            try lib.parseMdFrontmatter(arena, src)
        else
            try lib.parseHtmlFrontmatter(arena, src);

        // Content-calendar gate. A post's `date:` is the public publish date,
        // not metadata. If it is strictly after today (UTC) the source stays
        // in content/posts/ but the public artifact is not rendered. The GH
        // Actions daily cron at 00:01 UTC rebuilds the site so the post ships
        // automatically the morning its date arrives.
        //
        // `--preview` bypasses this gate and writes the future-dated post to
        // public/preview/ instead, letting the author verify rendering, OG
        // image, and voice before the public release date.
        if (!args.preview and lib.isFutureDate(fp.fm.date, today)) {
            future_skipped += 1;
            std.debug.print("future-skip {s} ({s} > {s})\n", .{ entry.name, fp.fm.date, today });
            continue;
        }

        const body_html: []u8 = if (is_md)
            try lib.renderMarkdown(arena, io, fp.body)
        else
            try arena.dupe(u8, fp.body);

        const body_text = try lib.stripTags(arena, body_html);

        const post: lib.Post = .{
            .slug = slug,
            .fm = fp.fm,
            .body_html = body_html,
            .body_text = body_text,
            .source_kind = if (is_md) .md else .html,
        };
        try posts.append(arena, post);

        std.debug.print("rendered {s} ({s})\n", .{ entry.name, post.fm.date });
    }

    std.mem.sort(lib.Post, posts.items, {}, lessThanByDateDesc);

    // Filter drafts out of the public-facing collections (essays.html,
    // feed.xml, sitemap.xml, crosspost.txt, and the {{recent}}/{{featured}}
    // template substitutions). Drafts still get rendered to public/posts/
    // so they can be previewed in the design system at the canonical URL,
    // they just don't appear in any navigable surface until promoted.
    var public_posts: std.ArrayList(lib.Post) = .empty;
    defer public_posts.deinit(arena);
    var draft_count: usize = 0;
    for (posts.items) |p| {
        if (p.fm.draft) {
            draft_count += 1;
            continue;
        }
        try public_posts.append(arena, p);
    }

    var public_dir = try cwd.openDir(io, public_dir_path, .{});
    defer public_dir.close(io);
    var posts_dir = try cwd.openDir(io, public_posts_path, .{ .iterate = true });
    defer posts_dir.close(io);

    // Wipe stale per-post HTML and crosspost snippets before regenerating.
    // Without this, a previously-rendered future post stays web-reachable
    // after the content calendar gate filters it out, defeating the gate.
    // Matches the canon arc wipe pattern below; only removes files this
    // builder owns (.html and .crosspost.txt).
    {
        var posts_iter = posts_dir.iterate();
        while (try posts_iter.next(io)) |posts_entry| {
            if (posts_entry.kind != .file) continue;
            const is_html_file = std.mem.endsWith(u8, posts_entry.name, ".html");
            const is_crosspost = std.mem.endsWith(u8, posts_entry.name, ".crosspost.txt");
            if (!is_html_file and !is_crosspost) continue;
            posts_dir.deleteFile(io, posts_entry.name) catch |e| switch (e) {
                error.FileNotFound => {},
                else => return e,
            };
        }
    }

    // Per-post HTML for non-draft posts only. Drafts are skipped entirely
    // from public/posts/ because public/ is the GitHub Pages source — any
    // file rendered here is web-reachable. Crosspost snippets follow the
    // same gate.
    for (posts.items, 0..) |p, idx| {
        if (p.fm.draft) continue;
        // 1. TOC: rewrite body with id-injected H2s, get TOC HTML.
        var toc_body: []const u8 = undefined;
        const toc_html = try lib.renderToc(arena, p.body_html, 3, &toc_body);
        // 2. Series prev/next nav.
        const series_nav = try lib.renderSeriesNav(arena, posts.items, idx);
        // 3. Per-post version stamp (construction-site receipt). Sits below
        //    the body's last <hr> and above the series-nav so it reads as
        //    the closing artifact of the post itself, not as chrome.
        const version_stamp = try lib.renderVersionStamp(arena, p);
        // 4. Compose: TOC + mutated body + version stamp + series nav.
        const composed = try std.fmt.allocPrint(arena, "{s}{s}{s}{s}", .{ toc_html, toc_body, version_stamp, series_nav });
        var p_aug = p;
        p_aug.body_html = composed;
        const wrapped = try lib.wrapPost(arena, p_aug, site_url);
        const html_name = try std.fmt.allocPrint(arena, "{s}.html", .{p.slug});
        try posts_dir.writeFile(io, .{ .sub_path = html_name, .data = wrapped });

        if (!p.fm.draft) {
            const cross = try lib.renderCrosspost(arena, p, site_url);
            const cross_name = try std.fmt.allocPrint(arena, "{s}.crosspost.txt", .{p.slug});
            try posts_dir.writeFile(io, .{ .sub_path = cross_name, .data = cross });
        }
    }

    const essays = try lib.renderEssaysIndex(arena, public_posts.items, site_url);
    try public_dir.writeFile(io, .{ .sub_path = "essays.html", .data = essays });

    // Per-arc index pages. Each is a curated landing for one content arc.
    // Use the same cwd.createDirPath pattern as public_posts above so we
    // don't depend on whatever subset of fs.Dir the io abstraction exposes.
    const arc_path = try std.fs.path.join(arena, &.{ public_dir_path, "arc" });
    cwd.createDirPath(io, arc_path) catch |e| switch (e) {
        else => return e,
    };
    var arc_dir = try public_dir.openDir(io, "arc", .{});
    defer arc_dir.close(io);
    const Arc = struct {
        prefix: []const u8,
        slug_file: []const u8,
        title: []const u8,
        blurb: []const u8,
    };
    const arcs = [_]Arc{
        .{ .prefix = "doctrine-", .slug_file = "doctrine.html", .title = "The Doctrine Arc", .blurb = "The operating playbook of Quantitative Mercantilism — capability-graded reasoning, lineage mining as methodology, dual-receipt epistemic discipline, and the eight-axis audit rubric." },
        .{ .prefix = "lineage-", .slug_file = "lineage.html", .title = "The Lineage Canon", .blurb = "Biographical merchant studies — Mansa Musa forward. Each essay reads one operator against the merchant lens: flow, bottleneck, risk, lineage, lesson." },
        .{ .prefix = "anti-edison-", .slug_file = "anti-edison.html", .title = "The Anti-Edison Arc", .blurb = "The War-of-Currents reading of bottleneck ownership versus spread-scalping. Reconstructs how Edison's empire lost a position the merchant lens predicted." },
        .{ .prefix = "sovereign-audit-", .slug_file = "sovereign-audit.html", .title = "The Sovereign Audit", .blurb = "Engineering field reports from the substrate side of the Mercantile Thesis — silicon, runtime, deterministic latency, the eight-axis rubric in production." },
    };
    for (arcs) |arc| {
        const page = try lib.renderArcIndex(arena, public_posts.items, arc.prefix, arc.title, arc.blurb, site_url);
        try arc_dir.writeFile(io, .{ .sub_path = arc.slug_file, .data = page });
    }

    const rss = try lib.renderRss(arena, public_posts.items, site_url);
    try public_dir.writeFile(io, .{ .sub_path = "feed.xml", .data = rss });

    const atom = try lib.renderAtom(arena, public_posts.items, site_url);
    try public_dir.writeFile(io, .{ .sub_path = "atom.xml", .data = atom });

    const json_feed = try lib.renderJsonFeed(arena, public_posts.items, site_url);
    try public_dir.writeFile(io, .{ .sub_path = "feed.json", .data = json_feed });

    const sitemap = try lib.renderSitemap(arena, public_posts.items, site_url);
    try public_dir.writeFile(io, .{ .sub_path = "sitemap.xml", .data = sitemap });

    // Optional: render public/index.html (and about.html) from a template
    // under content/. Templates support {{recent}}, {{recent N}}, and
    // {{site_url}} placeholders. If the template doesn't exist, we leave the
    // existing public file alone.
    const tpl_pairs = [_]struct { tpl: []const u8, out: []const u8 }{
        .{ .tpl = "index.template.html", .out = "index.html" },
        .{ .tpl = "about.template.html", .out = "about.html" },
    };
    for (tpl_pairs) |p| {
        const tpl_path = try std.fs.path.join(arena, &.{ root, "content", p.tpl });
        const tpl = readFileAll(arena, io, cwd, tpl_path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        const rendered = try lib.renderTemplate(arena, tpl, public_posts.items, site_url);
        try public_dir.writeFile(io, .{ .sub_path = p.out, .data = rendered });
        std.debug.print("rendered template {s} → {s}\n", .{ p.tpl, p.out });
    }

    // ----- Portfolio sections: /lab /objects /workshop /canon -----
    //
    // Each section reads from content/<section>/*.md and writes to
    // public/<section>/. The canon section additionally pulls existing
    // journal posts (lineage-*, anti-edison-*, doctrine-*) and re-renders
    // them under public/canon/<arc>/<NN>.html with book-grade typography.

    // /lab
    const lab_content = try std.fs.path.join(arena, &.{ root, "content", "lab" });
    const lab_public = try std.fs.path.join(arena, &.{ public_dir_path, "lab" });
    cwd.createDirPath(io, lab_public) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    var lab_entries = try loadSectionEntries(arena, io, cwd, lab_content);
    defer lab_entries.deinit(arena);
    // Lab: sort date desc (most recent first).
    std.mem.sort(lib.Post, lab_entries.items, {}, lessThanByDateDesc);
    {
        var lab_dir = try public_dir.openDir(io, "lab", .{});
        defer lab_dir.close(io);
        const idx = try lib.renderLabIndex(arena, lab_entries.items, site_url);
        try lab_dir.writeFile(io, .{ .sub_path = "index.html", .data = idx });
        for (lab_entries.items) |entry| {
            const html_name = try std.fmt.allocPrint(arena, "{s}.html", .{entry.slug});
            const wrapped = try lib.renderLabEntry(arena, entry, site_url);
            try lab_dir.writeFile(io, .{ .sub_path = html_name, .data = wrapped });
        }
    }

    // /objects
    const objects_content = try std.fs.path.join(arena, &.{ root, "content", "objects" });
    const objects_public = try std.fs.path.join(arena, &.{ public_dir_path, "objects" });
    cwd.createDirPath(io, objects_public) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    var object_entries = try loadSectionEntries(arena, io, cwd, objects_content);
    defer object_entries.deinit(arena);
    std.mem.sort(lib.Post, object_entries.items, {}, lessThanByDateDesc);
    {
        var obj_dir = try public_dir.openDir(io, "objects", .{});
        defer obj_dir.close(io);
        const idx = try lib.renderObjectsIndex(arena, object_entries.items, site_url);
        try obj_dir.writeFile(io, .{ .sub_path = "index.html", .data = idx });
        for (object_entries.items) |entry| {
            const html_name = try std.fmt.allocPrint(arena, "{s}.html", .{entry.slug});
            const wrapped = try lib.renderObjectEntry(arena, entry, site_url);
            try obj_dir.writeFile(io, .{ .sub_path = html_name, .data = wrapped });
        }
    }

    // /workshop
    const workshop_content = try std.fs.path.join(arena, &.{ root, "content", "workshop" });
    const workshop_public = try std.fs.path.join(arena, &.{ public_dir_path, "workshop" });
    cwd.createDirPath(io, workshop_public) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    var workshop_entries = try loadSectionEntries(arena, io, cwd, workshop_content);
    defer workshop_entries.deinit(arena);
    std.mem.sort(lib.Post, workshop_entries.items, {}, lessThanByStartedDesc);
    {
        var ws_dir = try public_dir.openDir(io, "workshop", .{});
        defer ws_dir.close(io);
        const idx = try lib.renderWorkshopIndex(arena, workshop_entries.items, site_url);
        try ws_dir.writeFile(io, .{ .sub_path = "index.html", .data = idx });
        for (workshop_entries.items) |entry| {
            const html_name = try std.fmt.allocPrint(arena, "{s}.html", .{entry.slug});
            const wrapped = try lib.renderWorkshopEntry(arena, entry, site_url);
            try ws_dir.writeFile(io, .{ .sub_path = html_name, .data = wrapped });
        }
    }

    // /substrate
    // Shipped engineering pieces. Each entry is a project tracked by
    // sovereign Forgejo. Sorted ship-date desc so the most recently
    // versioned substrate surfaces first inside its lane.
    const substrate_content = try std.fs.path.join(arena, &.{ root, "content", "substrate" });
    const substrate_public = try std.fs.path.join(arena, &.{ public_dir_path, "substrate" });
    cwd.createDirPath(io, substrate_public) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    var substrate_entries = try loadSectionEntries(arena, io, cwd, substrate_content);
    defer substrate_entries.deinit(arena);
    std.mem.sort(lib.Post, substrate_entries.items, {}, lessThanByDateDesc);
    {
        var sub_dir = try public_dir.openDir(io, "substrate", .{});
        defer sub_dir.close(io);
        const idx = try lib.renderSubstrateIndex(arena, substrate_entries.items, site_url);
        try sub_dir.writeFile(io, .{ .sub_path = "index.html", .data = idx });
        for (substrate_entries.items) |entry| {
            const html_name = try std.fmt.allocPrint(arena, "{s}.html", .{entry.slug});
            const wrapped = try lib.renderSubstrateEntry(arena, entry, site_url);
            try sub_dir.writeFile(io, .{ .sub_path = html_name, .data = wrapped });
        }
    }

    // /canon
    const canon_content = try std.fs.path.join(arena, &.{ root, "content", "canon" });
    const canon_public = try std.fs.path.join(arena, &.{ public_dir_path, "canon" });
    cwd.createDirPath(io, canon_public) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    var canon_intro = try loadSectionEntries(arena, io, cwd, canon_content);
    defer canon_intro.deinit(arena);
    {
        var canon_dir = try public_dir.openDir(io, "canon", .{});
        defer canon_dir.close(io);
        const idx = try lib.renderCanonIndex(arena, canon_intro.items, public_posts.items, site_url);
        try canon_dir.writeFile(io, .{ .sub_path = "index.html", .data = idx });
        // Per-arc subdirectories with renumbered, book-grade entries.
        for (lib.canon_arcs) |arc| {
            const arc_public_path = try std.fs.path.join(arena, &.{ canon_public, arc.arc_slug });
            cwd.createDirPath(io, arc_public_path) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return e,
            };
            // `.iterate = true` is required so the wipe-loop below can list
            // existing files. Without it, iterate() panics with BADF on the
            // first read.
            var canon_arc_dir = try canon_dir.openDir(io, arc.arc_slug, .{ .iterate = true });
            defer canon_arc_dir.close(io);

            // Wipe stale per-slot HTML before regenerating. Without this, a slot
            // whose source slug was renamed or whose draft flag toggled would
            // leave an orphaned file behind. Amendment 1's slug-derived numbering
            // requires the on-disk slot set to exactly match the published set.
            {
                var arc_iter = canon_arc_dir.iterate();
                while (try arc_iter.next(io)) |arc_entry| {
                    if (arc_entry.kind != .file) continue;
                    if (!std.mem.endsWith(u8, arc_entry.name, ".html")) continue;
                    canon_arc_dir.deleteFile(io, arc_entry.name) catch |e| switch (e) {
                        error.FileNotFound => {},
                        else => return e,
                    };
                }
            }

            var arc_posts: std.ArrayList(lib.Post) = .empty;
            defer arc_posts.deinit(arena);
            for (public_posts.items) |jp| {
                if (!std.mem.startsWith(u8, jp.slug, arc.slug_prefix)) continue;
                try arc_posts.append(arena, jp);
            }
            std.mem.sort(lib.Post, arc_posts.items, {}, lessThanBySlugAsc);
            for (arc_posts.items) |arc_post| {
                // Path A canon numbering: number is parsed from the slug,
                // never derived from the sorted-list index. Stable across
                // publish lifecycle. See ~/codex/methods/stax-dev-portfolio-design-system.md
                // Amendment 1.
                const number = lib.parseCanonNumberFromSlug(arc_post.slug, arc.slug_prefix);
                if (number == 0) {
                    std.debug.print("canon: skipping '{s}' — slug does not match {s}<NN>-… convention\n", .{ arc_post.slug, arc.slug_prefix });
                    continue;
                }
                const out_name = try std.fmt.allocPrint(arena, "{d:0>2}.html", .{number});
                const html = try lib.renderCanonEntry(arena, arc_post, arc, number, site_url);
                try canon_arc_dir.writeFile(io, .{ .sub_path = out_name, .data = html });
            }
            std.debug.print("rendered canon/{s}/ ({d} entries)\n", .{ arc.arc_slug, arc_posts.items.len });
        }
    }

    std.debug.print("\nwrote {d} posts ({d} draft{s}, {d} future-skipped) + essays.html + feed.xml + sitemap.xml\n", .{
        posts.items.len,
        draft_count,
        if (draft_count == 1) "" else "s",
        future_skipped,
    });
    std.debug.print("sections: lab={d} substrate={d} objects={d} workshop={d} canon_intro={d}\n", .{
        lab_entries.items.len,
        substrate_entries.items.len,
        object_entries.items.len,
        workshop_entries.items.len,
        canon_intro.items.len,
    });
    std.debug.print("site url: {s}\n", .{site_url});
}
