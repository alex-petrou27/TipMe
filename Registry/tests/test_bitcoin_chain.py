"""Configuration and pure logic for the self-managed on-chain Bitcoin rail.

Address derivation, coin selection, and transaction building are all
exercised for real here (no network) -- only broadcasting and querying the
block explorer need a live network, and those are covered by manual live
testing, the same as `lightning_node.py`'s HTTP calls.
"""
import asyncio

import pytest

from tipme_registry import bitcoin_chain

_TEST_MNEMONIC = (
    "abandon abandon abandon abandon abandon abandon abandon abandon "
    "abandon abandon abandon about"
)


def _clear(monkeypatch):
    monkeypatch.delenv("REGISTRY_BITCOIN_NETWORK", raising=False)
    monkeypatch.delenv("REGISTRY_BITCOIN_MNEMONIC", raising=False)
    monkeypatch.delenv("REGISTRY_BITCOIN_EXPLORER_BASE_URL", raising=False)


def _set_all(monkeypatch, network="signet"):
    monkeypatch.setenv("REGISTRY_BITCOIN_NETWORK", network)
    monkeypatch.setenv("REGISTRY_BITCOIN_MNEMONIC", _TEST_MNEMONIC)


def test_config_from_env_is_none_when_unset(monkeypatch):
    _clear(monkeypatch)
    assert bitcoin_chain.config_from_env() is None


def test_config_from_env_requires_both_values(monkeypatch):
    _clear(monkeypatch)
    monkeypatch.setenv("REGISTRY_BITCOIN_NETWORK", "signet")
    assert bitcoin_chain.config_from_env() is None


def test_config_from_env_rejects_an_unknown_network(monkeypatch):
    _clear(monkeypatch)
    monkeypatch.setenv("REGISTRY_BITCOIN_NETWORK", "not-a-network")
    monkeypatch.setenv("REGISTRY_BITCOIN_MNEMONIC", _TEST_MNEMONIC)
    with pytest.raises(bitcoin_chain.OnChainError):
        bitcoin_chain.config_from_env()


def test_config_from_env_defaults_the_explorer_per_network(monkeypatch):
    _clear(monkeypatch)
    _set_all(monkeypatch, network="mainnet")
    config = bitcoin_chain.config_from_env()
    assert config.explorer_base_url == "https://mempool.space/api"

    _clear(monkeypatch)
    _set_all(monkeypatch, network="signet")
    config = bitcoin_chain.config_from_env()
    assert config.explorer_base_url == "https://mempool.space/signet/api"


def test_config_from_env_allows_overriding_the_explorer(monkeypatch):
    _clear(monkeypatch)
    _set_all(monkeypatch)
    monkeypatch.setenv("REGISTRY_BITCOIN_EXPLORER_BASE_URL", "https://my-own-esplora.example/api/")
    config = bitcoin_chain.config_from_env()
    assert config.explorer_base_url == "https://my-own-esplora.example/api"


def test_rail_from_env_is_none_when_unconfigured(monkeypatch):
    _clear(monkeypatch)
    assert bitcoin_chain.rail_from_env() is None


def test_rail_from_env_returns_a_self_custody_rail_once_configured(monkeypatch):
    _clear(monkeypatch)
    _set_all(monkeypatch)
    rail = bitcoin_chain.rail_from_env()
    assert isinstance(rail, bitcoin_chain.SelfCustodyBitcoinRail)


# --- Address derivation ---

@pytest.fixture
def rail(monkeypatch):
    _clear(monkeypatch)
    _set_all(monkeypatch, network="mainnet")
    return bitcoin_chain.rail_from_env()


def test_deposit_address_matches_the_bip84_test_vector(rail):
    # The well-known BIP84 test vector for this exact mnemonic, m/84'/0'/0'/0/0.
    address = asyncio.run(rail.deposit_address(0))
    assert address == "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu"


def test_deposit_address_is_deterministic_and_index_specific(rail):
    first = asyncio.run(rail.deposit_address(1))
    again = asyncio.run(rail.deposit_address(1))
    other = asyncio.run(rail.deposit_address(2))
    assert first == again
    assert first != other


# --- Coin selection and transaction building (pure, no network) ---

def _utxo(txid_byte: str, vout: int, value: int, confirmed: bool = True) -> dict:
    return {"txid": txid_byte * 32, "vout": vout, "value": value,
            "status": {"confirmed": confirmed}}


def test_select_utxos_picks_the_fewest_inputs_that_cover_amount_and_fee(rail):
    utxos_by_index = {
        0: [_utxo("aa", 0, 20000)],
        1: [_utxo("bb", 1, 5000)],
    }
    selected, total_in = rail._select_utxos(utxos_by_index, amount_sats=15000, fee_rate=2)
    assert total_in == 20000
    assert [index for index, _utxo in selected] == [0]


def test_select_utxos_combines_multiple_when_needed(rail):
    utxos_by_index = {
        0: [_utxo("aa", 0, 8000)],
        1: [_utxo("bb", 1, 8000)],
    }
    selected, total_in = rail._select_utxos(utxos_by_index, amount_sats=15000, fee_rate=2)
    assert total_in == 16000
    assert len(selected) == 2


def test_select_utxos_raises_when_balance_is_insufficient(rail):
    utxos_by_index = {0: [_utxo("aa", 0, 100)]}
    with pytest.raises(bitcoin_chain.OnChainError):
        rail._select_utxos(utxos_by_index, amount_sats=15000, fee_rate=2)


def test_build_and_sign_produces_a_valid_two_output_transaction(rail):
    from bitcoinutils.keys import P2wpkhAddress

    utxos_by_index = {0: [_utxo("aa", 0, 20000)]}
    selected, total_in = rail._select_utxos(utxos_by_index, amount_sats=15000, fee_rate=2)
    destination = P2wpkhAddress("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4").to_script_pub_key()

    tx, fee_sats, change_used = rail._build_and_sign(
        selected, total_in, destination, amount_sats=15000, fee_rate=2, change_index=5,
    )

    assert change_used is True
    assert len(tx.outputs) == 2
    assert sum(o.amount for o in tx.outputs) == total_in - fee_sats
    assert fee_sats > 0
    # A real, parseable transaction id -- proves signing actually ran.
    assert len(tx.get_txid()) == 64


def test_build_and_sign_folds_dust_change_into_the_fee(rail):
    from bitcoinutils.keys import P2wpkhAddress

    # Leftover after amount + estimated fee is below the dust threshold.
    utxos_by_index = {0: [_utxo("aa", 0, 15300)]}
    selected, total_in = rail._select_utxos(utxos_by_index, amount_sats=15000, fee_rate=2)
    destination = P2wpkhAddress("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4").to_script_pub_key()

    tx, fee_sats, change_used = rail._build_and_sign(
        selected, total_in, destination, amount_sats=15000, fee_rate=2, change_index=5,
    )

    assert change_used is False
    assert len(tx.outputs) == 1
    assert fee_sats == total_in - 15000
