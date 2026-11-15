#!/usr/bin/env bash
set -Eeuo pipefail

# Crawler de vagas - Windows via Git Bash ou WSL; Linux/macOS via Bash.
# Requisitos: Bash, Python 3.10+ (biblioteca padrão) e acesso à Internet.

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$ROOT_DIR/jobs"

PYTHON=()

python_works() {
  "$@" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' >/dev/null 2>&1
}

# On Windows, "python3" may resolve to the Microsoft Store execution alias
# even when a working installation is available through "py" or "python".
if command -v py >/dev/null 2>&1 && python_works py -3; then
  PYTHON=(py -3)
elif command -v python >/dev/null 2>&1 && python_works python; then
  PYTHON=(python)
elif command -v python3 >/dev/null 2>&1 && python_works python3; then
  PYTHON=(python3)
else
  echo "ERRO: não encontrei um interpretador Python 3.10+ funcional." >&2
  echo "Verifique no Git Bash: py -3 --version; python --version; python3 --version" >&2
  echo "O alias python3 da Microsoft Store pode aparecer como instalado sem ter o Python instalado." >&2
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
    ago = re.search(r"(\d+)\s+(minute|minutes|hour|hours|day|days|week|weeks)\s+ago", low)
    if relative or ago:
        match = relative or ago
        amount, unit = int(match.group(1)), match.group(2)
        if unit.startswith(("minuto", "minute")):
            return reference - timedelta(minutes=amount), "datetime"
        if unit.startswith(("hora", "hour")):
            return reference - timedelta(hours=amount), "datetime"
        if unit.startswith(("dia", "day")):
            return (reference - timedelta(days=amount)).replace(hour=12, minute=0, second=0), "date"
        if unit.startswith(("semana", "week")):
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


JOB_LINK = re.compile(r"^/(?:vaga-de-emprego(?:-[^/]+)?|vagas-de-emprego-[^/]+/[^/]+|vagas/v\d+|rc/clk)(?:/|$)", re.I)
DATE_TEXT = re.compile(
    r"\b(?:\d{1,2}/\d{1,2}/\d{4}|\d{4}-\d{2}-\d{2}|hoje|ontem|today|yesterday|"
    r"há\s+\d+\s+(?:minutos?|horas?|dias?|semanas?|meses?)|"
    r"\d+\s+(?:minutes?|hours?|days?|weeks?)\s+ago)\b",
    re.I,
)


class ListingStructureError(RuntimeError):
    pass


def has_class(node: Node, class_name: str) -> bool:
    return class_name in node.attrs.get("class", "").split()


def find_nodes(
    root: Node,
    tag: str | None = None,
    class_name: str | None = None,
    node_id: str | None = None,
    attr_name: str | None = None,
    attr_value: str | None = None,
) -> list[Node]:
    found: list[Node] = []
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
    matches = find_nodes(root, tag, class_name, node_id, attr_name, attr_value)
    return matches[0] if matches else None


def has_any_class_text(card: Node, class_name: str) -> str | None:
    node = find_first(card, class_name=class_name)
    return clean(node.text()) if node else None


def listing_container(page: Page, platform: str) -> Node:
    selectors = {
        "gupy": ("job-listing-results", None),
        "bne": (None, "lista_vagas__grid"),
        "trabalhabrasil": (None, "jobs-list"),
        "vagas.com": ("todasVagas", None),
        "indeed": ("mosaic-jobResults", None),
    }
    if platform not in selectors:
        raise ListingStructureError(f"Plataforma sem seletor configurado: {platform}")
    node_id, class_name = selectors[platform]
    container = find_first(page.document.root, node_id=node_id, class_name=class_name)
    if container is None:
        raise ListingStructureError(
            f"Contêiner de resultados não encontrado para {platform}; "
            "a estrutura da página pode ter mudado."
        )
    return container


def job_link_for_card(card: Node, platform: str) -> Node | None:
    for anchor in find_nodes(card, tag="a"):
        href = html.unescape(anchor.attrs.get("href", "")).strip()
        if not href:
            continue
        parsed = urllib.parse.urlsplit(urllib.parse.urljoin("https://invalid.local", href))
        path = parsed.path
        if platform == "gupy":
            host = urllib.parse.urlsplit(href).netloc.casefold()
            if host.endswith(".gupy.io") and re.search(r"/job/[^/]+$", path, re.I):
                if find_first(card, class_name="MuiCard-job_default") is not None:
                    return anchor
        elif platform == "bne":
            if has_class(anchor, "card__link") and re.search(r"/vaga-de-emprego(?:-[^/]+)?/.+/\d+/?$", path, re.I):
                return anchor
        elif platform == "trabalhabrasil":
            if has_class(anchor, "job-link") and re.search(r"/vagas-de-emprego-[^/]+/.+/\d+/?$", path, re.I):
                return anchor
        elif platform == "vagas.com":
            if has_class(anchor, "link-detalhes-vaga") and re.search(r"/vagas/v\d+/", path, re.I):
                if anchor.attrs.get("data-id-vaga", "").isdigit():
                    return anchor
        elif platform == "indeed":
            query = dict(urllib.parse.parse_qsl(parsed.query))
            if has_class(anchor, "jcs-JobTitle") and query.get("jk"):
                return anchor
    return None


