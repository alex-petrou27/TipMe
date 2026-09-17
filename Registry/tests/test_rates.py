"""/v1/rates and the cache in front of the upstream price fetch."""
from tipme_registry import rates as rates_module


async def _fake_fetch(currency: str) -> tuple[float, float]:
    return 50000.0, 1.0


def test_rates_returns_bitcoin_and_usdt_price(client, monkeypatch):
    rates_module._cache.clear()
    monkeypatch.setattr(rates_module, "_fetch", _fake_fetch)
    response = client.get("/v1/rates", params={"currency": "GBP"})
    assert response.status_code == 200
    body = response.json()
    assert body["currency"] == "GBP"
    assert body["bitcoin_price"] == 50000.0
    assert body["usdt_price"] == 1.0
    assert body["as_of"]


def test_rates_defaults_to_gbp(client, monkeypatch):
    rates_module._cache.clear()
    monkeypatch.setattr(rates_module, "_fetch", _fake_fetch)
    response = client.get("/v1/rates")
    assert response.status_code == 200
    assert response.json()["currency"] == "GBP"


def test_rates_caches_within_the_ttl(client, monkeypatch):
    rates_module._cache.clear()
    calls = []

    async def counting_fetch(currency: str) -> tuple[float, float]:
        calls.append(currency)
        return 12345.0, 1.0

    monkeypatch.setattr(rates_module, "_fetch", counting_fetch)

    first = client.get("/v1/rates", params={"currency": "USD"})
    second = client.get("/v1/rates", params={"currency": "USD"})
    assert first.status_code == second.status_code == 200
    assert first.json()["bitcoin_price"] == 12345.0
    assert second.json()["bitcoin_price"] == 12345.0
    assert len(calls) == 1  # second request served from cache, no second fetch


def test_rates_surfaces_upstream_failure(client, monkeypatch):
    rates_module._cache.clear()

    async def failing_fetch(currency: str) -> tuple[float, float]:
        raise rates_module.RateUnavailable("upstream down")

    monkeypatch.setattr(rates_module, "_fetch", failing_fetch)
    response = client.get("/v1/rates", params={"currency": "EUR"})
    assert response.status_code == 503
