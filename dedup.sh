#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$ROOT_DIR/jobs"

if command -v python3 >/dev/null 2>&1; then
  PYTHON=(python3)
elif command -v python >/dev/null 2>&1; then
  PYTHON=(python)
elif command -v py >/dev/null 2>&1; then
  PYTHON=(py -3)
else
  echo "ERRO: Python 3 não encontrado. Instale Python 3.10+ e adicione-o ao PATH." >&2
  exit 127
fi

exec "${PYTHON[@]}" - "$ROOT_DIR" <<'PY'
from __future__ import annotations

import copy
import difflib
import json
import os
import re
import sys
import tempfile
import unicodedata
from pathlib import Path
from typing import Any
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

ROOT = Path(sys.argv[1]).resolve()
JOBS_DIR = (ROOT / "jobs").resolve()
DATABASE = ROOT / "jobs.json"
TRACKING_PARAMS = {
    "fbclid", "gclid", "dclid", "msclkid", "ref", "referrer",
    "source", "campaign", "from", "trk", "trackingid",
}


def normalize(value: Any) -> str:
    if value is None:
        return ""
    text = unicodedata.normalize("NFKD", str(value))
    text = "".join(char for char in text if not unicodedata.combining(char))
    return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9]+", " ", text.casefold())).strip()


def canonical_url(value: Any) -> str:
    if not value:
        return ""
    try:
        parsed = urlsplit(str(value).strip())
        if not parsed.scheme or not parsed.netloc:
            return str(value).strip().rstrip("/").casefold()
        host = parsed.netloc.casefold()
        if host.startswith("www."):
            host = host[4:]
        query = [
            (key, val) for key, val in parse_qsl(parsed.query, keep_blank_values=True)
            if key.casefold() not in TRACKING_PARAMS
            and not key.casefold().startswith("utm_")
        ]
        path = re.sub(r"/+$", "", parsed.path) or "/"
        return urlunsplit((parsed.scheme.casefold(), host, path, urlencode(sorted(query)), "")).rstrip("/")
    except (TypeError, ValueError):
        return str(value).strip().rstrip("/").casefold()


