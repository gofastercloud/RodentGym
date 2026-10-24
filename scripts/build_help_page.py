#!/usr/bin/env python3
"""Build docs/help.html from Resources/Help.md.

Resources/Help.md is the in-app help. This renders the same text as a page on
the website, so the two stay in sync. Standard library only.

    python3 scripts/build_help_page.py           # write docs/help.html
    python3 scripts/build_help_page.py --check   # exit 1 if docs/help.html is out of date

The format is the small one described in Help.md's header comment:

    # Title | sf.symbol.name | One-line summary
    ## Subheading
    Paragraphs separated by blank lines
    - Bullet
    > Tip, shown as a callout
    | Term | Description
    Inline: **bold**, `key or code`, [link text](url)

Links to x-apple.systempreferences: only work inside macOS, so they are
rendered as bold text instead of links.
"""

import argparse
import html
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Resources" / "Help.md"
OUTPUT = ROOT / "docs" / "help.html"

SITE_URL = "https://gofastercloud.github.io/RodentGym/"
REPO_URL = "https://github.com/gofastercloud/RodentGym"


# ---------------------------------------------------------------- inline

_CODE = re.compile(r"`([^`]+)`")
_LINK = re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)")
_BOLD = re.compile(r"\*\*(.+?)\*\*")


def inline(text):
    """Render inline markup. Code spans are protected from further processing."""
    stash = []

    def keep(fragment):
        stash.append(fragment)
        return "\x00%d\x00" % (len(stash) - 1)

    text = _CODE.sub(lambda m: keep("<code>%s</code>" % html.escape(m.group(1), quote=False)), text)

    def link(m):
        label, url = m.group(1), m.group(2)
        label_html = _BOLD.sub(r"\1", html.escape(label, quote=False))
        if url.startswith("x-apple.systempreferences:"):
            return keep("<strong>%s</strong>" % label_html)
        return keep('<a href="%s">%s</a>' % (html.escape(url, quote=True), label_html))

    text = _LINK.sub(link, text)
    text = html.escape(text, quote=False)
    text = _BOLD.sub(r"<strong>\1</strong>", text)
    return re.sub(r"\x00(\d+)\x00", lambda m: stash[int(m.group(1))], text)


def plain(text):
    """Inline markup stripped to plain text, for slugs and the topic list."""
    text = _CODE.sub(r"\1", text)
    text = _LINK.sub(r"\1", text)
    return _BOLD.sub(r"\1", text)


def slugify(text, used, max_words=6):
    words = re.findall(r"[a-z0-9]+", plain(text).lower())
    slug = "-".join(words[:max_words]) or "section"
    base, n = slug, 2
    while slug in used:
        slug = "%s-%d" % (base, n)
        n += 1
    used.add(slug)
    return slug


# ---------------------------------------------------------------- parsing

def parse(source):
    """Return a list of topics: {title, symbol, summary, id, blocks}."""
    source = re.sub(r"<!--.*?-->", "", source, count=1, flags=re.S)
    topics = []
    used = set()
    para = []

    def blocks():
        if not topics:
            raise ValueError("Help.md has content before the first '# ' topic")
        return topics[-1]["blocks"]

    def flush():
        if para:
            blocks().append(("p", " ".join(para)))
            para.clear()

    def append_group(kind, item):
        # Consecutive bullets, callout lines and rows group into one block.
        b = blocks()
        if b and b[-1][0] == kind:
            b[-1][1].append(item)
        else:
            b.append((kind, [item]))

    for raw in source.splitlines():
        line = raw.rstrip()
        stripped = line.strip()

        if not stripped:
            flush()
            continue

        if line.startswith("# "):
            flush()
            parts = [p.strip() for p in line[2:].split("|")]
            title = parts[0]
            symbol = parts[1] if len(parts) > 1 else ""
            summary = parts[2] if len(parts) > 2 else ""
            topics.append({
                "title": title,
                "symbol": symbol,
                "summary": summary,
                "id": slugify(title, used),
                "blocks": [],
            })
        elif line.startswith("## "):
            flush()
            title = line[3:].strip()
            blocks().append(("h", title, slugify(title, used)))
        elif stripped.startswith("- "):
            flush()
            append_group("ul", stripped[2:].strip())
        elif stripped.startswith(">"):
            flush()
            append_group("callout", stripped[1:].strip())
        elif stripped.startswith("|"):
            flush()
            cells = stripped[1:].split("|", 1)
            term = cells[0].strip()
            desc = cells[1].strip() if len(cells) > 1 else ""
            if desc.endswith("|"):
                desc = desc[:-1].rstrip()
            append_group("rows", (term, desc))
        else:
            para.append(stripped)
    flush()
    return topics


# ---------------------------------------------------------------- rendering

def render_block(block):
    kind = block[0]
    if kind == "p":
        return "<p>%s</p>" % inline(block[1])
    if kind == "h":
        _, title, anchor = block
        return '<h3 id="%s"><a class="heading-link" href="#%s">%s</a></h3>' % (anchor, anchor, inline(title))
    if kind == "ul":
        items = "\n".join("  <li>%s</li>" % inline(item) for item in block[1])
        return "<ul>\n%s\n</ul>" % items
    if kind == "callout":
        return '<aside class="callout"><p>%s</p></aside>' % inline(" ".join(block[1]))
    if kind == "rows":
        rows = "\n".join(
            '  <tr><th scope="row">%s</th><td>%s</td></tr>' % (inline(term), inline(desc))
            for term, desc in block[1]
        )
        return '<table class="rows">\n%s\n</table>' % rows
    raise ValueError("unknown block %r" % kind)


