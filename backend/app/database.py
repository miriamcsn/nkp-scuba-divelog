import os
import time
import logging
from sqlmodel import SQLModel, create_engine, Session
from sqlalchemy.exc import OperationalError

log = logging.getLogger("uvicorn.error")

DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "mysql+pymysql://divelog:divelog@localhost:3306/divelog"
)

engine = create_engine(DATABASE_URL, pool_pre_ping=True, echo=False)


def _wait_for_db(max_attempts: int = 30, delay_seconds: float = 2.0) -> None:
    """Block until the database accepts connections, or give up after max_attempts."""
    for attempt in range(1, max_attempts + 1):
        try:
            with engine.connect() as conn:
                conn.exec_driver_sql("SELECT 1")
            log.info("Database is up (attempt %d).", attempt)
            return
        except OperationalError as e:
            log.warning("DB not ready (attempt %d/%d): %s", attempt, max_attempts, e.orig)
            time.sleep(delay_seconds)
    raise RuntimeError(f"Database did not become ready after {max_attempts} attempts.")


def init_db() -> None:
    """Wait for the DB, then create all tables. Safe to call on every startup."""
    _wait_for_db()
    from . import models  # noqa: F401  — register models with SQLModel.metadata
    SQLModel.metadata.create_all(engine)


def get_session():
    with Session(engine) as session:
        yield session


# SQLite-style:

# import os
# from sqlmodel import SQLModel, create_engine, Session

# DATABASE_URL = os.getenv("DATABASE_URL", "sqlite:///./divelog.db")

# # check_same_thread=False is a SQLite-specific quirk so FastAPI's worker threads can share the connection
# engine = create_engine(
#     DATABASE_URL,
#     echo=False,
#     connect_args={"check_same_thread": False} if DATABASE_URL.startswith("sqlite") else {},
# )


# def init_db() -> None:
#     """Create all tables defined as SQLModel subclasses with table=True."""
#     SQLModel.metadata.create_all(engine)


# def get_session():
#     """FastAPI dependency: yields a session, closes it after the request."""
#     with Session(engine) as session:
#         yield session

