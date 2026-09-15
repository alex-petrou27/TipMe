"""Handle validation.

These rules deliberately mirror ``CreatorHandle`` in the iOS core. They must
stay in step: if the server accepts a handle the client will not, a creator can
register something no sender can ever look up, and the failure is silent on
both sides.
"""
from __future__ import annotations

from dataclasses import dataclass

PLATFORMS = ("tiktok", "instagram")

MAX_USERNAME_LENGTH = {"tiktok": 24, "instagram": 30}

# Path segments that are routes, not people. Without this, someone could claim
# "accounts" and collect tips from anyone who shared an Instagram login URL.
RESERVED = {
    "tiktok": {
        "t", "v", "embed", "music", "tag", "discover", "foryou", "following",
        "live", "upload", "search", "about", "legal", "business", "creators",
        "node", "share",
    },
    "instagram": {
        "p", "reel", "reels", "tv", "stories", "explore", "share", "accounts",
        "direct", "about", "developer", "legal", "privacy", "terms", "s",
        "challenge", "emails", "sessions", "web", "api", "oauth", "graphql",
        "invites", "help", "press",
    },
}

ALLOWED_CHARS = set("abcdefghijklmnopqrstuvwxyz0123456789._")


class InvalidHandle(ValueError):
    """Raised when a username could never be a real handle on that platform."""


@dataclass(frozen=True)
class Handle:
    platform: str
    username: str

    @property
    def key(self) -> str:
        return f"{self.platform}:{self.username}"


def normalise(platform: str, raw_username: str) -> Handle:
    """Validate and canonicalise. Lower-cases so lookups cannot be split by
    casing, and strips a leading ``@`` and trailing dots."""
    platform = (platform or "").strip().lower()
    if platform not in PLATFORMS:
        raise InvalidHandle(f"unknown platform {platform!r}")

    username = (raw_username or "").strip().lower()
    if username.startswith("@"):
        username = username[1:]
    username = username.rstrip(".")

    if not username:
        raise InvalidHandle("username is empty")
    if ".." in username:
        raise InvalidHandle("username contains '..'")
    if len(username) > MAX_USERNAME_LENGTH[platform]:
        raise InvalidHandle(
            f"username longer than {MAX_USERNAME_LENGTH[platform]} characters"
        )
    if not set(username) <= ALLOWED_CHARS:
        raise InvalidHandle("username contains characters that platform does not allow")
    if username in RESERVED[platform]:
        raise InvalidHandle(f"{username!r} is a reserved path, not a creator")

    return Handle(platform=platform, username=username)
