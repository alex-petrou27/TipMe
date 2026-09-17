"""Real on-chain Bitcoin movement, self-managed -- no third-party custodian.

## Why this exists, and why it isn't Voltage

The Lightning integration in `lightning_node.py` is proven and works, but its
provider (Voltage's credit-backed Payments API) requires business KYB
(registered company name, jurisdiction disclosures) to move onto mainnet --
that's a real lending relationship (Voltage extends a literal line of
Bitcoin credit), not a bug or a form to route around. This module sidesteps
that relationship entirely by not having a custodian at all: the registry
itself holds a Bitcoin wallet -- a BIP84 (native segwit) HD wallet derived
from a single mnemonic -- and talks directly to the public Bitcoin network
through a public block-explorer API (mempool.space by default). Nobody
extends anybody credit; broadcasting a validly-signed transaction needs no
account, no approval, and no business.

## What this trades away

Voltage's credit-backed product did real work for us: instant settlement,
no channel liquidity to manage, no on-chain confirmation delay. Going
on-chain gives all of that up -- deposits need real confirmations (this
module credits after just one, which is a deliberate simplification for
small test amounts; do not treat that as safe for meaningful volume), and a
send is an irreversible real transaction with a real, if usually small,
network fee. There is no channel liquidity problem here (that is Lightning's
complexity, not on-chain's), but coin selection, fee estimation and change
handling are now this module's job instead of a provider's.

## Security note

`bitcoinutils`' private-key operations are pure Python and explicitly
documented upstream as not side-channel hardened -- fine for the small test
amounts this is scoped to, not a foundation for anything holding real
volume. The mnemonic in `REGISTRY_BITCOIN_MNEMONIC` is the entire wallet:
anyone who obtains it can spend everything it ever controls. Treat it with
the same care as `REGISTRY_SIGNING_PRIVATE_KEY` -- never logged, never
shipped to a client, REGISTRY_-prefixed so `make-xcconfig.sh` never lets it
near the app bundle.

## Configuration

Reads ``REGISTRY_BITCOIN_NETWORK`` (``mainnet``, ``testnet`` or ``signet``)
and ``REGISTRY_BITCOIN_MNEMONIC`` (a BIP39 mnemonic -- generate one with
``python -m tipme_registry.bitcoin_keygen``). ``REGISTRY_BITCOIN_EXPLORER_BASE_URL``
is optional and defaults to the matching mempool.space network endpoint.
Until the first two are set, ``rail_from_env`` returns ``None`` and the
on-chain endpoints fail closed with a 503, the same convention every other
rail in this codebase uses.
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Protocol

import httpx
from bitcoinutils.hdwallet import HDWallet
from bitcoinutils.keys import P2wpkhAddress, PrivateKey
from bitcoinutils.script import Script
from bitcoinutils.setup import setup as _bitcoinutils_setup
from bitcoinutils.transactions import Transaction, TxInput, TxOutput, TxWitnessInput

# BIP84 coin type per SLIP-44: mainnet is its own; every test network shares
# testnet's.
_COIN_TYPE = {"mainnet": "0'", "testnet": "1'", "signet": "1'"}

_DEFAULT_EXPLORER = {
    "mainnet": "https://mempool.space/api",
    "testnet": "https://mempool.space/testnet/api",
    "signet": "https://mempool.space/signet/api",
}

# Below this, an output costs more to ever spend (in fees) than it's worth --
# the standard reason wallets fold small change into the fee instead of
# creating it. Deliberately conservative (the real relay-policy dust limit
# for a P2WPKH output is lower) rather than exact.
_DUST_SATS = 546

# P2WPKH-only vsize model used for fee estimation: overhead + per-input +
# per-output, in vbytes. Approximate but consistently so -- a witness
# signature's size varies by only a byte or two, and this is a fee estimate,
# not the actual size the built transaction is broadcast at.
_TX_OVERHEAD_VBYTES = 11
_INPUT_VBYTES = 68
_OUTPUT_VBYTES = 31


class OnChainError(Exception):
    """The chain (or its explorer) was reached but something about the
    request didn't work -- insufficient confirmed balance, a broadcast the
    network rejected, an unsupported destination address type."""


@dataclass(frozen=True)
class OnChainConfig:
    network: str
    mnemonic: str
    explorer_base_url: str


def config_from_env() -> OnChainConfig | None:
    network = os.environ.get("REGISTRY_BITCOIN_NETWORK")
    mnemonic = os.environ.get("REGISTRY_BITCOIN_MNEMONIC")
    if not (network and mnemonic):
        return None
    if network not in _COIN_TYPE:
        raise OnChainError(
            f"REGISTRY_BITCOIN_NETWORK must be one of {sorted(_COIN_TYPE)}, got {network!r}"
        )
    explorer_base_url = os.environ.get(
        "REGISTRY_BITCOIN_EXPLORER_BASE_URL", _DEFAULT_EXPLORER[network],
    )
    return OnChainConfig(network=network, mnemonic=mnemonic,
                         explorer_base_url=explorer_base_url.rstrip("/"))


@dataclass(frozen=True)
class SendResult:
    txid: str
    fee_sats: int
    # The derivation index change was sent to, or None if the leftover after
    # the fee was too small to be worth its own output (folded into the fee
    # instead) -- the caller only needs to remember an index as "used" if it
    # actually holds anything.
    change_index: int | None


class OnChainRail(Protocol):
    async def deposit_address(self, index: int) -> str: ...
    async def confirmed_received_sats(self, address: str) -> int: ...
    async def send(self, to_address: str, amount_sats: int,
                   known_index_count: int, change_index: int) -> SendResult: ...


class SelfCustodyBitcoinRail:
    """A BIP84 (native segwit, ``bc1``/``tb1``) hot wallet the registry
    itself derives, signs for, and broadcasts from -- no custodian.

    A fresh address is derived per deposit (``m/84'/{coin}'/0'/0/{index}``)
    so the ledger never needs to disambiguate two different deposits landing
    on the same address. A withdrawal scans every index handed out so far
    for spendable confirmed UTXOs, signs each selected input with its own
    derived key, and sends change to a freshly derived index. An index, once
    handed out for anything, is never reused -- see
    `Storage.next_bitcoin_index`.
    """

    def __init__(self, config: OnChainConfig):
        self._config = config
        _bitcoinutils_setup(config.network)

    def _key_at(self, index: int) -> PrivateKey:
        wallet = HDWallet(mnemonic=self._config.mnemonic)
        wallet.from_path(f"m/84'/{_COIN_TYPE[self._config.network]}/0'/0/{index}")
        return wallet.get_private_key()

    def _client(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(base_url=self._config.explorer_base_url, timeout=15)

    @staticmethod
    def _check(response: httpx.Response) -> None:
        if response.is_success:
            return
        # Esplora-family APIs (mempool.space included) return plain-text
        # error bodies, not JSON -- unlike Voltage's {"detail": ...} shape.
        raise OnChainError(f"chain explorer returned {response.status_code}: {response.text.strip()}")

    async def deposit_address(self, index: int) -> str:
        return self._key_at(index).get_public_key().get_segwit_address().to_string()

    async def confirmed_received_sats(self, address: str) -> int:
        """Total ever confirmed-received at `address`, ignoring anything
        since spent from it. Esplora's `chain_stats` excludes mempool
        (unconfirmed) activity entirely, so any nonzero value here already
        implies at least one confirmation -- see the module docstring's
        note on why that's the bar this uses, and why a deployment moving
        real volume should require more."""
        async with self._client() as client:
            try:
                response = await client.get(f"/address/{address}")
            except httpx.HTTPError as error:
                raise OnChainError(f"could not check address: {error}") from error
            self._check(response)
            stats = response.json().get("chain_stats", {})
        return int(stats.get("funded_txo_sum", 0))

    async def send(self, to_address: str, amount_sats: int,
                   known_index_count: int, change_index: int) -> SendResult:
        try:
            destination = P2wpkhAddress(to_address).to_script_pub_key()
        except Exception as error:  # bitcoinutils raises plain ValueError/Exception on bad input
            raise OnChainError(
                "only native segwit (bech32, \"bc1\"/\"tb1\") destinations are supported today"
            ) from error

        async with self._client() as client:
            utxos_by_index = await self._gather_utxos(client, known_index_count)
            fee_rate = await self._fee_rate(client)

            selected, total_in = self._select_utxos(utxos_by_index, amount_sats, fee_rate)
            tx, fee_sats, change_used = self._build_and_sign(
                selected, total_in, destination, amount_sats, fee_rate, change_index,
            )

            try:
                response = await client.post("/tx", content=tx.serialize())
            except httpx.HTTPError as error:
                raise OnChainError(f"could not broadcast transaction: {error}") from error
            self._check(response)
            txid = response.text.strip()

        return SendResult(txid=txid, fee_sats=fee_sats,
                          change_index=change_index if change_used else None)

    async def _gather_utxos(self, client: httpx.AsyncClient,
                            known_index_count: int) -> dict[int, list[dict]]:
        """Every confirmed, spendable UTXO across every address ever handed
        out. One request per index -- fine at the handful-of-deposits scale
        this is built for; a deployment with a large deposit history would
        want to track UTXOs incrementally instead of re-scanning everything
        on every send."""
        utxos_by_index: dict[int, list[dict]] = {}
        for index in range(known_index_count):
            address = await self.deposit_address(index)
            try:
                response = await client.get(f"/address/{address}/utxo")
            except httpx.HTTPError as error:
                raise OnChainError(f"could not list UTXOs: {error}") from error
            self._check(response)
            confirmed = [u for u in response.json() if u.get("status", {}).get("confirmed")]
            if confirmed:
                utxos_by_index[index] = confirmed
        return utxos_by_index

    async def _fee_rate(self, client: httpx.AsyncClient) -> int:
        """sat/vByte. Falls back to a fixed, conservative rate if the
        explorer doesn't expose mempool.space's fee-estimation extension
        (not every esplora-compatible instance does)."""
        try:
            response = await client.get("/v1/fees/recommended")
            self._check(response)
            return int(response.json()["halfHourFee"])
        except (httpx.HTTPError, OnChainError, KeyError, ValueError):
            return 2

    def _select_utxos(self, utxos_by_index: dict[int, list[dict]], amount_sats: int,
                      fee_rate: int) -> tuple[list[tuple[int, dict]], int]:
        flat = [(index, utxo) for index, utxos in utxos_by_index.items() for utxo in utxos]
        # Largest-first: minimises the number of inputs, which minimises the
        # fee, at the cost of leaving more, smaller UTXOs unspent for later --
        # a reasonable trade for a wallet that isn't trying to consolidate.
        flat.sort(key=lambda pair: pair[1]["value"], reverse=True)

        selected: list[tuple[int, dict]] = []
        total_in = 0
        for index, utxo in flat:
            selected.append((index, utxo))
            total_in += utxo["value"]
            estimated_vsize = _TX_OVERHEAD_VBYTES + _INPUT_VBYTES * len(selected) + _OUTPUT_VBYTES * 2
            if total_in >= amount_sats + fee_rate * estimated_vsize:
                return selected, total_in
        raise OnChainError("not enough confirmed on-chain balance to cover that amount and its fee")

    def _build_and_sign(self, selected: list[tuple[int, dict]], total_in: int,
                        destination: Script, amount_sats: int, fee_rate: int,
                        change_index: int) -> tuple[Transaction, int, bool]:
        change_key = self._key_at(change_index)
        change_script = change_key.get_public_key().get_segwit_address().to_script_pub_key()

        estimated_vsize_with_change = (
            _TX_OVERHEAD_VBYTES + _INPUT_VBYTES * len(selected) + _OUTPUT_VBYTES * 2
        )
        fee_sats = fee_rate * estimated_vsize_with_change
        change_sats = total_in - amount_sats - fee_sats

        outputs = [TxOutput(amount_sats, destination)]
        change_used = change_sats >= _DUST_SATS
        if change_used:
            outputs.append(TxOutput(change_sats, change_script))
        else:
            # Leftover too small to be worth its own output -- all of it
            # becomes fee instead of dust nobody will ever spend.
            fee_sats = total_in - amount_sats

        inputs = [TxInput(utxo["txid"], utxo["vout"]) for _index, utxo in selected]
        tx = Transaction(inputs, outputs, has_segwit=True)

        for position, (index, utxo) in enumerate(selected):
            key = self._key_at(index)
            pub = key.get_public_key()
            script_code = Script(["OP_DUP", "OP_HASH160", pub.to_hash160(), "OP_EQUALVERIFY", "OP_CHECKSIG"])
            signature = key.sign_segwit_input(tx, position, script_code, utxo["value"])
            tx.witnesses.append(TxWitnessInput([signature, pub.to_hex()]))

        return tx, fee_sats, change_used


def rail_from_env() -> OnChainRail | None:
    config = config_from_env()
    if config is None:
        return None
    return SelfCustodyBitcoinRail(config)
