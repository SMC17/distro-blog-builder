// blog-builder library: frontmatter parsing, markdown → html rendering,
// page/feed/sitemap/crosspost templates. Pure functions over slices; the
// CLI in main.zig wires file I/O.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// F5 — fenced-block option parser for the sovereign notebook surface.
/// See `~/Work/lab/blog-builder/docs/notebook-design.md` §2.
pub const block_opts = @import("block_opts.zig");
pub const executor = @import("executor.zig");
pub const sandbox = @import("sandbox.zig");
pub const BlockOptions = block_opts.BlockOptions;
pub const BlockCapture = block_opts.Capture;

test {
    _ = block_opts;
    _ = sandbox;
}

/// Apply a day-granularity content calendar. ISO timestamps use their stated
/// YYYY-MM-DD day; publication time/offset conversion is not performed.
/// Short dates preserve the legacy present-day behavior.
pub fn isFutureDate(date: []const u8, today: []const u8) bool {
    if (date.len < 10 or today.len < 10) return false;
    return std.mem.order(u8, date[0..10], today[0..10]) == .gt;
}

// ---------------------------------------------------------------- types

pub const Frontmatter = struct {
    title: []const u8,
    date: []const u8,
    summary: []const u8 = "",
    tags: []const []const u8 = &.{},
    featured: bool = false,
    draft: bool = false,

    // Section-specific optional metadata. All default to empty slices so the
    // existing journal pipeline (which doesn't read these) is unaffected.
    //
    // /lab entries:
    project: []const u8 = "",
    evidence: []const u8 = "", // unit-tested|differential-tested|compiled|audited|sketch
    reproducible: bool = false,
    // /objects entries:
    status: []const u8 = "", // concept|prototype|shipped  (also reused by /workshop)
    materials: []const []const u8 = &.{},
    dimensions: []const u8 = "",
    hero_image: []const u8 = "",
    // /workshop entries:
    started: []const u8 = "",
    github: []const u8 = "",

    // /substrate entries. `status` is shared with /objects and reused with
    // the fixed substrate vocabulary { experimental, pre-1.0, stable }.
    // `date` is the ship date; `latest_tag` is the latest shipped version.
    lane: []const u8 = "", // inference | validation | comms | editor | integration | research
    latest_tag: []const u8 = "",
    test_count: []const u8 = "",
    license: []const u8 = "",
    forgejo_url: []const u8 = "",
    mirror_url: []const u8 = "",

    // Per-post version-stamp footer. All optional; omitted spans render
    // nothing. `version` defaults to "v1.0" if absent. `audited` falls back
    // to `date`. `falsifier` and `lineage` are omitted when empty.
    version: []const u8 = "",
    audited: []const u8 = "",
    falsifier: []const u8 = "",
    lineage: []const u8 = "",

    pub fn deinit(self: *Frontmatter, alloc: Allocator) void {
        alloc.free(self.title);
        alloc.free(self.date);
        if (self.summary.len > 0) alloc.free(self.summary);
        for (self.tags) |tag| alloc.free(tag);
        if (self.tags.len > 0) alloc.free(self.tags);
        if (self.project.len > 0) alloc.free(self.project);
        if (self.evidence.len > 0) alloc.free(self.evidence);
        if (self.status.len > 0) alloc.free(self.status);
        for (self.materials) |m| alloc.free(m);
        if (self.materials.len > 0) alloc.free(self.materials);
        if (self.dimensions.len > 0) alloc.free(self.dimensions);
        if (self.hero_image.len > 0) alloc.free(self.hero_image);
        if (self.started.len > 0) alloc.free(self.started);
        if (self.github.len > 0) alloc.free(self.github);
        if (self.lane.len > 0) alloc.free(self.lane);
        if (self.latest_tag.len > 0) alloc.free(self.latest_tag);
        if (self.test_count.len > 0) alloc.free(self.test_count);
        if (self.license.len > 0) alloc.free(self.license);
        if (self.forgejo_url.len > 0) alloc.free(self.forgejo_url);
        if (self.mirror_url.len > 0) alloc.free(self.mirror_url);
        if (self.version.len > 0) alloc.free(self.version);
        if (self.audited.len > 0) alloc.free(self.audited);
        if (self.falsifier.len > 0) alloc.free(self.falsifier);
        if (self.lineage.len > 0) alloc.free(self.lineage);
    }
};

pub const SourceKind = enum { md, html };

pub const Post = struct {
    slug: []const u8,
    fm: Frontmatter,
    body_html: []const u8, // ready-to-embed HTML
    body_text: []const u8, // plain text fallback for crosspost summary
    source_kind: SourceKind,

    pub fn deinit(self: *Post, alloc: Allocator) void {
        alloc.free(self.slug);
        self.fm.deinit(alloc);
        alloc.free(self.body_html);
        alloc.free(self.body_text);
    }
};

// Pandoc-style footnote: defined by `[^label]: text` lines (extracted in
// renderMarkdown's pre-pass) and referenced inline by `[^label]`. Numbered
// by order of definition. Labels are arbitrary tokens (`1`, `smith2018`,
// `mansa-musa-hajj`); the renderer treats the label as opaque and uses it
// as the HTML id suffix.
pub const Footnote = struct {
    label: []const u8,
    number: usize,
    text_html: []const u8,
};

fn lookupFootnote(list: *const std.ArrayList(Footnote), label: []const u8) ?Footnote {
    for (list.items) |entry| {
        if (std.mem.eql(u8, entry.label, label)) return entry;
    }
    return null;
}

// ---------------------------------------------------------------- helpers

pub fn htmlEscape(alloc: Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (src) |c| {
        switch (c) {
            '&' => try out.appendSlice(alloc, "&amp;"),
            '<' => try out.appendSlice(alloc, "&lt;"),
            '>' => try out.appendSlice(alloc, "&gt;"),
            '"' => try out.appendSlice(alloc, "&quot;"),
            '\'' => try out.appendSlice(alloc, "&#39;"),
            else => try out.append(alloc, c),
        }
    }
    return out.toOwnedSlice(alloc);
}

// Known acronym tokens that should render all-caps rather than title-case.
// Conservative list — common business/finance/tech/governance acronyms that
// appear in the canon's slug vocabulary. Add as needed.
fn isKnownAcronym(word: []const u8) bool {
    const knowns = [_][]const u8{
        "ai",   "api",  "arr", "asic", "bis", "bnf",  "ceo",    "cfo",  "cia",
        "cio",  "cmo",  "coo", "cpu",  "cto", "dtc",  "ebitda", "etf",  "eu",
        "fbi",  "fpga", "ftc", "gic",  "gp",  "gpu",  "hbs",    "hk",   "hr",
        "imf",  "ip",   "ipo", "irs",  "it",  "jfk",  "jhu",    "kgb",  "kkr",
        "llc",  "lp",   "ltv", "m12",  "mit", "ml",   "mrr",    "nara", "nasa",
        "nato", "nih",  "nsa", "nsf",  "nyc", "oecd", "os",     "p&l",  "pe",
        "pif",  "pr",   "rfp", "rfq",  "roi", "saas", "sec",    "tpg",  "uk",
        "un",   "us",   "usa", "vc",   "wri",
    };
    for (knowns) |k| {
        if (std.mem.eql(u8, word, k)) return true;
    }
    return false;
}

// Convert a slug like "archives/baker-library-hbs" into a readable
// display string like "Baker Library HBS". Strips directory prefix,
// splits on '-'/'_', title-cases each token, and all-caps known acronyms.
// The raw slug stays in the title attribute for tooltip/debug.
// Slugify a heading title into an HTML id token: lowercase, alphanumerics
// and hyphens only, collapse runs of hyphens, strip leading/trailing
// hyphens. Stable across builds.
fn slugifyHeading(alloc: Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var last_was_dash: bool = true; // suppress leading
    for (src) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try out.append(alloc, std.ascii.toLower(c));
            last_was_dash = false;
        } else if (c == ' ' or c == '-' or c == '_' or c == '/' or c == ':' or c == '.' or c == ',' or c == ';') {
            if (!last_was_dash and out.items.len > 0) {
                try out.append(alloc, '-');
                last_was_dash = true;
            }
        }
        // skip other chars
    }
    // strip trailing dash
    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') {
        _ = out.pop();
    }
    return out.toOwnedSlice(alloc);
}

// Render a Table of Contents from the H2 headings in `body_html`. Returns
// empty string if there are fewer than `min_h2` H2 headings (default 3 is
// the threshold for "this essay is long enough to warrant a TOC").
//
// Also rewrites the body_html in place by injecting `id="<slug>"` into each
// H2 so the TOC links can target them. The mutated body is returned in
// `*body_out`; callers should free both returned strings.
pub fn renderToc(alloc: Allocator, body_html: []const u8, min_h2: usize, body_out: *[]const u8) ![]u8 {
    // Pass 1: count H2s.
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, body_html, pos, "<h2>")) |p| {
        count += 1;
        pos = p + 4;
    }
    if (count < min_h2) {
        body_out.* = try alloc.dupe(u8, body_html);
        return alloc.dupe(u8, "");
    }
    // Pass 2: rewrite body with id-injected H2s + collect (id, text) pairs.
    var new_body: std.ArrayList(u8) = .empty;
    defer new_body.deinit(alloc);
    var toc: std.ArrayList(u8) = .empty;
    defer toc.deinit(alloc);
    try toc.appendSlice(alloc, "<nav class=\"toc\" aria-label=\"Contents\"><div class=\"toc-title\">Contents</div><ol>\n");
    pos = 0;
    while (std.mem.indexOfPos(u8, body_html, pos, "<h2>")) |open| {
        try new_body.appendSlice(alloc, body_html[pos..open]);
        const close = std.mem.indexOfPos(u8, body_html, open + 4, "</h2>") orelse break;
        const inner = body_html[open + 4 .. close];
        // Strip HTML tags inside h2 for slug/text. Cheap: collect non-tag chars.
        var plain: std.ArrayList(u8) = .empty;
        defer plain.deinit(alloc);
        var in_tag: bool = false;
        for (inner) |c| {
            if (c == '<') in_tag = true else if (c == '>') in_tag = false else if (!in_tag) try plain.append(alloc, c);
        }
        const slug = try slugifyHeading(alloc, plain.items);
        defer alloc.free(slug);
        const slug_esc = try htmlEscape(alloc, slug);
        defer alloc.free(slug_esc);
        const inner_esc = try htmlEscape(alloc, plain.items);
        defer alloc.free(inner_esc);
        // Emit modified <h2 id="..."> opener.
        const h_open = try std.fmt.allocPrint(alloc, "<h2 id=\"{s}\">", .{slug_esc});
        defer alloc.free(h_open);
        try new_body.appendSlice(alloc, h_open);
        try new_body.appendSlice(alloc, inner);
        try new_body.appendSlice(alloc, "</h2>");
        // TOC entry.
        const toc_li = try std.fmt.allocPrint(alloc, "  <li><a href=\"#{s}\">{s}</a></li>\n", .{ slug_esc, inner_esc });
        defer alloc.free(toc_li);
        try toc.appendSlice(alloc, toc_li);
        pos = close + 5; // length of "</h2>"
    }
    try new_body.appendSlice(alloc, body_html[pos..]);
    try toc.appendSlice(alloc, "</ol></nav>\n");
    body_out.* = try new_body.toOwnedSlice(alloc);
    return toc.toOwnedSlice(alloc);
}

// Extract the series prefix from a slug like "doctrine-06-eight-axis-check"
// → "doctrine-". Returns null if the slug doesn't match `<prefix>-<NN>-...`
// (where NN is exactly two digits).
fn seriesPrefix(slug: []const u8) ?[]const u8 {
    // Find the position of "-NN-" where NN is two digits.
    var i: usize = 0;
    while (i + 4 < slug.len) : (i += 1) {
        if (slug[i] == '-' and
            std.ascii.isDigit(slug[i + 1]) and
            std.ascii.isDigit(slug[i + 2]) and
            slug[i + 3] == '-')
        {
            return slug[0 .. i + 1]; // include the trailing '-'
        }
    }
    return null;
}

// Render the prev/next series navigation HTML for a post within `posts`. If
// the post's slug doesn't follow the `<prefix>-NN-...` pattern, returns an
// empty string. Otherwise scans for sibling slugs with the same prefix and
// renders prev/next links (relative to the per-post HTML output dir).
pub fn renderSeriesNav(alloc: Allocator, posts: []const Post, current_idx: usize) ![]u8 {
    const me = posts[current_idx];
    const prefix = seriesPrefix(me.slug) orelse return alloc.dupe(u8, "");
    // Collect siblings (same prefix + draft-state-aware: only non-drafts).
    var siblings: std.ArrayList(Post) = .empty;
    defer siblings.deinit(alloc);
    for (posts) |p| {
        if (p.fm.draft) continue;
        const p_prefix = seriesPrefix(p.slug) orelse continue;
        if (std.mem.eql(u8, prefix, p_prefix)) {
            try siblings.append(alloc, p);
        }
    }
    if (siblings.items.len <= 1) return alloc.dupe(u8, "");

    // Sort siblings by slug ascending so NN ordering is stable.
    const Less = struct {
        fn lt(_: void, a: Post, b: Post) bool {
            return std.mem.lessThan(u8, a.slug, b.slug);
        }
    };
    std.mem.sort(Post, siblings.items, {}, Less.lt);

    // Find my index in the sibling list.
    var my_i: usize = 0;
    while (my_i < siblings.items.len) : (my_i += 1) {
        if (std.mem.eql(u8, siblings.items[my_i].slug, me.slug)) break;
    }
    if (my_i == siblings.items.len) return alloc.dupe(u8, "");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "\n        <nav class=\"series-nav\" aria-label=\"Series navigation\">\n");
    if (my_i > 0) {
        const prev = siblings.items[my_i - 1];
        const t = try htmlEscape(alloc, prev.fm.title);
        defer alloc.free(t);
        const tmp = try std.fmt.allocPrint(alloc, "            <a class=\"series-prev\" rel=\"prev\" href=\"{s}.html\">← {s}</a>\n", .{ prev.slug, t });
        defer alloc.free(tmp);
        try out.appendSlice(alloc, tmp);
    }
    if (my_i + 1 < siblings.items.len) {
        const next = siblings.items[my_i + 1];
        const t = try htmlEscape(alloc, next.fm.title);
        defer alloc.free(t);
        const tmp = try std.fmt.allocPrint(alloc, "            <a class=\"series-next\" rel=\"next\" href=\"{s}.html\">{s} →</a>\n", .{ next.slug, t });
        defer alloc.free(tmp);
        try out.appendSlice(alloc, tmp);
    }
    try out.appendSlice(alloc, "        </nav>\n");
    return out.toOwnedSlice(alloc);
}

// Count whitespace-separated words in a plain-text buffer. Used for the
// read-time + word-count meta line on each post.
pub fn countWords(s: []const u8) usize {
    var n: usize = 0;
    var in_word: bool = false;
    for (s) |c| {
        const ws = (c == ' ' or c == '\n' or c == '\r' or c == '\t');
        if (!ws and !in_word) {
            n += 1;
            in_word = true;
        } else if (ws) {
            in_word = false;
        }
    }
    return n;
}