def read_database() -> list[dict[str, Any]]:
    if not DATABASE.exists():
        return []
    try:
        payload = json.loads(DATABASE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError(f"Não foi possível ler jobs.json: {error}") from error
    if isinstance(payload, dict) and isinstance(payload.get("jobs"), list):
        payload = payload["jobs"]
    if not isinstance(payload, list) or not all(isinstance(item, dict) for item in payload):
        raise RuntimeError("jobs.json precisa conter uma lista JSON de objetos de vagas.")
    return copy.deepcopy(payload)


def read_pending_files() -> tuple[list[dict[str, Any]], list[Path]]:
    records: list[dict[str, Any]] = []
    files = sorted(
        (path for path in JOBS_DIR.glob("*.json") if path.is_file()),
        key=lambda path: (not path.stem.isdigit(), int(path.stem) if path.stem.isdigit() else path.stem),
    )
    for path in files:
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise RuntimeError(f"JSON inválido em {path.relative_to(ROOT)}: {error}") from error
        if not isinstance(value, dict):
            raise RuntimeError(f"{path.relative_to(ROOT)} não contém uma vaga em formato de objeto.")
        records.append(value)
    return records, files


def location_key(record: dict[str, Any]) -> str:
    address = record.get("address") or {}
    if not isinstance(address, dict):
        address = {}
    info = record.get("additional_info") or {}
    model = normalize(info.get("work_model") if isinstance(info, dict) else "")
    if model == "remote":
        return "remote"
    return "|".join((normalize(address.get("city")), normalize(address.get("state"))))


def semantic_key(record: dict[str, Any]) -> tuple[str, str, str] | None:
    title = normalize(record.get("title"))
    company = normalize(record.get("company"))
    place = location_key(record)
    if not title or not company or not place.strip("|"):
        return None
    return title, company, place


def source_entry(record: dict[str, Any]) -> dict[str, Any]:
    info = record.get("additional_info") or {}
    if not isinstance(info, dict):
        info = {}
    return {
        "platform": record.get("platform"),
        "url": record.get("url"),
        "external_id": info.get("external_id"),
    }


def merged_ids(record: dict[str, Any]) -> set[int]:
    result: set[int] = set()
    try:
        if record.get("id") is not None:
            result.add(int(record["id"]))
    except (TypeError, ValueError):
        pass
    info = record.get("additional_info") or {}
    if isinstance(info, dict):
        for value in info.get("merged_ids", []):
            try:
                result.add(int(value))
            except (TypeError, ValueError):
                pass
    return result


def descriptions_match(left: dict[str, Any], right: dict[str, Any]) -> bool:
    a = normalize(left.get("description"))
    b = normalize(right.get("description"))
    if not a or not b or a == b:
        return True
    if min(len(a), len(b)) < 100:
        return False
    return difflib.SequenceMatcher(None, a, b, autojunk=False).ratio() >= 0.90


def are_duplicates(left: dict[str, Any], right: dict[str, Any]) -> bool:
    if canonical_url(left.get("url")) and canonical_url(left.get("url")) == canonical_url(right.get("url")):
        return True

    left_info = left.get("additional_info") or {}
    right_info = right.get("additional_info") or {}
    if isinstance(left_info, dict) and isinstance(right_info, dict):
        left_id = str(left_info.get("external_id") or "").strip()
        right_id = str(right_info.get("external_id") or "").strip()
        if left_id and left_id == right_id and normalize(left.get("platform")) == normalize(right.get("platform")):
            return True

    left_key = semantic_key(left)
    return left_key is not None and left_key == semantic_key(right) and descriptions_match(left, right)


def fill_missing(target: Any, incoming: Any) -> Any:
    if target is None or target == "" or target == [] or target == {}:
        return copy.deepcopy(incoming)
    if isinstance(target, dict) and isinstance(incoming, dict):
        result = copy.deepcopy(target)
        for key, value in incoming.items():
            result[key] = fill_missing(result.get(key), value) if key in result else copy.deepcopy(value)
        return result
    if isinstance(target, list) and isinstance(incoming, list):
        result = copy.deepcopy(target)
        for value in incoming:
            if value not in result:
                result.append(copy.deepcopy(value))
        return result
    return copy.deepcopy(target)


def merge_records(existing: dict[str, Any], incoming: dict[str, Any]) -> dict[str, Any]:
    result = copy.deepcopy(existing)
    keeper_id = existing.get("id")
    for key, value in incoming.items():
        if key == "id":
            continue
        if key == "description" and isinstance(value, str):
            current = result.get(key)
            if isinstance(current, str) and len(value.strip()) > len(current.strip()):
                result[key] = value
            elif not current:
                result[key] = value
        else:
            result[key] = fill_missing(result.get(key), value)
    if keeper_id is not None:
        result["id"] = keeper_id

    info = result.get("additional_info")
    if not isinstance(info, dict):
        info = {}
        result["additional_info"] = info
    ids = merged_ids(existing) | merged_ids(incoming)
    if ids:
        info["merged_ids"] = sorted(ids)

    sources: list[dict[str, Any]] = []
    for record in (existing, incoming):
        old_sources = (record.get("additional_info") or {}).get("sources", [])
        candidates = (old_sources if isinstance(old_sources, list) else []) + [source_entry(record)]
        for item in candidates:
            if isinstance(item, dict) and item not in sources:
                sources.append(copy.deepcopy(item))
    if sources:
        info["sources"] = sources
    return result


def indexed_urls(record: dict[str, Any]) -> set[str]:
    values = {canonical_url(record.get("url"))}
    info = record.get("additional_info") or {}
    sources = info.get("sources", []) if isinstance(info, dict) else []
    if isinstance(sources, list):
        values.update(canonical_url(item.get("url")) for item in sources if isinstance(item, dict))
    return {value for value in values if value}


def write_database(records: list[dict[str, Any]]) -> None:
    payload = json.dumps(records, ensure_ascii=False, indent=2) + "\n"
    fd, temp_name = tempfile.mkstemp(prefix=".jobs.", suffix=".tmp", dir=ROOT)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as output:
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temp_name, DATABASE)
    finally:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass
    verified = json.loads(DATABASE.read_text(encoding="utf-8"))
    if not isinstance(verified, list) or len(verified) != len(records):
        raise RuntimeError("Falha na validação de jobs.json; os arquivos individuais foram preservados.")


