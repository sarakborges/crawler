#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

PYTHON=()

python_works() {
  "$@" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' >/dev/null 2>&1
}

if command -v py >/dev/null 2>&1 && python_works py -3; then
  PYTHON=(py -3)
elif command -v python >/dev/null 2>&1 && python_works python; then
  PYTHON=(python)
elif command -v python3 >/dev/null 2>&1 && python_works python3; then
  PYTHON=(python3)
else
  echo "ERRO: não encontrei um interpretador Python 3.10+ funcional." >&2
  echo "Verifique no Git Bash: py -3 --version; python --version; python3 --version" >&2
  exit 127
fi

exec "${PYTHON[@]}" - "$ROOT_DIR" <<'PY'
from __future__ import annotations

import copy
import html
import json
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.robotparser
import urllib.request
from datetime import datetime, timedelta, timezone
from html.parser import HTMLParser
from pathlib import Path
from typing import Any

ROOT = Path(sys.argv[1]).resolve()
DATABASE = ROOT / "jobs.json"
TZ = timezone(timedelta(hours=-3))
NOW = datetime.now(TZ).replace(microsecond=0)
USER_AGENT = "SaraJobCrawler/1.0 (+https://github.com/sarakborges/crawler; public-job-search)"
REQUEST_TIMEOUT = 35
MAX_RETRIES = 5
MAX_RESPONSE_BYTES = 18 * 1024 * 1024
MIN_HOST_DELAY = 1.25

DATE_TEXT = re.compile(
    r"\b(?:\d{1,2}/\d{1,2}/\d{4}|\d{4}-\d{2}-\d{2}|hoje|ontem|today|yesterday|"
    r"há\s+\d+\s+(?:minutos?|horas?|dias?|semanas?|meses?)|"
    r"\d+\s+(?:minutes?|hours?|days?|weeks?)\s+ago)\b",
    re.I,
)
SALARY_TEXT = re.compile(
    r"(?:R\$\s?[\d.]+(?:,\d{2})?(?:\s*(?:a|-)\s*R?\$?\s?[\d.]+(?:,\d{2})?)?)",
    re.I,
)


def log(message: str) -> None:
    print(message, flush=True)


def clean(value: Any) -> str | None:
    if value is None:
        return None
    value = html.unescape(str(value))
    value = re.sub(r"\s+", " ", value).strip()
    return value or None


class TextOnlyParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self.skip_depth = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.casefold() in {"script", "style", "noscript", "svg"}:
            self.skip_depth += 1

    def handle_endtag(self, tag: str) -> None:
        if tag.casefold() in {"script", "style", "noscript", "svg"} and self.skip_depth:
            self.skip_depth -= 1

    def handle_data(self, data: str) -> None:
        if not self.skip_depth:
            text = clean(data)
            if text:
                self.parts.append(text)


def strip_html(value: Any) -> str | None:
    if value is None:
        return None
    parser = TextOnlyParser()
    try:
        parser.feed(str(value))
        parser.close()
        return clean(" ".join(parser.parts))
    except Exception:
        return clean(re.sub(r"<[^>]+>", " ", str(value)))


def parse_date(value: Any) -> tuple[datetime | None, str | None]:
    if value is None:
        return None, None
    if isinstance(value, (int, float)):
        try:
            return datetime.fromtimestamp(value, TZ), "datetime"
        except (ValueError, OSError, OverflowError):
            return None, None
    raw = clean(value)
    if not raw:
        return None, None
    low = raw.casefold()

    if low in {"hoje", "today"}:
        return NOW.replace(hour=12, minute=0, second=0), "date"
    if low in {"ontem", "yesterday"}:
        return (NOW - timedelta(days=1)).replace(hour=12, minute=0, second=0), "date"

    relative = re.search(
        r"(?:há|ha)\s+(\d+)\s+(minuto|minutos|hora|horas|dia|dias|semana|semanas|m[eê]s|meses)",
        low,
    )
    ago = re.search(r"(\d+)\s+(minute|minutes|hour|hours|day|days|week|weeks)\s+ago", low)
    if relative or ago:
        match = relative or ago
        amount, unit = int(match.group(1)), match.group(2)
        if unit.startswith(("minuto", "minute")):
            return NOW - timedelta(minutes=amount), "datetime"
        if unit.startswith(("hora", "hour")):
            return NOW - timedelta(hours=amount), "datetime"
        if unit.startswith(("dia", "day")):
            return (NOW - timedelta(days=amount)).replace(hour=12, minute=0, second=0), "date"
        if unit.startswith(("semana", "week")):
            return (NOW - timedelta(weeks=amount)).replace(hour=12, minute=0, second=0), "date"
        return (NOW - timedelta(days=30 * amount)).replace(hour=12, minute=0, second=0), "date"

    try:
        parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=TZ)
        return parsed.astimezone(TZ), "datetime" if "T" in raw or ":" in raw else "date"
    except ValueError:
        pass

    for fmt in ("%d/%m/%Y", "%d-%m-%Y", "%Y-%m-%d", "%d.%m.%Y"):
        try:
            return datetime.strptime(raw[:10], fmt).replace(hour=12, tzinfo=TZ), "date"
        except ValueError:
            continue
    return None, None


