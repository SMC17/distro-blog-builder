# F5 — Sovereign Data Notebook Surface

Extends `~/Work/lab/blog-builder/`. Drafted 2026-05-06 by Plan
subagent. AGPL-3.0 per `~/LICENSING_STRATEGY.md`. Markdown is the
source of truth; never break that. No client-side JS in rendered
output (modulo Q1).

## 1. Scope vs Hex / Jupyter / Quarto / Observable

We pick the **Quarto-shape lane**, explicitly. Hex (hosted-collab),
Jupyter (`.ipynb` JSON + browser kernel), and Observable (reactive
JS cells) all violate at least one sovereign axis (sovereignty,
no-JS-render, or markdown-as-truth).

| Axis | Hex | Jupyter | Quarto | Observable | **Sovereign Notebook** |
|---|---|---|---|---|---|
| Source format | proprietary JSON | `.ipynb` JSON | markdown (.qmd) | JS/notebook | **plain markdown (.md)** |
| Execution host | cloud | local kernel + browser UI | local CLI | browser JS | **local Zig binary, bwrap-sandboxed** |
| Output rendering | proprietary widgets | browser HTML + JS | static HTML/PDF/docx | client-side reactive JS | **static HTML+SVG, zero client JS** |
| First-class language | Python/SQL | Python/R/Julia | R/Python/Julia | JS | **Zig, then Python/SQL/shell** |
| Determinism | none | none | partial | none | **bit-exact via content-addressed cache** |
| License / cost | SaaS, per-seat | BSD, heavy stack | MIT | MIT | **AGPL-3.0** |
| Single-binary install | no | no | no | no | **yes — one Zig artifact** |

