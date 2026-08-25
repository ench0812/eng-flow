"""設定：從 ~/.claude/memory-pg/.env 讀（不用 python-dotenv，格式只有 KEY=VALUE）。

環境變數優先於 .env（測試與緊急覆寫用）。找不到 DSN → ConfigError（exit 2）。
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from .errors import ConfigError


def claude_home() -> Path:
    return Path(os.environ.get("CLAUDE_HOME") or (Path.home() / ".claude"))


def env_file() -> Path:
    return claude_home() / "memory-pg" / ".env"


def _parse_env(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.is_file():
        return out
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip().strip('"').strip("'")
    return out


@dataclass(frozen=True)
class Config:
    dsn: str
    test_dsn: str | None
    ollama_url: str
    home: Path

    @property
    def bank_global(self) -> Path:
        return self.home / "memory"

    @property
    def projects_dir(self) -> Path:
        return self.home / "projects"


def load(*, use_test_db: bool = False) -> Config:
    home = claude_home()
    file_vals = _parse_env(env_file())

    def get(key: str) -> str | None:
        return os.environ.get(key) or file_vals.get(key)

    dsn = get("MEMORY_PG_DSN")
    test_dsn = get("MEMORY_PG_TEST_DSN")
    if use_test_db:
        if not test_dsn:
            raise ConfigError(f"{env_file()} 無 MEMORY_PG_TEST_DSN")
        dsn = test_dsn
    if not dsn:
        raise ConfigError(f"{env_file()} 無 MEMORY_PG_DSN（先跑 bootstrap.sh）")
    return Config(
        dsn=dsn,
        test_dsn=test_dsn,
        ollama_url=(get("OLLAMA_URL") or "http://127.0.0.1:11434").rstrip("/"),
        home=home,
    )
