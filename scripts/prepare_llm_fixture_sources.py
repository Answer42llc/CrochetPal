#!/usr/bin/env python3

import argparse
import json
import sys
import urllib.request
from pathlib import Path


def parse_args() -> argparse.Namespace:
    repo_root = Path(__file__).resolve().parent.parent
    default_manifest = repo_root / "CrochetPalTests/Fixtures/LLM/fixture_manifest.json"
    default_fixture_root = repo_root / "CrochetPalTests/Fixtures/LLM"

    parser = argparse.ArgumentParser(description="Prepare raw LLM fixture sources from PDFs and web pages.")
    parser.add_argument("--manifest", type=Path, default=default_manifest)
    parser.add_argument("--fixture-root", type=Path, default=default_fixture_root)
    parser.add_argument("--downloads-dir", type=Path, default=Path.home() / "Downloads")
    parser.add_argument("--fixtures", nargs="*", help="Only prepare the named fixture(s).")
    parser.add_argument("--overwrite", action="store_true", help="Overwrite existing raw files.")
    parser.add_argument("--timeout", type=int, default=60)
    return parser.parse_args()


def load_manifest(path: Path) -> list[dict]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    fixtures = payload.get("fixtures")
    if not isinstance(fixtures, list) or not fixtures:
        raise ValueError(f"manifest at {path} does not contain any fixtures")
    return fixtures


def extract_pdf_text(path: Path) -> str:
    try:
        from pypdf import PdfReader
    except ImportError as exc:
        raise RuntimeError("missing dependency: pypdf") from exc

    reader = PdfReader(str(path))
    chunks = [(page.extract_text() or "") for page in reader.pages]
    text = "\n".join(chunks).strip()
    if not text:
        raise RuntimeError(f"no extractable text found in {path}")
    return text + "\n"


def fetch_html(url: str, timeout: int) -> str:
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "CrochetPalFixtureBuilder/1.0",
            "Accept": "text/html,application/xhtml+xml"
        }
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        charset = response.headers.get_content_charset() or "utf-8"
        return response.read().decode(charset, errors="replace")


def should_prepare(name: str, selected: set[str] | None) -> bool:
    return selected is None or name in selected


def write_text(path: Path, content: str, overwrite: bool) -> bool:
    if path.exists() and not overwrite:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return True


def prepare_fixture(entry: dict, fixture_root: Path, downloads_dir: Path, overwrite: bool, timeout: int) -> str:
    name = entry["name"]
    source_type = entry["sourceType"]
    fixture_dir = fixture_root / name

    if source_type == "pdf":
        source_files = entry.get("sourceFiles") or []
        if not source_files:
            raise RuntimeError(f"{name}: manifest entry is missing sourceFiles")
        source_path = downloads_dir / source_files[0]
        if not source_path.exists():
            raise FileNotFoundError(f"{name}: missing PDF source {source_path}")
        content = extract_pdf_text(source_path)
        destination = fixture_dir / "raw.txt"
        wrote = write_text(destination, content, overwrite=overwrite)
        action = "wrote" if wrote else "kept"
        return f"{name}: {action} {destination.name} from {source_path.name}"

    if source_type == "web":
        url = entry.get("sourceURL")
        if not url:
            raise RuntimeError(f"{name}: manifest entry is missing sourceURL")
        content = fetch_html(url, timeout=timeout)
        destination = fixture_dir / "raw.html"
        wrote = write_text(destination, content, overwrite=overwrite)
        action = "wrote" if wrote else "kept"
        return f"{name}: {action} {destination.name} from {url}"

    raise RuntimeError(f"{name}: unsupported sourceType {source_type}")


def main() -> int:
    args = parse_args()
    try:
        entries = load_manifest(args.manifest)
        selected = set(args.fixtures) if args.fixtures else None
        for entry in entries:
            name = entry["name"]
            if not should_prepare(name, selected):
                continue
            print(prepare_fixture(entry, args.fixture_root, args.downloads_dir, args.overwrite, args.timeout))
        return 0
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