def text_by_selector(
    card: Node,
    tag: str | None = None,
    class_name: str | None = None,
    attr_name: str | None = None,
    attr_value: str | None = None,
) -> str | None:
    node = find_first(card, tag=tag, class_name=class_name, attr_name=attr_name, attr_value=attr_value)
    if node is None:
        return None
    return clean(node.text())


def card_candidates(page: Page, platform: str) -> tuple[list[dict[str, Any]], int]:
    container = listing_container(page, platform)

    if platform == "gupy":
        cards = [
            node for node in find_nodes(container, tag="li")
            if find_first(node, class_name="MuiCard-job_default") is not None
        ]
    elif platform == "bne":
        cards = find_nodes(container, tag="section", class_name="job__card__container")
    elif platform == "trabalhabrasil":
        cards = find_nodes(container, tag="article", class_name="job-card")
    elif platform == "vagas.com":
        cards = find_nodes(container, tag="li", class_name="vaga")
    else:
        cards = [
            node for node in find_nodes(container, class_name="cardOutline")
            if has_class(node, "result")
        ]

    candidates: list[dict[str, Any]] = []
    rejected_cards = 0
    remote_scope = bool(re.search(r"remote|remoto|home.?office", urllib.parse.unquote(page.url), re.I))

    for card in cards:
        anchor = job_link_for_card(card, platform)
        if anchor is None:
            rejected_cards += 1
            continue

        href = html.unescape(anchor.attrs.get("href", "")).strip()
        url = urllib.parse.urljoin(page.url, href)
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme not in {"http", "https"}:
            rejected_cards += 1
            continue

        if platform == "gupy":
            title = text_by_selector(card, tag="h3", class_name="MuiTypography-heading-small")
        elif platform == "trabalhabrasil":
            title = text_by_selector(card, tag="h2", class_name="job-title")
        elif platform == "vagas.com":
            title = text_by_selector(card, tag="h2", class_name="cargo")
        else:
            title = clean(anchor.attrs.get("title")) or clean(anchor.text())
        title = title or clean(anchor.attrs.get("title")) or clean(anchor.text())
        if platform == "indeed":
            title = (
                text_by_selector(card, tag="span", attr_name="id", attr_value=f"jobTitle-{dict(urllib.parse.parse_qsl(parsed.query)).get('jk', '')}")
                or clean(anchor.attrs.get("aria-label"))
                or clean(anchor.text())
            )
            title = re.sub(r"^informações completas da vaga de\s+", "", title or "", flags=re.I)
        if platform == "bne":
            title_attr = clean(anchor.attrs.get("title"))
            if title_attr:
                title = re.sub(r"\s+em\s+Porto Alegre\s*/\s*RS$", "", title_attr, flags=re.I)

        if not title or len(title) < 3:
            rejected_cards += 1
            continue

        company = None
        location = None
        published_raw = None
        external_id = None

        if platform == "gupy":
            company = text_by_selector(card, tag="p", class_name="MuiTypography-body-medium")
            location = text_by_selector(card, attr_name="data-testid", attr_value="job-location")
            external_id = re.search(r'"jobId"\s*:\s*(\d+)', urllib.parse.unquote(parsed.path))
            external_id = external_id.group(1) if external_id else None
        elif platform == "bne":
            external_id = re.search(r"/(\d+)/?$", parsed.path)
            external_id = external_id.group(1) if external_id else None
            info_items = [node.text() for node in find_nodes(card, class_name="info__vaga-item")]
            location = next((item for item in info_items if re.search(r"porto\s+alegre|remoto|h[ií]brido", item, re.I)), None)
        elif platform == "trabalhabrasil":
            company = text_by_selector(card, tag="p", class_name="job-company")
            location = text_by_selector(card, class_name="job-location")
            external_id = clean(card.attrs.get("data-job-id"))
        elif platform == "vagas.com":
            company = text_by_selector(card, tag="span", class_name="emprVaga")
            location = text_by_selector(card, class_name="vaga-local")
            external_id = clean(anchor.attrs.get("data-id-vaga"))
        elif platform == "indeed":
            company = text_by_selector(card, attr_name="data-testid", attr_value="company-name")
            location = text_by_selector(card, attr_name="data-testid", attr_value="text-location")
            external_id = dict(urllib.parse.parse_qsl(parsed.query)).get("jk")

        time_node = find_first(card, tag="time")
        if time_node:
            published_raw = time_node.attrs.get("datetime") or clean(time_node.text())
        if not published_raw:
            published_node = (
                find_first(card, class_name="data-publicacao")
                or find_first(card, class_name="eco-7ia25i")
                or find_first(card, attr_name="data-testid", attr_value="job-age")
            )
            if published_node:
                published_raw = clean(published_node.text())
        card_text = card.text()[:6000]
        if not published_raw:
            match = DATE_TEXT.search(card_text)
            published_raw = match.group(0) if match else None

        work_model = None
        card_lower = card_text.casefold()
        if re.search(r"remoto|home\s*office|remote|telecommute", card_lower):
            work_model = "remote"
        elif re.search(r"h[ií]brido|hybrid", card_lower):
            work_model = "hybrid"
        elif location and re.search(r"porto\s+alegre", location, re.I):
            work_model = "on_site"
        elif remote_scope:
            work_model = "remote"

        candidate = {
            "url": url,
            "title": title,
            "company": company,
            "location": location,
            "published_at": published_raw,
            "external_id": external_id,
            "work_model": work_model,
            "card_text": card_text,
        }
        candidates.append(candidate)

    unique: dict[str, dict[str, Any]] = {}
    for candidate in candidates:
        unique.setdefault(candidate["url"], candidate)
    return list(unique.values()), rejected_cards


