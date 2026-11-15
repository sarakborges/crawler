#!/usr/bin/env bash
set -Eeuo pipefail

# Crawler de vagas - Windows via Git Bash ou WSL; Linux/macOS via Bash.
# Requisitos: Bash, Python 3.10+ (biblioteca padrão) e acesso à Internet.

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

import html
import json
import re
import sys
import time
import tempfile
import urllib.error
import urllib.parse
import urllib.robotparser
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from html.parser import HTMLParser
from pathlib import Path
from typing import Any, Iterable

ROOT = Path(sys.argv[1]).resolve()
JOBS_DIR = ROOT / "jobs"
TIME_FILE = ROOT / "time.txt"
TZ = timezone(timedelta(hours=-3))
NOW = datetime.now(TZ).replace(microsecond=0)
USER_AGENT = "SaraJobCrawler/1.0 (+https://github.com/sarakborges/crawler; public-job-search)"
REQUEST_TIMEOUT = 35
MAX_RETRIES = 5
MAX_RESPONSE_BYTES = 18 * 1024 * 1024
HOST_DELAY_SECONDS = 1.25


@dataclass
class Source:
    name: str
    urls: list[str]


SOURCES = [
    Source("gupy", [
        "https://portal.gupy.io/job-search/sortBy%3DpublishedDate%26state%3DRio%20Grande%20do%20Sul%26city%5B%5D%3DPorto%20Alegre",
        "https://portal.gupy.io/job-search/sortBy%3DpublishedDate%26workplaceTypes%5B%5D%3Dremote",
    ]),
    Source("bne", ["https://www.bne.com.br/vagas-de-emprego-em-porto-alegre-rs"]),
    Source("trabalhabrasil", ["https://www.trabalhabrasil.com.br/vagas-de-emprego-em-porto-alegre-rs"]),
    Source("vagas.com", ["https://www.vagas.com.br/vagas-em-porto-alegre"]),
    Source("indeed", [
        "https://br.indeed.com/jobs?l=Porto+Alegre%2C+RS",
        "https://br.indeed.com/jobs?l=Remoto",
    ]),
]

RESTRICTED_SOURCES = {
    "linkedin": "Coleta automatizada exige autorização expressa do LinkedIn.",
    "infojobs": "Os termos do InfoJobs vedam crawler/scraping sem autorização.",
    "catho": "Os termos da Catho vedam robôs, crawlers e mineração automatizada.",
}


def log(message: str) -> None:
    print(message, flush=True)


def clean(value: Any) -> str | None:
    if value is None:
        return None
    value = html.unescape(str(value))
    value = re.sub(r"\s+", " ", value).strip()
    return value or None


def strip_html(value: Any) -> str | None:
    if value is None:
        return None
    value = re.sub(r"(?is)<(script|style).*?>.*?</\1>", " ", str(value))
    return clean(re.sub(r"(?s)<[^>]+>", " ", value))


def parse_date(value: Any, reference: datetime = NOW) -> tuple[datetime | None, str | None]:
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
        return reference.replace(hour=12, minute=0, second=0), "date"
    if low in {"ontem", "yesterday"}:
        return (reference - timedelta(days=1)).replace(hour=12, minute=0, second=0), "date"
    relative = re.search(r"(?:há|ha|há cerca de)\s+(\d+)\s+(minuto|minutos|hora|horas|dia|dias|semana|semanas|m[eê]s|meses)", low)
    if relative:
        amount, unit = int(relative.group(1)), relative.group(2)
        if unit.startswith("minuto"):
            return reference - timedelta(minutes=amount), "datetime"
        if unit.startswith("hora"):
            return reference - timedelta(hours=amount), "datetime"
        if unit.startswith("dia"):
            return (reference - timedelta(days=amount)).replace(hour=12, minute=0, second=0), "date"
        if unit.startswith("semana"):
            return (reference - timedelta(weeks=amount)).replace(hour=12, minute=0, second=0), "date"
        return (reference - timedelta(days=30 * amount)).replace(hour=12, minute=0, second=0), "date"
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