def main() -> int:
    existing = read_database()
    pending, pending_files = read_pending_files()
    combined = existing + pending

    result: list[dict[str, Any]] = []
    url_index: dict[str, int] = {}
    external_index: dict[tuple[str, str], int] = {}
    semantic_index: dict[tuple[str, str, str], list[int]] = {}
    duplicates = 0

    for record in combined:
        candidates: set[int] = set()
        for url in indexed_urls(record):
            if url in url_index:
                candidates.add(url_index[url])
        info = record.get("additional_info") or {}
        external_id = str(info.get("external_id") or "").strip() if isinstance(info, dict) else ""
        platform = normalize(record.get("platform"))
        if external_id and (platform, external_id) in external_index:
            candidates.add(external_index[(platform, external_id)])
        semantic = semantic_key(record)
        if semantic:
            candidates.update(semantic_index.get(semantic, []))

        matches = [index for index in sorted(candidates) if are_duplicates(result[index], record)]
        if matches:
            keeper = matches[0]
            result[keeper] = merge_records(result[keeper], record)
            duplicates += 1
            for extra in reversed(matches[1:]):
                result[keeper] = merge_records(result[keeper], result[extra])
                result.pop(extra)
                duplicates += 1

            url_index.clear()
            external_index.clear()
            semantic_index.clear()
            for index, item in enumerate(result):
                for item_url in indexed_urls(item):
                    url_index[item_url] = index
                item_info = item.get("additional_info") or {}
                item_external = str(item_info.get("external_id") or "").strip() if isinstance(item_info, dict) else ""
                item_platform = normalize(item.get("platform"))
                if item_external:
                    external_index[(item_platform, item_external)] = index
                item_semantic = semantic_key(item)
                if item_semantic:
                    semantic_index.setdefault(item_semantic, []).append(index)
            continue

        result.append(copy.deepcopy(record))
        index = len(result) - 1
        for item_url in indexed_urls(record):
            url_index[item_url] = index
        if external_id:
            external_index[(platform, external_id)] = index
        if semantic:
            semantic_index.setdefault(semantic, []).append(index)

    result.sort(key=lambda item: (
        int(item.get("id")) if str(item.get("id", "")).isdigit() else 2**63,
        str(item.get("title") or "").casefold(),
    ))

    # jobs.json é o histórico permanente. Primeiro grava e valida; só depois limpa jobs/*.json.
    write_database(result)

    deleted = 0
    failures: list[str] = []
    for path in pending_files:
        if path.parent.resolve() != JOBS_DIR:
            continue
        try:
            path.unlink()
            deleted += 1
        except OSError as error:
            failures.append(f"{path.name}: {error}")

    print(f"Base anterior: {len(existing)} vagas")
    print(f"Arquivos novos processados: {len(pending)}")
    print(f"Duplicatas consolidadas: {duplicates}")
    print(f"Total em jobs.json: {len(result)}")
    print(f"Arquivos individuais removidos: {deleted}")
    print(f"Base permanente preservada: {DATABASE}")

    if failures:
        print("AVISO: alguns arquivos individuais não puderam ser removidos:")
        for failure in failures:
            print(f"  - {failure}")
        return 2
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"ERRO: {error}", file=sys.stderr)
        print("Nenhum arquivo individual foi removido.", file=sys.stderr)
        raise SystemExit(1)
PY