def make_listing_record(candidate: dict[str, Any], platform: str) -> dict[str, Any]:
    published, precision = parse_date(candidate.get("published_at"))
    model = candidate.get("work_model")
    location_text = str(candidate.get("location") or "")
    if not model:
        if re.search(r"remoto|home\s*office|remote", location_text, re.I):
            model = "remote"
        elif re.search(r"h[ií]brido|hybrid", location_text, re.I):
            model = "hybrid"
        elif re.search(r"porto\s+alegre", location_text, re.I):
            model = "on_site"

    city = "Porto Alegre" if model == "remote" or re.search(r"\bporto\s+alegre\b", location_text, re.I) else None
    state = "RS" if city == "Porto Alegre" else None
    return {
        "id": None,
        "title": clean(candidate.get("title")),
        "description": None,
        "company": clean(candidate.get("company")),
        "platform": platform,
        "url": candidate["url"],
        "published_at": published.isoformat() if published else None,
        "salary": {"minimum": None, "maximum": None, "currency": None, "period": None, "raw": None},
        "schedule": None,
        "address": {
            "street": None,
            "number": None,
            "neighborhood": None,
            "city": city,
            "state": state,
            "postal_code": None,
            "country": "BR" if city or model == "remote" else None,
        },
        "additional_info": {
            "external_id": clean(candidate.get("external_id")),
            "first_seen_at": NOW.isoformat(),
            "employment_type": None,
            "work_model": model,
            "date_precision": precision,
            "listing_location": clean(location_text),
            "enrichment_status": "pending",
        },
    }

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


def next_pages(page: Page, platform: str) -> list[str]:
    # Paginação pode ficar imediatamente fora do contêiner de cards; só aceita
    # links explicitamente marcados como paginação/avanço, nunca links genéricos.
    listing_container(page, platform)
    urls: list[str] = []
    for node in find_nodes(page.document.root, tag="a"):
        href = node.attrs.get("href", "").strip()
        if not href:
            continue
        rel = node.attrs.get("rel", "").casefold()
        aria = node.attrs.get("aria-label", "").casefold()
        testid = node.attrs.get("data-testid", "").casefold()
        classes = node.attrs.get("class", "").casefold()
        label = (node.text() or "").strip().casefold()
        pagination_marker = (
            "pagination" in classes or "pager" in classes
            or "next" in rel or "next" in aria or "próxima" in aria or "proxima" in aria
            or "pagination-page-next" in testid
            or label in {">", "»", "›", "próxima", "proxima", "next"}
        )
        if not pagination_marker:
            continue
        url = urllib.parse.urljoin(page.url, href)
        parsed = urllib.parse.urlsplit(url)
        original = urllib.parse.urlsplit(page.url)
        if parsed.scheme in {"http", "https"} and parsed.netloc.casefold() == original.netloc.casefold():
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