pub fn humanizeSlug(alloc: Allocator, slug: []const u8) ![]u8 {
    var start: usize = 0;
    if (std.mem.lastIndexOfScalar(u8, slug, '/')) |lp| {
        start = lp + 1;
    }
    const stem = slug[start..];
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var word_start: usize = 0;
    var i: usize = 0;
    while (i <= stem.len) : (i += 1) {
        const at_end = i == stem.len;
        const is_sep = if (at_end) true else (stem[i] == '-' or stem[i] == '_');
        if (is_sep) {
            const word = stem[word_start..i];
            if (word.len > 0) {
                if (out.items.len > 0) try out.append(alloc, ' ');
                if (isKnownAcronym(word)) {
                    for (word) |ch| {
                        if (ch >= 'a' and ch <= 'z') {
                            try out.append(alloc, ch - 32);
                        } else {
                            try out.append(alloc, ch);
                        }
                    }
                } else {
                    for (word, 0..) |ch, idx| {
                        if (idx == 0 and ch >= 'a' and ch <= 'z') {
                            try out.append(alloc, ch - 32);
                        } else {
                            try out.append(alloc, ch);
                        }
                    }
                }
            }
            word_start = i + 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

pub fn xmlEscape(alloc: Allocator, src: []const u8) ![]u8 {
    return htmlEscape(alloc, src);
}

fn isBullet(line: []const u8) bool {
    return line.len >= 2 and (line[0] == '-' or line[0] == '*') and line[1] == ' ';
}

fn isOrdered(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
    if (i == 0 or i >= line.len) return false;
    if (line[i] != '.') return false;
    if (i + 1 >= line.len) return false;
    return line[i + 1] == ' ';
}

fn isBlockStart(trimmed: []const u8) bool {
    if (trimmed.len == 0) return false;
    if (trimmed[0] == '#') return true;
    if (std.mem.startsWith(u8, trimmed, "```")) return true;
    if (std.mem.startsWith(u8, trimmed, "> ")) return true;
    if (isBullet(trimmed)) return true;
    if (isOrdered(trimmed)) return true;
    if (std.mem.eql(u8, trimmed, "---") or std.mem.eql(u8, trimmed, "***")) return true;
    if (std.mem.startsWith(u8, trimmed, "![")) return true;
    return false;
}

fn isUrlTerminator(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', '<', '>', '"', '\'', ')', ',', ';' => true,
        else => false,
    };
}

// ---------------------------------------------------------------- frontmatter

pub const FmParse = struct { fm: Frontmatter, body: []const u8 };

pub fn parseMdFrontmatter(alloc: Allocator, src: []const u8) !FmParse {
    if (!std.mem.startsWith(u8, src, "---\n")) {
        return .{
            .fm = .{ .title = try alloc.dupe(u8, ""), .date = try alloc.dupe(u8, "") },
            .body = src,
        };
    }
    const end = std.mem.indexOfPos(u8, src, 4, "\n---\n") orelse return error.UnclosedFrontmatter;
    const block = src[4..end];
    var body_start = end + 5;
    while (body_start < src.len and (src[body_start] == '\n' or src[body_start] == '\r')) body_start += 1;
    const body = src[body_start..];
    const fm = try parseFmBlock(alloc, block);
    return .{ .fm = fm, .body = body };
}

pub fn parseHtmlFrontmatter(alloc: Allocator, src: []const u8) !FmParse {
    if (!std.mem.startsWith(u8, src, "<!--")) {
        return .{
            .fm = .{ .title = try alloc.dupe(u8, ""), .date = try alloc.dupe(u8, "") },
            .body = src,
        };
    }
    const end = std.mem.indexOf(u8, src, "-->") orelse return error.UnclosedFrontmatter;
    const block = std.mem.trim(u8, src[4..end], " \t\r\n");
    var body_start = end + 3;
    while (body_start < src.len and (src[body_start] == '\n' or src[body_start] == '\r')) body_start += 1;
    const body = src[body_start..];
    const fm = try parseFmBlock(alloc, block);
    return .{ .fm = fm, .body = body };
}

fn parseFmBlock(alloc: Allocator, block: []const u8) !Frontmatter {
    var fm: Frontmatter = .{
        .title = try alloc.dupe(u8, ""),
        .date = try alloc.dupe(u8, ""),
    };
    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \t\r");
        if (ln.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, ln, ':') orelse continue;
        const key = std.mem.trim(u8, ln[0..colon], " \t");
        var val = std.mem.trim(u8, ln[colon + 1 ..], " \t");
        if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
            val = val[1 .. val.len - 1];
        }
        if (std.mem.eql(u8, key, "title")) {
            alloc.free(fm.title);
            fm.title = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "date")) {
            alloc.free(fm.date);
            fm.date = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "summary")) {
            fm.summary = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "featured")) {
            fm.featured = std.mem.eql(u8, val, "true");
        } else if (std.mem.eql(u8, key, "draft")) {
            fm.draft = std.mem.eql(u8, val, "true");
        } else if (std.mem.eql(u8, key, "tags")) {
            var v = val;
            if (v.len >= 2 and v[0] == '[' and v[v.len - 1] == ']') {
                v = v[1 .. v.len - 1];
            }
            var tag_list: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (tag_list.items) |t| alloc.free(t);
                tag_list.deinit(alloc);
            }
            var it = std.mem.splitScalar(u8, v, ',');
            while (it.next()) |raw_tag| {
                var t = std.mem.trim(u8, raw_tag, " \t");
                if (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"') t = t[1 .. t.len - 1];
                if (t.len == 0) continue;
                try tag_list.append(alloc, try alloc.dupe(u8, t));
            }
            fm.tags = try tag_list.toOwnedSlice(alloc);
        } else if (std.mem.eql(u8, key, "project")) {
            fm.project = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "evidence")) {
            fm.evidence = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "reproducible")) {
            fm.reproducible = std.mem.eql(u8, val, "true");
        } else if (std.mem.eql(u8, key, "status")) {
            fm.status = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "dimensions")) {
            fm.dimensions = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "hero_image")) {
            fm.hero_image = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "started")) {
            fm.started = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "github")) {
            fm.github = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "lane")) {
            fm.lane = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "latest_tag")) {
            fm.latest_tag = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "test_count")) {
            fm.test_count = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "license")) {
            fm.license = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "forgejo_url")) {
            fm.forgejo_url = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "mirror_url")) {
            fm.mirror_url = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "version")) {
            fm.version = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "audited")) {
            fm.audited = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "falsifier")) {
            fm.falsifier = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "lineage")) {
            fm.lineage = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "materials")) {
            var v = val;
            if (v.len >= 2 and v[0] == '[' and v[v.len - 1] == ']') {
                v = v[1 .. v.len - 1];
            }
            var mat_list: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (mat_list.items) |t| alloc.free(t);
                mat_list.deinit(alloc);
            }
            var it = std.mem.splitScalar(u8, v, ',');
            while (it.next()) |raw_m| {
                var t = std.mem.trim(u8, raw_m, " \t");
                if (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"') t = t[1 .. t.len - 1];
                if (t.len == 0) continue;
                try mat_list.append(alloc, try alloc.dupe(u8, t));
            }
            fm.materials = try mat_list.toOwnedSlice(alloc);
        }
    }
    return fm;
}

// ---------------------------------------------------------------- inline

// `footnotes` is optional. When non-null and a `[^label]` reference resolves
// to a known footnote, the reference renders as a numbered superscript link.
// When null (or label unknown), the reference falls through to literal
// rendering. Recursive calls inside renderInline (bold/italic/link inner
// content) thread the same map through, so a footnote reference inside a
// bold span still resolves correctly.
pub fn renderInline(alloc: Allocator, src: []const u8, footnotes: ?*const std.ArrayList(Footnote)) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];

        if (c == '`') {
            if (std.mem.indexOfScalarPos(u8, src, i + 1, '`')) |e| {
                try out.appendSlice(alloc, "<code>");
                const esc = try htmlEscape(alloc, src[i + 1 .. e]);
                defer alloc.free(esc);
                try out.appendSlice(alloc, esc);
                try out.appendSlice(alloc, "</code>");
                i = e + 1;
                continue;
            }
        }

        if (c == '*' and i + 1 < src.len and src[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, src, i + 2, "**")) |e| {
                try out.appendSlice(alloc, "<b>");
                const inner = try renderInline(alloc, src[i + 2 .. e], footnotes);
                defer alloc.free(inner);
                try out.appendSlice(alloc, inner);
                try out.appendSlice(alloc, "</b>");
                i = e + 2;
                continue;
            }
        }

        if (c == '*' and (i == 0 or src[i - 1] != '*') and i + 1 < src.len and src[i + 1] != '*') {
            var j: usize = i + 1;
            var found: ?usize = null;
            while (j < src.len) : (j += 1) {
                if (src[j] == '*' and (j + 1 >= src.len or src[j + 1] != '*') and (j == 0 or src[j - 1] != '*')) {
                    found = j;
                    break;
                }
            }
            if (found) |e| {
                try out.appendSlice(alloc, "<i>");
                const inner = try renderInline(alloc, src[i + 1 .. e], footnotes);
                defer alloc.free(inner);
                try out.appendSlice(alloc, inner);
                try out.appendSlice(alloc, "</i>");
                i = e + 1;
                continue;
            }
        }

        // Footnote reference: [^label]
        if (c == '[' and i + 1 < src.len and src[i + 1] == '^') {
            if (std.mem.indexOfScalarPos(u8, src, i + 2, ']')) |close| {
                const label = src[i + 2 .. close];
                if (footnotes) |fns| {
                    if (lookupFootnote(fns, label)) |entry| {
                        const label_esc = try htmlEscape(alloc, label);
                        defer alloc.free(label_esc);
                        const tmp = try std.fmt.allocPrint(alloc, "<sup class=\"footnote-ref\" id=\"fnref-{s}\"><a href=\"#fn-{s}\">{d}</a></sup>", .{ label_esc, label_esc, entry.number });
                        defer alloc.free(tmp);
                        try out.appendSlice(alloc, tmp);
                        i = close + 1;
                        continue;
                    }
                }
                // Unknown label or no footnote map: fall through to default
                // (renders the `[` as `&#91;` etc.)
            }
        }

        // Wiki-link: [[path]] (Obsidian/Roam-style cross-reference)
        // - [[/posts/SLUG]] or [[posts/SLUG]] resolves to /posts/SLUG.html
        //   as a real anchor (both conventions accepted; canon uses both
        //   ~50/50 across 270 instances as of 2026-05).
        // - everything else (codex notes, archives, concepts) renders as
        //   italic prose with a title hint, so codex-pointers read as
        //   readable text rather than literal [[bracket noise]] in HTML.
        if (c == '[' and i + 1 < src.len and src[i + 1] == '[') {
            if (std.mem.indexOfPos(u8, src, i + 2, "]]")) |close| {
                const slug = src[i + 2 .. close];
                const posts_prefix: ?usize = if (std.mem.startsWith(u8, slug, "/posts/"))
                    "/posts/".len
                else if (std.mem.startsWith(u8, slug, "posts/"))
                    "posts/".len
                else
                    null;
                if (posts_prefix) |prefix_len| {
                    const display = slug[prefix_len..];
                    const display_esc = try htmlEscape(alloc, display);
                    defer alloc.free(display_esc);
                    const tmp = try std.fmt.allocPrint(alloc, "<a href=\"/posts/{s}.html\" class=\"wiki-link\">{s}</a>", .{ display_esc, display_esc });
                    defer alloc.free(tmp);
                    try out.appendSlice(alloc, tmp);
                } else {
                    const slug_esc = try htmlEscape(alloc, slug);
                    defer alloc.free(slug_esc);
                    const humanized = try humanizeSlug(alloc, slug);
                    defer alloc.free(humanized);
                    const display_esc = try htmlEscape(alloc, humanized);
                    defer alloc.free(display_esc);
                    const tmp = try std.fmt.allocPrint(alloc, "<i class=\"wiki-codex\" title=\"codex: {s}\">{s}</i>", .{ slug_esc, display_esc });
                    defer alloc.free(tmp);
                    try out.appendSlice(alloc, tmp);
                }
                i = close + 2;
                continue;
            }
        }

        if (c == '[') {
            if (std.mem.indexOfScalarPos(u8, src, i + 1, ']')) |ct| {
                if (ct + 1 < src.len and src[ct + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, src, ct + 2, ')')) |cu| {
                        const text_html = try renderInline(alloc, src[i + 1 .. ct], footnotes);
                        defer alloc.free(text_html);
                        const url_esc = try htmlEscape(alloc, src[ct + 2 .. cu]);
                        defer alloc.free(url_esc);
                        try out.appendSlice(alloc, "<a href=\"");
                        try out.appendSlice(alloc, url_esc);
                        try out.appendSlice(alloc, "\">");
                        try out.appendSlice(alloc, text_html);
                        try out.appendSlice(alloc, "</a>");
                        i = cu + 1;
                        continue;
                    }
                }
            }
        }

        if (c == 'h' and (std.mem.startsWith(u8, src[i..], "http://") or std.mem.startsWith(u8, src[i..], "https://"))) {
            var j: usize = i;
            while (j < src.len and !isUrlTerminator(src[j])) : (j += 1) {}
            const url_esc = try htmlEscape(alloc, src[i..j]);
            defer alloc.free(url_esc);
            try out.appendSlice(alloc, "<a href=\"");
            try out.appendSlice(alloc, url_esc);
            try out.appendSlice(alloc, "\">");
            try out.appendSlice(alloc, url_esc);
            try out.appendSlice(alloc, "</a>");
            i = j;
            continue;
        }

        if (c == '-' and i + 1 < src.len and src[i + 1] == '-' and (i + 2 >= src.len or src[i + 2] != '-')) {
            try out.appendSlice(alloc, "&mdash;");
            i += 2;
            continue;
        }

        switch (c) {
            '&' => try out.appendSlice(alloc, "&amp;"),
            '<' => try out.appendSlice(alloc, "&lt;"),
            '>' => try out.appendSlice(alloc, "&gt;"),
            else => try out.append(alloc, c),
        }
        i += 1;
    }

    return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------- block

