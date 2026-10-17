#!/usr/bin/env python3
"""Builds the HTML docs pages and llms-full.txt from the Markdown docs in site/public.

The Markdown files are the source of truth: public/docs/*.md become public/docs/*.html in the
site's look, and index.md plus the docs are concatenated into llms-full.txt.

Run from anywhere: python3 site/tools/build-docs.py
"""
import html
import json
import re
from pathlib import Path

PUBLIC = Path(__file__).resolve().parent.parent / "public"
DOCS = PUBLIC / "docs"
SITE = "https://wbwriter.app"
ORDER = ["quick-start", "faq"]  # nav order
NAV_TITLES = {"quick-start": "Quick start", "faq": "FAQ"}
OG_ALT = ("WBWriter: a black stage board with 'Welcome to the show!' handwritten in white, "
          "next to the headline Write it live. Put it on the wall.")


# ---------------------------------------------------------------- Markdown

def inline(text: str) -> str:
    """Inline Markdown: code, images, links, bold, italic. Everything else is escaped."""
    out, i = [], 0
    pattern = re.compile(r"`([^`]+)`|!\[([^\]]*)\]\(([^)\s]+)\)|\[([^\]]+)\]\(([^)\s]+)\)|\*\*(.+?)\*\*|\*(.+?)\*"
                         r"|(https?://[^\s<]*[^\s<.,;:])|([\w.+-]+@[\w-]+\.[a-z]{2,})")
    for m in pattern.finditer(text):
        out.append(html.escape(text[i:m.start()], quote=False))
        code, alt, src, label, href, bold, em, url, email = m.groups()
        if url is not None:
            out.append(f'<a href="{html.escape(local(url))}">{html.escape(url, quote=False)}</a>')
        elif email is not None:
            out.append(f'<a href="mailto:{html.escape(email)}">{html.escape(email, quote=False)}</a>')
        elif code is not None:
            out.append(f"<code>{html.escape(code, quote=False)}</code>")
        elif src is not None:
            out.append(img_tag(src, alt))
        elif href is not None:
            out.append(f'<a href="{html.escape(local(href))}">{inline(label)}</a>')
        elif bold is not None:
            out.append(f"<strong>{inline(bold)}</strong>")
        else:
            out.append(f"<em>{inline(em)}</em>")
        i = m.end()
    out.append(html.escape(text[i:], quote=False))
    return "".join(out)


def image_size(src: str):
    """Width and height of a local WebP or PNG image, read from its header (no image libraries)."""
    path = PUBLIC / src.lstrip("/")
    if not src.startswith("/") or not path.is_file():
        return None
    data = path.read_bytes()[:64]
    if data[:4] == b"\x89PNG":
        return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        chunk = data[12:16]
        if chunk == b"VP8X":
            return int.from_bytes(data[24:27], "little") + 1, int.from_bytes(data[27:30], "little") + 1
        if chunk == b"VP8 ":
            return int.from_bytes(data[26:28], "little") & 0x3FFF, int.from_bytes(data[28:30], "little") & 0x3FFF
        if chunk == b"VP8L":
            b = int.from_bytes(data[21:25], "little")
            return (b & 0x3FFF) + 1, ((b >> 14) & 0x3FFF) + 1
    return None


def img_tag(src: str, alt: str) -> str:
    src = local(src)
    size = image_size(src)
    dims = f' width="{size[0]}" height="{size[1]}"' if size else ""
    return f'<img src="{html.escape(src)}" alt="{html.escape(alt)}"{dims} loading="lazy" decoding="async">'


def local(url: str) -> str:
    """Site URLs become root-relative so pages also work on preview hosts; .md docs links point to the HTML page."""
    if url.startswith(SITE):
        url = url[len(SITE):] or "/"
    m = re.fullmatch(r"/docs/([a-z0-9-]+)\.md", url)
    if m and m.group(1) in ORDER:
        return f"/docs/{m.group(1)}"
    return url