def save_record(next_id: int, record: dict[str, Any]) -> int:
    record["id"] = next_id
    path = JOBS_DIR / f"{next_id}.json"
    log(f"[GRAVAÇÃO] Salvando {path.relative_to(ROOT)}: {record.get('title') or '(sem título)'}")
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
    log(f"[OK] {path.relative_to(ROOT)} gravado.")
    return next_id + 1


def next_id_from_disk() -> int:
    highest = 0

    # jobs.json é o histórico consolidado e continua existindo após dedup.sh.
    aggregate_path = ROOT / "jobs.json"
    if aggregate_path.exists():
        try:
            aggregate = json.loads(aggregate_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise RuntimeError(f"Não foi possível ler jobs.json para gerar IDs: {error}") from error
        if isinstance(aggregate, dict) and isinstance(aggregate.get("jobs"), list):
            aggregate = aggregate["jobs"]
        if not isinstance(aggregate, list):
            raise RuntimeError("jobs.json precisa conter uma lista de vagas.")
        for item in aggregate:
            if not isinstance(item, dict):
                continue
            ids = [item.get("id")]
            info = item.get("additional_info") or {}
            if isinstance(info, dict):
                ids.extend(info.get("merged_ids", []))
            for value in ids:
                try:
                    highest = max(highest, int(value))
                except (TypeError, ValueError):
                    continue

    # Também considera arquivos ainda não consolidados.
    for path in JOBS_DIR.glob("*.json"):
        try:
            item = json.loads(path.read_text(encoding="utf-8"))
            highest = max(highest, int(item.get("id", path.stem)))
            info = item.get("additional_info") or {}
            if isinstance(info, dict):
                for value in info.get("merged_ids", []):
                    highest = max(highest, int(value))
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
            log(f"  [PÁGINA {result['pages'] + 1}] Consultando {url}")
            page = fetcher.get(url)
            result["pages"] += 1
            log(f"  [SELETOR] Localizando contêiner de resultados de {source.name}.")
            candidates, rejected_cards = card_candidates(page, source.name)
            log(f"  [CARDS] {len(candidates)} vagas válidas; {rejected_cards} cards descartados por não conterem link de vaga reconhecido.")
            if has_explicit_no_results(page):
                log("  [RESULTADO] A página informa que não há vagas para esta consulta.")
                saw_listings = True
            if candidates:
                saw_listings = True

            for index, candidate in enumerate(candidates, start=1):
                log(f"  [VAGA {index}/{len(candidates)}] {candidate['title']}")
                record = make_listing_record(candidate, source.name)
                context = candidate.get("card_text", "")
                allowed, model = location_allowed(record, context)
                if not allowed:
                    log(f"    [FILTRO] Fora da localidade/modalidade: {candidate['location'] or 'local não identificado'}")
                    continue
                if not in_window(record, start, end):
                    log("    [FILTRO] Sem data verificável ou fora do intervalo solicitado.")
                    continue
                record.setdefault("additional_info", {})["work_model"] = model or record["additional_info"].get("work_model")
                next_id = save_record(next_id, record)
                result["saved"] += 1

            discovered = next_pages(page, source.name)
            added = 0
            for next_url in discovered:
                if next_url not in visited and next_url not in queue:
                    queue.append(next_url)
                    added += 1
            log(f"  [PAGINAÇÃO] {added} próxima(s) página(s) adicionada(s) à fila.")

        except RobotsDisallowed as error:
            result["status"] = "SKIPPED_ROBOTS"
            result["notes"].append(f"Pesquisa não permitida por robots.txt: {url} ({error})")
            log(f"  [ROBOTS] Coleta não permitida em {url}; ignorando esta plataforma/página.")
        except RobotsUnavailable as error:
            failed = True
            result["errors"].append(f"robots.txt indisponível em {url}: {error}")
            log(f"  [ERRO] Não foi possível verificar robots.txt em {url}: {error}")
        except ListingStructureError as error:
            failed = True
            result["errors"].append(f"Estrutura de resultados não reconhecida em {url}: {error}")
            log(f"  [ERRO DE ESTRUTURA] {error}")
        except Exception as error:
            failed = True
            result["errors"].append(f"Página {url}: {error}")
            log(f"  [ERRO] Falha ao consultar {url}: {error}")

    if failed:
        result["status"] = "INCOMPLETE"
    elif not saw_listings and not (result["status"] == "SKIPPED_ROBOTS" and result["pages"] == 0):
        result["status"] = "INCOMPLETE"
        result["notes"].append("Nenhum card de vaga reconhecido; a página pode ter mudado de estrutura.")
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
    log(f"[INICIALIZAÇÃO] Próximo ID interno: {next_id}")
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
