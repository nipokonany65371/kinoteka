import os
from datetime import timedelta


def _env_bool(name, default=False):
    value = os.environ.get(name)
    if value is None:
        return default
    return value.strip().lower() in ("1", "true", "yes", "on")


class Config:
    # Sekrety i adres bazy zawsze ze zmiennych środowiskowych, nigdy w kodzie.
    SECRET_KEY = os.environ.get("SECRET_KEY")
    SQLALCHEMY_DATABASE_URI = os.environ.get("DATABASE_URL")
    SQLALCHEMY_ENGINE_OPTIONS = {"pool_pre_ping": True}

    # Pliki (plakaty). Domyślnie instance/uploads, w chmurze docelowo storage obiektowy.
    UPLOAD_FOLDER = os.environ.get("UPLOAD_FOLDER")
    MAX_CONTENT_LENGTH = 2 * 1024 * 1024  # 2 MB na request

    # Sesja
    PERMANENT_SESSION_LIFETIME = timedelta(minutes=int(os.environ.get("SESSION_MINUTES", "30")))
    SESSION_COOKIE_HTTPONLY = True
    SESSION_COOKIE_SAMESITE = "Lax"
    SESSION_COOKIE_SECURE = _env_bool("SESSION_COOKIE_SECURE")

    # Blokada konta po serii nieudanych logowań (timeout).
    LOGIN_MAX_ATTEMPTS = int(os.environ.get("LOGIN_MAX_ATTEMPTS", "5"))
    LOGIN_LOCK_MINUTES = int(os.environ.get("LOGIN_LOCK_MINUTES", "15"))

    # Panel admina leży pod losowym prefiksem /panel-<token>. Bez ADMIN_PANEL_TOKEN
    # token jest wyliczany z SECRET_KEY (stały między restartami i instancjami).
    ADMIN_PANEL_TOKEN = os.environ.get("ADMIN_PANEL_TOKEN")
    # Po tylu minutach bez aktywności w panelu admin jest wylogowywany, a panel daje 404.
    ADMIN_SESSION_MINUTES = int(os.environ.get("ADMIN_SESSION_MINUTES", "15"))

    # Ile proxy (np. load balancer) stoi przed aplikacją. 0 = brak.
    TRUSTED_PROXIES = int(os.environ.get("TRUSTED_PROXIES", "0"))

    # Rate limiting. Przy kilku instancjach trzeba wspólnego magazynu, np. redis://...
    RATELIMIT_STORAGE_URI = os.environ.get("RATELIMIT_STORAGE_URI", "memory://")
