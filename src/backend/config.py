import os
import re


NUT_DIR = "/etc/nut"
ALLOWED_CONFIGS = {"ups.conf", "upsd.conf", "upsmon.conf", "upsd.users"}
IDENTIFIER_REGEX = re.compile(r"^[A-Za-z][A-Za-z0-9._-]{0,127}$")

NUTWATCH_HOST = os.environ.get("NUTWATCH_HOST", "0.0.0.0")

try:
    NUTWATCH_PORT = int(os.environ.get("NUTWATCH_PORT", "8081"))
except ValueError:
    NUTWATCH_PORT = 8081

# Auth: accounts + per-user API keys (see services/auth_db.py). Empty by
# default; auto-generated and persisted in the auth DB on first run if unset,
# so sessions survive restarts without requiring operator setup.
NUTWATCH_SECRET_KEY = os.environ.get("NUTWATCH_SECRET_KEY", "")
# A weak override would undermine Flask session-cookie signing. When empty we
# fall back to a strong auto-generated key (see services/auth_db.py); when set,
# fail fast unless it carries enough entropy.
if NUTWATCH_SECRET_KEY and len(NUTWATCH_SECRET_KEY) < 32:
    raise RuntimeError(
        "NUTWATCH_SECRET_KEY must be at least 32 characters; "
        "unset it to use the auto-generated key instead."
    )

# Secure defaults to false because NutWatch is typically served over plain
# HTTP on the LAN; browsers silently drop Secure cookies over non-HTTPS
# origins, which would break login. Set to true when running behind TLS.
NUTWATCH_SESSION_COOKIE_SECURE = os.environ.get(
    "NUTWATCH_SESSION_COOKIE_SECURE", "false"
).strip().lower() in ("1", "true", "yes")
