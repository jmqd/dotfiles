"""Download files politely: one host at a time, robots.txt first, under an honest name.

Used for a listing's photos and for map tiles. Listing pages themselves are
read in a browser, not here.
"""

from __future__ import annotations

import ssl
import time
import urllib.error
import urllib.request
from typing import Dict, Optional, Tuple
from urllib.parse import urlsplit

import robots

USER_AGENT = "jpx-brochure/1.0 (personal use; one listing at a time)"
MAX_BYTES = 40 * 1024 * 1024


class Disallowed(Exception):
    """robots.txt forbids the URL, or the host's robots.txt could not be read."""


class FetchFailed(Exception):
    """The server did not return the file."""


def robots_state(status: int, body: str) -> Tuple[str, Optional[str]]:
    """What a host's robots.txt response means: ("open", None), ("rules", text) or ("closed", reason).

    No robots.txt (404, 410) permits everything. Any other failure closes the
    host: a 403 or 5xx on robots.txt is the site declining automated visitors.
    """
    if status in (404, 410):
        return "open", None
    if status == 200:
        return "rules", body
    return "closed", "robots.txt returned HTTP %d" % status


class Fetcher:
    def __init__(self, delay_seconds: float = 1.0) -> None:
        self.delay_seconds = delay_seconds
        self._rules: Dict[str, Tuple[str, Optional[str]]] = {}
        self._last: Dict[str, float] = {}
        # One TLS context for the run: building one per request reloads the
        # system's certificate store each time, which takes seconds.
        self._opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ssl.create_default_context()))

    def _wait(self, host: str) -> None:
        elapsed = time.monotonic() - self._last.get(host, 0.0)
        if elapsed < self.delay_seconds:
            time.sleep(self.delay_seconds - elapsed)
        self._last[host] = time.monotonic()

    def _request(self, url: str, referer: Optional[str]) -> Tuple[int, str, bytes]:
        headers = {"User-Agent": USER_AGENT, "Accept": "*/*"}
        if referer:
            headers["Referer"] = referer
        self._wait(urlsplit(url).netloc)
        request = urllib.request.Request(url, headers=headers)
        try:
            with self._opener.open(request, timeout=30) as response:
                body = response.read(MAX_BYTES + 1)
                if len(body) > MAX_BYTES:
                    raise FetchFailed("%s is larger than %d MB" % (url, MAX_BYTES // 1024 // 1024))
                return response.status, response.headers.get("Content-Type", ""), body
        except urllib.error.HTTPError as error:
            return error.code, error.headers.get("Content-Type", "") if error.headers else "", b""
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            raise FetchFailed("%s: %s" % (url, error)) from error

    def _robots(self, url: str) -> Tuple[str, Optional[str]]:
        parts = urlsplit(url)
        origin = "%s://%s" % (parts.scheme, parts.netloc)
        if origin not in self._rules:
            try:
                status, _kind, body = self._request(origin + "/robots.txt", None)
            except FetchFailed as error:
                self._rules[origin] = ("closed", str(error))
            else:
                self._rules[origin] = robots_state(status, body.decode("utf-8", errors="replace"))
        return self._rules[origin]

    def check(self, url: str) -> None:
        """Raise Disallowed unless robots.txt permits fetching `url`."""
        state, detail = self._robots(url)
        if state == "closed":
            raise Disallowed("%s: %s" % (urlsplit(url).netloc, detail))
        if state == "rules" and not robots.allowed(detail, url):
            raise Disallowed("robots.txt disallows %s" % url)

    def get(self, url: str, referer: Optional[str] = None) -> Tuple[str, bytes]:
        """(content type, body) of `url`. Raises Disallowed or FetchFailed."""
        self.check(url)
        status, kind, body = self._request(url, referer)
        if status != 200:
            raise FetchFailed("%s returned HTTP %d" % (url, status))
        return kind, body