def render(md: str):
    """Returns (title, summary, body_html) for a doc in this project's Markdown subset."""
    lines = md.splitlines()
    title, summary, blocks, i = "", "", [], 0
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        if line.startswith("```"):
            code = []
            i += 1
            while i < len(lines) and not lines[i].startswith("```"):
                code.append(lines[i])
                i += 1
            i += 1
            blocks.append(f"<pre><code>{html.escape(chr(10).join(code), quote=False)}</code></pre>")
            continue
        m = re.match(r"(#{1,3}) (.*)", line)
        if m:
            level, text = len(m.group(1)), m.group(2)
            if level == 1 and not title:
                title = text
            else:
                slug = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
                blocks.append(f'<h{level} id="{slug}"><a class="anchor" href="#{slug}">{inline(text)}</a></h{level}>')
            i += 1
            continue
        if line.startswith("> "):
            summary = line[2:].strip()
            i += 1
            continue
        if line.startswith("|"):
            rows = []
            while i < len(lines) and lines[i].startswith("|"):
                cells = [c.strip() for c in lines[i].strip().strip("|").split("|")]
                if not all(re.fullmatch(r":?-{3,}:?", c) for c in cells):
                    rows.append(cells)
                i += 1
            head, body = rows[0], rows[1:]
            t = "<thead><tr>" + "".join(f"<th>{inline(c)}</th>" for c in head) + "</tr></thead><tbody>"
            t += "".join("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in r) + "</tr>" for r in body)
            blocks.append(f'<div class="table"><table>{t}</tbody></table></div>')
            continue
        if re.match(r"(- |\d+\. )", line):
            ordered = bool(re.match(r"\d+\. ", line))
            items = []
            while i < len(lines) and re.match(r"(- |\d+\. )", lines[i]):
                items.append(re.sub(r"^(- |\d+\. )", "", lines[i]))
                i += 1
            tag = "ol" if ordered else "ul"
            blocks.append(f"<{tag}>" + "".join(f"<li>{inline(t)}</li>" for t in items) + f"</{tag}>")
            continue
        m = re.fullmatch(r"!\[([^\]]*)\]\(([^)\s]+)\)", line.strip())
        if m:
            alt, src = m.groups()
            blocks.append(f"<figure>{img_tag(src, alt)}<figcaption>{inline(alt)}</figcaption></figure>")
            i += 1
            continue
        para = [line.strip()]
        i += 1
        while i < len(lines) and lines[i].strip() and not re.match(r"(#|>|\||- |\d+\. |```|!\[)", lines[i]):
            para.append(lines[i].strip())
            i += 1
        blocks.append(f"<p>{inline(' '.join(para))}</p>")
    return title, summary, "\n".join(blocks)


# ---------------------------------------------------------------- Page

STYLE = """
:root {
  --bg: #0d0a12; --surface: #16111d; --line: #2a2233; --fg: #f2eef8; --muted: #a59bb3;
  --accent: #b48cff; --brand: #4b1c7a; --brand-ink: #ffffff; --code-bg: #1d1626;
  --font-display: "Archivo", "Helvetica Neue", Arial, sans-serif;
  --font-body: "IBM Plex Sans", "Helvetica Neue", Arial, sans-serif;
  --font-mono: "IBM Plex Mono", ui-monospace, "SF Mono", Menlo, monospace;
  --gutter-l: max(16px, env(safe-area-inset-left, 0px));
  --gutter-r: max(16px, env(safe-area-inset-right, 0px));
  color-scheme: dark;
}
@media (prefers-color-scheme: light) {
  :root:not([data-theme="dark"]) { --bg: #f6f3fa; --surface: #ffffff; --line: #e1d9ea; --fg: #1a1024; --muted: #5e536c; --accent: #4b1c7a; --code-bg: #efe9f6; color-scheme: light; }
}
:root[data-theme="light"] { --bg: #f6f3fa; --surface: #ffffff; --line: #e1d9ea; --fg: #1a1024; --muted: #5e536c; --accent: #4b1c7a; --code-bg: #efe9f6; color-scheme: light; }
* { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; }
body { margin: 0; background: var(--bg); color: var(--fg); font-family: var(--font-body); font-size: 1.0625rem; line-height: 1.65; }
img { max-width: 100%; }
a { color: inherit; }
:focus-visible { outline: 2px solid var(--accent); outline-offset: 3px; border-radius: 6px; }
.wrap { max-width: 1180px; margin: 0 auto; padding-left: var(--gutter-l); padding-right: var(--gutter-r); }
.promo { background: var(--brand); color: #fff; font-size: 0.88rem; }
.promo .wrap { display: flex; justify-content: space-between; align-items: center; gap: 6px 18px; flex-wrap: wrap; padding-block: 8px; }
.promo a { color: #fff; }
.promo-cta { font-weight: 600; text-decoration: none; border-bottom: 1px solid rgba(255,255,255,0.5); }
.top { padding-block: 18px; border-bottom: 1px solid var(--line); }
.top .wrap { display: flex; align-items: center; gap: 16px 22px; flex-wrap: wrap; }
.brand-block { display: grid; }
.brand { display: flex; align-items: center; gap: 10px; text-decoration: none; font-family: var(--font-display); font-weight: 800; font-stretch: 112%; font-size: 1.25rem; }
.brand img { width: 34px; height: 34px; }
.byline { display: flex; align-items: center; gap: 8px; text-decoration: none; color: var(--muted); font-family: var(--font-mono); font-size: 0.66rem; letter-spacing: 0.08em; text-transform: uppercase; margin-left: 44px; }
.byline img { width: 36px; height: 36px; display: block; }
.logo-on-light { display: none !important; }
@media (prefers-color-scheme: light) { :root:not([data-theme="dark"]) .logo-on-dark { display: none !important; } :root:not([data-theme="dark"]) .logo-on-light { display: block !important; } }
:root[data-theme="light"] .logo-on-dark { display: none !important; }
:root[data-theme="light"] .logo-on-light { display: block !important; }
.nav { display: flex; align-items: center; gap: 22px; flex-wrap: wrap; font-size: 0.95rem; margin-left: auto; }
.nav a { text-decoration: none; color: var(--muted); }
.nav a:hover, .nav a[aria-current="page"] { color: var(--fg); }
.nav .btn { background: var(--brand); color: var(--brand-ink); padding: 8px 16px; border-radius: 999px; font-weight: 600; }
.doc { max-width: 780px; padding-block: 48px 24px; }
.eyebrow { font-family: var(--font-mono); font-size: 0.78rem; letter-spacing: 0.12em; text-transform: uppercase; color: var(--muted); margin: 0 0 12px; }
h1, h2, h3 { font-family: var(--font-display); font-stretch: 112%; line-height: 1.1; text-wrap: balance; }
h1 { font-size: clamp(2rem, 5vw, 3rem); font-weight: 800; margin: 0 0 14px; }
h2 { font-size: 1.6rem; font-weight: 700; margin: 48px 0 12px; }
h3 { font-size: 1.2rem; font-weight: 700; margin: 32px 0 8px; }
.anchor { text-decoration: none; }
.anchor:hover::after { content: " #"; color: var(--muted); }
.lede { font-size: 1.25rem; color: var(--muted); margin: 0 0 8px; }
.md-link { font-family: var(--font-mono); font-size: 0.8rem; color: var(--muted); }
p, ul, ol { margin: 0 0 16px; }
li { margin-bottom: 6px; }
code { font-family: var(--font-mono); font-size: 0.86em; background: var(--code-bg); padding: 1px 6px; border-radius: 5px; }
pre { background: var(--code-bg); border: 1px solid var(--line); border-radius: 10px; padding: 14px 16px; overflow-x: auto; }
pre code { background: none; padding: 0; }
.table { overflow-x: auto; margin: 0 0 20px; border: 1px solid var(--line); border-radius: 10px; }
table { border-collapse: collapse; width: 100%; font-size: 0.95rem; }
th, td { text-align: left; vertical-align: top; padding: 10px 14px; border-bottom: 1px solid var(--line); }
th { font-weight: 600; background: var(--surface); }
tr:last-child td { border-bottom: 0; }
figure { margin: 8px 0 28px; }
figure img { display: block; width: 100%; height: auto; border-radius: 10px; border: 1px solid var(--line); background: #000; }
figure img[src*="web-control"] { max-width: 360px; }
figure img[src*="setup-window"] { max-width: 520px; }
figcaption { font-size: 0.88rem; color: var(--muted); margin-top: 8px; }
.pager { display: flex; justify-content: space-between; gap: 16px; flex-wrap: wrap; border-top: 1px solid var(--line); padding-top: 24px; margin-top: 48px; }
.pager a { text-decoration: none; color: var(--accent); font-weight: 600; }
footer { padding-block: 40px; }
footer .wrap { display: flex; justify-content: space-between; gap: 12px 24px; flex-wrap: wrap; font-size: 0.85rem; color: var(--muted); border-top: 1px solid var(--line); padding-top: 24px; }
@media (max-width: 560px) { .nav a:not(.btn) { display: none; } }
"""


def page(slug: str, title: str, summary: str, body: str) -> str:
    nav = "".join(
        f'<a href="/docs/{s}"{" aria-current=\"page\"" if s == slug else ""}>{NAV_TITLES[s]}</a>' for s in ORDER
    )
    idx = ORDER.index(slug)
    prev_link = f'<a href="/docs/{ORDER[idx - 1]}">← {NAV_TITLES[ORDER[idx - 1]]}</a>' if idx > 0 else '<a href="/">← wbwriter.app</a>'
    next_link = f'<a href="/docs/{ORDER[idx + 1]}">{NAV_TITLES[ORDER[idx + 1]]} →</a>' if idx + 1 < len(ORDER) else '<a href="https://github.com/4H1Mzs/wbwriter/releases/latest">Download WBWriter →</a>'
    url = f"{SITE}/docs/{slug}"
    og_image = next(PUBLIC.glob("og-*.png")).name
    ld = {
        "@context": "https://schema.org", "@type": "TechArticle", "headline": title, "description": summary,
        "url": url, "inLanguage": "en", "image": f"{SITE}/{og_image}",
        "about": {"@type": "SoftwareApplication", "name": "WBWriter", "url": f"{SITE}/"},
        "publisher": {"@type": "Organization", "name": "4H1M, z.s.", "url": "https://4h1m.com/"},
    }
    t = html.escape(title)
    d = html.escape(summary)
    # Page title for tabs and shares; add the product name only when the heading lacks it.
    full = t if "WBWriter" in title else f"{t} · WBWriter"
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>{full}</title>
<meta name="description" content="{d}">
<link rel="canonical" href="{url}">
<link rel="alternate" type="text/markdown" href="/docs/{slug}.md" title="{t} (Markdown)">
<meta name="theme-color" content="#4b1c7a">
<meta name="color-scheme" content="dark light">
<link rel="icon" href="/favicon.ico" sizes="48x48">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<meta property="og:type" content="article">
<meta property="og:site_name" content="WBWriter">
<meta property="og:url" content="{url}">
<meta property="og:title" content="{full}">
<meta property="og:description" content="{d}">
<meta property="og:image" content="{SITE}/{og_image}">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="{OG_ALT}">
<meta property="og:locale" content="en_US">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{full}">
<meta name="twitter:description" content="{d}">
<meta name="twitter:image" content="{SITE}/{og_image}">
<script type="application/ld+json">{json.dumps(ld, ensure_ascii=False)}</script>
<link rel="preload" href="/fonts/archivo-var-ad517450.woff2" as="font" type="font/woff2" crossorigin>
<link rel="preload" href="/fonts/plex-sans-var-676a1a97.woff2" as="font" type="font/woff2" crossorigin>
<style>
@font-face{{font-family:"Archivo";font-style:normal;font-weight:500 800;font-stretch:112% 125%;font-display:swap;src:url(/fonts/archivo-var-ad517450.woff2) format("woff2")}}
@font-face{{font-family:"IBM Plex Sans";font-style:normal;font-weight:400 600;font-display:swap;src:url(/fonts/plex-sans-var-676a1a97.woff2) format("woff2")}}
@font-face{{font-family:"IBM Plex Mono";font-style:normal;font-weight:400;font-display:swap;src:url(/fonts/plex-mono-400-0f395b10.woff2) format("woff2")}}
@font-face{{font-family:"IBM Plex Mono";font-style:normal;font-weight:500;font-display:swap;src:url(/fonts/plex-mono-500-a521013b.woff2) format("woff2")}}
@font-face{{font-family:"Caveat";font-style:normal;font-weight:700;font-display:swap;src:url(/fonts/caveat-700-f4ee4fbd.woff2) format("woff2")}}
</style>
<style>{STYLE}</style>
</head>
<body>
<div class="promo"><div class="wrap">
  <p style="margin:0">A free, open-source tool by <a href="https://4h1m.com/"><strong>4H1M Production</strong></a></p>
  <a class="promo-cta" href="https://www.darujme.cz/4h1m">Support 4H1M →</a>
</div></div>
<header class="top"><div class="wrap">
  <div class="brand-block">
    <a class="brand" href="/"><img src="/img/wbwriter-mark-68-9c17d8d8.webp" alt="" width="34" height="34">WBWriter</a>
    <a class="byline" href="https://4h1m.com/" aria-label="Open-source tool by 4H1M Production">
      <span>Open-source tool by</span>
      <img class="logo-on-dark" src="/img/4h1m-white-72-5bca41ed.webp" alt="4H1M Production" width="36" height="36">
      <img class="logo-on-light" src="/img/4h1m-black-72-fc75611a.webp" alt="4H1M Production" width="36" height="36">
    </a>
  </div>
  <nav class="nav" aria-label="Docs">{nav}<a class="btn" href="https://github.com/4H1Mzs/wbwriter/releases/latest">Download</a></nav>
</div></header>
<main class="wrap doc">
  <p class="eyebrow">WBWriter docs</p>
  <h1>{inline(title)}</h1>
  <p class="lede">{inline(summary)}</p>
  <p class="md-link"><a href="/docs/{slug}.md">View as Markdown</a></p>
{body}
  <nav class="pager" aria-label="More docs">{prev_link}{next_link}</nav>
</main>
<footer><div class="wrap">
  <span>© 2026 4H1M, z.s. · <a href="/">wbwriter.app</a> · <a href="https://github.com/4H1Mzs/wbwriter">Open source on GitHub</a> · Support: <a href="mailto:simon@4h1m.com">simon@4h1m.com</a></span>
  <span>NDI® is a registered trademark of Vizrt NDI AB.</span>
</div></footer>
</body>
</html>
"""


def main():
    for slug in ORDER:
        title, summary, body = render((DOCS / f"{slug}.md").read_text())
        (DOCS / f"{slug}.html").write_text(page(slug, title, summary, body))
        print(f"docs/{slug}.html")
    parts = [(PUBLIC / "index.md").read_text()] + [(DOCS / f"{s}.md").read_text() for s in ORDER]
    (PUBLIC / "llms-full.txt").write_text("\n\n---\n\n".join(p.strip() for p in parts) + "\n")
    print("llms-full.txt")


if __name__ == "__main__":
    main()