class Node:
    __slots__ = ("tag", "attrs", "children")

    def __init__(self, tag: str, attrs: dict[str, str]):
        self.tag = tag
        self.attrs = attrs
        self.children: list[Node | str] = []

    def text(self) -> str:
        parts: list[str] = []

        def walk(node: Node) -> None:
            for child in node.children:
                if isinstance(child, Node):
                    if child.tag not in {"script", "style", "noscript", "svg"}:
                        walk(child)
                else:
                    parts.append(child)

        walk(self)
        return clean(" ".join(parts)) or ""

    def descendants(self):
        for child in self.children:
            if isinstance(child, Node):
                yield child
                yield from child.descendants()


class HTMLDocument(HTMLParser):
    VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = Node("document", {})
        self.stack = [self.root]
        self.meta: dict[str, str] = {}
        self.jsonld: list[str] = []
        self.script_type = ""
        self.script_parts: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = {key.casefold(): value or "" for key, value in attrs}
        node = Node(tag.casefold(), values)
        self.stack[-1].children.append(node)

        if tag.casefold() == "meta":
            key = (values.get("property") or values.get("name") or values.get("itemprop") or "").casefold()
            if key:
                self.meta[key] = values.get("content", "")
        if tag.casefold() == "script":
            self.script_type = values.get("type", "").casefold()
            self.script_parts = []
        if tag.casefold() not in self.VOID:
            self.stack.append(node)

    def handle_endtag(self, tag: str) -> None:
        tag = tag.casefold()
        if tag == "script" and self.script_type == "application/ld+json":
            raw = "".join(self.script_parts).strip()
            if raw:
                self.jsonld.append(raw)
        for index in range(len(self.stack) - 1, 0, -1):
            if self.stack[index].tag == tag:
                del self.stack[index:]
                break
        if tag == "script":
            self.script_type = ""
            self.script_parts = []

    def handle_data(self, data: str) -> None:
        if self.script_type == "application/ld+json":
            self.script_parts.append(data)
        self.stack[-1].children.append(data)


class RobotsDisallowed(PermissionError):
    pass


class RobotsUnavailable(RuntimeError):
    pass


