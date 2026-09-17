"""Generate a mnemonic for the registry's self-managed Bitcoin wallet.

    python -m tipme_registry.bitcoin_keygen

The mnemonic goes into REGISTRY_BITCOIN_MNEMONIC and nowhere else -- it *is*
the wallet. Anyone who obtains it can derive every key it ever controls and
spend everything at every address it has ever handed out, on any network.
Treat it with the same care as REGISTRY_SIGNING_PRIVATE_KEY: never logged,
never committed, never pasted anywhere it could be indexed or cached.
"""
from mnemonic import Mnemonic

if __name__ == "__main__":
    # 256 bits of entropy -> a 24-word phrase, the same strength Bitcoin
    # Core's own descriptor wallets default to.
    phrase = Mnemonic("english").generate(strength=256)
    print("REGISTRY_BITCOIN_MNEMONIC=" + phrase)
