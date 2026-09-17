"""Configuration for the Voltage Lightning rail.

The rail's HTTP behaviour (`VoltageLightningRail`) is exercised for real
only against an actual node -- see the module docstring. What's tested here
is the pure "is this configured" logic, and `FakeLightningRail`'s own
bookkeeping (exercised indirectly by test_deposit_withdraw.py).
"""
from tipme_registry import lightning_node


def test_config_from_env_is_none_when_unset(monkeypatch):
    monkeypatch.delenv("REGISTRY_VOLTAGE_REST_URL", raising=False)
    monkeypatch.delenv("REGISTRY_VOLTAGE_MACAROON_HEX", raising=False)
    assert lightning_node.config_from_env() is None


def test_config_from_env_requires_both_values(monkeypatch):
    monkeypatch.setenv("REGISTRY_VOLTAGE_REST_URL", "https://node.example.voltageapp.io")
    monkeypatch.delenv("REGISTRY_VOLTAGE_MACAROON_HEX", raising=False)
    assert lightning_node.config_from_env() is None


def test_config_from_env_strips_a_trailing_slash(monkeypatch):
    monkeypatch.setenv("REGISTRY_VOLTAGE_REST_URL", "https://node.example.voltageapp.io/")
    monkeypatch.setenv("REGISTRY_VOLTAGE_MACAROON_HEX", "deadbeef")
    config = lightning_node.config_from_env()
    assert config is not None
    assert config.rest_url == "https://node.example.voltageapp.io"
    assert config.macaroon_hex == "deadbeef"


def test_rail_from_env_is_none_when_unconfigured(monkeypatch):
    monkeypatch.delenv("REGISTRY_VOLTAGE_REST_URL", raising=False)
    monkeypatch.delenv("REGISTRY_VOLTAGE_MACAROON_HEX", raising=False)
    assert lightning_node.rail_from_env() is None


def test_rail_from_env_returns_a_voltage_rail_once_configured(monkeypatch):
    monkeypatch.setenv("REGISTRY_VOLTAGE_REST_URL", "https://node.example.voltageapp.io")
    monkeypatch.setenv("REGISTRY_VOLTAGE_MACAROON_HEX", "deadbeef")
    rail = lightning_node.rail_from_env()
    assert isinstance(rail, lightning_node.VoltageLightningRail)