def load_checkpoint() -> datetime:
    try:
        parsed, _ = parse_date(TIME_FILE.read_text(encoding="utf-8").strip())
        if parsed is None or parsed > NOW:
            raise ValueError("timestamp inválido ou futuro")
        return parsed
    except (OSError, ValueError):
        return NOW - timedelta(days=7)


class Node:
    __slots__ = ("tag", "attrs", "children", "parent")

    def __init__(self, tag: str, attrs: dict[str, str], parent: Node | None = None):
        self.tag, self.attrs, self.parent = tag, attrs, parent
        self.children: list[Node | str] = []

    def text(self) -> str:
        pieces: list[str] = []
        def walk(node: Node) -> None:
            for child in node.children:
                if isinstance(child, Node):
                    if child.tag not in {"script", "style", "noscript", "svg"}:
                        walk(child)
                else:
                    pieces.append(child)
        walk(self)
        return clean(" ".join(pieces)) or ""

    def descendants(self) -> Iterable[Node]:
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
        values = {key.lower(): value or "" for key, value in attrs}
        node = Node(tag.lower(), values, self.stack[-1])
        self.stack[-1].children.append(node)
        if tag.lower() == "meta":
            key = (values.get("property") or values.get("name") or values.get("itemprop") or "").lower()
            if key:
                self.meta[key] = values.get("content", "")
        if tag.lower() == "script":
            self.script_type = values.get("type", "").lower()
            self.script_parts = []
        if tag.lower() not in self.VOID:
            self.stack.append(node)

    def handle_endtag(self, tag: str) -> None:
        tag = tag.lower()
        if tag == "script" and self.script_type == "application/ld+json":
            raw = "".join(self.script_parts).strip()
            if raw:
                self.jsonld.append(raw)
        for index in range(len(self.stack) - 1, 0, -1):
            if self.stack[index].tag == tag:
                del self.stack[index:]
                break
        if tag == "script":
            self.script_type, self.script_parts = "", []

    def handle_data(self, data: str) -> None:
        if self.script_type == "application/ld+json":
            self.script_parts.append(data)
        self.stack[-1].children.append(data)


@dataclass
class Page:
    url: str
    document: HTMLDocument


class RobotsDisallowed(PermissionError):
    pass


class RobotsUnavailable(RuntimeError):
    pass


