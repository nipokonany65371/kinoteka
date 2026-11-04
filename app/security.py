"""Log zdarzeń bezpieczeństwa (logowania, blokady, odmowy dostępu)."""

import hashlib
import hmac
import logging
import re
import time
from functools import wraps

from flask import abort, current_app, request, session
from flask_login import current_user, logout_user

logger = logging.getLogger("kinoteka.security")


def setup_security_logger():
    if logger.handlers:
        return
    handler = logging.StreamHandler()
    handler.setFormatter(logging.Formatter("%(asctime)s SECURITY %(message)s"))
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)
    logger.propagate = False


def log_event(event, **details):
    user = current_user.get_id() if current_user.is_authenticated else "-"
    # repr() escapuje znaki nowej linii, więc dane od użytkownika nie podrobią wpisów w logu.
    extra = " ".join(f"{key}={value!r}" for key, value in details.items())
    logger.info("event=%s user=%s ip=%s %s", event, user, request.remote_addr, extra)


def forbid():
    log_event("forbidden", path=request.path)
    abort(403)


def require_owner_or_admin(owner_id):
    if not (current_user.is_admin or current_user.id == owner_id):
        forbid()


def admin_required(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        if not current_user.is_admin:
            forbid()
        return view(*args, **kwargs)

    return wrapped


# --- Panel admina pod ukrytym prefiksem ---------------------------------------------------

_TOKEN_RE = re.compile(r"^[A-Za-z0-9]{12,64}$")


def admin_prefix(app=None):
    """Prefiks panelu: /panel-<token>. Token z ADMIN_PANEL_TOKEN albo wyliczony z SECRET_KEY."""
    app = app or current_app
    token = app.config.get("ADMIN_PANEL_TOKEN")
    if token:
        if not _TOKEN_RE.match(token):
            raise RuntimeError("ADMIN_PANEL_TOKEN: 12-64 znaków, tylko litery i cyfry.")
    else:
        token = hmac.new(app.config["SECRET_KEY"].encode(), b"admin-panel-prefix", hashlib.sha256).hexdigest()[:20]
    return f"/panel-{token}"


def start_admin_session():
    """Admin dostaje przy logowaniu znacznik czasu, po którego upływie panel daje 404."""
    session["admin_until"] = int(time.time()) + current_app.config["ADMIN_SESSION_MINUTES"] * 60


def _in_admin_area(path):
    prefix = current_app.config["ADMIN_PREFIX"]
    return path == prefix or path.startswith(prefix + "/")


def admin_area_gate():
    """before_request: cały prefiks panelu widzi tylko zalogowany admin z ważną sesją admina.

    Każdy inny (niezalogowany, zwykły user, wygasła sesja admina) dostaje zwykłe 404,
    bez przekierowania na logowanie i bez 403, więc nie widać, że panel istnieje.
    Musi być zarejestrowany przed CSRF, żeby brak tokenu też nie zdradzał adresu.
    """
    if not _in_admin_area(request.path):
        return
    if not (current_user.is_authenticated and current_user.is_admin):
        log_event("admin_area_denied", path=request.path[:200])
        abort(404)
    if int(session.get("admin_until", 0)) <= time.time():
        # Sesja admina wygasła: wylogowanie całkowite, a panel udaje, że go nie ma.
        log_event("admin_session_expired", path=request.path[:200])
        logout_user()
        session.clear()
        abort(404)
    start_admin_session()  # odświeżenie po aktywności (sesja przesuwna)