pub fn renderMarkdown(alloc: Allocator, io: std.Io, source: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    // ---------- PRE-PASS: extract footnote definitions ----------
    // Lines beginning with `[^LABEL]: text` are footnote definitions. They
    // are removed from the body source and collected in a list, numbered by
    // order of first definition. The footnote text is run through
    // renderInline immediately (with footnotes=null to avoid recursion);
    // the rendered HTML is stored alongside the label.
    var footnotes: std.ArrayList(Footnote) = .empty;
    defer {
        for (footnotes.items) |entry| {
            alloc.free(entry.label);
            alloc.free(entry.text_html);
        }
        footnotes.deinit(alloc);
    }

    var clean_src: std.ArrayList(u8) = .empty;
    defer clean_src.deinit(alloc);

    {
        var src_it = std.mem.splitScalar(u8, source, '\n');
        while (src_it.next()) |ln| {
            if (std.mem.startsWith(u8, ln, "[^")) {
                if (std.mem.indexOfScalarPos(u8, ln, 2, ']')) |close| {
                    if (close + 1 < ln.len and ln[close + 1] == ':') {
                        const label = ln[2..close];
                        const text = std.mem.trim(u8, ln[close + 2 ..], " \t");
                        const text_html = try renderInline(alloc, text, null);
                        const number = footnotes.items.len + 1;
                        try footnotes.append(alloc, .{
                            .label = try alloc.dupe(u8, label),
                            .number = number,
                            .text_html = text_html,
                        });
                        continue;
                    }
                }
            }
            try clean_src.appendSlice(alloc, ln);
            try clean_src.append(alloc, '\n');
        }
    }

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);
    {
        var it = std.mem.splitScalar(u8, clean_src.items, '\n');
        while (it.next()) |ln| try lines.append(alloc, ln);
    }
    const all = lines.items;

    var i: usize = 0;
    while (i < all.len) {
        const trimmed = std.mem.trim(u8, all[i], " \t\r");

        if (trimmed.len == 0) {
            i += 1;
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "```")) {
            const raw_lang = std.mem.trim(u8, trimmed[3..], " \t\r");
            // Markdown allows an empty info-string. The block-options
            // parser treats that as an error; here we fall back to a
            // BlockOptions with an empty language so the code renders
            // as a plain `<pre><code class="language-">`.
            var parsed: block_opts.BlockOptions = if (raw_lang.len == 0)
                .{ .language = try alloc.dupe(u8, "") }
            else
                try block_opts.parse(alloc, raw_lang);
            defer parsed.deinit(alloc);

            i += 1;
            var code_buf: std.ArrayList(u8) = .empty;
            defer code_buf.deinit(alloc);

            while (i < all.len) {
                const cl = all[i];
                const ct = std.mem.trim(u8, cl, " \t\r");
                if (std.mem.startsWith(u8, ct, "```")) {
                    i += 1;
                    break;
                }
                try code_buf.appendSlice(alloc, cl);
                try code_buf.append(alloc, '\n');
                i += 1;
            }

            // 1. Render the code block itself
            try out.appendSlice(alloc, "        <pre><code class=\"language-");
            const lang_esc = try htmlEscape(alloc, parsed.language);
            defer alloc.free(lang_esc);
            try out.appendSlice(alloc, lang_esc);
            try out.appendSlice(alloc, "\">");
            const code_esc = try htmlEscape(alloc, code_buf.items);
            defer alloc.free(code_esc);
            try out.appendSlice(alloc, code_esc);
            try out.appendSlice(alloc, "</code></pre>\n");

            // 2. If 'vega=true', embed as a chart container
            if (parsed.vega) {
                try out.appendSlice(alloc, "        <div class=\"vega-lite\" data-spec='");
                const vega_esc = try htmlEscape(alloc, code_buf.items);
                defer alloc.free(vega_esc);
                try out.appendSlice(alloc, vega_esc);
                try out.appendSlice(alloc, "'></div>\n");
            }

            // 3. If 'run=true', execute and embed the result
            if (parsed.run) {
                var exec = executor.Executor.init(alloc);
                const res = exec.execute(io, parsed.language, code_buf.items, parsed) catch |err| {
                    if (err == error.UnsupportedLanguage) continue;
                    return err;
                };
                defer alloc.free(res);

                if (res.len > 0) {
                    try out.appendSlice(alloc, "        <div class=\"notebook-result\">\n");
                    try out.appendSlice(alloc, "            <pre><code>");
                    const res_esc = try htmlEscape(alloc, res);
                    defer alloc.free(res_esc);
                    try out.appendSlice(alloc, res_esc);
                    try out.appendSlice(alloc, "</code></pre>\n");
                    try out.appendSlice(alloc, "        </div>\n");
                }
            }
            continue;
        }

        if (trimmed[0] == '#') {
            var level: usize = 0;
            while (level < trimmed.len and trimmed[level] == '#' and level < 6) : (level += 1) {}
            if (level > 0 and level < trimmed.len and trimmed[level] == ' ') {
                const rest = std.mem.trim(u8, trimmed[level + 1 ..], " \t");
                const inner = try renderInline(alloc, rest, &footnotes);
                defer alloc.free(inner);
                const tmp = try std.fmt.allocPrint(alloc, "        <h{d}>{s}</h{d}>\n", .{ level, inner, level });
                defer alloc.free(tmp);
                try out.appendSlice(alloc, tmp);
                i += 1;
                continue;
            }
        }

        if (std.mem.eql(u8, trimmed, "---") or std.mem.eql(u8, trimmed, "***")) {
            try out.appendSlice(alloc, "        <hr>\n");
            i += 1;
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "> ")) {
            try out.appendSlice(alloc, "        <blockquote>\n");
            while (i < all.len) {
                const ct = std.mem.trim(u8, all[i], " \t\r");
                if (!std.mem.startsWith(u8, ct, "> ")) break;
                const inner = try renderInline(alloc, ct[2..], &footnotes);
                defer alloc.free(inner);
                const tmp = try std.fmt.allocPrint(alloc, "            <p>{s}</p>\n", .{inner});
                defer alloc.free(tmp);
                try out.appendSlice(alloc, tmp);
                i += 1;
            }
            try out.appendSlice(alloc, "        </blockquote>\n");
            continue;
        }

        if (isBullet(trimmed)) {
            try out.appendSlice(alloc, "        <ul>\n");
            while (i < all.len) {
                const ct = std.mem.trim(u8, all[i], " \t\r");
                if (ct.len == 0) {
                    i += 1;
                    continue;
                }
                if (!isBullet(ct)) break;
                const item = std.mem.trim(u8, ct[2..], " \t");
                const inner = try renderInline(alloc, item, &footnotes);
                defer alloc.free(inner);
                const tmp = try std.fmt.allocPrint(alloc, "            <li>{s}</li>\n", .{inner});
                defer alloc.free(tmp);
                try out.appendSlice(alloc, tmp);
                i += 1;
            }
            try out.appendSlice(alloc, "        </ul>\n");
            continue;
        }

        if (isOrdered(trimmed)) {
            try out.appendSlice(alloc, "        <ol>\n");
            while (i < all.len) {
                const ct = std.mem.trim(u8, all[i], " \t\r");
                if (ct.len == 0) {
                    i += 1;
                    continue;
                }
                if (!isOrdered(ct)) break;
                const dot = std.mem.indexOfScalar(u8, ct, '.') orelse 0;
                const item = std.mem.trim(u8, ct[dot + 1 ..], " \t");
                const inner = try renderInline(alloc, item, &footnotes);
                defer alloc.free(inner);
                const tmp = try std.fmt.allocPrint(alloc, "            <li>{s}</li>\n", .{inner});
                defer alloc.free(tmp);
                try out.appendSlice(alloc, tmp);
                i += 1;
            }
            try out.appendSlice(alloc, "        </ol>\n");
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "![")) {
            if (std.mem.indexOfScalar(u8, trimmed, ']')) |ca| {
                if (ca + 1 < trimmed.len and trimmed[ca + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, trimmed, ca + 2, ')')) |cu| {
                        const alt_esc = try htmlEscape(alloc, trimmed[2..ca]);
                        defer alloc.free(alt_esc);
                        const url_esc = try htmlEscape(alloc, trimmed[ca + 2 .. cu]);
                        defer alloc.free(url_esc);
                        const tmp = try std.fmt.allocPrint(alloc, "        <p><img src=\"{s}\" alt=\"{s}\"></p>\n", .{ url_esc, alt_esc });
                        defer alloc.free(tmp);
                        try out.appendSlice(alloc, tmp);
                        i += 1;
                        continue;
                    }
                }
            }
        }

        var para: std.ArrayList(u8) = .empty;
        defer para.deinit(alloc);
        while (i < all.len) {
            const cl = all[i];
            const ct = std.mem.trim(u8, cl, " \t\r");
            if (ct.len == 0) break;
            if (isBlockStart(ct)) break;
            if (para.items.len > 0) try para.append(alloc, ' ');
            try para.appendSlice(alloc, ct);
            i += 1;
        }
        if (para.items.len > 0) {
            const inner = try renderInline(alloc, para.items, &footnotes);
            defer alloc.free(inner);
            const tmp = try std.fmt.allocPrint(alloc, "        <p>{s}</p>\n", .{inner});
            defer alloc.free(tmp);
            try out.appendSlice(alloc, tmp);
        }
    }

    // ---------- POST: footnotes section ----------
    if (footnotes.items.len > 0) {
        try out.appendSlice(alloc, "        <section class=\"footnotes\">\n            <ol>\n");
        for (footnotes.items) |entry| {
            const label_esc = try htmlEscape(alloc, entry.label);
            defer alloc.free(label_esc);
            const tmp = try std.fmt.allocPrint(alloc, "                <li id=\"fn-{s}\">{s} <a href=\"#fnref-{s}\" class=\"footnote-back\" aria-label=\"Back to text\">↩</a></li>\n", .{ label_esc, entry.text_html, label_esc });
            defer alloc.free(tmp);
            try out.appendSlice(alloc, tmp);
        }
        try out.appendSlice(alloc, "            </ol>\n        </section>\n");
    }

    return out.toOwnedSlice(alloc);
}

pub fn stripTags(alloc: Allocator, html: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var i: usize = 0;
    var in_tag = false;
    while (i < html.len) : (i += 1) {
        const c = html[i];
        if (c == '<') {
            in_tag = true;
            continue;
        }
        if (c == '>') {
            in_tag = false;
            try out.append(alloc, ' ');
            continue;
        }
        if (in_tag) continue;
        try out.append(alloc, c);
    }
    const raw = try out.toOwnedSlice(alloc);
    defer alloc.free(raw);
    var clean: std.ArrayList(u8) = .empty;
    defer clean.deinit(alloc);
    var j: usize = 0;
    while (j < raw.len) {
        if (raw[j] == '&') {
            const semi = std.mem.indexOfScalarPos(u8, raw, j, ';') orelse {
                try clean.append(alloc, raw[j]);
                j += 1;
                continue;
            };
            const entity = raw[j .. semi + 1];
            if (std.mem.eql(u8, entity, "&amp;")) {
                try clean.append(alloc, '&');
            } else if (std.mem.eql(u8, entity, "&lt;")) {
                try clean.append(alloc, '<');
            } else if (std.mem.eql(u8, entity, "&gt;")) {
                try clean.append(alloc, '>');
            } else if (std.mem.eql(u8, entity, "&quot;")) {
                try clean.append(alloc, '"');
            } else if (std.mem.eql(u8, entity, "&#39;")) {
                try clean.append(alloc, '\'');
            } else if (std.mem.eql(u8, entity, "&mdash;")) {
                try clean.appendSlice(alloc, "—");
            } else {
                try clean.appendSlice(alloc, entity);
            }
            j = semi + 1;
            continue;
        }
        try clean.append(alloc, raw[j]);
        j += 1;
    }
    var compact: std.ArrayList(u8) = .empty;
    defer compact.deinit(alloc);
    var prev_space = true;
    for (clean.items) |c| {
        const is_ws = c == ' ' or c == '\t' or c == '\n' or c == '\r';
        if (is_ws) {
            if (!prev_space) try compact.append(alloc, ' ');
            prev_space = true;
        } else {
            try compact.append(alloc, c);
            prev_space = false;
        }
    }
    const trimmed = std.mem.trim(u8, compact.items, " ");
    return alloc.dupe(u8, trimmed);
}

// ---------------------------------------------------------------- post-marker

// Map a known series prefix (trailing `-` included) to the display label
// used in the post-marker bumper. Returns null if the prefix is not known;
// callers fall back to a generic uppercase-with-hyphen derivation.
fn knownSeriesLabel(prefix: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, prefix, "doctrine-")) return "DOCTRINE";
    if (std.mem.eql(u8, prefix, "lineage-")) return "LINEAGE";
    if (std.mem.eql(u8, prefix, "anti-edison-")) return "ANTI-EDISON";
    if (std.mem.eql(u8, prefix, "sovereign-audit-")) return "SOVEREIGN AUDIT";
    return null;
}

// Derive the "DOCTRINE 01"-style bumper string for a slug. Returns an empty
// slice if the slug does not follow `<prefix>-NN-...`. Caller owns the
// returned bytes.
pub fn derivePostMarker(alloc: Allocator, slug: []const u8) ![]u8 {
    const prefix = seriesPrefix(slug) orelse return alloc.dupe(u8, "");
    const number = parseCanonNumberFromSlug(slug, prefix);
    if (number == 0) return alloc.dupe(u8, "");
    if (knownSeriesLabel(prefix)) |label| {
        return std.fmt.allocPrint(alloc, "{s} {d:0>2}", .{ label, number });
    }
    // Generic fallback: strip trailing `-`, uppercase, preserve hyphens.
    const stem = prefix[0 .. prefix.len - 1];
    var upper: std.ArrayList(u8) = .empty;
    defer upper.deinit(alloc);
    for (stem) |c| {
        if (c >= 'a' and c <= 'z') {
            try upper.append(alloc, c - 32);
        } else {
            try upper.append(alloc, c);
        }
    }
    return std.fmt.allocPrint(alloc, "{s} {d:0>2}", .{ upper.items, number });
}

// Map a series prefix to a human-readable lineage label used in the
// version-stamp footer. Doctrine / Anti-Edison / Sovereign Audit are "arcs";
// Lineage is the "canon". Unknown prefixes return empty.
fn lineageArcLabel(prefix: []const u8) []const u8 {
    if (std.mem.eql(u8, prefix, "doctrine-")) return "doctrine arc";
    if (std.mem.eql(u8, prefix, "anti-edison-")) return "anti-edison arc";
    if (std.mem.eql(u8, prefix, "lineage-")) return "lineage canon";
    if (std.mem.eql(u8, prefix, "sovereign-audit-")) return "sovereign audit arc";
    return "";
}

// Derive a "doctrine arc · 2026-Q2"-style lineage string from a slug and an
// ISO date. Returns empty if the slug isn't part of a known arc. Caller owns.
pub fn deriveLineage(alloc: Allocator, slug: []const u8, date: []const u8) ![]u8 {
    const prefix = seriesPrefix(slug) orelse return alloc.dupe(u8, "");
    const arc = lineageArcLabel(prefix);
    if (arc.len == 0) return alloc.dupe(u8, "");
    const quarter = quarterFromDate(date);
    if (quarter.len == 0) return alloc.dupe(u8, arc);
    // date is YYYY-MM-DD; take the first 4 chars as the year.
    if (date.len < 4) return alloc.dupe(u8, arc);
    return std.fmt.allocPrint(alloc, "{s} · {s}-{s}", .{ arc, date[0..4], quarter });
}

// Return "Q1".."Q4" for a YYYY-MM-DD date, or empty string on parse failure.
fn quarterFromDate(date: []const u8) []const u8 {
    if (date.len < 7) return "";
    if (date[4] != '-') return "";
    const m1 = date[5];
    const m2 = date[6];
    if (m1 < '0' or m1 > '9' or m2 < '0' or m2 > '9') return "";
    const month: u8 = (m1 - '0') * 10 + (m2 - '0');
    return switch (month) {
        1, 2, 3 => "Q1",
        4, 5, 6 => "Q2",
        7, 8, 9 => "Q3",
        10, 11, 12 => "Q4",
        else => "",
    };
}

// Render the version-stamp footer fragment. Always emits a `<footer
// class="version-stamp">…</footer>` with at minimum a `stamp-version` span
// (defaults to "v1.0") and a `stamp-audited` span (defaults to `fm.date`).
// `stamp-falsifier` is emitted only when `fm.falsifier` is non-empty.
// `stamp-lineage` is emitted only when `fm.lineage` is non-empty OR a default
// can be derived from the slug. Caller owns the returned bytes.
pub fn renderVersionStamp(alloc: Allocator, p: Post) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const version = if (p.fm.version.len > 0) p.fm.version else "v1.0";
    const audited = if (p.fm.audited.len > 0) p.fm.audited else p.fm.date;

    const version_esc = try htmlEscape(alloc, version);
    defer alloc.free(version_esc);
    const audited_esc = try htmlEscape(alloc, audited);
    defer alloc.free(audited_esc);

    try out.appendSlice(alloc, "\n        <footer class=\"version-stamp\">\n");
    const v_line = try std.fmt.allocPrint(alloc, "            <span class=\"stamp-version\">{s}</span>\n", .{version_esc});
    defer alloc.free(v_line);
    try out.appendSlice(alloc, v_line);
    const a_line = try std.fmt.allocPrint(alloc, "            <span class=\"stamp-audited\">audited {s}</span>\n", .{audited_esc});
    defer alloc.free(a_line);
    try out.appendSlice(alloc, a_line);

    if (p.fm.falsifier.len > 0) {
        const f_esc = try htmlEscape(alloc, p.fm.falsifier);
        defer alloc.free(f_esc);
        const f_line = try std.fmt.allocPrint(alloc, "            <span class=\"stamp-falsifier\">falsifier {s}</span>\n", .{f_esc});
        defer alloc.free(f_line);
        try out.appendSlice(alloc, f_line);
    }

    const lineage_src: []u8 = if (p.fm.lineage.len > 0)
        try alloc.dupe(u8, p.fm.lineage)
    else
        try deriveLineage(alloc, p.slug, p.fm.date);
    defer alloc.free(lineage_src);
    if (lineage_src.len > 0) {
        const l_esc = try htmlEscape(alloc, lineage_src);
        defer alloc.free(l_esc);
        const l_line = try std.fmt.allocPrint(alloc, "            <span class=\"stamp-lineage\">lineage: {s}</span>\n", .{l_esc});
        defer alloc.free(l_line);
        try out.appendSlice(alloc, l_line);
    }

    try out.appendSlice(alloc, "        </footer>\n");
    return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------- templates

