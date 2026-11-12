import os

import psycopg
from psycopg import sql


def grant_runtime_access():
    connection_url = os.environ["DATABASE_URL"].replace("postgresql+psycopg://", "postgresql://", 1)
    runtime_role = "kinoteka_app"
    password = sql.Literal(os.environ["RUNTIME_DB_PASSWORD"])
    role = sql.Identifier(runtime_role)

    with psycopg.connect(connection_url) as connection:
        exists = connection.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (runtime_role,)).fetchone()
        if exists:
            connection.execute(sql.SQL("ALTER ROLE {} PASSWORD {}").format(role, password))
        else:
            connection.execute(sql.SQL("CREATE ROLE {} LOGIN PASSWORD {}").format(role, password))

        connection.execute(sql.SQL("GRANT USAGE ON SCHEMA public TO {}").format(role))
        for table in ("users", "movies", "reviews", "comments"):
            connection.execute(
                sql.SQL("GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.{} TO {}").format(
                    sql.Identifier(table), role
                )
            )
        connection.execute(sql.SQL("GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO {}").format(role))


if __name__ == "__main__":
    grant_runtime_access()