class Fetcher:
    def __init__(self):
        self.robots_cache: dict[str, urllib.robotparser.RobotFileParser | None] = {}
        self.last_request: dict[str, float] = {}
        self.delays: dict[str, float] = {}

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
            self.delays[base] = max(HOST_DELAY_SECONDS, float(delay))
            return parser
        except urllib.error.HTTPError as error:
            if error.code == 404:
                parser.parse([])
                self.robots_cache[base] = parser
                self.delays[base] = HOST_DELAY_SECONDS
                return parser
            self.robots_cache[base] = None
            return None
        except Exception:
            self.robots_cache[base] = None
            return None

    def get(self, url: str) -> Page:
        parser = self.robots(url)
        if parser is None:
            raise RobotsUnavailable("robots.txt não pôde ser verificado")
        if not parser.can_fetch(USER_AGENT, url):
            raise RobotsDisallowed("robots.txt não permite este caminho")
        parts = urllib.parse.urlsplit(url)
        host = f"{parts.scheme}://{parts.netloc}"
        delay = self.delays.get(host, HOST_DELAY_SECONDS)
        remaining = delay - (time.monotonic() - self.last_request.get(host, 0))
        if remaining > 0:
            time.sleep(remaining)
        last_error: Exception | None = None
        for attempt in range(MAX_RETRIES):
            request = urllib.request.Request(url, headers={
                "User-Agent": USER_AGENT,
                "Accept": "text/html,application/xhtml+xml,application/ld+json;q=0.9,*/*;q=0.5",
                "Accept-Language": "pt-BR,pt;q=0.9,en;q=0.7",
            })
            self.last_request[host] = time.monotonic()
            try:
                with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT) as response:
                    raw = response.read(MAX_RESPONSE_BYTES + 1)
                    final_url = response.geturl()
                    charset = response.headers.get_content_charset() or "utf-8"
                if len(raw) > MAX_RESPONSE_BYTES:
                    raise RuntimeError("resposta excedeu o limite de 18 MB")
                document = HTMLDocument()
                document.feed(raw.decode(charset, "replace"))
                document.close()
                return Page(final_url, document)
            except urllib.error.HTTPError as error:
                if error.code == 429:
                    header = error.headers.get("Retry-After", "")
                    wait = int(header) if header.isdigit() else min(60, 2 ** attempt)
                    log(f"    HTTP 429; aguardando {wait}s")
                    time.sleep(wait)
                    last_error = error
                    continue
                if 500 <= error.code < 600 and attempt < MAX_RETRIES - 1:
                    time.sleep(min(45, 2 ** attempt))
                    last_error = error
                    continue
                raise
            except (urllib.error.URLError, TimeoutError, ConnectionError) as error:
                last_error = error
                if attempt < MAX_RETRIES - 1:
                    wait = min(45, 2 ** attempt)
                    log(f"    falha de conexão; nova tentativa em {wait}s")
                    time.sleep(wait)
                    continue
                raise
        raise RuntimeError(f"tentativas esgotadas: {last_error}")


def find_job_postings(value: Any) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    def walk(item: Any) -> None:
        if isinstance(item, dict):
            types = item.get("@type", [])
            types = types if isinstance(types, list) else [types]
            if any(str(value).casefold().endswith("jobposting") for value in types):
                result.append(item)
            for child in item.values():
                walk(child)
        elif isinstance(item, list):
            for child in item:
                walk(child)
    walk(value)
    return result


def jsonld_jobs(document: HTMLDocument) -> list[dict[str, Any]]:
    result = []
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


def salary_from(job: dict[str, Any]) -> dict[str, Any]:
    raw = job.get("baseSalary") or job.get("salary")
    if not raw:
        return {"minimum": None, "maximum": None, "currency": None, "period": None, "raw": None}
    if isinstance(raw, str):
        return {"minimum": None, "maximum": None, "currency": None, "period": None, "raw": clean(raw)}
    if not isinstance(raw, dict):
        return {"minimum": None, "maximum": None, "currency": None, "period": None, "raw": clean(raw)}
    value = raw.get("value", raw)
    if not isinstance(value, dict):
        value = {"value": value}
    def number(item: Any) -> float | None:
        try:
            return float(str(item).replace(",", ".")) if item is not None else None
        except (TypeError, ValueError):
            return None
    minimum = number(value.get("minValue", value.get("value")))
    maximum = number(value.get("maxValue", value.get("value")))
    currency = clean(raw.get("currency") or value.get("currency"))
    period = clean(value.get("unitText") or raw.get("unitText"))
    raw_text = raw.get("description") or f"{minimum or ''}-{maximum or ''} {currency or ''} {period or ''}"
    return {"minimum": minimum, "maximum": maximum, "currency": currency, "period": period, "raw": clean(raw_text)}


