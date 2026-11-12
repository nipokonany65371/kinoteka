"""Testy blokady logowania i ukrytego panelu admina (SQLite w pamięci, bez Dockera)."""

import re
import time

import pytest

from app import create_app
from app.config import Config
from app.extensions import db
from app.models import User


class TestConfig(Config):
    SECRET_KEY = "test-secret-key"
    SQLALCHEMY_DATABASE_URI = "sqlite://"
    SQLALCHEMY_ENGINE_OPTIONS = {}
    WTF_CSRF_ENABLED = False
    RATELIMIT_ENABLED = False
    LOGIN_MAX_ATTEMPTS = 3
    LOGIN_LOCK_MINUTES = 15
    ADMIN_SESSION_MINUTES = 15


@pytest.fixture()
def app():
    app = create_app(TestConfig)
    with app.app_context():
        db.create_all()
        for name, role in (("admin", "admin"), ("zwykly", "user")):
            user = User(username=name, email=f"{name}@example.com", role=role)
            user.set_password("haslo12345")
            db.session.add(user)
        db.session.commit()
        yield app
        db.session.remove()
        db.drop_all()


@pytest.fixture()
def client(app):
    return app.test_client()


def login(client, user="admin", password="haslo12345"):
    return client.post("/login", data={"username": user, "password": password})


def test_blokada_po_serii_nieudanych_logowan(client, app):
    for _ in range(3):
        assert login(client, "zwykly", "zle").status_code == 200
    # Teraz nawet poprawne hasło jest odrzucone, a komunikat jest ten sam.
    response = login(client, "zwykly")
    assert response.status_code == 200
    assert "czasowo zablokowane" in response.get_data(as_text=True)
    with app.app_context():
        assert db.session.scalar(db.select(User).filter_by(username="zwykly")).is_locked


def test_po_uplywie_blokady_mozna_sie_zalogowac(client, app):
    for _ in range(3):
        login(client, "zwykly", "zle")
    with app.app_context():
        user = db.session.scalar(db.select(User).filter_by(username="zwykly"))
        from datetime import timedelta
        from app.models import utcnow

        user.locked_until = utcnow() - timedelta(seconds=1)
        db.session.commit()
    assert login(client, "zwykly").status_code == 302


def test_udane_logowanie_zeruje_licznik(client, app):
    login(client, "zwykly", "zle")
    login(client, "zwykly", "zle")
    assert login(client, "zwykly").status_code == 302
    with app.app_context():
        assert db.session.scalar(db.select(User).filter_by(username="zwykly")).failed_logins == 0


def test_stary_adres_admin_to_404(client):
    login(client)
    assert client.get("/admin/").status_code == 404


def test_menu_zawiera_link_do_panelu_po_zalogowaniu_admina(client, app):
    login(client)
    html = client.get("/").get_data(as_text=True)
    assert f'href="{app.config["ADMIN_PREFIX"]}/">Panel admina</a>' in html


@pytest.mark.parametrize("user", [None, "zwykly", "admin"])
def test_menu_ukrywa_link_bez_waznej_sesji_admina(client, app, user):
    if user:
        login(client, user)
    if user == "admin":
        with client.session_transaction() as sess:
            sess["admin_until"] = int(time.time()) - 1
    html = client.get("/").get_data(as_text=True)
    assert app.config["ADMIN_PREFIX"] not in html
    assert "Panel admina" not in html


def test_hsts_na_https_za_proxy():
    class Production(TestConfig):
        SESSION_COOKIE_SECURE = True
        TRUSTED_PROXIES = 1

    client = create_app(Production).test_client()
    assert "Strict-Transport-Security" not in client.get("/live").headers
    response = client.get("/live", headers={"X-Forwarded-Proto": "https"})
    assert response.headers["Strict-Transport-Security"] == "max-age=31536000"


def test_niezalogowany_dostaje_404_bez_przekierowania(client, app):
    prefix = app.config["ADMIN_PREFIX"]
    for path in (prefix + "/", prefix, prefix + "/costam", prefix + "/users/1/toggle-active"):
        assert client.get(path).status_code == 404
    assert client.post(prefix + "/users/1/toggle-active").status_code == 404
    assert client.post(prefix + "/").status_code == 404


def test_zwykly_user_dostaje_404(client, app):
    login(client, "zwykly")
    prefix = app.config["ADMIN_PREFIX"]
    assert client.get(prefix + "/").status_code == 404
    assert client.post(prefix + "/users/1/toggle-active").status_code == 404


def test_404_wyglada_tak_samo_jak_dla_nieistniejacej_strony(client, app):
    prefix = app.config["ADMIN_PREFIX"]
    assert client.get(prefix + "/").get_data() == client.get("/nie-ma-takiej").get_data()


def test_admin_widzi_panel_i_nieznana_podstrona_to_404(client, app):
    login(client)
    prefix = app.config["ADMIN_PREFIX"]
    assert client.get(prefix + "/").status_code == 200
    assert client.get(prefix + "/costam").status_code == 404
    # Po 404 w panelu admin nadal jest zalogowany.
    assert client.get(prefix + "/").status_code == 200


def test_wygasla_sesja_admina_daje_404_i_wylogowuje(client, app):
    login(client)
    prefix = app.config["ADMIN_PREFIX"]
    with client.session_transaction() as sess:
        sess["admin_until"] = int(time.time()) - 1
    assert client.get(prefix + "/").status_code == 404
    # Wylogowany: powrót do panelu nadal 404, a strona główna widzi gościa.
    assert client.get(prefix + "/").status_code == 404
    assert "Zaloguj" in client.get("/").get_data(as_text=True)


def test_wylogowanie_z_panelu(client, app):
    login(client)
    prefix = app.config["ADMIN_PREFIX"]
    assert client.post(prefix + "/logout").status_code == 302
    assert client.get(prefix + "/").status_code == 404


def test_prefiks_jest_stabilny_i_losowy(app):
    assert re.fullmatch(r"/panel-[0-9a-f]{20}", app.config["ADMIN_PREFIX"])
    assert create_app(TestConfig).config["ADMIN_PREFIX"] == app.config["ADMIN_PREFIX"]


def test_csrf_nie_zdradza_panelu(app):
    class Csrf(TestConfig):
        WTF_CSRF_ENABLED = True

    client = create_app(Csrf).test_client()
    # Bez tokenu CSRF obcy nadal widzi 404 (nie 400).
    assert client.post(app.config["ADMIN_PREFIX"] + "/users/1/toggle-active").status_code == 404
