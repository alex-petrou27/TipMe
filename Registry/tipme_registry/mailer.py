"""Delivers transactional email -- today, just the password-reset code.

No real email provider (SMTP, Postmark, SendGrid, SES...) is wired up yet.
That is a real gap for production -- an actual creator cannot receive a code
mailed only to this process's own log -- but it should not block *building
and testing* the reset flow itself, the way `oauth.py` fails closed with a
503 when a platform's client id/secret are absent. A password reset has no
equivalent safe "fail closed": refusing to work at all would mean nobody
could test or use the feature until a paid email provider is configured, for
what is otherwise a fully self-contained flow.

So the fallback here is a loud, clearly-labelled log line instead. Whoever
operates this process can read the code there for local testing right now;
swapping in a real provider later is a one-function change, not a redesign
-- see `send_password_reset` below for exactly where that goes.
"""
from __future__ import annotations

import logging

logger = logging.getLogger("tipme_registry.mailer")


def send_password_reset(email: str, code: str) -> None:
    # TODO(production): call a real provider here (SMTP, Postmark, SendGrid,
    # SES...) instead of logging. Keep the log line as a local-dev fallback
    # when no provider is configured, the same way oauth.py's config_for
    # falls back to "not configured" rather than crashing.
    logger.warning(
        "[DEV EMAIL] Password reset code for %s: %s (expires in 30 minutes). "
        "No real email provider is configured -- see mailer.py.",
        email, code,
    )