def to_record(job: dict[str, Any], platform: str, page_url: str, fallback: dict[str, Any] | None = None) -> dict[str, Any]:
    fallback = fallback or {}
    organization = job.get("hiringOrganization") or {}
    company = organization.get("name") if isinstance(organization, dict) else organization
    published, precision = parse_date(job.get("datePosted") or fallback.get("published_at"))
    location = address_from(job)
    location_type = clean(job.get("jobLocationType") or job.get("workplaceType") or fallback.get("work_model")) or ""
    description = strip_html(job.get("description") or fallback.get("description"))
    job_text = " ".join(str(job.get(key) or "") for key in ("title", "description", "jobLocationType", "workplaceType"))
    is_remote = bool(re.search(r"telecommute|remote|remot|home.?office", location_type + " " + job_text, re.I))
    if is_remote:
        location.update({
            "city": location.get("city") or "Porto Alegre",
            "state": location.get("state") or "RS",
            "country": location.get("country") or "BR",
        })
    employment = job.get("employmentType") or fallback.get("employment_type")
    if isinstance(employment, list):
        employment = ", ".join(str(item) for item in employment)
    identifier = job.get("identifier")
    if isinstance(identifier, dict):
        identifier = identifier.get("value")
    info = {
        "external_id": clean(identifier or fallback.get("external_id")),
        "first_seen_at": NOW.isoformat(),
        "employment_type": clean(employment),
        "work_model": "remote" if is_remote else location_type or fallback.get("work_model"),
        "date_precision": precision,
    }
    for key in ("validThrough", "experienceRequirements", "qualifications", "responsibilities", "skills", "industry", "jobLocationType", "applicantLocationRequirements", "directApply"):
        if job.get(key) is not None:
            info[key] = job[key]
    return {
        "id": None,
        "title": clean(job.get("title") or fallback.get("title")),
        "description": description,
        "company": clean(company or fallback.get("company")),
        "platform": platform,
        "url": clean(job.get("url") or fallback.get("url") or page_url),
        "published_at": published.isoformat() if published else None,
        "salary": salary_from(job),
        "schedule": clean(job.get("workHours") or job.get("schedule") or fallback.get("schedule")),
        "address": location,
        "additional_info": info,
    }


JOB_LINK = re.compile(r"/(?:vaga|vagas|job|jobs|oportunidade|oportunidades|emprego|empregos|position|positions|offer|oferta|viewjob)(?:/|[-_?]|$)|/rc/clk(?:/|$)", re.I)
DATE_TEXT = re.compile(r"\b(?:\d{1,2}/\d{1,2}/\d{4}|\d{4}-\d{2}-\d{2}|hoje|ontem|h[aá]\s+\d+\s+(?:minutos?|horas?|dias?|semanas?))\b", re.I)
SALARY_TEXT = re.compile(r"(?:R\$\s?[\d.]+(?:,\d{2})?(?:\s*(?:a|-)\s*R?\$?\s?[\d.]+(?:,\d{2})?)?|\$\s?[\d,.]+)", re.I)


def candidates_from(page: Page) -> list[dict[str, Any]]:
    host = urllib.parse.urlsplit(page.url).netloc.lower()
    found: dict[str, dict[str, Any]] = {}
    for node in page.document.root.descendants():
        if node.tag != "a":
            continue
        href = node.attrs.get("href", "").strip()
        title = node.text() or clean(node.attrs.get("aria-label") or node.attrs.get("title")) or ""
        if not href or len(title) < 3 or href.startswith(("#", "javascript:", "mailto:", "tel:")):
            continue
        url = urllib.parse.urljoin(page.url, href)
        parsed = urllib.parse.urlsplit(url)
        path = parsed.path.lower()
        if parsed.netloc.lower() != host or not JOB_LINK.search(path):
            continue
        if path in {"/jobs", "/jobs/", "/job", "/job/", "/vagas", "/vagas/"} or any(x in path for x in ("job-search", "vagas-de-emprego-em-", "vagas-em-porto-alegre", "vagas-de-emprego-home-office", "/jobs/home")):
            continue
        parent = node
        for _ in range(5):
            if parent.parent is None:
                break
            parent = parent.parent
            if parent.tag in {"article", "li"} or any(x in parent.attrs.get("class", "").lower() for x in ("job", "vaga", "card", "result", "item")):
                break
        card = parent.text()[:5000]
        candidate = {
            "url": url,
            "title": title,
            "card_text": card,
            "description": card or None,
            "company": None,
            "published_at": None,
            "salary_raw": None,
            "schedule": None,
            "work_model": None,
        }
        match = DATE_TEXT.search(card)
        if match:
            candidate["published_at"] = match.group(0)
        match = SALARY_TEXT.search(card)
        if match:
            candidate["salary_raw"] = match.group(0)
        if re.search(r"remoto|home\s*office|remote", card, re.I):
            candidate["work_model"] = "remote"
        elif re.search(r"h[ií]brido|hybrid", card, re.I):
            candidate["work_model"] = "hybrid"
        elif re.search(r"porto\s+alegre", card, re.I):
            candidate["work_model"] = "on_site"
        match = re.search(r"(?:escala|jornada|hor[aá]rio)\s*:?\s*([^.;\n]{3,100})", card, re.I)
        if match:
            candidate["schedule"] = clean(match.group(0))
        match = re.search(r"(?:[?&](?:id|jk|jobId|offerId)=|/)([A-Za-z0-9_-]{5,})(?:[/?&#]|$)", url, re.I)
        if match:
            candidate["external_id"] = match.group(1)
        found[url] = candidate
    return list(found.values())


