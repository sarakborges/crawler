#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "\${BASH_SOURCE[0]}")" && pwd)"

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

exec "\${PYTHON[@]}" - "$ROOT_DIR" <<'PY'
from __future__ import annotations

import json
import os
import re
import sys
import tempfile
import unicodedata
from collections import Counter
from difflib import SequenceMatcher
from pathlib import Path
from typing import Any

ROOT = Path(sys.argv[1]).resolve()
JOBS_FILE = ROOT / "jobs.json"
CATALOG_FILE = ROOT / "catalog.json"

# Tolerância conservadora para não agrupar cargos apenas relacionados.
SIMILARITY_THRESHOLD = 0.86

STOP_WORDS = {
    "a", "as", "o", "os", "um", "uma", "uns", "umas",
    "de", "da", "das", "do", "dos", "e", "em", "na", "nas",
    "no", "nos", "para", "por", "com", "the", "and", "of", "in",
}

# Senioridade e modalidade não alteram a família principal do cargo.
LEVEL_WORDS = {
    "jr", "junior", "juniora", "pl", "pleno", "plena",
    "sr", "senior", "seniora", "trainee", "estagio",
    "estagiario", "estagiaria", "aprendiz", "intern",
}

WORD_ALIASES = {
    "desenvolvedora": "desenvolvedor",
    "programadora": "programador",
    "analista": "analista",
    "dev": "desenvolvedor",
    "developer": "desenvolvedor",
    "desenvolvedor": "desenvolvedor",
    "front end": "frontend",
    "back end": "backend",
    "full stack": "fullstack",
    "dot net": "dotnet",
    "c sharp": "csharp",
    "c plus plus": "cpp",
    "ui ux": "uiux",
    "ux ui": "uiux",
}


def normalize_title(value: Any) -> str:
    if not isinstance(value, str):
        return ""

    text = unicodedata.normalize("NFKD", value.casefold())
    text = "".join(char for char in text if not unicodedata.combining(char))

    text = re.sub(r"\bfront[\s_-]*end\b", " frontend ", text)
    text = re.sub(r"\bback[\s_-]*end\b", " backend ", text)
    text = re.sub(r"\bfull[\s_-]*stack\b", " fullstack ", text)
    text = re.sub(r"\.net\b", " dotnet ", text)
    text = re.sub(r"\bc\s*#\b", " csharp ", text)
    text = re.sub(r"\bc\s*\+\s*\+\b", " cpp ", text)

    text = re.sub(r"[^a-z0-9]+", " ", text)
    words = [word for word in text.split() if word not in STOP_WORDS and word not in LEVEL_WORDS]

    normalized = " ".join(words)
    for alias, canonical in WORD_ALIASES.items():
        normalized = re.sub(
            rf"\b{re.escape(alias)}\b",
            canonical,
            normalized,
        )
    return re.sub(r"\s+", " ", normalized).strip()


def similarity(left: str, right: str) -> float:
    if not left or not right:
        return 0.0
    if left == right:
        return 1.0

    sequence_score = SequenceMatcher(None, left, right, autojunk=False).ratio()
    left_words = set(left.split())
    right_words = set(right.split())
    union = left_words | right_words
    token_score = len(left_words & right_words) / len(union) if union else 0.0

    # Uma sequência muito curta não deve ganhar correspondência por uma palavra comum.
    if min(len(left_words), len(right_words)) <= 1:
        token_score *= 0.75

    return max(sequence_score, token_score)


def load_jobs() -> list[dict[str, Any]]:
    if not JOBS_FILE.is_file():
        raise RuntimeError("jobs.json não existe. Execute dedup.sh antes de catalog.sh.")

    try:
        payload = json.loads(JOBS_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError(f"Não foi possível ler jobs.json: {error}") from error

    if isinstance(payload, dict) and isinstance(payload.get("jobs"), list):
        payload = payload["jobs"]

    if not isinstance(payload, list):
        raise RuntimeError("jobs.json precisa conter uma lista de vagas.")

    jobs: list[dict[str, Any]] = []
    seen_ids: set[int] = set()

    for index, job in enumerate(payload):
        if not isinstance(job, dict):
            raise RuntimeError(f"A vaga na posição {index} não é um objeto JSON.")

        title = job.get("title")
        if not isinstance(title, str) or not title.strip():
            raise RuntimeError(f"A vaga na posição {index} não possui título válido.")

        raw_id = job.get("id")
        try:
            job_id = int(raw_id)
        except (TypeError, ValueError):
            raise RuntimeError(f"A vaga '{title}' não possui ID numérico válido.")

        if job_id in seen_ids:
            raise RuntimeError(f"ID de vaga duplicado em jobs.json: {job_id}")
        seen_ids.add(job_id)

        normalized = normalize_title(title)
        if not normalized:
            raise RuntimeError(f"Não foi possível normalizar o título da vaga {job_id}: {title}")

        jobs.append({
            "id": job_id,
            "title": title.strip(),
            "normalized_title": normalized,
        })

    jobs.sort(key=lambda item: item["id"])
    return jobs


def choose_representative(titles: list[str]) -> str:
    counts = Counter(titles)
    first_position: dict[str, int] = {}
    for index, title in enumerate(titles):
        first_position.setdefault(title, index)
    return min(
        counts,
        key=lambda title: (-counts[title], first_position[title], title.casefold()),
    )


def build_catalog(jobs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    groups: list[dict[str, Any]] = []

    for job in jobs:
        best_group: int | None = None
        best_score = 0.0

        for index, group in enumerate(groups):
            # Compara com os títulos já vistos no grupo, não apenas com o título exibido.
            score = max(
                similarity(job["normalized_title"], existing_title)
                for existing_title in group["normalized_titles"]
            )
            if score >= SIMILARITY_THRESHOLD and score > best_score:
                best_group = index
                best_score = score

        if best_group is None:
            groups.append({
                "id": len(groups) + 1,
                "titles": [job["title"]],
                "normalized_titles": [job["normalized_title"]],
                "jobs": [job["id"]],
            })
        else:
            group = groups[best_group]
            group["titles"].append(job["title"])
            group["normalized_titles"].append(job["normalized_title"])
            group["jobs"].append(job["id"])

    catalog = []
    for group in groups:
        catalog.append({
            "id": group["id"],
            "title": choose_representative(group["titles"]),
            "jobs": group["jobs"],
        })
    return catalog


def save_catalog(catalog: list[dict[str, Any]]) -> None:
    payload = json.dumps(catalog, ensure_ascii=False, indent=2) + "\n"
    fd, temporary_path = tempfile.mkstemp(
        prefix=".catalog.",
        suffix=".tmp",
        dir=ROOT,
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as output:
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_path, CATALOG_FILE)
    finally:
        try:
            os.unlink(temporary_path)
        except FileNotFoundError:
            pass

    # Confirma que o arquivo gravado é JSON válido antes de encerrar.
    verified = json.loads(CATALOG_FILE.read_text(encoding="utf-8"))
    if verified != catalog:
        raise RuntimeError("A validação de catalog.json falhou.")


def main() -> int:
    jobs = load_jobs()
    catalog = build_catalog(jobs)
    save_catalog(catalog)

    print(f"Vagas analisadas: {len(jobs)}")
    print(f"Grupos de títulos: {len(catalog)}")
    print(f"Arquivo gerado: {CATALOG_FILE}")
    print("jobs.json foi preservado.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"ERRO: {error}", file=sys.stderr)
        raise SystemExit(1)
PY
