"""Generate a registry signing keypair.

    python -m tipme_registry.keygen

The private half goes into the registry's REGISTRY_SIGNING_PRIVATE_KEY and
nowhere else. The public half is baked into the app as
TIPME_REGISTRY_PUBLIC_KEY — baked in, not fetched, because a key fetched at
runtime from the server whose responses it authenticates proves nothing.
"""
from . import signing

if __name__ == "__main__":
    private, public = signing.generate_keypair()
    print("REGISTRY_SIGNING_PRIVATE_KEY=" + private)
    print("TIPME_REGISTRY_PUBLIC_KEY=" + public)