def has_explicit_no_results(page: Page) -> bool:
    page_text = page.document.root.text().casefold()
    phrases = (
        "nenhuma vaga encontrada", "nenhuma vaga foi encontrada",
        "não encontramos vagas", "nao encontramos vagas",
        "nenhum resultado encontrado", "não há vagas disponíveis",
        "nao ha vagas disponiveis", "no jobs found", "no results found",
        "we couldn't find any jobs", "we could not find any jobs",
    )
    return any(phrase in page_text for phrase in phrases)


def next_pages(page: Page) -> list[str]:
    host = urllib.parse.urlsplit(page.url).netloc.lower()
    urls = []
    for node in page.document.root.descendants():
        if node.tag != "a" or not node.attrs.get("href"):
            continue
        rel = node.attrs.get("rel", "").lower()
        cls = node.attrs.get("class", "").lower()
        aria = node.attrs.get("aria-label", "").lower()
        label = (node.text() or "").strip().lower()
        parent = node.parent
        classes = []
        for _ in range(3):
            if parent is None:
                break
            classes.append(parent.attrs.get("class", "").lower())
            parent = parent.parent
        is_next = (
            "next" in rel or "next" in cls or "pagination" in cls
            or any("pagination" in item or "pager" in item for item in classes)
            or "próxima" in aria or "proxima" in aria
            or any(word in label for word in ("próxima", "proxima", "next"))
            or label in {">", "»", "›"}
        )
        if is_next:
            url = urllib.parse.urljoin(page.url, node.attrs["href"])
            if urllib.parse.urlsplit(url).netloc.lower() == host:
                urls.append(url)
    return list(dict.fromkeys(urls))


def work_model(record: dict[str, Any], context: str = "") -> str | None:
    address = record.get("address") or {}
    declared = str((record.get("additional_info") or {}).get("work_model") or "").casefold()
    if re.search(r"telecommute|remoto|home\s*office|remote", declared):
        return "remote"
    if re.search(r"h[ií]brido|hybrid", declared):
        return "hybrid"
    if re.search(r"presencial|on.?site|onsite", declared):
        return "on_site"
    content = (declared + " " + context).casefold()
    if re.search(r"remoto|home\s*office|telecommute|remote", content):
        return "remote"
    if re.search(r"h[ií]brido|hybrid", content):
        return "hybrid"
    if address.get("city") or re.search(r"presencial|on.?site|onsite", content):
        return "on_site"
    return None


