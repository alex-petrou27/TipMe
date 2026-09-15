"""These rules must match CreatorHandle in the iOS core exactly.

If the server accepts a handle the client will not, a creator can register
something no sender is able to look up, and neither side reports an error.
"""
import pytest

from tipme_registry.handles import InvalidHandle, normalise


def test_lowercases_and_strips_at_sign():
    assert normalise("tiktok", "@ZachKing").username == "zachking"
    assert normalise("TikTok", "zachking").platform == "tiktok"


def test_strips_trailing_dots():
    assert normalise("tiktok", "someone.").username == "someone"


def test_allows_platform_legal_characters():
    assert normalise("tiktok", "charli.damelio").username == "charli.damelio"
    assert normalise("instagram", "nat_geo.official").username == "nat_geo.official"


@pytest.mark.parametrize("platform,username", [
    ("tiktok", ""),
    ("tiktok", "@"),
    ("tiktok", ".."),
    ("tiktok", "a" * 25),
    ("instagram", "a" * 31),
    ("tiktok", "créator"),
    ("tiktok", "user name"),
    ("tiktok", "user/../other"),
    ("mastodon", "someone"),
])
def test_rejects_impossible_handles(platform, username):
    with pytest.raises(InvalidHandle):
        normalise(platform, username)


@pytest.mark.parametrize("platform,username", [
    ("instagram", "accounts"),
    ("instagram", "explore"),
    ("instagram", "p"),
    ("tiktok", "discover"),
    ("tiktok", "music"),
])
def test_rejects_reserved_paths(platform, username):
    """Someone claiming 'accounts' would collect tips from anyone who shared an
    Instagram login URL."""
    with pytest.raises(InvalidHandle):
        normalise(platform, username)


def test_length_limits_are_per_platform():
    assert normalise("tiktok", "a" * 24)
    assert normalise("instagram", "a" * 30)
