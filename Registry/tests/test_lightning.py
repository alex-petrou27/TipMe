import pytest

from tipme_registry.lightning import InvalidLightningAddress, normalise, redact


def test_accepts_ordinary_addresses():
    assert normalise("Alice@GetAlby.com") == "alice@getalby.com"
    assert normalise("lightning:bob@strike.me") == "bob@strike.me"
    assert normalise("  first.last+tag@sub.domain.co.uk  ") == "first.last+tag@sub.domain.co.uk"


@pytest.mark.parametrize("value", [
    "",
    "nodomain",
    "@getalby.com",
    "alice@",
    "alice@localhost",
    "a@b@c.com",
    "../../etc@passwd.com",
    "alice@evil..com",
    "alice@.evil.com",
    "alice@x.com/path",
    "alice/../bob@x.com",
])
def test_rejects_malformed_and_hostile(value):
    """Whatever is stored here is where senders' money goes; a forgiving parser
    is a payment-redirection bug."""
    with pytest.raises(InvalidLightningAddress):
        normalise(value)


def test_redaction_keeps_logs_from_becoming_a_directory():
    assert redact("charlidamelio@getalby.com") == "ch***@getalby.com"