pub fn wrapPost(alloc: Allocator, p: Post, site_url: []const u8) ![]u8 {
    const title_esc = try htmlEscape(alloc, p.fm.title);
    defer alloc.free(title_esc);
    const date_esc = try htmlEscape(alloc, p.fm.date);
    defer alloc.free(date_esc);
    const slug_esc = try htmlEscape(alloc, p.slug);
    defer alloc.free(slug_esc);

    // Series bumper: literal-quoted "DOCTRINE 01" rendered above the H1.
    // Empty for posts without a `<prefix>-NN-...` slug, in which case the
    // marker block is omitted entirely (the renderer collapses to "" so the
    // template's substitution still type-checks).
    const marker_raw = try derivePostMarker(alloc, p.slug);
    defer alloc.free(marker_raw);
    const marker_block: []u8 = if (marker_raw.len > 0) blk: {
        const marker_esc = try htmlEscape(alloc, marker_raw);
        defer alloc.free(marker_esc);
        break :blk try std.fmt.allocPrint(alloc, "        <div class=\"post-marker\">&quot;{s}&quot;</div>\n", .{marker_esc});
    } else try alloc.dupe(u8, "");
    defer alloc.free(marker_block);

    // Description: prefer frontmatter summary, fall back to a generic line.
    const desc_src = if (p.fm.summary.len > 0) p.fm.summary else "An essay in the canon of Quantitative Mercantilism.";
    const desc_esc = try htmlEscape(alloc, desc_src);
    defer alloc.free(desc_esc);

    // Per-post og:image path. Generated by scripts/gen-og-images.py for
    // non-draft posts; drafts get the site-default OG image (their per-post
    // PNG doesn't exist).
    const og_path = if (p.fm.draft)
        try alloc.dupe(u8, "og/default.png")
    else
        try std.fmt.allocPrint(alloc, "og/{s}.png", .{p.slug});
    defer alloc.free(og_path);

    const site_url_esc = try htmlEscape(alloc, site_url);
    defer alloc.free(site_url_esc);

    // Read-time: word count on plain-text body, 250 words/min reading speed.
    // Round up so a 2-word post isn't "0 min read"; cap displayed at 1 min minimum.
    const word_count = countWords(p.body_text);
    const read_min = @max(@as(usize, 1), (word_count + 249) / 250);
    const meta_line = try std.fmt.allocPrint(alloc, "{s} · {d} min read · {d} words", .{ date_esc, read_min, word_count });
    defer alloc.free(meta_line);

    return std.fmt.allocPrint(alloc,
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\    <meta charset="UTF-8">
        \\    <meta name="viewport" content="width=device-width, initial-scale=1">
        \\    <title>{s} — Stax</title>
        \\    <meta name="description" content="{s}">
        \\    <link rel="canonical" href="{s}/posts/{s}.html">
        \\    <link rel="icon" type="image/svg+xml" href="../favicon.svg">
        \\    <link rel="icon" type="image/png" sizes="32x32" href="../favicon-32.png">
        \\    <link rel="icon" type="image/png" sizes="192x192" href="../favicon-192.png">
        \\    <link rel="apple-touch-icon" href="../favicon-192.png">
        \\    <link rel="manifest" href="../site.webmanifest">
        \\    <meta name="theme-color" content="#121212">
        \\    <link rel="stylesheet" href="../css/stax.css">
        \\    <link rel="alternate" type="application/rss+xml" href="../feed.xml" title="Stax RSS">
        \\    <link rel="alternate" type="application/atom+xml" href="../atom.xml" title="Stax Atom">
        \\    <link rel="alternate" type="application/feed+json" href="../feed.json" title="Stax JSON Feed">
        \\    <meta property="og:type" content="article">
        \\    <meta property="og:title" content="{s}">
        \\    <meta property="og:description" content="{s}">
        \\    <meta property="og:url" content="{s}/posts/{s}.html">
        \\    <meta property="og:site_name" content="Stax — The Journal of Quantitative Mercantilism">
        \\    <meta property="og:image" content="{s}/{s}">
        \\    <meta property="og:image:type" content="image/png">
        \\    <meta property="og:image:width" content="1200">
        \\    <meta property="og:image:height" content="630">
        \\    <meta property="article:published_time" content="{s}">
        \\    <meta property="article:author" content="https://x.com/Staxxxx17">
        \\    <meta name="twitter:card" content="summary_large_image">
        \\    <meta name="twitter:title" content="{s}">
        \\    <meta name="twitter:description" content="{s}">
        \\    <meta name="twitter:image" content="{s}/{s}">
        \\    <meta name="twitter:site" content="@Staxxxx17">
        \\    <meta name="twitter:creator" content="@Staxxxx17">
        \\    <script type="application/ld+json">{{
        \\      "@context": "https://schema.org",
        \\      "@type": "BlogPosting",
        \\      "headline": "{s}",
        \\      "description": "{s}",
        \\      "datePublished": "{s}",
        \\      "url": "{s}/posts/{s}.html",
        \\      "image": "{s}/{s}",
        \\      "author": {{
        \\        "@type": "Person",
        \\        "name": "Stax",
        \\        "alternateName": "SMC17",
        \\        "url": "{s}/about.html",
        \\        "jobTitle": "Independent operator and research engineer",
        \\        "sameAs": ["https://x.com/Staxxxx17", "https://github.com/SMC17"],
        \\        "knowsAbout": ["Quantitative Mercantilism", "Sovereign Computing", "Multi-Agent Systems", "Zig Programming Language", "Merchant Systems", "Bottleneck Analysis", "Cross-Agent Verification", "Hardware-Native Inference"]
        \\      }},
        \\      "publisher": {{
        \\        "@type": "Organization",
        \\        "name": "Stax — The Journal of Quantitative Mercantilism",
        \\        "url": "{s}/",
        \\        "logo": {{ "@type": "ImageObject", "url": "{s}/favicon.svg" }}
        \\      }},
        \\      "mainEntityOfPage": {{ "@type": "WebPage", "@id": "{s}/posts/{s}.html" }}
        \\    }}</script>
        \\</head>
        \\<body>
        \\    <header class="site-header">
        \\        <div class="brand">
        \\            <span class="brand-mark">STAX</span>
        \\            <span class="brand-tag">Quantitative Mercantilism</span>
        \\        </div>
        \\        <nav>
        \\            <a href="../index.html">Journal</a>
        \\            <a href="../lab/">Lab</a>
        \\            <a href="../substrate/">Substrate</a>
        \\            <a href="../objects/">Objects</a>
        \\            <a href="../workshop/">Workshop</a>
        \\            <a href="../canon/">Canon</a>
        \\            <a href="../essays.html">Archive</a>
        \\            <a href="../search.html">Search</a>
        \\        </nav>
        \\    </header>
        \\    <main>
        \\{s}        <h1>{s}</h1>
        \\        <p class="meta">{s}</p>
        \\{s}    </main>
        \\    <footer class="site-footer">
        \\        STAX // <a href="https://x.com/Staxxxx17">@Staxxxx17</a> &middot; <a href="../feed.xml">RSS</a> &middot; <a href="../essays.html">All essays</a>
        \\    </footer>
        \\</body>
        \\</html>
        \\
    , .{
        // head
        title_esc,    desc_esc,     site_url_esc, slug_esc,
        title_esc,    desc_esc,     site_url_esc, slug_esc,
        site_url_esc, og_path,      date_esc,     title_esc,
        desc_esc,     site_url_esc, og_path,
        // JSON-LD
             title_esc,
        desc_esc,     date_esc,     site_url_esc, slug_esc,
        site_url_esc, og_path,      site_url_esc, site_url_esc,
        site_url_esc, site_url_esc, slug_esc,
        // body
            marker_block,
        title_esc,    meta_line,    p.body_html,
    });
}

// Render a single <li> fragment for the essay-list. Title/date always; first
// tag appended to meta as a category badge; summary as a one-line dek when
// present.
fn emitEssayListItem(alloc: Allocator, p: Post) ![]u8 {
    const t = try htmlEscape(alloc, p.fm.title);
    defer alloc.free(t);
    const d = try htmlEscape(alloc, p.fm.date);
    defer alloc.free(d);
    const cat: []const u8 = if (p.fm.tags.len > 0) p.fm.tags[0] else "";
    const wc = countWords(p.body_text);
    const rt = @max(@as(usize, 1), (wc + 249) / 250);
    const meta = if (cat.len > 0) blk: {
        const cat_esc = try htmlEscape(alloc, cat);
        defer alloc.free(cat_esc);
        break :blk try std.fmt.allocPrint(alloc, "{s} · {s} · {d} min", .{ d, cat_esc, rt });
    } else try std.fmt.allocPrint(alloc, "{s} · {d} min", .{ d, rt });
    defer alloc.free(meta);

    if (p.fm.summary.len > 0) {
        const s = try htmlEscape(alloc, p.fm.summary);
        defer alloc.free(s);
        return std.fmt.allocPrint(alloc,
            \\    <li>
            \\        <a href="posts/{s}.html">
            \\            <span class="essay-meta">{s}</span><span class="essay-sep"> — </span><span class="essay-title">{s}</span>
            \\            <span class="essay-summary">{s}</span>
            \\        </a>
            \\    </li>
            \\
        , .{ p.slug, meta, t, s });
    } else {
        return std.fmt.allocPrint(alloc,
            \\    <li>
            \\        <a href="posts/{s}.html">
            \\            <span class="essay-meta">{s}</span><span class="essay-sep"> — </span><span class="essay-title">{s}</span>
            \\        </a>
            \\    </li>
            \\
        , .{ p.slug, meta, t });
    }
}

// Render an essay-list fragment of up to `max` posts (date-desc as sorted).
pub fn renderEssayListFragment(alloc: Allocator, posts: []const Post, max: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "<ul class=\"essay-list\">\n");
    const n = @min(max, posts.len);
    for (posts[0..n]) |p| {
        const item = try emitEssayListItem(alloc, p);
        defer alloc.free(item);
        try out.appendSlice(alloc, item);
    }
    try out.appendSlice(alloc, "</ul>\n");
    return out.toOwnedSlice(alloc);
}

// Render a per-arc index page. Filters posts by slug prefix (e.g. "doctrine-"),
// sorts by slug ascending so the NN numbering reads top-down, and emits a
// standalone HTML page with the arc's essays.
pub fn renderArcIndex(alloc: Allocator, all_posts: []const Post, slug_prefix: []const u8, arc_title: []const u8, arc_blurb: []const u8, site_url: []const u8) ![]u8 {
    var arc_posts: std.ArrayList(Post) = .empty;
    defer arc_posts.deinit(alloc);
    for (all_posts) |p| {
        if (p.fm.draft) continue;
        if (!std.mem.startsWith(u8, p.slug, slug_prefix)) continue;
        try arc_posts.append(alloc, p);
    }
    const Less = struct {
        fn lt(_: void, a: Post, b: Post) bool {
            return std.mem.lessThan(u8, a.slug, b.slug);
        }
    };
    std.mem.sort(Post, arc_posts.items, {}, Less.lt);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    const su = try htmlEscape(alloc, site_url);
    defer alloc.free(su);
    const title_esc = try htmlEscape(alloc, arc_title);
    defer alloc.free(title_esc);
    const blurb_esc = try htmlEscape(alloc, arc_blurb);
    defer alloc.free(blurb_esc);
    const file_slug = slug_prefix[0 .. slug_prefix.len - 1]; // "doctrine-" → "doctrine"
    const file_slug_esc = try htmlEscape(alloc, file_slug);
    defer alloc.free(file_slug_esc);

    const head = try std.fmt.allocPrint(alloc,
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\    <meta charset="UTF-8">
        \\    <meta name="viewport" content="width=device-width, initial-scale=1">
        \\    <title>{s} — Stax</title>
        \\    <meta name="description" content="{s}">
        \\    <link rel="canonical" href="{s}/arc/{s}.html">
        \\    <link rel="icon" type="image/svg+xml" href="../favicon.svg">
        \\    <link rel="icon" type="image/png" sizes="32x32" href="../favicon-32.png">
        \\    <link rel="icon" type="image/png" sizes="192x192" href="../favicon-192.png">
        \\    <link rel="apple-touch-icon" href="../favicon-192.png">
        \\    <link rel="manifest" href="../site.webmanifest">
        \\    <meta name="theme-color" content="#121212">
        \\    <link rel="stylesheet" href="../css/stax.css">
        \\    <link rel="alternate" type="application/rss+xml" href="../feed.xml" title="Stax RSS">
        \\    <link rel="alternate" type="application/atom+xml" href="../atom.xml" title="Stax Atom">
        \\    <link rel="alternate" type="application/feed+json" href="../feed.json" title="Stax JSON Feed">
        \\    <meta property="og:type" content="website">
        \\    <meta property="og:title" content="{s} — Stax">
        \\    <meta property="og:description" content="{s}">
        \\    <meta property="og:url" content="{s}/arc/{s}.html">
        \\    <meta property="og:site_name" content="Stax — The Journal of Quantitative Mercantilism">
        \\    <meta property="og:image" content="{s}/og/default.png">
        \\    <meta property="og:image:type" content="image/png">
        \\    <meta property="og:image:width" content="1200">
        \\    <meta property="og:image:height" content="630">
        \\    <meta name="twitter:card" content="summary_large_image">
        \\    <meta name="twitter:title" content="{s} — Stax">
        \\    <meta name="twitter:description" content="{s}">
        \\    <meta name="twitter:image" content="{s}/og/default.png">
        \\    <meta name="twitter:site" content="@Staxxxx17">
        \\</head>
        \\<body>
        \\    <header class="site-header">
        \\        <div class="brand">
        \\            <span class="brand-mark">STAX</span>
        \\            <span class="brand-tag">Quantitative Mercantilism</span>
        \\        </div>
        \\        <nav>
        \\            <a href="../index.html">Journal</a>
        \\            <a href="../lab/">Lab</a>
        \\            <a href="../substrate/">Substrate</a>
        \\            <a href="../objects/">Objects</a>
        \\            <a href="../workshop/">Workshop</a>
        \\            <a href="../canon/">Canon</a>
        \\            <a href="../essays.html">Archive</a>
        \\            <a href="../about.html">About</a>
        \\        </nav>
        \\    </header>
        \\    <main>
        \\        <h1>{s}</h1>
        \\        <p class="lede">{s}</p>
        \\        <ul class="essay-list">
        \\
    , .{ title_esc, blurb_esc, su, file_slug_esc, title_esc, blurb_esc, su, file_slug_esc, su, title_esc, blurb_esc, su, title_esc, blurb_esc });
    defer alloc.free(head);
    try out.appendSlice(alloc, head);

    for (arc_posts.items) |p| {
        const t = try htmlEscape(alloc, p.fm.title);
        defer alloc.free(t);
        const d = try htmlEscape(alloc, p.fm.date);
        defer alloc.free(d);
        const wc = countWords(p.body_text);
        const rt = @max(@as(usize, 1), (wc + 249) / 250);
        const summary_esc = if (p.fm.summary.len > 0) try htmlEscape(alloc, p.fm.summary) else try alloc.dupe(u8, "");
        defer alloc.free(summary_esc);
        const item = try std.fmt.allocPrint(alloc,
            \\            <li>
            \\                <a href="../posts/{s}.html">
            \\                    <span class="essay-meta">{s} · {d} min · {d} words</span>
            \\                    <span class="essay-title">{s}</span>
            \\                    <span class="essay-summary">{s}</span>
            \\                </a>
            \\            </li>
            \\
        , .{ p.slug, d, rt, wc, t, summary_esc });
        defer alloc.free(item);
        try out.appendSlice(alloc, item);
    }

    try out.appendSlice(alloc,
        \\        </ul>
        \\        <p style="text-align: right; margin-top: 3rem;"><a href="../essays.html">All essays →</a></p>
        \\    </main>
        \\    <footer class="site-footer">
        \\        STAX // <a href="https://x.com/Staxxxx17">@Staxxxx17</a> &middot; <a href="../feed.xml">RSS</a> &middot; <a href="../essays.html">All essays</a>
        \\    </footer>
        \\</body>
        \\</html>
        \\
    );
    return out.toOwnedSlice(alloc);
}

// Render an essay-list of all posts marked `featured: true` (date-desc as sorted).
pub fn renderFeaturedFragment(alloc: Allocator, posts: []const Post) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "<ul class=\"essay-list\">\n");
    for (posts) |p| {
        if (!p.fm.featured) continue;
        const item = try emitEssayListItem(alloc, p);
        defer alloc.free(item);
        try out.appendSlice(alloc, item);
    }
    try out.appendSlice(alloc, "</ul>\n");
    return out.toOwnedSlice(alloc);
}

