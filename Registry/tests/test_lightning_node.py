"""Configuration for the Voltage Payments rail.

The rail's HTTP behaviour (`VoltagePaymentsRail`) is exercised for real only
against an actual Voltage account -- see the module docstring. What's tested
here is the pure "is this configured" logic, plus the local BOLT11 amount
decoder (which needs no network at all); `FakeLightningRail`'s own
bookkeeping is exercised indirectly by test_deposit_withdraw.py.
"""
import pytest

from tipme_registry import lightning_node

_ALL_ENV_VARS = (
    "REGISTRY_VOLTAGE_API_KEY",
    "REGISTRY_VOLTAGE_ORGANIZATION_ID",
    "REGISTRY_VOLTAGE_ENVIRONMENT_ID",
    "REGISTRY_VOLTAGE_WALLET_ID",
    "REGISTRY_VOLTAGE_LINE_OF_CREDIT_ID",
    "REGISTRY_VOLTAGE_NETWORK",
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
    monkeypatch.setenv("REGISTRY_VOLTAGE_NETWORK", "mutinynet")


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
    assert config.network == "mutinynet"


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


# Real invoices from live testing against a Voltage Mutinynet wallet -- these
# amounts (1000 and 300 sats) are independently confirmed by what was
# actually credited/paid, not just re-deriving the encoding.
_REAL_1000_SAT_INVOICE = (
    "lntbs10u1p42cer8pp5n22m02nyv8vflvaess8cxdsykstptkmvjsszhgykrrqezxrlp73q"
    "dqqcqzzsxqrrsssp5ypj5qhhsgwwg9cpf0ql4s3s3jgzk05v6yjt3gk9w49fx5pcmmwxs9qx"
    "pqysgqeglfk0gd0v8aths9sv9jw8asazdale9d0uw68lxtq0aaq6pk2cn8yf9re9mzqsl3f"
    "tqqkg3f9zuayp6xm97w4l6njnnjnk4d4getfeqqad930y"
)
_REAL_300_SAT_INVOICE = (
    "lntbs3u1p42c6qapp5ekjg0cnv3tgnahk02tyvf0td4074plmrl9zc69rhxvduzkq3j55qd"
    "qqcqzzsxqrrsssp58677fv2z9lm6je0pme4y8pqnp4htc8aqp4lm2kmakdx5cjuxdzys9qx"
    "pqysgq6sccgfxzdzn9c2vxpzd6q7ezy4c3hmwhpz8dp0gyve7mzxj34tys9qe0hww6l2cg8"
    "u64alp938eckge69atlkh7s4hkhz084pya3r8cq3g9ecj"
)


def test_bolt11_amount_sats_matches_real_confirmed_invoices():
    assert lightning_node._bolt11_amount_sats(_REAL_1000_SAT_INVOICE) == 1000
    assert lightning_node._bolt11_amount_sats(_REAL_300_SAT_INVOICE) == 300


def test_bolt11_amount_sats_is_case_insensitive():
    assert lightning_node._bolt11_amount_sats(_REAL_300_SAT_INVOICE.upper()) == 300


@pytest.mark.parametrize(
    "amount,multiplier,expected_sats",
    [
        (5, "m", 500_000),   # milli-bitcoin
        (10, "u", 1000),     # micro-bitcoin
        (5, "n", 0),         # nano-bitcoin, sub-satoshi rounds down to 0
        (10_000, "n", 1000), # nano-bitcoin, a whole number of sats
        (10_000, "p", 1),    # pico-bitcoin, exactly 1 sat
    ],
)
def test_bolt11_amount_sats_handles_every_multiplier(amount, multiplier, expected_sats):
    invoice = f"lntb{amount}{multiplier}1p0mockdata"
    assert lightning_node._bolt11_amount_sats(invoice) == expected_sats


def test_bolt11_amount_sats_rejects_non_invoice_strings():
    with pytest.raises(lightning_node.LightningNodeError):
        lightning_node._bolt11_amount_sats("not-an-invoice")


def test_bolt11_amount_sats_rejects_zero_amount_invoices():
    with pytest.raises(lightning_node.LightningNodeError):
        lightning_node._bolt11_amount_sats("lntbs1p42cer8pp5mockdata")


def test_bolt11_amount_sats_rejects_fractional_millisatoshi_pico_amounts():
    with pytest.raises(lightning_node.LightningNodeError):
        lightning_node._bolt11_amount_sats("lntbs15p1p0mockdata")