def render_topic(topic):
    tid = topic["id"]
    parts = [
        '<section class="topic" id="%s" aria-labelledby="%s-title" data-symbol="%s">' % (
            tid, tid, html.escape(topic["symbol"], quote=True)),
        "<header>",
        '<h2 id="%s-title"><a class="heading-link" href="#%s">%s</a></h2>' % (tid, tid, inline(topic["title"])),
    ]
    if topic["summary"]:
        parts.append('<p class="summary">%s</p>' % inline(topic["summary"]))
    parts.append("</header>")
    parts.extend(render_block(b) for b in topic["blocks"])
    parts.append("</section>")
    return "\n".join(parts)


PAGE = """<!doctype html>
<!-- Generated by scripts/build_help_page.py from Resources/Help.md. Edit Help.md, then run the script. -->
<html lang="en-AU">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>RodentGym Help</title>
<meta name="description" content="The RodentGym user guide: the main window, fixing common Magic Mouse and Magic Trackpad problems, the Latency Monitor, Hardware Self-Test, settings and shortcuts.">
<link rel="canonical" href="{site}help.html">
<meta name="color-scheme" content="light dark">
<meta name="theme-color" content="#ffffff" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#0b111e" media="(prefers-color-scheme: dark)">
<link rel="icon" type="image/png" href="images/icon.png">
<link rel="apple-touch-icon" href="images/icon.png">
<meta property="og:type" content="website">
<meta property="og:site_name" content="RodentGym">
<meta property="og:title" content="RodentGym Help">
<meta property="og:description" content="The RodentGym user guide, the same one that's built into the app.">
<meta property="og:url" content="{site}help.html">
<meta property="og:image" content="{site}images/help-light.png">
<meta property="og:locale" content="en_AU">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="RodentGym Help">
<meta name="twitter:description" content="The RodentGym user guide, the same one that's built into the app.">
<meta name="twitter:image" content="{site}images/help-light.png">
<link rel="stylesheet" href="style.css">
</head>
<body>
<a class="skip" href="#guide">Skip to the guide</a>

<header class="site-header">
  <div class="wrap">
    <a class="brand" href="./" aria-label="RodentGym home">
      <img src="images/icon.png" alt="" width="30" height="30">
      <span>RodentGym</span>
    </a>
    <nav class="site-nav" aria-label="Main">
      <ul>
        <li class="wide-only"><a href="./#features">Features</a></li>
        <li class="wide-only"><a href="./#privacy">Privacy</a></li>
        <li class="wide-only"><a href="./#install">Install</a></li>
        <li><a href="help.html" aria-current="page">Help</a></li>
        <li><a href="{repo}">GitHub</a></li>
      </ul>
    </nav>
  </div>
</header>

<main id="top">
<div class="wrap help-layout">
<div class="help-intro">
<h1>RodentGym Help</h1>
<p>The same guide that&rsquo;s built into the app, where <kbd>&#x2318;?</kbd> opens it. Settings links that open System Settings only work from inside RodentGym, so here they&rsquo;re shown in bold.</p>
</div>

<nav class="toc" aria-labelledby="toc-title">
<h2 id="toc-title">Topics</h2>
<ol>
{toc}
</ol>
</nav>

<div class="help-content" id="guide">
{topics}
<p class="back-top"><a href="#top">Back to top</a></p>
</div>
</div>
</main>

<footer class="site-footer">
  <div class="wrap">
    <div class="footer-top">
      <a class="brand" href="./">
        <img src="images/icon.png" alt="" width="24" height="24" loading="lazy">
        <span>RodentGym</span>
      </a>
      <nav aria-label="Footer">
        <ul>
          <li><a href="./">Home</a></li>
          <li><a href="{repo}">GitHub</a></li>
          <li><a href="{repo}/discussions">Discussions</a></li>
          <li><a href="{repo}/blob/main/Resources/Help.md">Edit this guide</a></li>
          <li><a href="https://github.com/sponsors/gofastercloud">Sponsor</a></li>
        </ul>
      </nav>
    </div>
    <p>Free and open source under the <a href="{repo}/blob/main/LICENSE">MIT licence</a>. &copy; 2026 gofastercloud.</p>
    <p>RodentGym isn&rsquo;t affiliated with or endorsed by Apple. Magic Mouse, Magic Trackpad, Force Touch and Liquid Glass are trademarks of Apple Inc.</p>
  </div>
</footer>
</body>
</html>
"""


def build(source_text):
    topics = parse(source_text)
    toc = "\n".join('<li><a href="#%s">%s</a></li>' % (t["id"], inline(t["title"])) for t in topics)
    body = "\n\n".join(render_topic(t) for t in topics)
    return PAGE.format(site=SITE_URL, repo=REPO_URL, toc=toc, topics=body)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--check", action="store_true",
                        help="don't write; exit 1 if docs/help.html doesn't match Help.md")
    args = parser.parse_args()

    page = build(SOURCE.read_text(encoding="utf-8"))

    if args.check:
        current = OUTPUT.read_text(encoding="utf-8") if OUTPUT.exists() else ""
        if current != page:
            print("docs/help.html is out of date. Run: python3 scripts/build_help_page.py", file=sys.stderr)
            return 1
        print("docs/help.html is up to date.")
        return 0

    OUTPUT.write_text(page, encoding="utf-8")
    print("Wrote %s" % OUTPUT.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