// Substitute placeholders in a hand-curated template:
//   {{recent}}        → essay-list of top 6 posts
//   {{recent N}}      → essay-list of top N posts
//   {{site_url}}      → BLOG_SITE_URL value
// Pass-through anything else.
pub fn renderTemplate(alloc: Allocator, template: []const u8, posts: []const Post, site_url: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{' and i + 1 < template.len and template[i + 1] == '{') {
            if (std.mem.indexOfPos(u8, template, i + 2, "}}")) |close| {
                const inner = std.mem.trim(u8, template[i + 2 .. close], " \t");
                if (std.mem.startsWith(u8, inner, "recent")) {
                    const rest = std.mem.trim(u8, inner["recent".len..], " \t");
                    const n: usize = if (rest.len == 0) 6 else (std.fmt.parseInt(usize, rest, 10) catch 6);
                    const frag = try renderEssayListFragment(alloc, posts, n);
                    defer alloc.free(frag);
                    try out.appendSlice(alloc, frag);
                    i = close + 2;
                    continue;
                }
                if (std.mem.eql(u8, inner, "featured")) {
                    const frag = try renderFeaturedFragment(alloc, posts);
                    defer alloc.free(frag);
                    try out.appendSlice(alloc, frag);
                    i = close + 2;
                    continue;
                }
                if (std.mem.eql(u8, inner, "site_url")) {
                    try out.appendSlice(alloc, site_url);
                    i = close + 2;
                    continue;
                }
                // unknown placeholder — leave verbatim
            }
        }
        try out.append(alloc, template[i]);
        i += 1;
    }

    return out.toOwnedSlice(alloc);
}

pub fn renderEssaysIndex(alloc: Allocator, posts: []const Post, site_url: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    const su = try htmlEscape(alloc, site_url);
    defer alloc.free(su);
    const head = try std.fmt.allocPrint(alloc,
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\    <meta charset="UTF-8">
        \\    <meta name="viewport" content="width=device-width, initial-scale=1">
        \\    <title>Essays — Stax</title>
        \\    <meta name="description" content="The full canon of Quantitative Mercantilism essays — Mercantile Thesis, Doctrine arc, Lineage canon, and field reports from the substrate.">
        \\    <link rel="canonical" href="{s}/essays.html">
        \\    <link rel="icon" type="image/svg+xml" href="favicon.svg">
        \\    <link rel="icon" type="image/png" sizes="32x32" href="favicon-32.png">
        \\    <link rel="icon" type="image/png" sizes="192x192" href="favicon-192.png">
        \\    <link rel="apple-touch-icon" href="favicon-192.png">
        \\    <link rel="manifest" href="site.webmanifest">
        \\    <meta name="theme-color" content="#121212">
        \\    <link rel="stylesheet" href="css/stax.css">
        \\    <link rel="alternate" type="application/rss+xml" href="feed.xml" title="Stax RSS">
        \\    <link rel="alternate" type="application/atom+xml" href="atom.xml" title="Stax Atom">
        \\    <link rel="alternate" type="application/feed+json" href="feed.json" title="Stax JSON Feed">
        \\    <meta property="og:type" content="website">
        \\    <meta property="og:title" content="Essays — Stax">
        \\    <meta property="og:description" content="The full canon of Quantitative Mercantilism essays.">
        \\    <meta property="og:url" content="{s}/essays.html">
        \\    <meta property="og:site_name" content="Stax — The Journal of Quantitative Mercantilism">
        \\    <meta property="og:image" content="{s}/og/default.png">
        \\    <meta property="og:image:type" content="image/png">
        \\    <meta property="og:image:width" content="1200">
        \\    <meta property="og:image:height" content="630">
        \\    <meta name="twitter:card" content="summary_large_image">
        \\    <meta name="twitter:title" content="Essays — Stax">
        \\    <meta name="twitter:description" content="The full canon of Quantitative Mercantilism essays.">
        \\    <meta name="twitter:image" content="{s}/og/default.png">
        \\    <meta name="twitter:site" content="@Staxxxx17">
        \\</head>
        \\
    , .{ su, su, su, su });
    defer alloc.free(head);
    try out.appendSlice(alloc, head);
    try out.appendSlice(alloc,
        \\<body>
        \\    <header class="site-header">
        \\        <div class="brand">
        \\            <span class="brand-mark">STAX</span>
        \\            <span class="brand-tag">Quantitative Mercantilism</span>
        \\        </div>
        \\        <nav>
        \\            <a href="index.html">Journal</a>
        \\            <a href="lab/">Lab</a>
        \\            <a href="substrate/">Substrate</a>
        \\            <a href="objects/">Objects</a>
        \\            <a href="workshop/">Workshop</a>
        \\            <a href="canon/">Canon</a>
        \\            <a href="about.html">About</a>
        \\            <a href="search.html">Search</a>
        \\        </nav>
        \\    </header>
        \\    <main>
        \\        <section class="arcs">
        \\            <h2>By arc</h2>
        \\            <ul class="arc-list">
        \\                <li><a href="arc/doctrine.html">The Doctrine Arc</a> — the operating playbook</li>
        \\                <li><a href="arc/lineage.html">The Lineage Canon</a> — merchant biographies</li>
        \\                <li><a href="arc/anti-edison.html">The Anti-Edison Arc</a> — War of Currents</li>
        \\                <li><a href="arc/sovereign-audit.html">The Sovereign Audit</a> — engineering field reports</li>
        \\            </ul>
        \\        </section>
        \\        <section class="all-essays">
        \\            <h2>All essays</h2>
        \\        <ul class="essay-list">
        \\
    );
    for (posts) |p| {
        const t = try htmlEscape(alloc, p.fm.title);
        defer alloc.free(t);
        const d = try htmlEscape(alloc, p.fm.date);
        defer alloc.free(d);
        const wc = countWords(p.body_text);
        const rt = @max(@as(usize, 1), (wc + 249) / 250);
        const meta = try std.fmt.allocPrint(alloc, "{s} · {d} min · {d} words", .{ d, rt, wc });
        defer alloc.free(meta);
        const tmp = try std.fmt.allocPrint(alloc,
            \\            <li>
            \\                <a href="posts/{s}.html">
            \\                    <span class="essay-meta">{s}</span><span class="essay-sep"> — </span><span class="essay-title">{s}</span>
            \\                </a>
            \\            </li>
            \\
        , .{ p.slug, meta, t });
        defer alloc.free(tmp);
        try out.appendSlice(alloc, tmp);
    }
    try out.appendSlice(alloc,
        \\        </ul>
        \\        </section>
        \\    </main>
        \\    <footer class="site-footer">
        \\        STAX // <a href="https://x.com/Staxxxx17">@Staxxxx17</a> &middot; <a href="feed.xml">RSS</a> &middot; <a href="/sitemap.xml">Sitemap</a>
        \\    </footer>
        \\</body>
        \\</html>
        \\
    );
    return out.toOwnedSlice(alloc);
}

fn rssDate(alloc: Allocator, date: []const u8) ![]u8 {
    if (date.len < 10) return alloc.dupe(u8, "Mon, 01 Jan 2026 00:00:00 GMT");
    const y = date[0..4];
    const m = date[5..7];
    const d = date[8..10];
    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const mi = std.fmt.parseInt(usize, m, 10) catch 1;
    const idx: usize = if (mi >= 1 and mi <= 12) mi - 1 else 0;
    return std.fmt.allocPrint(alloc, "{s}, {s} {s} {s} 00:00:00 GMT", .{ "Mon", d, month_names[idx], y });
}

pub fn renderRss(alloc: Allocator, posts: []const Post, site_url: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const su = std.mem.trimEnd(u8, site_url, "/");

    const head = try std.fmt.allocPrint(alloc,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom" xmlns:content="http://purl.org/rss/1.0/modules/content/">
        \\<channel>
        \\<title>Stax — The Journal of Quantitative Mercantilism</title>
        \\<link>{s}/</link>
        \\<atom:link href="{s}/feed.xml" rel="self" type="application/rss+xml"/>
        \\<description>Operator notes from the substrate. Quantitative Mercantilism — directing intelligence and capital flows through the bottlenecks the rest of the economy must route through.</description>
        \\<language>en</language>
        \\<image>
        \\<url>{s}/favicon-512.png</url>
        \\<title>Stax — The Journal of Quantitative Mercantilism</title>
        \\<link>{s}/</link>
        \\<width>144</width>
        \\<height>144</height>
        \\</image>
        \\
    , .{ su, su, su, su });
    defer alloc.free(head);
    try out.appendSlice(alloc, head);

    for (posts) |p| {
        const t = try xmlEscape(alloc, p.fm.title);
        defer alloc.free(t);
        const link = try std.fmt.allocPrint(alloc, "{s}/posts/{s}.html", .{ su, p.slug });
        defer alloc.free(link);
        const link_esc = try xmlEscape(alloc, link);
        defer alloc.free(link_esc);
        const desc_src = if (p.fm.summary.len > 0) p.fm.summary else p.body_text;
        const desc_esc = try xmlEscape(alloc, desc_src);
        defer alloc.free(desc_esc);
        const body_esc = try xmlEscape(alloc, p.body_html);
        defer alloc.free(body_esc);
        const pub_date = try rssDate(alloc, p.fm.date);
        defer alloc.free(pub_date);

        const item = try std.fmt.allocPrint(alloc,
            \\<item>
            \\<title>{s}</title>
            \\<link>{s}</link>
            \\<guid isPermaLink="true">{s}</guid>
            \\<pubDate>{s}</pubDate>
            \\<description>{s}</description>
            \\<content:encoded>{s}</content:encoded>
            \\</item>
            \\
        , .{ t, link_esc, link_esc, pub_date, desc_esc, body_esc });
        defer alloc.free(item);
        try out.appendSlice(alloc, item);
    }

    try out.appendSlice(alloc, "</channel>\n</rss>\n");
    return out.toOwnedSlice(alloc);
}

// Atom 1.0 feed. Same content as RSS, different schema.
pub fn renderAtom(alloc: Allocator, posts: []const Post, site_url: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    const su = std.mem.trimEnd(u8, site_url, "/");

    const latest_date = if (posts.len > 0) posts[0].fm.date else "2026-01-01";
    const updated = try std.fmt.allocPrint(alloc, "{s}T00:00:00Z", .{latest_date});
    defer alloc.free(updated);

    const head = try std.fmt.allocPrint(alloc,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<feed xmlns="http://www.w3.org/2005/Atom">
        \\<title>Stax — The Journal of Quantitative Mercantilism</title>
        \\<subtitle>Operator notes from the substrate.</subtitle>
        \\<link href="{s}/atom.xml" rel="self" type="application/atom+xml"/>
        \\<link href="{s}/" rel="alternate" type="text/html"/>
        \\<id>{s}/</id>
        \\<updated>{s}</updated>
        \\<icon>{s}/favicon-192.png</icon>
        \\<logo>{s}/og/default.png</logo>
        \\<rights>© Stax. AGPL-3.0 for code; CC-BY-SA 4.0 for prose.</rights>
        \\<author><name>Stax</name><uri>{s}/about.html</uri></author>
        \\
    , .{ su, su, su, updated, su, su, su });
    defer alloc.free(head);
    try out.appendSlice(alloc, head);

    for (posts) |p| {
        const t = try xmlEscape(alloc, p.fm.title);
        defer alloc.free(t);
        const link = try std.fmt.allocPrint(alloc, "{s}/posts/{s}.html", .{ su, p.slug });
        defer alloc.free(link);
        const link_esc = try xmlEscape(alloc, link);
        defer alloc.free(link_esc);
        const desc_src = if (p.fm.summary.len > 0) p.fm.summary else p.body_text;
        const desc_esc = try xmlEscape(alloc, desc_src);
        defer alloc.free(desc_esc);
        const body_esc = try xmlEscape(alloc, p.body_html);
        defer alloc.free(body_esc);
        const entry_updated = try std.fmt.allocPrint(alloc, "{s}T00:00:00Z", .{p.fm.date});
        defer alloc.free(entry_updated);

        const entry = try std.fmt.allocPrint(alloc,
            \\<entry>
            \\<title>{s}</title>
            \\<link href="{s}" rel="alternate" type="text/html"/>
            \\<id>{s}</id>
            \\<updated>{s}</updated>
            \\<published>{s}</published>
            \\<summary>{s}</summary>
            \\<content type="html">{s}</content>
            \\</entry>
            \\
        , .{ t, link_esc, link_esc, entry_updated, entry_updated, desc_esc, body_esc });
        defer alloc.free(entry);
        try out.appendSlice(alloc, entry);
    }

    try out.appendSlice(alloc, "</feed>\n");
    return out.toOwnedSlice(alloc);
}

