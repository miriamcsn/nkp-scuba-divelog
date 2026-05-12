import os
from sqlmodel import SQLModel, create_engine, Session

DATABASE_URL = os.getenv("DATABASE_URL", "sqlite:///./divelog.db")

# check_same_thread=False is a SQLite-specific quirk so FastAPI's worker threads can share the connection
engine = create_engine(
    DATABASE_URL,
    echo=False,
    connect_args={"check_same_thread": False} if DATABASE_URL.startswith("sqlite") else {},
)


def init_db() -> None:
    """Create all tables defined as SQLModel subclasses with table=True."""
    SQLModel.metadata.create_all(engine)


def get_session():
    """FastAPI dependency: yields a session, closes it after the request."""
    with Session(engine) as session:
        yield session
