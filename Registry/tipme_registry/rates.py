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


class RateUnavailable(RuntimeError):
    """Raised when the upstream price source cannot be reached, or has no
    price for the requested currency."""


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

    bitcoin_price, usdt_price = await _fetch(currency)
    _cache[code] = (bitcoin_price, usdt_price, now)
    return bitcoin_price, usdt_price