// JSON Feed 1.1 (https://www.jsonfeed.org/version/1.1/).
pub fn renderJsonFeed(alloc: Allocator, posts: []const Post, site_url: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    const su = std.mem.trimEnd(u8, site_url, "/");

    const head = try std.fmt.allocPrint(alloc,
        \\{{
        \\  "version": "https://jsonfeed.org/version/1.1",
        \\  "title": "Stax — The Journal of Quantitative Mercantilism",
        \\  "description": "Operator notes from the substrate.",
        \\  "home_page_url": "{s}/",
        \\  "feed_url": "{s}/feed.json",
        \\  "language": "en",
        \\  "icon": "{s}/favicon.svg",
        \\  "favicon": "{s}/favicon.svg",
        \\  "authors": [{{ "name": "Stax", "url": "{s}/about.html" }}],
        \\  "items": [
    , .{ su, su, su, su, su });
    defer alloc.free(head);
    try out.appendSlice(alloc, head);

    for (posts, 0..) |p, idx| {
        const link = try std.fmt.allocPrint(alloc, "{s}/posts/{s}.html", .{ su, p.slug });
        defer alloc.free(link);
        // JSON-escape title + summary + body
        const t = try jsonEscape(alloc, p.fm.title);
        defer alloc.free(t);
        const summary_src = if (p.fm.summary.len > 0) p.fm.summary else "";
        const summary_esc = try jsonEscape(alloc, summary_src);
        defer alloc.free(summary_esc);
        const body_esc = try jsonEscape(alloc, p.body_html);
        defer alloc.free(body_esc);

        const item = try std.fmt.allocPrint(alloc,
            \\
            \\    {{
            \\      "id": "{s}",
            \\      "url": "{s}",
            \\      "title": "{s}",
            \\      "summary": "{s}",
            \\      "date_published": "{s}T00:00:00Z",
            \\      "content_html": "{s}"
            \\    }}{s}
        , .{ link, link, t, summary_esc, p.fm.date, body_esc, if (idx + 1 < posts.len) "," else "" });
        defer alloc.free(item);
        try out.appendSlice(alloc, item);
    }

    try out.appendSlice(alloc, "\n  ]\n}\n");
    return out.toOwnedSlice(alloc);
}

// JSON string escape: quotes, backslash, control chars.
pub fn jsonEscape(alloc: Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (src) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            0x08 => try out.appendSlice(alloc, "\\b"),
            0x0C => try out.appendSlice(alloc, "\\f"),
            else => {
                if (c < 0x20) {
                    const buf = try std.fmt.allocPrint(alloc, "\\u{x:0>4}", .{c});
                    defer alloc.free(buf);
                    try out.appendSlice(alloc, buf);
                } else {
                    try out.append(alloc, c);
                }
            },
        }
    }
    return out.toOwnedSlice(alloc);
}

pub fn renderSitemap(alloc: Allocator, posts: []const Post, site_url: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    const su = std.mem.trimEnd(u8, site_url, "/");

    try out.appendSlice(alloc,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        \\
    );

    const home = try std.fmt.allocPrint(alloc, "<url><loc>{s}/</loc></url>\n", .{su});
    defer alloc.free(home);
    try out.appendSlice(alloc, home);

    const essays = try std.fmt.allocPrint(alloc, "<url><loc>{s}/essays.html</loc></url>\n", .{su});
    defer alloc.free(essays);
    try out.appendSlice(alloc, essays);

    const about = try std.fmt.allocPrint(alloc, "<url><loc>{s}/about.html</loc></url>\n", .{su});
    defer alloc.free(about);
    try out.appendSlice(alloc, about);

    for (posts) |p| {
        const u = try std.fmt.allocPrint(alloc, "<url><loc>{s}/posts/{s}.html</loc><lastmod>{s}</lastmod></url>\n", .{ su, p.slug, p.fm.date });
        defer alloc.free(u);
        try out.appendSlice(alloc, u);
    }

    try out.appendSlice(alloc, "</urlset>\n");
    return out.toOwnedSlice(alloc);
}

fn truncateAt(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var cut = max;
    while (cut > 0 and (s[cut] & 0xC0) == 0x80) cut -= 1;
    var sp = cut;
    while (sp > 0 and s[sp - 1] != ' ') sp -= 1;
    if (sp > max / 2) cut = sp - 1;
    return std.mem.trimEnd(u8, s[0..cut], " ");
}

pub fn renderCrosspost(alloc: Allocator, post: Post, site_url: []const u8) ![]u8 {
    const su = std.mem.trimEnd(u8, site_url, "/");
    const link = try std.fmt.allocPrint(alloc, "{s}/posts/{s}.html", .{ su, post.slug });
    defer alloc.free(link);

    const summary = if (post.fm.summary.len > 0) post.fm.summary else post.body_text;

    const x_budget: usize = if (link.len + 1 < 270) 270 - link.len - 1 else 1;
    const x_body = truncateAt(summary, x_budget);
    const long_body = truncateAt(summary, 700);
    const elevator_src = if (post.fm.summary.len > 0) post.fm.summary else truncateAt(post.body_text, 240);

    return std.fmt.allocPrint(alloc,
        \\## X (~280)
        \\{s}: {s}
        \\
        \\{s}
        \\
        \\## LinkedIn / Substack (~700)
        \\{s}
        \\
        \\{s}
        \\
        \\Read: {s}
        \\
        \\## Elevator
        \\{s}
        \\
    , .{ post.fm.title, x_body, link, post.fm.title, long_body, link, elevator_src });
}

// ---------------------------------------------------------------- sections
//
// The four portfolio surfaces beyond /posts/. Each section reads markdown
// frontmatter via the same Frontmatter struct (with section-specific
// optional fields populated) and renders an index + per-entry HTML under
// public/<section>/.
//
// Path convention: every section page lives one directory deep
// (public/<section>/index.html, public/<section>/<slug>.html), parallel to
// public/posts/<slug>.html. So all assets, CSS, and feed links use "../".

// Common page head + header + footer skeleton, parameterized by section
// directory and active-nav highlighting. Pulled out so all four section
// renderers (and the journal-essay wrapper, conceptually) stay aligned.
//
// `relative_root` is "../" for section index + entry pages (they're one dir
// deep). `active` is one of "journal"|"lab"|"objects"|"workshop"|"canon"
// and is currently used only to set body class for CSS hooks.
fn sectionHeadAndHeader(
    alloc: Allocator,
    title: []const u8,
    description: []const u8,
    site_url: []const u8,
    canonical_path: []const u8, // e.g. "lab/index.html" or "lab/some-slug.html"
    active: []const u8,
) ![]u8 {
    const title_esc = try htmlEscape(alloc, title);
    defer alloc.free(title_esc);
    const desc_esc = try htmlEscape(alloc, description);
    defer alloc.free(desc_esc);
    const su = try htmlEscape(alloc, site_url);
    defer alloc.free(su);
    const cpath_esc = try htmlEscape(alloc, canonical_path);
    defer alloc.free(cpath_esc);
    const active_esc = try htmlEscape(alloc, active);
    defer alloc.free(active_esc);

    return std.fmt.allocPrint(alloc,
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\    <meta charset="UTF-8">
        \\    <meta name="viewport" content="width=device-width, initial-scale=1">
        \\    <title>{s} — Stax</title>
        \\    <meta name="description" content="{s}">
        \\    <link rel="canonical" href="{s}/{s}">
        \\    <link rel="icon" type="image/svg+xml" href="../favicon.svg">
        \\    <link rel="icon" type="image/png" sizes="32x32" href="../favicon-32.png">
        \\    <link rel="icon" type="image/png" sizes="192x192" href="../favicon-192.png">
        \\    <link rel="apple-touch-icon" href="../favicon-192.png">
        \\    <link rel="manifest" href="../site.webmanifest">
        \\    <meta name="theme-color" content="#121212">
        \\    <link rel="stylesheet" href="../css/stax.css">
        \\    <link rel="alternate" type="application/rss+xml" href="../feed.xml" title="Stax RSS">
        \\    <meta property="og:type" content="website">
        \\    <meta property="og:title" content="{s} — Stax">
        \\    <meta property="og:description" content="{s}">
        \\    <meta property="og:url" content="{s}/{s}">
        \\    <meta property="og:image" content="{s}/og/default.png">
        \\    <meta name="twitter:card" content="summary_large_image">
        \\    <meta name="twitter:title" content="{s} — Stax">
        \\    <meta name="twitter:description" content="{s}">
        \\    <meta name="twitter:image" content="{s}/og/default.png">
        \\    <meta name="twitter:site" content="@Staxxxx17">
        \\</head>
        \\<body class="section-{s}">
        \\    <header class="site-header">
        \\        <div class="brand">
        \\            <span class="brand-mark">STAX</span>
        \\            <span class="brand-tag">Quantitative Mercantilism</span>
        \\        </div>
        \\        <nav>
        \\            <a href="../index.html">Journal</a>
        \\            <a href="../lab/">Lab</a>
        \\            <a href="../substrate/">Substrate</a>
        \\            <a href="../objects/">Objects</a>
        \\            <a href="../workshop/">Workshop</a>
        \\            <a href="../canon/">Canon</a>
        \\            <a href="../essays.html">Archive</a>
        \\            <a href="../about.html">About</a>
        \\            <a href="../feed.xml">RSS</a>
        \\        </nav>
        \\    </header>
        \\
    , .{
        title_esc,  desc_esc,  su,       cpath_esc,
        title_esc,  desc_esc,  su,       cpath_esc,
        su,         title_esc, desc_esc, su,
        active_esc,
    });
}

fn sectionFooter(alloc: Allocator) ![]u8 {
    return alloc.dupe(u8,
        \\    <footer class="site-footer">
        \\        STAX // <a href="https://x.com/Staxxxx17">@Staxxxx17</a> &middot; <a href="../feed.xml">RSS</a> &middot; <a href="../essays.html">All essays</a>
        \\    </footer>
        \\</body>
        \\</html>
        \\
    );
}

// ---------------- /lab — The Notebook

pub fn renderLabIndex(alloc: Allocator, entries: []const Post, site_url: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const head = try sectionHeadAndHeader(
        alloc,
        "Lab — The Notebook",
        "Dated, evidence-graded entries from the Sovereign Stack substrate. Each line is reproducible to the level claimed.",
        site_url,
        "lab/index.html",
        "lab",
    );
    defer alloc.free(head);
    try out.appendSlice(alloc, head);

    try out.appendSlice(alloc,
        \\    <main class="lab-main">
        \\        <h1>The Notebook</h1>
        \\        <p class="lede">Dated, evidence-graded entries from the substrate. Each row links to a reproducible recipe. Sort: most recent first.</p>
        \\        <table class="lab-table">
        \\            <thead>
        \\                <tr><th>Date</th><th>Project</th><th>Title</th><th>Evidence</th></tr>
        \\            </thead>
        \\            <tbody>
        \\
    );

    for (entries) |p| {
        const t = try htmlEscape(alloc, p.fm.title);
        defer alloc.free(t);
        const d = try htmlEscape(alloc, p.fm.date);
        defer alloc.free(d);
        const proj = try htmlEscape(alloc, p.fm.project);
        defer alloc.free(proj);
        const ev = try htmlEscape(alloc, p.fm.evidence);
        defer alloc.free(ev);
        const ev_class = try sanitizeForClass(alloc, p.fm.evidence);
        defer alloc.free(ev_class);
        const row = try std.fmt.allocPrint(alloc,
            \\                <tr>
            \\                    <td class="lab-date"><code>{s}</code></td>
            \\                    <td class="lab-project"><span class="lab-project-tag">{s}</span></td>
            \\                    <td class="lab-title"><a href="{s}.html">{s}</a></td>
            \\                    <td class="lab-evidence"><span class="lab-entry-evidence-pill ev-{s}">{s}</span></td>
            \\                </tr>
            \\
        , .{ d, proj, p.slug, t, ev_class, ev });
        defer alloc.free(row);
        try out.appendSlice(alloc, row);
    }

    try out.appendSlice(alloc,
        \\            </tbody>
        \\        </table>
        \\    </main>
        \\
    );

    const foot = try sectionFooter(alloc);
    defer alloc.free(foot);
    try out.appendSlice(alloc, foot);

    return out.toOwnedSlice(alloc);
}

pub fn renderLabEntry(alloc: Allocator, p: Post, site_url: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const canon = try std.fmt.allocPrint(alloc, "lab/{s}.html", .{p.slug});
    defer alloc.free(canon);
    const head = try sectionHeadAndHeader(
        alloc,
        p.fm.title,
        if (p.fm.summary.len > 0) p.fm.summary else "A notebook entry from the Sovereign Stack substrate.",
        site_url,
        canon,
        "lab",
    );
    defer alloc.free(head);
    try out.appendSlice(alloc, head);

    const t = try htmlEscape(alloc, p.fm.title);
    defer alloc.free(t);
    const d = try htmlEscape(alloc, p.fm.date);
    defer alloc.free(d);
    const proj = try htmlEscape(alloc, p.fm.project);
    defer alloc.free(proj);
    const ev = try htmlEscape(alloc, p.fm.evidence);
    defer alloc.free(ev);
    const ev_class = try sanitizeForClass(alloc, p.fm.evidence);
    defer alloc.free(ev_class);

    const main_open = try std.fmt.allocPrint(alloc,
        \\    <main class="lab-entry">
        \\        <aside class="lab-entry-sidebar">
        \\            <dl class="lab-entry-meta">
        \\                <dt>Project</dt>
        \\                <dd><a href="https://github.com/SMC17/{s}">SMC17/{s}</a></dd>
        \\                <dt>Evidence</dt>
        \\                <dd><span class="lab-entry-evidence-pill ev-{s}">{s}</span></dd>
        \\                <dt>Last verified</dt>
        \\                <dd><code>{s}</code></dd>
        \\                <dt>Reproducible</dt>
        \\                <dd>{s}</dd>
        \\            </dl>
        \\        </aside>
        \\        <article class="lab-entry-body">
        \\            <h1>{s}</h1>
        \\            <p class="meta">{s} · project <code>{s}</code></p>
        \\
    , .{ proj, proj, ev_class, ev, d, if (p.fm.reproducible) "yes" else "not yet", t, d, proj });
    defer alloc.free(main_open);
    try out.appendSlice(alloc, main_open);

    try out.appendSlice(alloc, p.body_html);

    try out.appendSlice(alloc,
        \\        </article>
        \\    </main>
        \\
    );

    const foot = try sectionFooter(alloc);
    defer alloc.free(foot);
    try out.appendSlice(alloc, foot);

    return out.toOwnedSlice(alloc);
}

// ---------------- /objects — Industrial design

pub fn renderObjectsIndex(alloc: Allocator, entries: []const Post, site_url: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const head = try sectionHeadAndHeader(
        alloc,
        "Objects",
        "Industrial design and physical artifacts. Concept through shipped.",
        site_url,
        "objects/index.html",
        "objects",
    );
    defer alloc.free(head);
    try out.appendSlice(alloc, head);

    try out.appendSlice(alloc,
        \\    <main class="objects-main">
        \\        <h1>Objects</h1>
        \\        <p class="lede">Physical artifacts and industrial design studies.</p>
        \\        <ul class="objects-grid">
        \\
    );

    for (entries) |p| {
        const t = try htmlEscape(alloc, p.fm.title);
        defer alloc.free(t);
        const status_esc = try htmlEscape(alloc, p.fm.status);
        defer alloc.free(status_esc);
        const status_class = try sanitizeForClass(alloc, p.fm.status);
        defer alloc.free(status_class);
        const hero_esc = try htmlEscape(alloc, p.fm.hero_image);
        defer alloc.free(hero_esc);
        const hero_block = if (p.fm.hero_image.len > 0)
            try std.fmt.allocPrint(alloc, "<div class=\"object-hero\" style=\"background-image: url('..{s}');\"></div>", .{hero_esc})
        else
            try alloc.dupe(u8, "<div class=\"object-hero object-hero-placeholder\"></div>");
        defer alloc.free(hero_block);
        const row = try std.fmt.allocPrint(alloc,
            \\            <li class="object-card">
            \\                <a href="{s}.html">
            \\                    {s}
            \\                    <div class="object-card-meta">
            \\                        <span class="object-card-title">{s}</span>
            \\                        <span class="object-status-pill st-{s}">{s}</span>
            \\                    </div>
            \\                </a>
            \\            </li>
            \\
        , .{ p.slug, hero_block, t, status_class, status_esc });
        defer alloc.free(row);
        try out.appendSlice(alloc, row);
    }

    try out.appendSlice(alloc,
        \\        </ul>
        \\    </main>
        \\
    );

    const foot = try sectionFooter(alloc);
    defer alloc.free(foot);
    try out.appendSlice(alloc, foot);

    return out.toOwnedSlice(alloc);
}

pub fn renderObjectEntry(alloc: Allocator, p: Post, site_url: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const canon = try std.fmt.allocPrint(alloc, "objects/{s}.html", .{p.slug});
    defer alloc.free(canon);
    const head = try sectionHeadAndHeader(
        alloc,
        p.fm.title,
        if (p.fm.summary.len > 0) p.fm.summary else "An object study.",
        site_url,
        canon,
        "objects",
    );
    defer alloc.free(head);
    try out.appendSlice(alloc, head);

    const t = try htmlEscape(alloc, p.fm.title);
    defer alloc.free(t);
    const d = try htmlEscape(alloc, p.fm.date);
    defer alloc.free(d);
    const status_esc = try htmlEscape(alloc, p.fm.status);
    defer alloc.free(status_esc);
    const status_class = try sanitizeForClass(alloc, p.fm.status);
    defer alloc.free(status_class);
    const dims_esc = try htmlEscape(alloc, p.fm.dimensions);
    defer alloc.free(dims_esc);
    const hero_esc = try htmlEscape(alloc, p.fm.hero_image);
    defer alloc.free(hero_esc);

    const hero_block = if (p.fm.hero_image.len > 0)
        try std.fmt.allocPrint(alloc, "<figure class=\"object-bleed-hero\"><img src=\"..{s}\" alt=\"{s}\" /></figure>\n", .{ hero_esc, t })
    else
        try alloc.dupe(u8, "<figure class=\"object-bleed-hero object-bleed-hero-placeholder\"><div class=\"object-bleed-hero-fill\" aria-hidden=\"true\"></div></figure>\n");
    defer alloc.free(hero_block);

    var mat_html: std.ArrayList(u8) = .empty;
    defer mat_html.deinit(alloc);
    if (p.fm.materials.len > 0) {
        try mat_html.appendSlice(alloc, "<ul class=\"object-materials\">");
        for (p.fm.materials) |m| {
            const m_esc = try htmlEscape(alloc, m);
            defer alloc.free(m_esc);
            const li = try std.fmt.allocPrint(alloc, "<li>{s}</li>", .{m_esc});
            defer alloc.free(li);
            try mat_html.appendSlice(alloc, li);
        }
        try mat_html.appendSlice(alloc, "</ul>");
    }

    const body = try std.fmt.allocPrint(alloc,
        \\    <main class="object-entry">
        \\        {s}
        \\        <header class="object-entry-header">
        \\            <h1>{s}</h1>
        \\            <p class="meta">{s} · <span class="object-status-pill st-{s}">{s}</span>{s}{s}</p>
        \\            {s}
        \\        </header>
        \\        <article class="object-entry-body">
        \\
    , .{
        hero_block,
        t,
        d,
        status_class,
        status_esc,
        if (p.fm.dimensions.len > 0) " · " else "",
        dims_esc,
        mat_html.items,
    });
    defer alloc.free(body);
    try out.appendSlice(alloc, body);

    try out.appendSlice(alloc, p.body_html);
    try out.appendSlice(alloc,
        \\        </article>
        \\    </main>
        \\
    );

    const foot = try sectionFooter(alloc);
    defer alloc.free(foot);
    try out.appendSlice(alloc, foot);

    return out.toOwnedSlice(alloc);
}

// ---------------- /workshop — Currently Building

pub fn renderWorkshopIndex(alloc: Allocator, entries: []const Post, site_url: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const head = try sectionHeadAndHeader(
        alloc,
        "Workshop — Currently Building",
        "Open build logs. Active work surfaces here before it becomes a notebook entry or a shipped object.",
        site_url,
        "workshop/index.html",
        "workshop",
    );
    defer alloc.free(head);
    try out.appendSlice(alloc, head);

    try out.appendSlice(alloc,
        \\    <main class="workshop-main">
        \\        <h1>Workshop</h1>
        \\        <p class="lede">Open build logs. Active work surfaces here before it crystallizes into a notebook entry or a shipped object.</p>
        \\        <ul class="workshop-log">
        \\
    );

    for (entries) |p| {
        const t = try htmlEscape(alloc, p.fm.title);
        defer alloc.free(t);
        const started_esc = try htmlEscape(alloc, p.fm.started);
        defer alloc.free(started_esc);
        const status_esc = try htmlEscape(alloc, p.fm.status);
        defer alloc.free(status_esc);
        const status_class = try sanitizeForClass(alloc, p.fm.status);
        defer alloc.free(status_class);
        const gh_esc = try htmlEscape(alloc, p.fm.github);
        defer alloc.free(gh_esc);
        const gh_block = if (p.fm.github.len > 0)
            try std.fmt.allocPrint(alloc, " · <a href=\"https://github.com/{s}\">{s}</a>", .{ gh_esc, gh_esc })
        else
            try alloc.dupe(u8, "");
        defer alloc.free(gh_block);
        const row = try std.fmt.allocPrint(alloc,
            \\            <li class="workshop-entry workshop-status-{s}">
            \\                <a href="{s}.html">
            \\                    <span class="workshop-entry-date"><code>{s}</code></span>
            \\                    <span class="workshop-entry-title">{s}</span>
            \\                    <span class="workshop-entry-meta">
            \\                        <span class="workshop-status-pill st-{s}">{s}</span>{s}
            \\                    </span>
            \\                </a>
            \\            </li>
            \\
        , .{ status_class, p.slug, started_esc, t, status_class, status_esc, gh_block });
        defer alloc.free(row);
        try out.appendSlice(alloc, row);
    }

    try out.appendSlice(alloc,
        \\        </ul>
        \\        <p class="workshop-note">Filter: showing all entries. Status pills mark <code>active</code>, <code>paused</code>, <code>shipped</code>.</p>
        \\    </main>
        \\
    );

    const foot = try sectionFooter(alloc);
    defer alloc.free(foot);
    try out.appendSlice(alloc, foot);

    return out.toOwnedSlice(alloc);
}

pub fn renderWorkshopEntry(alloc: Allocator, p: Post, site_url: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const canon = try std.fmt.allocPrint(alloc, "workshop/{s}.html", .{p.slug});
    defer alloc.free(canon);
    const head = try sectionHeadAndHeader(
        alloc,
        p.fm.title,
        if (p.fm.summary.len > 0) p.fm.summary else "A workshop build log.",
        site_url,
        canon,
        "workshop",
    );
    defer alloc.free(head);
    try out.appendSlice(alloc, head);

    const t = try htmlEscape(alloc, p.fm.title);
    defer alloc.free(t);
    const started_esc = try htmlEscape(alloc, p.fm.started);
    defer alloc.free(started_esc);
    const status_esc = try htmlEscape(alloc, p.fm.status);
    defer alloc.free(status_esc);
    const status_class = try sanitizeForClass(alloc, p.fm.status);
    defer alloc.free(status_class);
    const gh_esc = try htmlEscape(alloc, p.fm.github);
    defer alloc.free(gh_esc);
    const gh_block = if (p.fm.github.len > 0)
        try std.fmt.allocPrint(alloc, " · <a href=\"https://github.com/{s}\">{s}</a>", .{ gh_esc, gh_esc })
    else
        try alloc.dupe(u8, "");
    defer alloc.free(gh_block);

    const body = try std.fmt.allocPrint(alloc,
        \\    <main class="workshop-entry-page">
        \\        <h1>{s}</h1>
        \\        <p class="meta workshop-meta">Started <code>{s}</code> · <span class="workshop-status-pill st-{s}">{s}</span>{s}</p>
        \\        <article class="workshop-entry-body">
        \\
    , .{ t, started_esc, status_class, status_esc, gh_block });
    defer alloc.free(body);
    try out.appendSlice(alloc, body);

    try out.appendSlice(alloc, p.body_html);
    try out.appendSlice(alloc,
        \\        </article>
        \\    </main>
        \\
    );

    const foot = try sectionFooter(alloc);
    defer alloc.free(foot);
    try out.appendSlice(alloc, foot);

    return out.toOwnedSlice(alloc);
}

// ---------------- /substrate — Shipped engineering pieces
//
// Substrate is the engineering peer of canon. Each entry is a shipped
// project tracked by Forgejo (sovereign canonical). The catalog groups
// entries by `lane`: inference, validation, comms, editor, integration,
// research. Per-project pages carry quoted-word section markers
// (WHY / WHAT / MILESTONES / DEPENDENCIES / ADAPTER TARGETS / RELATED
// CANON / RELATED LAB NOTES / RELATED WORKSHOP / LIMITS / SOURCE) per
// SUBSTRATE_DISTRIBUTION_DESIGN.md. GitHub never gets a primary CTA;
// per the funnel discipline GitHub is the optional source mirror, not
// the distribution surface.

const SubstrateLane = struct {
    slug: []const u8, // lowercase tag matching fm.lane
    label: []const u8, // section H2 (rendered as quoted-word marker)
    intro: []const u8, // one-line section intro
};

pub const substrate_lanes = [_]SubstrateLane{
    .{
        .slug = "inference",
        .label = "INFERENCE",
        .intro = "Pure-Zig CPU inference stack from on-disk weights to streamed tokens. Composed in lab/ai-inference-zig-stack.",
    },
    .{
        .slug = "validation",
        .label = "VALIDATION",
        .intro = "Statistical-discipline substrate. PSR + DSR + Purged K-Fold + forecast-log gates.",
    },
    .{
        .slug = "comms",
        .label = "COMMS",
        .intro = "Threshold-flock messaging substrate and BEAM multi-agent orchestration.",
    },
    .{
        .slug = "editor",
        .label = "EDITOR",
        .intro = "Multi-agent-native editor substrate. AGPL.",
    },
    .{
        .slug = "integration",
        .label = "INTEGRATION",
        .intro = "Substrate that composes lower layers into running runtime.",
    },
    .{
        .slug = "research",
        .label = "RESEARCH",
        .intro = "Research substrate not yet on a primary lane.",
    },
};

pub fn renderSubstrateIndex(alloc: Allocator, entries: []const Post, site_url: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const head = try sectionHeadAndHeader(
        alloc,
        "Substrate",
        "Shipped engineering pieces from the Sovereign Stack. Every load-bearing claim in the canon is checkable against this code.",
        site_url,
        "substrate/index.html",
        "substrate",
    );
    defer alloc.free(head);
    try out.appendSlice(alloc, head);

    try out.appendSlice(alloc,
        \\    <main class="substrate-main">
        \\        <header class="substrate-hero">
        \\            <p class="section-label">Substrate</p>
        \\            <h1>Substrate</h1>
        \\            <p class="lede">Substrate is the engineering position the canon names. Every load-bearing claim in the journal is meant to be checkable against working code. This page lists the working code.</p>
        \\            <p class="substrate-note">Status vocabulary: <span class="substrate-status-pill st-experimental">experimental</span> for un-tagged work, <span class="substrate-status-pill st-pre-10">pre-1.0</span> for versioned releases against a pre-1.0 toolchain, <span class="substrate-status-pill st-stable">stable</span> reserved for post-1.0 ABI-stable substrate. Zig 0.16 ceiling applies to everything in this catalog.</p>
        \\        </header>
        \\
    );

    for (substrate_lanes) |lane| {
        // Filter entries for this lane.
        var any_in_lane: bool = false;
        for (entries) |p| {
            if (std.mem.eql(u8, p.fm.lane, lane.slug)) {
                any_in_lane = true;
                break;
            }
        }
        if (!any_in_lane) continue;

        const lane_label = try htmlEscape(alloc, lane.label);
        defer alloc.free(lane_label);
        const lane_intro = try htmlEscape(alloc, lane.intro);
        defer alloc.free(lane_intro);

        const section_open = try std.fmt.allocPrint(alloc,
            \\        <section class="substrate-lane substrate-lane-{s}">
            \\            <h2 class="section-label">{s}</h2>
            \\            <p class="section-intro">{s}</p>
            \\            <ul class="substrate-grid">
            \\
        , .{ lane.slug, lane_label, lane_intro });
        defer alloc.free(section_open);
        try out.appendSlice(alloc, section_open);

        for (entries) |p| {
            if (!std.mem.eql(u8, p.fm.lane, lane.slug)) continue;

            const t = try htmlEscape(alloc, p.fm.title);
            defer alloc.free(t);
            const summary_esc = try htmlEscape(alloc, p.fm.summary);
            defer alloc.free(summary_esc);
            const status_esc = try htmlEscape(alloc, p.fm.status);
            defer alloc.free(status_esc);
            const status_class = try sanitizeForClass(alloc, p.fm.status);
            defer alloc.free(status_class);
            const tag_esc = try htmlEscape(alloc, p.fm.latest_tag);
            defer alloc.free(tag_esc);
            const date_esc = try htmlEscape(alloc, p.fm.date);
            defer alloc.free(date_esc);
            const tests_esc = try htmlEscape(alloc, p.fm.test_count);
            defer alloc.free(tests_esc);
            const license_esc = try htmlEscape(alloc, p.fm.license);
            defer alloc.free(license_esc);
            const forgejo_esc = try htmlEscape(alloc, p.fm.forgejo_url);
            defer alloc.free(forgejo_esc);

            // The card carries: name, status pill, latest tag, ship date,
            // test count, license, forgejo URL. The forgejo URL is the
            // sovereign canonical source. NO GitHub link on the card —
            // the per-project page is where any optional mirror surfaces.
            const card = try std.fmt.allocPrint(alloc,
                \\                <li class="substrate-card">
                \\                    <a class="substrate-card-link" href="{s}.html">
                \\                        <header class="substrate-card-head">
                \\                            <span class="substrate-card-name">{s}</span>
                \\                            <span class="substrate-status-pill st-{s}">{s}</span>
                \\                        </header>
                \\                        <p class="substrate-card-summary">{s}</p>
                \\                        <dl class="substrate-card-meta">
                \\                            <div class="substrate-meta-row"><dt>tag</dt><dd><code>{s}</code></dd></div>
                \\                            <div class="substrate-meta-row"><dt>shipped</dt><dd><code>{s}</code></dd></div>
                \\                            <div class="substrate-meta-row"><dt>tests</dt><dd>{s}</dd></div>
                \\                            <div class="substrate-meta-row"><dt>license</dt><dd>{s}</dd></div>
                \\                        </dl>
                \\                    </a>
                \\                    <p class="substrate-card-source"><span class="substrate-source-label">source</span> <code>{s}</code></p>
                \\                </li>
                \\
            , .{
                p.slug,      t,           status_class, status_esc,
                summary_esc, tag_esc,     date_esc,     tests_esc,
                license_esc, forgejo_esc,
            });
            defer alloc.free(card);
            try out.appendSlice(alloc, card);
        }

        try out.appendSlice(alloc,
            \\            </ul>
            \\        </section>
            \\
        );
    }

    try out.appendSlice(alloc,
        \\        <hr>
        \\        <p class="substrate-footnote">War-mode posture per the operating doctrine: substrate marked private in the local register stays off the public catalog until its public-push gate clears. The catalog is a curation, not a dump.</p>
        \\    </main>
        \\
    );

    const foot = try sectionFooter(alloc);
    defer alloc.free(foot);
    try out.appendSlice(alloc, foot);

    return out.toOwnedSlice(alloc);
}

pub fn renderSubstrateEntry(alloc: Allocator, p: Post, site_url: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const canon = try std.fmt.allocPrint(alloc, "substrate/{s}.html", .{p.slug});
    defer alloc.free(canon);
    const head = try sectionHeadAndHeader(
        alloc,
        p.fm.title,
        if (p.fm.summary.len > 0) p.fm.summary else "A substrate piece.",
        site_url,
        canon,
        "substrate",
    );
    defer alloc.free(head);
    try out.appendSlice(alloc, head);

    const t = try htmlEscape(alloc, p.fm.title);
    defer alloc.free(t);
    const status_esc = try htmlEscape(alloc, p.fm.status);
    defer alloc.free(status_esc);
    const status_class = try sanitizeForClass(alloc, p.fm.status);
    defer alloc.free(status_class);
    const tag_esc = try htmlEscape(alloc, p.fm.latest_tag);
    defer alloc.free(tag_esc);
    const date_esc = try htmlEscape(alloc, p.fm.date);
    defer alloc.free(date_esc);
    const tests_esc = try htmlEscape(alloc, p.fm.test_count);
    defer alloc.free(tests_esc);
    const license_esc = try htmlEscape(alloc, p.fm.license);
    defer alloc.free(license_esc);
    const lane_esc = try htmlEscape(alloc, p.fm.lane);
    defer alloc.free(lane_esc);

    // Title block. The H1 carries the project name. The kicker line is
    // the quoted-word marker showing SUBSTRATE / <NAME>. Meta line carries
    // status pill, latest tag, ship date, license. Test line is separate
    // so it can absorb extra detail later (e.g., "69 unit tests, fuzz pass").
    const head_block = try std.fmt.allocPrint(alloc,
        \\    <main class="substrate-entry">
        \\        <header class="substrate-entry-header">
        \\            <p class="substrate-kicker">"SUBSTRATE / {s}"</p>
        \\            <h1>{s}</h1>
        \\            <p class="substrate-meta-primary">
        \\                <span class="substrate-status-pill st-{s}">{s}</span>
        \\                <span class="substrate-meta-dot">.</span>
        \\                <code>{s}</code>
        \\                <span class="substrate-meta-dot">.</span>
        \\                shipped <code>{s}</code>
        \\                <span class="substrate-meta-dot">.</span>
        \\                {s}
        \\            </p>
        \\            <p class="substrate-meta-secondary">{s} . lane: <code>{s}</code></p>
        \\        </header>
        \\        <article class="substrate-entry-body">
        \\
    , .{
        t,        t,        status_class, status_esc,
        tag_esc,  date_esc, license_esc,  tests_esc,
        lane_esc,
    });
    defer alloc.free(head_block);
    try out.appendSlice(alloc, head_block);

    try out.appendSlice(alloc, p.body_html);

    try out.appendSlice(alloc,
        \\        </article>
        \\    </main>
        \\
    );

    const foot = try sectionFooter(alloc);
    defer alloc.free(foot);
    try out.appendSlice(alloc, foot);

    return out.toOwnedSlice(alloc);
}

// ---------------- /canon — Lineage + Doctrine + Anti-Edison arcs

// Convert a 1-based index to its uppercase Roman-numeral form. Covers 1..3999.
pub fn romanNumeral(alloc: Allocator, n: usize) ![]u8 {
    if (n == 0 or n > 3999) return alloc.dupe(u8, "");
    const Pair = struct { v: usize, s: []const u8 };
    const table = [_]Pair{
        .{ .v = 1000, .s = "M" }, .{ .v = 900, .s = "CM" }, .{ .v = 500, .s = "D" }, .{ .v = 400, .s = "CD" },
        .{ .v = 100, .s = "C" },  .{ .v = 90, .s = "XC" },  .{ .v = 50, .s = "L" },  .{ .v = 40, .s = "XL" },
        .{ .v = 10, .s = "X" },   .{ .v = 9, .s = "IX" },   .{ .v = 5, .s = "V" },   .{ .v = 4, .s = "IV" },
        .{ .v = 1, .s = "I" },
    };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var rem = n;
    for (table) |entry| {
        while (rem >= entry.v) {
            try out.appendSlice(alloc, entry.s);
            rem -= entry.v;
        }
    }
    return out.toOwnedSlice(alloc);
}

// Sanitize a value for use in a CSS class token: lowercase, alphanumerics
// and hyphens only. Used for evidence-pill and status-pill class hooks
// so we don't trust user-provided frontmatter to be class-safe.
fn sanitizeForClass(alloc: Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (src) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try out.append(alloc, std.ascii.toLower(c));
        } else if (c == '-' or c == ' ' or c == '_') {
            try out.append(alloc, '-');
        }
    }
    if (out.items.len == 0) try out.appendSlice(alloc, "unknown");
    return out.toOwnedSlice(alloc);
}

