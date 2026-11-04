from flask import Blueprint, flash, redirect, render_template, session, url_for
from flask_login import current_user, logout_user
from sqlalchemy import select

from .extensions import db
from .models import User
from .security import log_event

# Prefiks (/panel-<token>) nadaje create_app, a dostęp pilnuje admin_area_gate (bez niego 404).
bp = Blueprint("admin", __name__)


@bp.route("/", strict_slashes=False)
def index():
    users = db.session.scalars(select(User).order_by(User.created_at)).all()
    return render_template("admin/index.html", users=users)


@bp.post("/users/<int:user_id>/toggle-active")
def toggle_active(user_id):
    user = db.get_or_404(User, user_id)
    if user.id == current_user.id:
        flash("Nie możesz zablokować samego siebie.")
    else:
        user.is_active = not user.is_active
        db.session.commit()
        log_event("user_blocked" if not user.is_active else "user_unblocked", target=user.username)
        flash(f"Konto {user.username} {'odblokowane' if user.is_active else 'zablokowane'}.")
    return redirect(url_for("admin.index"))


@bp.post("/logout")
def logout():
    log_event("admin_logout")
    logout_user()
    session.clear()
    flash("Wylogowano z panelu.")
    return redirect(url_for("movies.index"))
