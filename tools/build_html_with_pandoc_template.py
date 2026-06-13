import argparse
import hashlib
import re
import subprocess
import tempfile
from pathlib import Path


def run_pandoc(
    md_path: Path,
    out_path: Path,
    title: str,
    template_path: Path,
    toc_depth: int,
    highlight_style: str,
) -> None:
    cmd = [
        "pandoc",
        str(md_path),
        "-f",
        "gfm",
        "-t",
        "html5",
        "--standalone",
        "--template",
        str(template_path),
        "--toc",
        "--toc-depth",
        str(toc_depth),
        "--syntax-highlighting",
        highlight_style,
        "--metadata",
        f"title={title}",
        "-o",
        str(out_path),
    ]

    result = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8")
    if result.returncode != 0:
        raise RuntimeError(f"pandoc failed for {md_path}: {result.stderr.strip()}")


RUNTIME_DIR_NAME = "_docs_runtime"


def write_runtime_asset(out_path: Path, prefix: str, suffix: str, content: str) -> str:
    asset_dir = out_path.parent / RUNTIME_DIR_NAME
    asset_dir.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256(content.encode("utf-8")).hexdigest()[:12]
    filename = f"{prefix}.{digest}.{suffix}"
    asset_path = asset_dir / filename
    asset_path.write_text(content, encoding="utf-8")
    return f"{RUNTIME_DIR_NAME}/{filename}"


def replace_tag_by_id(html: str, tag: str, element_id: str, replacement: str) -> str:
    pattern = re.compile(
        rf"\s*<{tag}\s+id=[\"']{re.escape(element_id)}[\"']>\s*.*?\s*</{tag}>",
        re.DOTALL | re.IGNORECASE,
    )
    new_html, count = pattern.subn("\n" + replacement, html, count=1)
    if count != 1:
        raise RuntimeError(f"could not replace <{tag} id=\"{element_id}\">")
    return new_html


def link_stylesheet(html: str, element_id: str, href: str) -> str:
    return replace_tag_by_id(
        html,
        "style",
        element_id,
        f'  <link rel="stylesheet" href="{href}" />',
    )


def link_script(html: str, element_id: str, src: str) -> str:
    return replace_tag_by_id(
        html,
        "script",
        element_id,
        f'  <script src="{src}"></script>',
    )


def externalize_style_by_id(out_path: Path, element_id: str, prefix: str) -> None:
    html = out_path.read_text(encoding="utf-8", errors="ignore")
    pattern = re.compile(
        rf"<style\s+id=[\"']{re.escape(element_id)}[\"']>\s*(.*?)\s*</style>",
        re.DOTALL | re.IGNORECASE,
    )
    match = pattern.search(html)
    if not match:
        raise RuntimeError(f"style block not found: {element_id}")

    href = write_runtime_asset(out_path, prefix, "css", match.group(1).strip() + "\n")
    html = link_stylesheet(html, element_id, href)
    out_path.write_text(html, encoding="utf-8")


def externalize_script_by_id(out_path: Path, element_id: str, prefix: str) -> None:
    html = out_path.read_text(encoding="utf-8", errors="ignore")
    pattern = re.compile(
        rf"<script\s+id=[\"']{re.escape(element_id)}[\"']>\s*(.*?)\s*</script>",
        re.DOTALL | re.IGNORECASE,
    )
    match = pattern.search(html)
    if not match:
        raise RuntimeError(f"script block not found: {element_id}")

    src = write_runtime_asset(out_path, prefix, "js", match.group(1).strip() + "\n")
    html = link_script(html, element_id, src)
    out_path.write_text(html, encoding="utf-8")


def inject_local_pinyin_match(out_path: Path) -> None:
    token = "__PINYIN_MATCH_INLINE__"
    html = out_path.read_text(encoding="utf-8", errors="ignore")
    if token not in html:
        return

    vendor_path = Path(__file__).resolve().parent / "vendor" / "pinyin-match.main.js"
    if vendor_path.exists():
        js = vendor_path.read_text(encoding="utf-8", errors="ignore")
    else:
        # Graceful fallback: keep runtime safe even if vendor file is missing.
        js = "window.PinyinMatch = window.PinyinMatch || null;"

    html = html.replace(token, js)
    out_path.write_text(html, encoding="utf-8")