pub const CanonArc = struct {
    slug_prefix: []const u8, // e.g. "lineage-"
    arc_slug: []const u8, // canonical url segment, e.g. "lineage"
    title: []const u8, // display label, e.g. "Lineage"
};

pub const canon_arcs = [_]CanonArc{
    .{ .slug_prefix = "lineage-", .arc_slug = "lineage", .title = "Lineage" },
    .{ .slug_prefix = "anti-edison-", .arc_slug = "anti-edison", .title = "Anti-Edison" },
    .{ .slug_prefix = "doctrine-", .arc_slug = "doctrine", .title = "Doctrine" },
};

// Parse the canonical number out of a canon slug.
//
// Slug convention: <arc-prefix><NN>-<rest>, e.g. "lineage-44-kenneth-forbus".
// The NN is the canonical citation primitive — stable across the publish
// lifecycle. This is the load-bearing contract from the
// stax-dev-portfolio-design-system.md Amendment 1 (Canon-numbering Path A):
// the number comes from the slug, not from the position of the post in a
// sorted, draft-filtered list.
//
// Returns 0 if the slug does not match the convention; callers should treat
// 0 as "skip" (the canon-renderer logs this so misnamed canon entries surface
// loudly rather than silently being numbered as I, II, III, …).
pub fn parseCanonNumberFromSlug(slug: []const u8, arc_prefix: []const u8) usize {
    if (!std.mem.startsWith(u8, slug, arc_prefix)) return 0;
    const rest = slug[arc_prefix.len..];
    var i: usize = 0;
    while (i < rest.len and std.ascii.isDigit(rest[i])) : (i += 1) {}
    if (i == 0) return 0;
    return std.fmt.parseInt(usize, rest[0..i], 10) catch 0;
}