def location_allowed(record: dict[str, Any], context: str = "") -> tuple[bool, str | None]:
    model = work_model(record, context)
    address = record.get("address") or {}
    city = clean(address.get("city")) or ""
    location = " ".join(str(address.get(key) or "") for key in ("city", "state", "country")) + " " + context
    porto_alegre = city.casefold() == "porto alegre" or "porto alegre" in location.casefold()
    if model == "remote":
        info = record.get("additional_info") or {}
        requirements = info.get("applicantLocationRequirements")
        required_text = json.dumps(requirements, ensure_ascii=False).casefold() if requirements is not None else ""
        country = str(address.get("country") or "").casefold()
        if required_text:
            brazil = any(term in required_text for term in ("brazil", "brasil", '"br"'))
            worldwide = any(term in required_text for term in ("worldwide", "anywhere", "global", "latin america", "américa latina"))
            if not brazil and not worldwide:
                return False, model
        elif country and not any(term in country for term in ("brazil", "brasil", "br")):
            return False, model
        return True, model
    if model in {"hybrid", "on_site"}:
        return porto_alegre, model
    return porto_alegre, model


UNDATED_SKIPPED = 0


def in_window(record: dict[str, Any], start: datetime, end: datetime) -> bool:
    global UNDATED_SKIPPED
    published, precision = parse_date(record.get("published_at"))
    if published is None:
        record.setdefault("additional_info", {})["publication_date_missing"] = True
        UNDATED_SKIPPED += 1
        return False
    if precision == "date":
        return start.date() <= published.date() <= end.date()
    return start <= published <= end


def fallback_record(candidate: dict[str, Any], platform: str, detail: Page | None = None) -> dict[str, Any]:
    title = candidate.get("title")
    description = candidate.get("description")
    published_raw = candidate.get("published_at")
    schedule = candidate.get("schedule")
    context = candidate.get("card_text", "")
    address_text = context
    if detail:
        title = detail.document.meta.get("og:title") or next((node.text() for node in detail.document.root.descendants() if node.tag == "h1" and node.text()), None) or title
        description = strip_html(detail.document.meta.get("description") or detail.document.meta.get("og:description")) or description
        address_text += " " + detail.document.root.text()
        if not published_raw:
            match = DATE_TEXT.search(address_text)
            published_raw = match.group(0) if match else None
        if not schedule:
            match = re.search(r"(?:escala|jornada|hor[aá]rio)\s*:?\s*([^.;\n]{3,100})", address_text, re.I)
            schedule = clean(match.group(0)) if match else None
    model = candidate.get("work_model")
    if not model:
        if re.search(r"remoto|home\s*office|remote", address_text, re.I):
            model = "remote"
        elif re.search(r"h[ií]brido|hybrid", address_text, re.I):
            model = "hybrid"
        elif re.search(r"porto\s+alegre", address_text, re.I):
            model = "on_site"
    published, precision = parse_date(published_raw)
    poa_or_remote = "porto alegre" in address_text.casefold() or model == "remote"
    return {
        "id": None,
        "title": clean(title),
        "description": clean(description),
        "company": clean(candidate.get("company")),
        "platform": platform,
        "url": detail.url if detail else candidate.get("url"),
        "published_at": published.isoformat() if published else None,
        "salary": {"minimum": None, "maximum": None, "currency": "BRL" if candidate.get("salary_raw") else None, "period": None, "raw": candidate.get("salary_raw")},
        "schedule": clean(schedule),
        "address": {
            "street": None, "number": None, "neighborhood": None,
            "city": "Porto Alegre" if poa_or_remote else None,
            "state": "RS" if poa_or_remote else None,
            "postal_code": None,
            "country": "BR" if poa_or_remote else None,
        },
        "additional_info": {
            "external_id": candidate.get("external_id"),
            "first_seen_at": NOW.isoformat(),
            "employment_type": candidate.get("employment_type"),
            "work_model": model,
            "date_precision": precision,
            "source_card_text": context[:3000],
        },
    }


