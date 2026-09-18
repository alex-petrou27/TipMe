"""Fetches a public post's link-preview metadata -- the same technique
iMessage, Slack, and every other link-unfurl feature uses, and the same one
`PageTitleFetcher` already uses client-side (in the share extension) to
resolve who a shared post is from. See that file's doc comment for why
`facebookexternalhit` is the right identity to fetch Instagram pages under:
it's the identity Meta's own products use for link previews, so Instagram
has every reason to keep serving it the real, server-rendered page instead
of a stripped-down one.

Reused here for creator verification: if a claim token only the real
account owner could have set shows up in a page Instagram/TikTok serves
back for that account's own URL, that's real proof, gathered the same
legitimate way any link unfurl works -- fetching a URL, not crawling with
credentials or a private API. Two fields matter, confirmed by fetching
real profiles (NASA vs. Cristiano Ronaldo, one with a bio and one without)
before relying on this:

  - `og:description` -- for a POST/Reel this is the caption ("N likes, N
    comments - username on <date>: caption"), confirmed on a real device.
    For a PROFILE it is *not* the bio -- Instagram fills it with generic
    follower-count boilerplate instead.
  - The plain `<meta name="description">` tag -- for a PROFILE this one
    *does* carry the real bio, verbatim, in a trailing quoted segment
    ("... on Instagram: \"<bio>\""). Confirmed live: NASA's fetch echoed
    their actual bio text exactly as shown in the app; Cristiano's (who
    has no bio) came back with an empty quoted string, not a stale cache
    or a wrong guess.

So a profile fetch and a post fetch each carry proof in a different one of
these two fields -- callers should check both, not just one.
"""
from __future__ import annotations

import re
from dataclasses import dataclass

import httpx

USER_AGENT = "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)"
MAX_BYTES = 65_536


class PageFetchError(Exception):
    """The page couldn't be fetched at all -- offline, 404, timeout, etc."""


@dataclass(frozen=True)
class PageMetadata:
    og_description: str | None
    meta_description: str | None
    canonical_url: str | None

    def contains(self, token: str) -> bool:
        """Whichever field actually carries proof for this kind of page."""
        return token in (self.og_description or "") or token in (self.meta_description or "")


_OG_DESCRIPTION = re.compile(
    r'<meta\s+property=["\']og:description["\']\s+content=["\']([^"\']*)["\']'
    r'|<meta\s+content=["\']([^"\']*)["\']\s+property=["\']og:description["\']',
    re.IGNORECASE,
)
_META_DESCRIPTION = re.compile(
    r'<meta\s+name=["\']description["\']\s+content=["\']([^"\']*)["\']'
    r'|<meta\s+content=["\']([^"\']*)["\']\s+name=["\']description["\']',
    re.IGNORECASE,
)
_CANONICAL = re.compile(
    r'<link\s+rel=["\']canonical["\']\s+href=["\']([^"\']*)["\']'
    r'|<link\s+href=["\']([^"\']*)["\']\s+rel=["\']canonical["\']',
    re.IGNORECASE,
)


async def fetch(url: str, *, timeout: float = 6.0) -> PageMetadata:
    headers = {"User-Agent": USER_AGENT, "Accept": "text/html"}
    body = b""
    try:
        async with httpx.AsyncClient(timeout=timeout, follow_redirects=True) as client:
            async with client.stream("GET", url, headers=headers) as response:
                response.raise_for_status()
                async for chunk in response.aiter_bytes():
                    body += chunk
                    # Metadata is always within the first few KB of <head> --
                    # no need to read a multi-megabyte page past that.
                    if len(body) >= MAX_BYTES:
                        break
    except httpx.HTTPError as error:
        raise PageFetchError(str(error)) from error

    html = body.decode("utf-8", errors="ignore")
    return PageMetadata(og_description=_first_match(_OG_DESCRIPTION, html),
                        meta_description=_first_match(_META_DESCRIPTION, html),
                        canonical_url=_first_match(_CANONICAL, html))


def _first_match(pattern: re.Pattern, text: str) -> str | None:
    match = pattern.search(text)
    if not match:
        return None
    for group in match.groups():
        if group:
            return group.strip()
    return None
