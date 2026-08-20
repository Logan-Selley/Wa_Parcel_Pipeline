"""Warehouse connection.

Credentials come from .env, which is gitignored. .env.example documents the keys.
Nothing in this package accepts a password as an argument or logs a DSN.
"""

from __future__ import annotations

import os
from pathlib import Path

from dotenv import load_dotenv
from sqlalchemy import Engine, create_engine

REPO_ROOT = Path(__file__).resolve().parent.parent


def _require(key: str) -> str:
    value = os.environ.get(key)
    if not value:
        raise RuntimeError(
            f"{key} is not set. Copy .env.example to .env and fill it in."
        )
    return value


def get_engine() -> Engine:
    """SQLAlchemy engine for the local PostGIS warehouse.

    Note the port: the container maps 5433 on the host to 5432 inside, so
    anything running outside Docker connects on 5433.
    """
    load_dotenv(REPO_ROOT / ".env")

    user = _require("POSTGRES_USER")
    password = _require("POSTGRES_PASSWORD")
    host = os.environ.get("WAREHOUSE_HOST", "localhost")
    port = os.environ.get("WAREHOUSE_PORT", "5433")
    database = _require("POSTGRES_DB")

    return create_engine(
        f"postgresql+psycopg2://{user}:{password}@{host}:{port}/{database}",
        future=True,
    )