class RobotsAwareRedirectHandler(urllib.request.HTTPRedirectHandler):
    def __init__(self, fetcher: "Fetcher"):
        super().__init__()
        self.fetcher = fetcher

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        self.fetcher.authorize(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class Fetcher:
    def __init__(self):
        self.robots_cache: dict[str, urllib.robotparser.RobotFileParser | None] = {}
        self.last_request: dict[str, float] = {}
        self.delays: dict[str, float] = {}
        self.opener = urllib.request.build_opener(RobotsAwareRedirectHandler(self))

    def robots(self, url: str) -> urllib.robotparser.RobotFileParser | None:
        parts = urllib.parse.urlsplit(url)
        base = f"{parts.scheme}://{parts.netloc}"
        if base in self.robots_cache:
            return self.robots_cache[base]

        parser = urllib.robotparser.RobotFileParser()
        robots_url = base + "/robots.txt"
        request = urllib.request.Request(robots_url, headers={"User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT) as response:
                body = response.read(1024 * 1024).decode("utf-8", "replace")
            parser.parse(body.splitlines())
            self.robots_cache[base] = parser
            delay = parser.crawl_delay(USER_AGENT) or parser.crawl_delay("*") or 0
            rate = parser.request_rate(USER_AGENT) or parser.request_rate("*")
            if rate and rate.requests:
                delay = max(float(delay), rate.seconds / rate.requests)
            self.delays[base] = max(MIN_HOST_DELAY, float(delay))
            return parser
        except urllib.error.HTTPError as error:
            if error.code == 404:
                parser.parse([])
                self.robots_cache[base] = parser
                self.delays[base] = MIN_HOST_DELAY
                return parser
            self.robots_cache[base] = None
            return None
        except Exception:
            self.robots_cache[base] = None
            return None

    def authorize(self, url: str) -> None:
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise RuntimeError(f"URL não HTTP(S): {url}")
        parser = self.robots(url)
        if parser is None:
            raise RobotsUnavailable("robots.txt não pôde ser verificado")
        if not parser.can_fetch(USER_AGENT, url):
            raise RobotsDisallowed("robots.txt não permite este caminho")

        host = f"{parsed.scheme}://{parsed.netloc}"
        delay = self.delays.get(host, MIN_HOST_DELAY)
        remaining = delay - (time.monotonic() - self.last_request.get(host, 0))
        if remaining > 0:
            time.sleep(remaining)
        self.last_request[host] = time.monotonic()

    def get(self, url: str) -> tuple[str, HTMLDocument]:
        self.authorize(url)
        last_error: Exception | None = None

        for attempt in range(MAX_RETRIES):
            request = urllib.request.Request(url, headers={
                "User-Agent": USER_AGENT,
                "Accept": "text/html,application/xhtml+xml,application/ld+json;q=0.9,*/*;q=0.5",
                "Accept-Language": "pt-BR,pt;q=0.9,en;q=0.7",
            })
            try:
                with self.opener.open(request, timeout=REQUEST_TIMEOUT) as response:
                    raw = response.read(MAX_RESPONSE_BYTES + 1)
                    final_url = response.geturl()
                    charset = response.headers.get_content_charset() or "utf-8"
                if len(raw) > MAX_RESPONSE_BYTES:
                    raise RuntimeError("resposta excedeu o limite de 18 MB")
                document = HTMLDocument()
                document.feed(raw.decode(charset, "replace"))
                document.close()
                return final_url, document
            except urllib.error.HTTPError as error:
                if error.code == 429:
                    header = error.headers.get("Retry-After", "")
                    wait = int(header) if header.isdigit() else min(60, 2 ** attempt)
                    log(f"      HTTP 429; aguardando {wait}s")
                    time.sleep(wait)
                    last_error = error
                    continue
                if 500 <= error.code < 600 and attempt < MAX_RETRIES - 1:
                    wait = min(45, 2 ** attempt)
                    log(f"      HTTP {error.code}; nova tentativa em {wait}s")
                    time.sleep(wait)
                    last_error = error
                    continue
                raise
            except (urllib.error.URLError, TimeoutError, ConnectionError) as error:
                last_error = error
                if attempt < MAX_RETRIES - 1:
                    wait = min(45, 2 ** attempt)
                    log(f"      falha de conexão; nova tentativa em {wait}s")
                    time.sleep(wait)
                    continue
                raise
        raise RuntimeError(f"tentativas esgotadas: {last_error}")


def has_class(node: Node, name: str) -> bool:
    return name in node.attrs.get("class", "").split()


def find_nodes(
    root: Node,
    tag: str | None = None,
    class_name: str | None = None,
    node_id: str | None = None,
    attr_name: str | None = None,
    attr_value: str | None = None,
) -> list[Node]:
    found = []
    for node in root.descendants():
        if tag and node.tag != tag:
            continue
        if class_name and not has_class(node, class_name):
            continue
        if node_id and node.attrs.get("id") != node_id:
            continue
        if attr_name and node.attrs.get(attr_name) != attr_value:
            continue
        found.append(node)
    return found


def find_first(
    root: Node,
    tag: str | None = None,
    class_name: str | None = None,
    node_id: str | None = None,
    attr_name: str | None = None,
    attr_value: str | None = None,
) -> Node | None:
    nodes = find_nodes(root, tag, class_name, node_id, attr_name, attr_value)
    return nodes[0] if nodes else None


def find_job_postings(value: Any) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []

    def walk(item: Any) -> None:
        if isinstance(item, dict):
            raw_types = item.get("@type", [])
            types = raw_types if isinstance(raw_types, list) else [raw_types]
            if any(str(kind).casefold().endswith("jobposting") for kind in types):
                result.append(item)
            for child in item.values():
                walk(child)
        elif isinstance(item, list):
            for child in item:
                walk(child)

    walk(value)
    return result


def jsonld_jobs(document: HTMLDocument) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for raw in document.jsonld:
        try:
            result.extend(find_job_postings(json.loads(raw)))
        except (json.JSONDecodeError, TypeError):
            continue
    return result


def first(value: Any) -> Any:
    return value[0] if isinstance(value, list) and value else value


def address_from(job: dict[str, Any]) -> dict[str, Any]:
    location = first(job.get("jobLocation")) or {}
    address = location.get("address", {}) if isinstance(location, dict) else {}
    address = first(address) or {}
    if not isinstance(address, dict):
        address = {}
    return {
        "street": clean(address.get("streetAddress")),
        "number": None,
        "neighborhood": clean(address.get("addressRegion2") or address.get("addressNeighborhood")),
        "city": clean(address.get("addressLocality")),
        "state": clean(address.get("addressRegion")),
        "postal_code": clean(address.get("postalCode")),
        "country": clean(address.get("addressCountry")),
    }


def numeric(value: Any) -> float | None:
    if value is None or value == "":
        return None
    try:
        return float(str(value).replace(",", "."))
    except (TypeError, ValueError):
        return None


def salary_from_job(job: dict[str, Any]) -> dict[str, Any]:
    empty = {"minimum": None, "maximum": None, "currency": None, "period": None, "raw": None}
    raw = job.get("baseSalary") or job.get("salary")
    if not raw:
        return empty
    if isinstance(raw, str):
        empty["raw"] = clean(raw)
        return empty
    if not isinstance(raw, dict):
        empty["raw"] = clean(raw)
        return empty

    value = raw.get("value", raw)
    if not isinstance(value, dict):
        value = {"value": value}
    minimum = numeric(value.get("minValue", value.get("value")))
    maximum = numeric(value.get("maxValue", value.get("value")))
    currency = clean(raw.get("currency") or value.get("currency"))
    period = clean(value.get("unitText") or raw.get("unitText"))
    raw_text = raw.get("description") or " ".join(str(x) for x in (minimum, maximum, currency, period) if x is not None)
    return {"minimum": minimum, "maximum": maximum, "currency": currency, "period": period, "raw": clean(raw_text)}


def salary_from_text(text: str) -> dict[str, Any] | None:
    match = SALARY_TEXT.search(text)
    if not match:
        return None
    raw = match.group(0)
    values = re.findall(r"\d[\d.]*,\d{2}|\d[\d.]*", raw.replace("R$", ""))
    numbers = []
    for item in values:
        normalized = item.replace(".", "").replace(",", ".")
        value = numeric(normalized)
        if value is not None:
            numbers.append(value)
    return {
        "minimum": numbers[0] if numbers else None,
        "maximum": numbers[1] if len(numbers) > 1 else (numbers[0] if numbers else None),
        "currency": "BRL",
        "period": None,
        "raw": raw,
    }


def value_to_text(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, list):
        return ", ".join(str(item) for item in value if item is not None)
    if isinstance(value, dict):
        return clean(value.get("name") or value.get("value") or value.get("description") or json.dumps(value, ensure_ascii=False))
    return clean(value)


def company_from_job(job: dict[str, Any]) -> str | None:
    organization = job.get("hiringOrganization") or job.get("organization") or {}
    if isinstance(organization, list):
        organization = first(organization) or {}
    if isinstance(organization, dict):
        return clean(organization.get("name"))
    return clean(organization)


def work_model_from(job: dict[str, Any], body_text: str) -> str | None:
    location_type = value_to_text(job.get("jobLocationType") or job.get("workplaceType") or "")
    text = f"{location_type or ''} {body_text[:5000]}".casefold()
    if re.search(r"telecommute|remote|remoto|home\s*office", text):
        return "remote"
    if re.search(r"h[ií]brido|hybrid", text):
        return "hybrid"
    if re.search(r"on.?site|presencial", text):
        return "on_site"
    return None


def text_from_selectors(document: HTMLDocument, selectors: list[tuple[str | None, str | None, str | None, str | None]]) -> str | None:
    for tag, class_name, attr_name, attr_value in selectors:
        node = find_first(document.root, tag=tag, class_name=class_name, attr_name=attr_name, attr_value=attr_value)
        if node:
            value = clean(node.text())
            if value:
                return value
    return None


def extract_detail(url: str, document: HTMLDocument) -> dict[str, Any]:
    body_text = document.root.text()
    structured_candidates = jsonld_jobs(document)
    job = structured_candidates[0] if structured_candidates else {}

    title = clean(job.get("title")) or text_from_selectors(document, [
        ("h1", None, None, None),
        (None, "job-title", None, None),
        (None, "cargo", None, None),
    ])
    if not title:
        title = clean(document.meta.get("og:title") or document.meta.get("twitter:title"))

    description = strip_html(job.get("description"))
    if not description:
        description = text_from_selectors(document, [
            (None, "job-description", None, None),
            (None, "description", None, None),
            (None, "job-description-content", None, None),
            (None, "descricao-vaga", None, None),
            (None, None, "itemprop", "description"),
        ])
    if not description:
        description = strip_html(document.meta.get("description") or document.meta.get("og:description"))

    company = company_from_job(job) or text_from_selectors(document, [
        (None, "job-company", None, None),
        (None, "company-name", None, None),
        (None, "emprVaga", None, None),
        (None, "companyName", None, None),
        (None, None, "data-testid", "company-name"),
    ])

    published_raw = job.get("datePosted") or document.meta.get("article:published_time") or document.meta.get("date")
    if not published_raw:
        time_node = find_first(document.root, tag="time")
        if time_node:
            published_raw = time_node.attrs.get("datetime") or clean(time_node.text())
    if not published_raw:
        match = DATE_TEXT.search(body_text)
        published_raw = match.group(0) if match else None
    published, precision = parse_date(published_raw)

    salary = salary_from_job(job)
    if salary.get("raw") is None:
        salary = salary_from_text(body_text) or salary

    schedule = clean(job.get("workHours") or job.get("schedule"))
    if not schedule:
        match = re.search(r"(?:escala|jornada|hor[aá]rio)\s*:?\s*([^.;\n]{3,120})", body_text, re.I)
        schedule = clean(match.group(0)) if match else None

    address = address_from(job)
    if not any(address.values()):
        location_text = text_from_selectors(document, [
            (None, "job-location", None, None),
            (None, "vaga-local", None, None),
            (None, "location", None, None),
            (None, None, "data-testid", "text-location"),
            (None, None, "data-testid", "job-location"),
        ]) or ""
        if re.search(r"porto\s+alegre", location_text, re.I):
            address["city"] = "Porto Alegre"
            address["state"] = "RS"
            address["country"] = "BR"
        elif re.search(r"remoto|remote|home\s*office", location_text, re.I):
            address["country"] = "BR"

    model = work_model_from(job, body_text)

    additional: dict[str, Any] = {}
    for source_key, target_key in (
        ("identifier", "structured_identifier"),
        ("validThrough", "valid_through"),
        ("experienceRequirements", "experience_requirements"),
        ("qualifications", "qualifications"),
        ("responsibilities", "responsibilities"),
        ("skills", "skills"),
        ("industry", "industry"),
        ("jobLocationType", "job_location_type"),
        ("applicantLocationRequirements", "applicant_location_requirements"),
        ("directApply", "direct_apply"),
        ("educationRequirements", "education_requirements"),
    ):
        if job.get(source_key) is not None:
            additional[target_key] = job[source_key]

    return {
        "title": title,
        "description": description,
        "company": company,
        "published_at": published.isoformat() if published else None,
        "date_precision": precision,
        "salary": salary,
        "schedule": schedule,
        "address": address,
        "work_model": model,
        "employment_type": value_to_text(job.get("employmentType")),
        "external_id": value_to_text(job.get("identifier")),
        "additional_info": additional,
        "structured": bool(structured_candidates),
        "resolved_url": url,
    }


def nonempty(value: Any) -> bool:
    return value is not None and value != "" and value != [] and value != {}


def merge_address(existing: Any, incoming: Any) -> dict[str, Any]:
    result = copy.deepcopy(existing) if isinstance(existing, dict) else {}
    if not isinstance(incoming, dict):
        return result
    for key, value in incoming.items():
        if nonempty(value) and not nonempty(result.get(key)):
            result[key] = value
    return result


def merge_salary(existing: Any, incoming: Any) -> dict[str, Any]:
    result = copy.deepcopy(existing) if isinstance(existing, dict) else {}
    if not isinstance(incoming, dict):
        return result
    for key, value in incoming.items():
        if not nonempty(value):
            continue
        if not nonempty(result.get(key)):
            result[key] = value
        elif key == "raw" and len(str(value)) > len(str(result.get(key))):
            result[key] = value
    return result


def apply_detail(record: dict[str, Any], detail: dict[str, Any]) -> None:
    for key in ("title", "company"):
        value = clean(detail.get(key))
        if value:
            record[key] = value

    description = clean(detail.get("description"))
    current_description = clean(record.get("description"))
    if description and (not current_description or len(description) > len(current_description)):
        record["description"] = description

    if detail.get("published_at"):
        record["published_at"] = detail["published_at"]

    record["salary"] = merge_salary(record.get("salary"), detail.get("salary"))
    if nonempty(detail.get("schedule")):
        record["schedule"] = detail["schedule"]
    record["address"] = merge_address(record.get("address"), detail.get("address"))

    info = record.setdefault("additional_info", {})
    if not isinstance(info, dict):
        info = {}
        record["additional_info"] = info
    if nonempty(detail.get("work_model")):
        info["work_model"] = detail["work_model"]
    if nonempty(detail.get("employment_type")):
        info["employment_type"] = detail["employment_type"]
    if nonempty(detail.get("external_id")) and not nonempty(info.get("external_id")):
        info["external_id"] = detail["external_id"]
    if detail.get("date_precision"):
        info["date_precision"] = detail["date_precision"]
    info["enriched_at"] = NOW.isoformat()
    info["enrichment_status"] = "completed"
    info["enrichment_structured_data"] = bool(detail.get("structured"))
    structured_info = detail.get("additional_info") or {}
    if isinstance(structured_info, dict):
        for key, value in structured_info.items():
            if nonempty(value) and not nonempty(info.get(key)):
                info[key] = value


def load_database() -> list[dict[str, Any]]:
    if not DATABASE.is_file():
        raise RuntimeError("jobs.json não existe. Execute dedup.sh antes de enrich.sh.")
    try:
        payload = json.loads(DATABASE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError(f"Não foi possível ler jobs.json: {error}") from error

    if isinstance(payload, dict) and isinstance(payload.get("jobs"), list):
        payload = payload["jobs"]
    if not isinstance(payload, list) or not all(isinstance(item, dict) for item in payload):
        raise RuntimeError("jobs.json precisa conter uma lista de objetos de vagas.")
    return payload


def write_database(records: list[dict[str, Any]]) -> None:
    payload = json.dumps(records, ensure_ascii=False, indent=2) + "\n"
    fd, temp_path = tempfile.mkstemp(prefix=".jobs-enrich.", suffix=".tmp", dir=ROOT)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as output:
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temp_path, DATABASE)
    finally:
        try:
            os.unlink(temp_path)
        except FileNotFoundError:
            pass

    verified = json.loads(DATABASE.read_text(encoding="utf-8"))
    if not isinstance(verified, list) or len(verified) != len(records):
        raise RuntimeError("Falha na validação de jobs.json.")


def job_urls(record: dict[str, Any]) -> list[str]:
    urls: list[str] = []
    primary = record.get("url")
    if isinstance(primary, str) and primary.startswith(("http://", "https://")):
        urls.append(primary)
    info = record.get("additional_info") or {}
    sources = info.get("sources", []) if isinstance(info, dict) else []
    if isinstance(sources, list):
        for source in sources:
            if isinstance(source, dict):
                value = source.get("url")
                if isinstance(value, str) and value.startswith(("http://", "https://")) and value not in urls:
                    urls.append(value)
    return urls


def main() -> int:
    records = load_database()
    if not records:
        log("[INFO] jobs.json não contém vagas. Nada para enriquecer.")
        return 0

    fetcher = Fetcher()
    succeeded = 0
    skipped = 0
    failed = 0
    log(f"[INÍCIO] Enriquecimento de {len(records)} vagas em jobs.json.")

    for index, record in enumerate(records, start=1):
        job_id = record.get("id", "?")
        title = clean(record.get("title")) or "(sem título)"
        urls = job_urls(record)
        log(f"\n[VAGA {index}/{len(records)}] ID {job_id}: {title}")

        if not urls:
            log("  [IGNORADA] A vaga não possui URL HTTP(S).")
            info = record.setdefault("additional_info", {})
            if isinstance(info, dict):
                info["enrichment_status"] = "no_url"
                info["enriched_at"] = NOW.isoformat()
            skipped += 1
            write_database(records)
            continue

        per_url_results = []
        for url_index, url in enumerate(urls, start=1):
            log(f"  [LINK {url_index}/{len(urls)}] Acessando {url}")
            try:
                final_url, document = fetcher.get(url)
                detail = extract_detail(final_url, document)
                before_description = clean(record.get("description"))
                apply_detail(record, detail)
                # Persist after each successful page so an interruption does not
                # discard fields already extracted from this source.
                write_database(records)
                log(f"    [PERSISTÊNCIA] Dados desta página gravados em jobs.json.")
                per_url_results.append({
                    "url": url,
                    "status": "completed",
                    "resolved_url": final_url,
                    "structured_data": detail.get("structured", False),
                })
                if clean(record.get("description")) != before_description:
                    log("    [ATUALIZAÇÃO] Descrição da vaga obtida/expandida.")
                for key in ("title", "company", "published_at", "salary", "schedule", "address"):
                    if nonempty(detail.get(key)):
                        log(f"    [ATUALIZAÇÃO] {key}: informação obtida na página.")
                log("    [OK] Página analisada.")
                succeeded += 1
            except RobotsDisallowed as error:
                log(f"    [ROBOTS] Página não permitida: {error}")
                per_url_results.append({"url": url, "status": "skipped_robots", "message": str(error)})
                skipped += 1
            except RobotsUnavailable as error:
                log(f"    [ERRO] Não foi possível verificar robots.txt: {error}")
                per_url_results.append({"url": url, "status": "robots_unavailable", "message": str(error)})
                failed += 1
            except urllib.error.HTTPError as error:
                log(f"    [ERRO HTTP {error.code}] {error.reason}")
                per_url_results.append({"url": url, "status": f"http_{error.code}", "message": str(error.reason)})
                failed += 1
            except Exception as error:
                log(f"    [ERRO] {error}")
                per_url_results.append({"url": url, "status": "failed", "message": str(error)})
                failed += 1

        info = record.setdefault("additional_info", {})
        if not isinstance(info, dict):
            info = {}
            record["additional_info"] = info
        previous_enrichment = info.get("enrichment") if isinstance(info.get("enrichment"), dict) else {}
        enrichment = copy.deepcopy(previous_enrichment)
        existing_sources = enrichment.get("sources", [])
        if not isinstance(existing_sources, list):
            existing_sources = []
        for item in per_url_results:
            previous = next((value for value in existing_sources if isinstance(value, dict) and value.get("url") == item["url"]), None)
            if previous:
                previous.update(item)
            else:
                existing_sources.append(item)
        enrichment["sources"] = existing_sources
        statuses = [item["status"] for item in per_url_results]
        if any(status == "completed" for status in statuses):
            overall_status = "completed" if all(status == "completed" for status in statuses) else "partial"
        elif any(status in {"failed", "robots_unavailable"} or status.startswith("http_") for status in statuses):
            overall_status = "failed"
        else:
            overall_status = "skipped"
        enrichment["status"] = overall_status
        enrichment["updated_at"] = NOW.isoformat()
        info["enrichment"] = enrichment
        if overall_status != "completed":
            info["enrichment_status"] = overall_status
        write_database(records)
        log(f"  [PERSISTÊNCIA] jobs.json atualizado para a vaga ID {job_id}.")

    log("\n[RESUMO DO ENRIQUECIMENTO]")
    log(f"  Vagas analisadas: {len(records)}")
    log(f"  Páginas enriquecidas: {succeeded}")
    log(f"  Links ignorados por política/ausência: {skipped}")
    log(f"  Falhas: {failed}")
    log("  Arquivo atualizado: jobs.json")

    if failed:
        log("[AVISO] Enriquecimento parcial; os dados obtidos foram preservados.")
        return 2
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        log("\n[INTERRUPÇÃO] Enriquecimento interrompido. Os dados já persistidos foram preservados.")
        raise SystemExit(130)
    except Exception as error:
        log(f"[ERRO FATAL] {error}")
        raise SystemExit(1)
PY