def inject_local_github_markdown_css(out_path: Path) -> None:
    token = "__GITHUB_MARKDOWN_CSS_INLINE__"
    html = out_path.read_text(encoding="utf-8", errors="ignore")
    if token not in html:
        return

    vendor_path = Path(__file__).resolve().parent / "vendor" / "github-markdown.min.css"
    if vendor_path.exists():
        css = vendor_path.read_text(encoding="utf-8", errors="ignore")
    else:
        raise RuntimeError(f"missing required vendor css: {vendor_path}")

    html = html.replace(token, css)
    out_path.write_text(html, encoding="utf-8")


def externalize_runtime_assets(out_path: Path) -> None:
    externalize_style_by_id(out_path, "github-markdown-css", "github-markdown")
    externalize_style_by_id(out_path, "docs-runtime-css", "docs-runtime")
    externalize_script_by_id(out_path, "pinyin-match-js", "pinyin-match")
    externalize_script_by_id(out_path, "docs-runtime-js", "docs-runtime")


def infer_code_lang(block_lines: list[str]) -> str:
    non_empty = [ln.strip() for ln in block_lines if ln.strip()]
    if not non_empty:
        return ""

    first = non_empty[0]
    upper_first = first.upper()

    if upper_first.startswith(("GET ", "POST ", "PUT ", "DELETE ", "PATCH ", "HEAD ", "OPTIONS ")):
        return "http"

    if first.startswith(("{", "[")):
        body = "\n".join(non_empty[:30])
        if ":" in body:
            return "json"

    joined = "\n".join(non_empty[:60])
    upper_joined = joined.upper()
    if "SELECT " in upper_joined or "INSERT INTO " in upper_joined or "UPDATE " in upper_joined or "DELETE FROM " in upper_joined:
        return "sql"

    if "public class " in joined or "private " in joined or "implements " in joined:
        return "java"

    if first.startswith("#!/bin/bash") or first.startswith("#!/usr/bin/env bash") or first.startswith("curl "):
        return "bash"

    return ""


def normalize_fenced_code_lang(md_text: str) -> str:
    lines = md_text.splitlines(keepends=False)
    out: list[str] = []
    i = 0
    n = len(lines)

    while i < n:
        line = lines[i]
        stripped = line.lstrip()
        indent = line[: len(line) - len(stripped)]

        if stripped.startswith("```"):
            fence = stripped[:3]
            info = stripped[3:].strip()
            out.append(line)
            i += 1

            block_start = len(out) - 1
            block_lines: list[str] = []
            while i < n:
                cur = lines[i]
                out.append(cur)
                if cur.lstrip().startswith(fence):
                    break
                block_lines.append(cur)
                i += 1

            if not info:
                lang = infer_code_lang(block_lines)
                if lang:
                    out[block_start] = f"{indent}```{lang}"

            i += 1
            continue

        out.append(line)
        i += 1

    return "\n".join(out) + ("\n" if md_text.endswith("\n") else "")


def main() -> None:
    ap = argparse.ArgumentParser(description="Build html with pandoc + custom docs template")
    ap.add_argument("--md", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--title", default="")
    ap.add_argument("--template", required=True)
    ap.add_argument("--toc-depth", type=int, default=3)
    ap.add_argument("--highlight-style", default="pygments", help="Pandoc highlight style, e.g. none, pygments, tango, kate")
    args = ap.parse_args()

    md_path = Path(args.md)
    out_path = Path(args.out)
    template_path = Path(args.template)

    if not md_path.exists():
        raise SystemExit(f"md not found: {md_path}")
    if not template_path.exists():
        raise SystemExit(f"template not found: {template_path}")
    if args.toc_depth < 1 or args.toc_depth > 6:
        raise SystemExit("toc depth must be in range [1, 6]")

    title = args.title.strip() or md_path.stem
    normalized = normalize_fenced_code_lang(md_path.read_text(encoding="utf-8", errors="ignore"))
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", suffix=".md", delete=False) as tmp:
        tmp.write(normalized)
        tmp_md_path = Path(tmp.name)

    try:
        run_pandoc(
            md_path=tmp_md_path,
            out_path=out_path,
            title=title,
            template_path=template_path,
            toc_depth=args.toc_depth,
            highlight_style=args.highlight_style,
        )
        inject_local_github_markdown_css(out_path)
        inject_local_pinyin_match(out_path)
        externalize_runtime_assets(out_path)
    finally:
        try:
            tmp_md_path.unlink(missing_ok=True)
        except Exception:
            pass
    print(f"generated: {out_path}")


if __name__ == "__main__":
    main()
