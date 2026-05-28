Changelog
=========

All notable changes to this builder are recorded here. Pre-1.0; API and
flag surface may shift between minor versions.

v0.1.0 - 2026-05-28
-------------------

Initial canonical release. Extracted from `~/blog/tools/blog-builder/`
(the vendored CI copy) which is the more current of the two working
trees that previously held the source. The other tree
(`~/Work/lab/blog-builder/`) was strictly older: it lacked the
`/substrate/` route and the extended substrate frontmatter.

Capabilities at extraction time:

- Reads markdown (`.md`) and hand-curated HTML (`.html`) posts under
  `$BLOG_ROOT/content/posts/`.
- Renders per-post pages, `essays.html` index, RSS 2.0 feed,
  `sitemap.xml`, per-post `*.crosspost.txt` snippets.
- Renders section trees: `/lab/`, `/objects/`, `/workshop/`, `/canon/`,
  `/substrate/`.
- `/substrate/` route groups entries by `fm.lane` over the fixed lane
  vocabulary (`inference`, `validation`, `comms`, `editor`,
  `integration`, `research`) and emits per-project pages with
  quoted-word section markers per `SUBSTRATE_DISTRIBUTION_DESIGN.md`.
- `BLOG_TODAY` env var to force a deterministic "today" for date
  filtering.
- Sandboxed executor + block options module for fenced-code blocks
  (see `src/sandbox.zig`, `src/executor.zig`, `src/block_opts.zig`).

Code footprint at v0.1.0: ~4620 lines of Zig across 5 source files.

Minimum Zig: 0.16.0.
