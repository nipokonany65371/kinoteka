from flask import Blueprint
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError

from .extensions import db, limiter

bp = Blueprint("main", __name__)


@bp.get("/live")
@limiter.exempt
def live():
    return {"status": "ok"}


@bp.route("/health")
@limiter.exempt
def health():
    """Zwraca 200, gdy baza odpowiada, lub 503 przy błędzie połączenia."""
    try:
        db.session.execute(text("SELECT 1"))
    except SQLAlchemyError:
        db.session.rollback()
        return {"status": "db_error"}, 503
    return {"status": "ok"}
