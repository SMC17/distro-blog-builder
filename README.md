blog-builder
============

Zig 0.16 static-site builder. Reads a content tree, writes a public tree.
The engine behind sunlitmoon.online; reusable on any blog tree with the same
content layout.

What it builds
--------------

Given `$BLOG_ROOT/content/`, the builder writes to `$BLOG_ROOT/public/`:

- `posts/<slug>.html` per-post page wrapped in the site frame
- `posts/<slug>.crosspost.txt` X / LinkedIn / elevator snippets
- `essays.html` index of all posts (newest first)
- `feed.xml` RSS 2.0 with full text
- `sitemap.xml` for crawlers
- `lab/`, `objects/`, `workshop/`, `canon/`, `substrate/` section trees

Sections, source kinds, and frontmatter
---------------------------------------

Two source kinds share one rendering pipeline:

1. Markdown (`.md`) with YAML frontmatter (`---` block). Body covers headers,
   paragraphs, bold/italic/inline code, fenced code (with language tag),
   `[link](url)`, bare URLs, `- ` and `1. ` lists, blockquotes, `---` HR,
   `![alt](url)` images, `--` -> en-dash, `---` -> em-dash.
2. Hand-curated HTML (`.html`) with frontmatter as an HTML comment
   (`<!-- title: ... -->`). The body is bare markup; the same site frame
   wraps it.

Recognized frontmatter keys: `title`, `date`, `summary`, `tags`, `status`,
`lane`, `latest_tag`, `test_count`, `license`, `forgejo_url`, `mirror_url`.
The substrate-section keys drive `/substrate/` cards and per-project pages.

Substrate lanes (`fm.lane`): `inference`, `validation`, `comms`, `editor`,
`integration`, `research`.

Configuration
-------------

| Env var          | Default                  | Purpose                                          |
| ---------------- | ------------------------ | ------------------------------------------------ |
| `BLOG_ROOT`      | `$HOME/blog`             | Project root containing `content/` and `public/` |
| `BLOG_SITE_URL`  | `https://example.invalid`| Canonical base URL for RSS / sitemap / crosspost |
| `BLOG_TODAY`     | system date              | Override "today" for deterministic date filters  |

CLI flags override env: `--root <path>`, `--site-url <url>`, `--force`.

Build
-----

```sh
zig build              # build executable into zig-out/bin/blog-build
zig build run          # build and run against $BLOG_ROOT
zig build test         # unit tests for the markdown library
```

Install:

```sh
zig build install --prefix ~/.local
~/.local/bin/blog-build
```

Provenance
----------

This repo is the canonical extraction of the builder that lived in two
working trees during pre-1.0:

- `~/Work/lab/blog-builder/` original local scratch
- `~/blog/tools/blog-builder/` vendored copy for CI self-containment

The vendored copy received the `/substrate/` route plus extended
frontmatter (`renderSubstrateIndex`, `renderSubstrateEntry`,
`substrate_lanes`) during the blog substrate-route work. v0.1.0 here is
that vendored tree promoted to its own sovereign repo. Both consumers
now pull this repo as a git submodule.

License
-------

AGPL-3.0-or-later. See `LICENSE`.
