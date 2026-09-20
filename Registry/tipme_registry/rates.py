"""Fiat exchange rates for BTC and USDT.

Fetched from a public price API rather than a wallet SDK -- now that the app
is custodial, it no longer runs its own Breez SDK instance to get rates from.
See the account/ledger work in accounts.py and storage.py.
"""
from __future__ import annotations

import time

import httpx

_COINGECKO_URL = "https://api.coingecko.com/api/v3/simple/price"

# Public API, no key, no SLA. Cached in-process so a burst of app requests
# for the same currency does not turn into a burst of upstream requests --
# CoinGecko's free tier rate-limits aggressively enough that this is not
# optional.
_CACHE_TTL = 30.0
_cache: dict[str, tuple[float, float, float]] = {}

# Approximate fallback prices (fiat major units per one whole coin), used
# only when CoinGecko is unreachable or rate-limited -- confirmed to happen
# in practice: its free tier has no SLA and rate-limits aggressively under
# any real burst of traffic, and every tip in this app now depends on a
# rate lookup succeeding (see TipSheetViewModel.selectAmount). A tip quoted
# a few percent off a live price is a rounding annoyance; a tip that cannot
# be quoted at all because a free public API had a bad moment is a broken
# product. These are rough, deliberately not auto-updated -- if they drift
# far from reality, tighten them, but they exist to fail soft, not to be
# precise.
_FALLBACK_PRICES: dict[str, tuple[float, float]] = {
    "usd": (95_000.0, 1.00),
    "gbp": (75_000.0, 0.79),
    "eur": (88_000.0, 0.92),
}


class RateUnavailable(RuntimeError):
    """Raised when the upstream price source cannot be reached and no
    fallback exists for the requested currency."""


async def _fetch(currency: str) -> tuple[float, float]:
    """Returns (bitcoin_price, usdt_price): fiat major units per one whole
    coin, in `currency`."""
    code = currency.lower()
    async with httpx.AsyncClient(timeout=10) as client:
        try:
            response = await client.get(_COINGECKO_URL, params={
                "ids": "bitcoin,tether",
                "vs_currencies": code,
            })
            response.raise_for_status()
            data = response.json()
        except (httpx.HTTPError, ValueError) as error:
            raise RateUnavailable(str(error)) from error

    try:
        bitcoin_price = float(data["bitcoin"][code])
        usdt_price = float(data["tether"][code])
    except (KeyError, TypeError, ValueError) as error:
        raise RateUnavailable(f"no price available for currency {currency!r}") from error
    return bitcoin_price, usdt_price


async def get(currency: str) -> tuple[float, float]:
    code = currency.lower()
    now = time.monotonic()
    cached = _cache.get(code)
    if cached is not None and now - cached[2] < _CACHE_TTL:
        return cached[0], cached[1]

    try:
        bitcoin_price, usdt_price = await _fetch(currency)
    except RateUnavailable:
        fallback = _FALLBACK_PRICES.get(code)
        if fallback is None:
            raise
        bitcoin_price, usdt_price = fallback
    _cache[code] = (bitcoin_price, usdt_price, now)
    return bitcoin_price, usdt_price