def save_record(next_id: int, record: dict[str, Any]) -> int:
    record["id"] = next_id
    path = JOBS_DIR / f"{next_id}.json"
    payload = json.dumps(record, ensure_ascii=False, indent=2) + "\n"
    fd, temp_path = tempfile.mkstemp(prefix=f".{next_id}.", suffix=".tmp", dir=JOBS_DIR)
    try:
        with open(fd, "w", encoding="utf-8", newline="\n", closefd=True) as file:
            file.write(payload)
            file.flush()
        import os
        os.replace(temp_path, path)
    finally:
        try:
            os.unlink(temp_path)
        except FileNotFoundError:
            pass
    return next_id + 1


def next_id_from_disk() -> int:
    highest = 0
    for path in JOBS_DIR.glob("*.json"):
        try:
            item = json.loads(path.read_text(encoding="utf-8"))
            highest = max(highest, int(item.get("id", path.stem)))
        except (OSError, ValueError, TypeError, json.JSONDecodeError):
            try:
                highest = max(highest, int(path.stem))
            except ValueError:
                pass
    return highest + 1


def crawl(source: Source, fetcher: Fetcher, start: datetime, end: datetime, next_id: int) -> tuple[int, dict[str, Any]]:
    result = {"status": "COMPLETED", "pages": 0, "saved": 0, "errors": [], "notes": []}
    queue = list(source.urls)
    visited: set[str] = set()
    saw_listings = False
    failed = False
    while queue:
        url = queue.pop(0)
        if url in visited:
            continue
        visited.add(url)
        try:
            log(f"  Página {result['pages'] + 1}: {url}")
            page = fetcher.get(url)
            result["pages"] += 1
            structured = jsonld_jobs(page.document)
            candidates = candidates_from(page)
            if structured or candidates or has_explicit_no_results(page):
                saw_listings = True
            known_urls = set()
            for job in structured:
                record = to_record(job, source.name, page.url)
                if record.get("url"):
                    known_urls.add(urllib.parse.urldefrag(record["url"])[0])
                context = " ".join(str(record.get(key) or "") for key in ("title", "description"))
                allowed, model = location_allowed(record, context)
                if allowed and in_window(record, start, end):
                    record.setdefault("additional_info", {})["work_model"] = model or record["additional_info"].get("work_model")
                    next_id = save_record(next_id, record)
                    result["saved"] += 1
            for candidate in candidates:
                if urllib.parse.urldefrag(candidate["url"])[0] in known_urls or candidate["url"] in visited:
                    continue
                try:
                    detail = fetcher.get(candidate["url"])
                    visited.add(candidate["url"])
                    jobs = jsonld_jobs(detail.document)
                    if jobs:
                        record = to_record(jobs[0], source.name, detail.url, candidate)
                    else:
                        record = fallback_record(candidate, source.name, detail)
                    context = candidate.get("card_text", "") + " " + detail.document.root.text()[:5000]
                    allowed, model = location_allowed(record, context)
                    if allowed and in_window(record, start, end):
                        record.setdefault("additional_info", {})["work_model"] = model or record.get("additional_info", {}).get("work_model")
                        next_id = save_record(next_id, record)
                        result["saved"] += 1
                except RobotsDisallowed as error:
                    result["notes"].append(f"Detalhe ignorado por robots.txt: {candidate['url']} ({error})")
                    record = fallback_record(candidate, source.name)
                    allowed, model = location_allowed(record, candidate.get("card_text", ""))
                    if allowed and in_window(record, start, end):
                        record.setdefault("additional_info", {})["work_model"] = model
                        next_id = save_record(next_id, record)
                        result["saved"] += 1
                except RobotsUnavailable as error:
                    failed = True
                    result["errors"].append(f"robots.txt indisponível em {candidate['url']}: {error}")
                except urllib.error.HTTPError as error:
                    if error.code in (404, 410):
                        record = fallback_record(candidate, source.name)
                        allowed, model = location_allowed(record, candidate.get("card_text", ""))
                        if allowed and in_window(record, start, end):
                            record.setdefault("additional_info", {})["work_model"] = model
                            next_id = save_record(next_id, record)
                            result["saved"] += 1
                        result["notes"].append(f"Detalhe HTTP {error.code}: {candidate['url']}")
                    else:
                        failed = True
                        result["errors"].append(f"Detalhe {candidate['url']}: {error}")
                except Exception as error:
                    failed = True
                    result["errors"].append(f"Detalhe {candidate['url']}: {error}")
            for next_url in next_pages(page):
                if next_url not in visited:
                    queue.append(next_url)
        except RobotsDisallowed as error:
            result["status"] = "SKIPPED_ROBOTS"
            result["notes"].append(f"Pesquisa não permitida: {url} ({error})")
        except RobotsUnavailable as error:
            failed = True
            result["errors"].append(f"robots.txt indisponível em {url}: {error}")
        except Exception as error:
            failed = True
            result["errors"].append(f"Página {url}: {error}")
    if failed:
        result["status"] = "INCOMPLETE"
    elif not saw_listings and not (result["status"] == "SKIPPED_ROBOTS" and result["pages"] == 0):
        result["status"] = "INCOMPLETE"
        result["notes"].append("Nenhuma vaga reconhecida; a página pode depender de JavaScript ou ter mudado de estrutura.")
    return next_id, result