We do **not** pursue real-time multi-user collab (Hex's wedge);
that's out of scope.

## 2. Source format

Notebook mode is opt-in per-file via frontmatter `notebook: true`.
Without it, blog-builder behavior is identical to today (regression-
free for `~/blog`). With it, fenced code blocks gain an option
string after the language tag:

````
```zig run capture=stdout cache=true timeout=30s
const std = @import("std");
pub fn main() !void { ... }
```
````

Block options:

- `run` — execute (absent = display-only).
- `capture=stdout|stdout+stderr|none`.
- `cache=true|false` (default `true`).
- `timeout=<n>s|<n>ms` (default `30s`).
- `id=<slug>` — stable id for cross-block refs and cache stability.
- `depends=<id1,id2>` — pseudo-dependency edges.

Languages first cut: `zig`, `python`, `sql`, `bash`. Anything else
falls through to display-only.

Frontmatter additions:

```
notebook: true
allow_network: false           # default false; blocks the bwrap netns
allow_shell: ["sqlite3","cat"] # allowlist for `bash` blocks
sql_db: data/silver.duckdb     # default DB for `sql` blocks
python_pin: 3.12
```

## 3. Execution sandbox

Each runnable block goes through `src/notebook/exec.zig`, which
builds a `bwrap` argv:

```
bwrap --ro-bind /nix /nix --ro-bind <essay-dir> /work \
      --bind <cache-scratch> /tmp --proc /proc --dev /dev \
      --unshare-all  $( [allow_network] && --share-net ) \
      --die-with-parent --setenv HOME /work \
      --rlimit-as 1073741824 \
      -- <kernel-cmd>
```

Per-language kernels:

- **Zig:** writes block to `/work/.block.zig`, spawns `zig run`.
- **Python:** `python3 /work/.block.py`. Pinned by `python_pin`.
- **SQL:** prefer `duckdb`, fall back to `sqlite3`. Read-only by
  default.
- **Shell:** `bash -c`, top-level command checked against
  `allow_shell` allowlist.

Caps: bwrap rlimits + Zig wall-clock timeout. Hard ceiling: 30s
wall, 1GB RSS, no network unless opted in. Sandbox layout matches
the harness sandbox shape so future hardening (seccomp, landlock)
is reusable.

## 4. Output capture and render

Kernel stdout parsed for an optional `Content-Type:` first-line
header:

- `text/plain` → `<pre class="output">...</pre>`.
- `text/csv` → parse via `src/notebook/csv.zig`, emit sortable HTML
  table with a `<details>` raw-CSV panel and CSV download anchor
  (data: URL, no fetch).
- `application/json` array → same table renderer.
- `image/png;base64` → `<img src="data:image/png;base64,...">`.
- `image/svg+xml` → inline `<svg>...</svg>` (sanitized: drop
  `<script>`, `on*=` attrs).
- `application/vnd.vegalite.v5+json` → render via `vl-convert`
  subprocess to static SVG. **No client-side JS.**

Rendered outputs wrapped in `<figure class="output"
data-block-id="...">` for cross-link.

## 5. Determinism

Cache key = `SHA256(language || "\0" || normalized_options || "\0"
|| block_content || "\0" || depends_chain_hashes || "\0" ||
frontmatter_runtime_keys)`.

Cache file layout: `~/.cache/notebook/<essay-slug>/<block-hash>.{stdout,
stderr,meta.json}`. Meta records `wall_ms`, `rss_kb`, kernel
version, exit code, content-type.

Two consecutive `notebook build foo.md` runs produce **byte-equal**
`public/posts/foo.html`. This is the through-line.

`notebook build --clean` drops the per-essay cache dir.
`notebook build --no-cache` runs without reads but still writes.
`notebook build --verify` re-executes everything, compares to cache,
fails loudly on divergence — the **honesty probe** for non-
determinism creeping in.

## 6. CLI

Extend `src/main.zig`:

- `blog-build` — unchanged today's behavior.
- `blog-build notebook <file.md>` — render one essay (notebook mode).
- `blog-build notebook --all <dir>` — batch.
- `blog-build notebook --watch <dir>` — inotify rebuild loop.
- `blog-build notebook --clean [<slug>]` — drop caches.
- `blog-build notebook --stats` — JSON: per-block timing, cache hit
  rate, sandbox refusals.

Symlink `notebook` → `blog-build` at install gives the user-facing
`notebook build foo.md` shape.

## 7. Integration with blog-builder (extend, don't fork)

New layout under `src/`:

- `src/root.zig` — gains `renderNotebook()` entrypoint.
- `src/notebook/block_opts.zig` — option parser.
- `src/notebook/exec.zig` — bwrap wrapper, per-language kernel
  dispatch.
- `src/notebook/cache.zig` — content-addressed cache I/O.
- `src/notebook/render.zig` — output → HTML for csv/json/png/svg/
  vega.
- `src/notebook/csv.zig` — minimal RFC 4180 reader.

Render path: `parseMdFrontmatter` exposes `notebook: true`; if
absent, today's `renderMarkdown()` runs untouched. If present, the
renderer **switches to a token stream** (instead of line-by-line
emit) so it can intercept fenced blocks with `run` options before
they're emitted as `<pre><code>`. Smallest invasive change to
`root.zig:renderMarkdown` (split fenced-code branch into
`emitDisplayBlock()` vs `emitRunnableBlock()`). Existing tests
still pass.

`build.zig` gains a `notebook` test step and a `notebook` exe alias
to `blog-build`. **One artifact.**

## 8. First customers — PhysicsAlphaDesk and steam

**Essay 1 (PhysicsAlphaDesk):**
`~/Work/PhysicsAlphaDesk/theory/atomic_hierarchy.md` already exists
as prose. Notebook version inserts a Zig block doing comptime-
verified atomic-units calc (Hartree → eV) and a second Zig block
printing derived-constants table. Output: stdout text + CSV table.
Acceptance: prose matches computed numbers exactly; editing prose
without touching code → cache full hit, sub-second rebuild.

**Essay 2 (steam) — the v1 demo:**
"NYISO realtime → silver scarcity per zone, one day". Three blocks:

1. **sql** — reads `data/bronze/nyiso_realtime_zone/date=20260506/realtime_zone.csv`
   via `read_csv_auto`, computes scarcity per zone.
2. **sql** — emits `Content-Type: text/csv` with zone × hour
   scarcity table.
3. **python** — emits Vega-Lite spec; vl-convert → SVG.

Headline acceptance artifact. Lives at
`~/steam/notebooks/scarcity-2026-05-06.md`.

## 9. Acceptance gate

`scripts/notebook-accept.sh`:

1. Build `examples/acceptance/full.md` (Zig + SQL + CSV + Vega-Lite +
   cached re-run).
2. `sha256sum public/posts/full.html` recorded.
3. Re-run; sha256 matches.
4. Block doing `curl https://example.com` → build fails with clear
   sandbox-refusal citing `allow_network: false`.
5. Time the 5-cached-block essay: under 30s wall.
6. `lynx -dump public/posts/full.html` succeeds; tables sortable
   via `:target` (no JS).

Ships as a Zig integration test under `tests/notebook/acceptance.zig`
so `zig build test` runs it.

## 10. Repository plan (extend, don't fork — justification)

`~/Work/lab/blog-builder/` is **750 LOC of Zig** parsing/rendering
that already covers frontmatter, fenced blocks with language tags,
lists, blockquotes, link/image/inline markup, RSS, sitemap,
crossposts, and a 12-test markdown library. Forking costs:

- Second markdown parser to maintain (drift inevitable).
- Second site-frame template to keep in visual sync.
- Second RSS/sitemap pipeline.
- Two binaries on PATH where one suffices.

Extending costs:

- ~600 LOC of new Zig under `src/notebook/`.
- One feature flag (`notebook: true` frontmatter).
- Branched fenced-block emit path (one `if` in `renderMarkdown`).

Strictly additive: every existing test still passes, every existing
`~/blog` post still renders identically. Satisfies no-downgrade rule.

## 11. Open questions for stax

1. **Sortable tables without client JS.** `:target`-CSS multi-render
   inflates HTML by ~Nx. Acceptable for <20 columns. Confirm strict
   no-JS, or allow one inlined audited 60-line vanilla-JS sorter as
   an opt-in?
2. **`vl-convert` provisioning.** Not currently on PATH. Lean: add
   to project's Nix flake. Confirm.
3. **Python kernel pinning.** Adds a flake to blog-builder
   (currently flake-free). Worth it for determinism.
4. **Cache location.** XDG default + `--cache-dir` flag for
   essay-bundled cache.
5. **SQL `write` semantics.** `write=true` requires `cache=false`
   and writes only to designated `<essay-dir>/scratch/` wiped on
   every run.
6. **Versioning the cache format.** Bump cache key on kernel-version
   change; design `kernel_versions.json` now or v2?
