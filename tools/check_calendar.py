#!/usr/bin/env python3
"""Run the builder against an original fixed-clock content calendar."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin", type=Path, default=Path("zig-out/bin/blog-build"))
    args = parser.parse_args()
    binary = args.bin.resolve()
    with tempfile.TemporaryDirectory(prefix="blog-calendar-") as temp:
        root = Path(temp)
        posts = root / "content/posts"
        posts.mkdir(parents=True)
        for slug, date, draft in [
            ("past", "2026-11-11T00:00:00Z", False),
            ("same-day", "2026-11-12T00:00:00Z", False),
            ("same-late", "2026-11-12T23:59:59Z", False),
            ("tomorrow", "2026-11-13T00:00:00Z", False),
            ("draft-note", "2026-11-12", True),
        ]:
            (posts / (slug + ".md")).write_text(
                f"---\ntitle: {slug}\ndate: {date}\ndraft: {str(draft).lower()}\n"
                f"summary: Original calendar fixture\n---\n\nCalendar body for {slug}.\n")

        def build(day, preview=False):
            env = os.environ | {"BLOG_ROOT": str(root), "BLOG_SITE_URL": "https://example.invalid", "BLOG_TODAY": day}
            subprocess.run([str(binary), *(["--preview"] if preview else [])], env=env,
                           check=True, capture_output=True, timeout=30)

        build("2026-11-12")
        public = root / "public"
        for slug in ["past", "same-day", "same-late"]:
            assert (public / "posts" / (slug + ".html")).is_file(), slug
        assert not (public / "posts/tomorrow.html").exists()
        for name in ["feed.xml", "sitemap.xml"]:
            ET.parse(public / name)
        for name in ["essays.html", "feed.xml", "sitemap.xml"]:
            text = (public / name).read_text()
            assert "same-day" in text and "same-late" in text
            assert "tomorrow" not in text and "draft-note" not in text
        # Drafts retain the existing unlisted-URL policy; they are not private.
        snapshots = {p.relative_to(public): p.read_bytes() for p in public.rglob("*") if p.is_file()}
        build("2026-11-12")
        assert all((public / p).read_bytes() == raw for p, raw in snapshots.items())
        build("2026-11-12", preview=True)
        assert (public / "preview/posts/tomorrow.html").is_file()
        assert not (public / "posts/tomorrow.html").exists()
        build("2026-11-13")
        assert (public / "posts/tomorrow.html").is_file()
        assert "tomorrow" in (public / "feed.xml").read_text()
    print("CALENDAR_TASK_OK same_day=published future=held advance=published preview=isolated repeat=identical xml=parsed drafts=unlisted")


if __name__ == "__main__":
    main()