def save_checkpoint(value: datetime) -> None:
    payload = value.astimezone(TZ).isoformat(timespec="seconds") + "\n"
    fd, temp_path = tempfile.mkstemp(prefix=".time.", suffix=".tmp", dir=ROOT)
    try:
        with open(fd, "w", encoding="utf-8", newline="\n", closefd=True) as file:
            file.write(payload)
            file.flush()
        import os
        os.replace(temp_path, TIME_FILE)
    finally:
        try:
            os.unlink(temp_path)
        except FileNotFoundError:
            pass


def main() -> int:
    JOBS_DIR.mkdir(parents=True, exist_ok=True)
    start, end = load_checkpoint(), NOW
    if start >= end:
        start = end - timedelta(days=7)
    log("Crawler iniciado")
    log(f"Intervalo: {start.isoformat()} até {end.isoformat()}")
    log("Localidade: Porto Alegre/RS presencial ou híbrido; remoto elegível no Brasil")
    log(f"Armazenamento: {JOBS_DIR}")
    summary: dict[str, dict[str, Any]] = {
        name: {"status": "SKIPPED_POLICY", "pages": 0, "saved": 0, "errors": [], "notes": [note]}
        for name, note in RESTRICTED_SOURCES.items()
    }
    next_id = next_id_from_disk()
    fetcher = Fetcher()
    for source in SOURCES:
        log(f"\n[{source.name}]")
        next_id, result = crawl(source, fetcher, start, end, next_id)
        summary[source.name] = result
        log(f"  {result['status']} | páginas: {result['pages']} | vagas: {result['saved']}")
        for item in result["errors"] + result["notes"]:
            log(f"  AVISO: {item}")
    incomplete = [name for name, result in summary.items() if result["status"] == "INCOMPLETE"]
    log("\nResumo")
    log(f"  Páginas: {sum(item['pages'] for item in summary.values())}")
    log(f"  Novos arquivos: {sum(item['saved'] for item in summary.values())}")
    log(f"  Ignoradas sem data de publicação verificável: {UNDATED_SKIPPED}")
    for name, result in summary.items():
        log(f"  {name}: {result['status']}")
    if incomplete:
        log("\nExecução incompleta. time.txt preservado para repetir o intervalo.")
        log("Fontes: " + ", ".join(incomplete))
        return 2
    save_checkpoint(end)
    log(f"\nConsultas das fontes acessíveis concluídas. time.txt = {end.isoformat()}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        log("\nInterrompido manualmente. time.txt preservado.")
        raise SystemExit(130)
PY