test "parseCanonNumberFromSlug — happy path" {
    try std.testing.expectEqual(@as(usize, 44), parseCanonNumberFromSlug("lineage-44-kenneth-forbus", "lineage-"));
    try std.testing.expectEqual(@as(usize, 1), parseCanonNumberFromSlug("anti-edison-01-edison-as-original-scalper", "anti-edison-"));
    try std.testing.expectEqual(@as(usize, 10), parseCanonNumberFromSlug("doctrine-10-lineage-mining-methodology", "doctrine-"));
}

test "parseCanonNumberFromSlug — mismatched prefix returns 0" {
    try std.testing.expectEqual(@as(usize, 0), parseCanonNumberFromSlug("doctrine-10-foo", "lineage-"));
    try std.testing.expectEqual(@as(usize, 0), parseCanonNumberFromSlug("lineage-no-number", "lineage-"));
    try std.testing.expectEqual(@as(usize, 0), parseCanonNumberFromSlug("", "lineage-"));
}

// Render the /canon/ index page. Reads from BOTH the canon_intro entries
// (the /canon/*.md authored content — usually one "index" prose intro) and
// the journal posts whose slugs start with one of the canon-arc prefixes.
// Renders three parallel numbered lists.
pub fn renderCanonIndex(
    alloc: Allocator,
    canon_intro: []const Post,
    journal_posts: []const Post,
    site_url: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const head = try sectionHeadAndHeader(
        alloc,
        "Canon",
        "The three canonical arcs of Quantitative Mercantilism: Lineage, Anti-Edison, Doctrine.",
        site_url,
        "canon/index.html",
        "canon",
    );
    defer alloc.free(head);
    try out.appendSlice(alloc, head);

    try out.appendSlice(alloc,
        \\    <main class="canon-main">
        \\        <h1>The Canon</h1>
        \\
    );

    // Render any /canon/*.md prose intros (typically just index.md) as a
    // lede block before the three arc lists.
    for (canon_intro) |p| {
        try out.appendSlice(alloc, "        <section class=\"canon-intro\">\n");
        try out.appendSlice(alloc, p.body_html);
        try out.appendSlice(alloc, "\n        </section>\n");
    }

    for (canon_arcs) |arc| {
        // Collect journal posts in this arc, sorted by slug ascending so the
        // NN numbering reads top-down.
        var arc_posts: std.ArrayList(Post) = .empty;
        defer arc_posts.deinit(alloc);
        for (journal_posts) |jp| {
            if (jp.fm.draft) continue;
            if (!std.mem.startsWith(u8, jp.slug, arc.slug_prefix)) continue;
            try arc_posts.append(alloc, jp);
        }
        const Less = struct {
            fn lt(_: void, a: Post, b: Post) bool {
                return std.mem.lessThan(u8, a.slug, b.slug);
            }
        };
        std.mem.sort(Post, arc_posts.items, {}, Less.lt);

        const arc_t = try htmlEscape(alloc, arc.title);
        defer alloc.free(arc_t);
        const head_block = try std.fmt.allocPrint(alloc,
            \\        <section class="canon-arc canon-arc-{s}">
            \\            <h2><a href="{s}/">{s}</a> <span class="canon-arc-count">{d} entries</span></h2>
            \\            <ol class="canon-arc-list">
            \\
        , .{ arc.arc_slug, arc.arc_slug, arc_t, arc_posts.items.len });
        defer alloc.free(head_block);
        try out.appendSlice(alloc, head_block);

        for (arc_posts.items) |p| {
            // Path A: canonical number comes from the slug, not the
            // sorted-list index. Stable across publish lifecycle. See
            // ~/codex/methods/stax-dev-portfolio-design-system.md Amendment 1.
            const num = parseCanonNumberFromSlug(p.slug, arc.slug_prefix);
            if (num == 0) {
                std.debug.print("canon: skipping '{s}' — slug does not match {s}<NN>-… convention\n", .{ p.slug, arc.slug_prefix });
                continue;
            }
            const roman = try romanNumeral(alloc, num);
            defer alloc.free(roman);
            const t = try htmlEscape(alloc, p.fm.title);
            defer alloc.free(t);
            const li = try std.fmt.allocPrint(alloc,
                \\                <li><span class="canon-roman">{s}.</span> <a href="{s}/{d:0>2}.html">{s}</a></li>
                \\
            , .{ roman, arc.arc_slug, num, t });
            defer alloc.free(li);
            try out.appendSlice(alloc, li);
        }
        try out.appendSlice(alloc,
            \\            </ol>
            \\        </section>
            \\
        );
    }

    try out.appendSlice(alloc,
        \\    </main>
        \\
    );

    const foot = try sectionFooter(alloc);
    defer alloc.free(foot);
    try out.appendSlice(alloc, foot);

    return out.toOwnedSlice(alloc);
}

// Render a single canon entry — book-grade typography wrap of an existing
// journal post. Path: public/canon/<arc>/<NN>.html. Since this lives two
// directories deep, all asset paths need "../../" instead of the section
// helper's "../". We render inline rather than reusing sectionHeadAndHeader.
pub fn renderCanonEntry(
    alloc: Allocator,
    p: Post,
    arc: CanonArc,
    number: usize,
    site_url: []const u8,
) ![]u8 {
    const title_esc = try htmlEscape(alloc, p.fm.title);
    defer alloc.free(title_esc);
    const date_esc = try htmlEscape(alloc, p.fm.date);
    defer alloc.free(date_esc);
    const desc_src = if (p.fm.summary.len > 0) p.fm.summary else "An entry in the canon of Quantitative Mercantilism.";
    const desc_esc = try htmlEscape(alloc, desc_src);
    defer alloc.free(desc_esc);
    const su = try htmlEscape(alloc, site_url);
    defer alloc.free(su);
    const arc_t = try htmlEscape(alloc, arc.title);
    defer alloc.free(arc_t);
    const roman = try romanNumeral(alloc, number);
    defer alloc.free(roman);

    return std.fmt.allocPrint(alloc,
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\    <meta charset="UTF-8">
        \\    <meta name="viewport" content="width=device-width, initial-scale=1">
        \\    <title>{s} {s}. {s} — Stax</title>
        \\    <meta name="description" content="{s}">
        \\    <link rel="canonical" href="{s}/canon/{s}/{d:0>2}.html">
        \\    <link rel="icon" type="image/svg+xml" href="../../favicon.svg">
        \\    <link rel="manifest" href="../../site.webmanifest">
        \\    <meta name="theme-color" content="#121212">
        \\    <link rel="stylesheet" href="../../css/stax.css">
        \\    <link rel="alternate" type="application/rss+xml" href="../../feed.xml" title="Stax RSS">
        \\    <meta property="og:type" content="article">
        \\    <meta property="og:title" content="{s} {s}. {s}">
        \\    <meta property="og:description" content="{s}">
        \\    <meta property="og:url" content="{s}/canon/{s}/{d:0>2}.html">
        \\    <meta property="og:image" content="{s}/og/default.png">
        \\    <meta name="twitter:card" content="summary_large_image">
        \\    <meta name="twitter:title" content="{s} {s}. {s}">
        \\    <meta name="twitter:image" content="{s}/og/default.png">
        \\    <meta name="twitter:site" content="@Staxxxx17">
        \\</head>
        \\<body class="section-canon canon-entry">
        \\    <header class="site-header">
        \\        <div class="brand">
        \\            <span class="brand-mark">STAX</span>
        \\            <span class="brand-tag">Quantitative Mercantilism</span>
        \\        </div>
        \\        <nav>
        \\            <a href="../../index.html">Journal</a>
        \\            <a href="../../lab/">Lab</a>
        \\            <a href="../../substrate/">Substrate</a>
        \\            <a href="../../objects/">Objects</a>
        \\            <a href="../../workshop/">Workshop</a>
        \\            <a href="../../canon/">Canon</a>
        \\            <a href="../../essays.html">Archive</a>
        \\            <a href="../../about.html">About</a>
        \\        </nav>
        \\    </header>
        \\    <main class="canon-entry-main">
        \\        <p class="canon-entry-eyebrow"><a href="../">Canon</a> · <a href="../{s}/">{s}</a></p>
        \\        <h1 class="canon-entry-title"><span class="canon-roman">{s} {s}.</span> {s}</h1>
        \\        <p class="meta canon-entry-meta">{s}</p>
        \\        <article class="canon-entry-body">
        \\{s}        </article>
        \\        <p class="canon-entry-source">Originally published in the journal as <a href="../../posts/{s}.html">{s}</a>.</p>
        \\    </main>
        \\    <footer class="site-footer">
        \\        STAX // <a href="https://x.com/Staxxxx17">@Staxxxx17</a> &middot; <a href="../../feed.xml">RSS</a> &middot; <a href="../../essays.html">All essays</a>
        \\    </footer>
        \\</body>
        \\</html>
        \\
    , .{
        // <title>
        arc_t,        roman,        title_esc,
        desc_esc,     su,           arc.arc_slug,
        number,
        // og
              arc_t,        roman,
        title_esc,    desc_esc,     su,
        arc.arc_slug, number,       su,
        // twitter
        arc_t,        roman,        title_esc,
        su,
        // body breadcrumb
                  arc.arc_slug, arc_t,
        // h1
        arc_t,        roman,        title_esc,
        date_esc,
        // body
            p.body_html,
            // source link
         p.slug,
        title_esc,
    });
}

// ---------------------------------------------------------------- tests

test "html escape basics" {
    const a = std.testing.allocator;
    const out = try htmlEscape(a, "a & b < c > d \" e ' f");
    defer a.free(out);
    try std.testing.expectEqualStrings("a &amp; b &lt; c &gt; d &quot; e &#39; f", out);
}

test "inline bold and code" {
    const a = std.testing.allocator;
    const out = try renderInline(a, "this is **bold** and `code`", null);
    defer a.free(out);
    try std.testing.expectEqualStrings("this is <b>bold</b> and <code>code</code>", out);
}

test "inline link" {
    const a = std.testing.allocator;
    const out = try renderInline(a, "see [docs](https://example.com/x)", null);
    defer a.free(out);
    try std.testing.expectEqualStrings("see <a href=\"https://example.com/x\">docs</a>", out);
}

test "inline em-dash from --" {
    const a = std.testing.allocator;
    const out = try renderInline(a, "this--that", null);
    defer a.free(out);
    try std.testing.expectEqualStrings("this&mdash;that", out);
}

test "footnote reference and definition" {
    const a = std.testing.allocator;
    const src = "Some text[^1] and more[^smith].\n\n[^1]: First footnote.\n[^smith]: Smith 2018.\n";
    const out = try renderMarkdown(a, std.testing.io, src);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "<sup class=\"footnote-ref\" id=\"fnref-1\"><a href=\"#fn-1\">1</a></sup>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<sup class=\"footnote-ref\" id=\"fnref-smith\"><a href=\"#fn-smith\">2</a></sup>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<section class=\"footnotes\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<li id=\"fn-1\">First footnote.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<li id=\"fn-smith\">Smith 2018.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<p>[^1]: First footnote.</p>") == null);
}

test "footnote reference without definition renders no superscript" {
    const a = std.testing.allocator;
    const src = "Reference[^missing] with no def.\n";
    const out = try renderMarkdown(a, std.testing.io, src);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "<section class=\"footnotes\">") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<sup") == null);
}

test "render heading and paragraph" {
    const a = std.testing.allocator;
    const out = try renderMarkdown(a, std.testing.io, "# Title\n\nA para.\n");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "<h1>Title</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<p>A para.</p>") != null);
}

test "render fenced code with language" {
    const a = std.testing.allocator;
    const src = "```zig\nconst x = 1;\n```\n";
    const out = try renderMarkdown(a, std.testing.io, src);
    defer a.free(out);
    // The renderer preserves the trailing newline of the code block
    // before the closing tag — match the language attribute + the
    // first line, then assert closure separately.
    try std.testing.expect(std.mem.indexOf(u8, out, "<pre><code class=\"language-zig\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "const x = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "</code></pre>") != null);
}

test "render bullet list" {
    const a = std.testing.allocator;
    const out = try renderMarkdown(a, std.testing.io, "- one\n- two\n- three\n");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "<ul>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<li>one</li>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<li>three</li>") != null);
}

test "render ordered list" {
    const a = std.testing.allocator;
    const out = try renderMarkdown(a, std.testing.io, "1. one\n2. two\n");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "<ol>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<li>one</li>") != null);
}

test "render blockquote" {
    const a = std.testing.allocator;
    const out = try renderMarkdown(a, std.testing.io, "> quoted\n> two\n");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "<blockquote>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<p>quoted</p>") != null);
}

test "frontmatter md" {
    const a = std.testing.allocator;
    const src = "---\ntitle: \"Hello\"\ndate: 2026-05-06\n---\n\nbody\n";
    var fp = try parseMdFrontmatter(a, src);
    defer fp.fm.deinit(a);
    try std.testing.expectEqualStrings("Hello", fp.fm.title);
    try std.testing.expectEqualStrings("2026-05-06", fp.fm.date);
    try std.testing.expectEqualStrings("body\n", fp.body);
}

test "frontmatter html comment" {
    const a = std.testing.allocator;
    const src = "<!--\ntitle: Hand HTML\ndate: 2026-05-06\nsummary: A summary line.\n-->\n<p>body</p>\n";
    var fp = try parseHtmlFrontmatter(a, src);
    defer fp.fm.deinit(a);
    try std.testing.expectEqualStrings("Hand HTML", fp.fm.title);
    try std.testing.expectEqualStrings("A summary line.", fp.fm.summary);
    try std.testing.expectEqualStrings("<p>body</p>\n", fp.body);
}

test "strip tags" {
    const a = std.testing.allocator;
    const out = try stripTags(a, "<p>hello <b>world</b> &amp; cheese</p>");
    defer a.free(out);
    try std.testing.expectEqualStrings("hello world & cheese", out);
}

test "calendar accepts same-day ISO timestamps and holds tomorrow" {
    const today = "2026-11-12";
    for ([_][]const u8{ "2026-11-11", "2026-11-12", "2026-11-12T00:00:00Z", "2026-11-12T23:59:59Z" }) |date| {
        try std.testing.expect(!isFutureDate(date, today));
    }
    for ([_][]const u8{ "2026-11-13", "2026-11-13T00:00:00Z", "2027-01-01" }) |date| {
        try std.testing.expect(isFutureDate(date, today));
    }
    try std.testing.expect(!isFutureDate("2026-11-13T00:00:00Z", "2026-11-13"));
    try std.testing.expect(!isFutureDate("", today));
    try std.testing.expect(!isFutureDate("short", today));
}
