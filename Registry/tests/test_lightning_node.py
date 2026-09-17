"""Configuration for the Voltage Payments rail.

The rail's HTTP behaviour (`VoltagePaymentsRail`) is exercised for real only
against an actual Voltage account -- see the module docstring. What's tested
here is the pure "is this configured" logic; `FakeLightningRail`'s own
bookkeeping is exercised indirectly by test_deposit_withdraw.py.
"""
from tipme_registry import lightning_node

_ALL_ENV_VARS = (
    "REGISTRY_VOLTAGE_API_KEY",
    "REGISTRY_VOLTAGE_ORGANIZATION_ID",
    "REGISTRY_VOLTAGE_ENVIRONMENT_ID",
    "REGISTRY_VOLTAGE_WALLET_ID",
    "REGISTRY_VOLTAGE_LINE_OF_CREDIT_ID",
)


def _clear(monkeypatch):
    for name in _ALL_ENV_VARS:
        monkeypatch.delenv(name, raising=False)
    monkeypatch.delenv("REGISTRY_VOLTAGE_API_BASE_URL", raising=False)


def _set_all(monkeypatch):
    monkeypatch.setenv("REGISTRY_VOLTAGE_API_KEY", "test-api-key")
    monkeypatch.setenv("REGISTRY_VOLTAGE_ORGANIZATION_ID", "org-123")
    monkeypatch.setenv("REGISTRY_VOLTAGE_ENVIRONMENT_ID", "production")
    monkeypatch.setenv("REGISTRY_VOLTAGE_WALLET_ID", "wallet-abc")
    monkeypatch.setenv("REGISTRY_VOLTAGE_LINE_OF_CREDIT_ID", "loc-xyz")


def test_config_from_env_is_none_when_unset(monkeypatch):
    _clear(monkeypatch)
    assert lightning_node.config_from_env() is None


def test_config_from_env_requires_every_value(monkeypatch):
    _clear(monkeypatch)
    _set_all(monkeypatch)
    monkeypatch.delenv("REGISTRY_VOLTAGE_WALLET_ID", raising=False)
    assert lightning_node.config_from_env() is None


def test_config_from_env_uses_the_documented_default_base_url(monkeypatch):
    _clear(monkeypatch)
    _set_all(monkeypatch)
    config = lightning_node.config_from_env()
    assert config is not None
    assert config.api_base_url == "https://voltageapi.com/v1"
    assert config.api_key == "test-api-key"
    assert config.organization_id == "org-123"
    assert config.environment_id == "production"
    assert config.wallet_id == "wallet-abc"
    assert config.line_of_credit_id == "loc-xyz"


def test_config_from_env_allows_overriding_the_base_url(monkeypatch):
    _clear(monkeypatch)
    _set_all(monkeypatch)
    monkeypatch.setenv("REGISTRY_VOLTAGE_API_BASE_URL", "https://staging.voltageapi.com/v1/")
    config = lightning_node.config_from_env()
    assert config is not None
    assert config.api_base_url == "https://staging.voltageapi.com/v1"


def test_rail_from_env_is_none_when_unconfigured(monkeypatch):
    _clear(monkeypatch)
    assert lightning_node.rail_from_env() is None


def test_rail_from_env_returns_a_voltage_rail_once_configured(monkeypatch):
    _clear(monkeypatch)
    _set_all(monkeypatch)
    rail = lightning_node.rail_from_env()
    assert isinstance(rail, lightning_node.VoltagePaymentsRail)
