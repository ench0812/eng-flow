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
    def bank_machine(self) -> Path:
        return self.home / "memory-machine"

    @property
    def bank_work(self) -> Path:
        return self.home / "memory-work"

    @property
    def projects_dir(self) -> Path:
        return self.home / "projects"

    def bank_for_scope(self, scope: str) -> Path:
        """scope → bank 目錄。project 不在此列（它有多個 bank，由 projects.bank_path 決定）。"""
        try:
            return {"global": self.bank_global,
                    "machine": self.bank_machine,
                    "work": self.bank_work}[scope]
        except KeyError:
            raise ConfigError(f"沒有單一 bank 的 scope: {scope}") from None

    def git_dir_for_scope(self, scope: str) -> Path:
        """三個 git dir 共用 ~/.claude 工作樹，所以本機與工作的 git dir 在 home 的上一層。"""
        return {"global": self.home / ".git",
                "machine": self.home.parent / ".claude-machine.git",
                "work": self.home.parent / ".claude-work.git"}[scope]

    def bank_presence(self, scope: str) -> str:
        """installed | unavailable | damaged_install | not_installed。

        判定必須**窮舉**——「git dir 在但 bank 目錄不在」若不歸類，會被當成空 bank 而觸發
        delete-absent，把該 scope 的記憶整批刪掉。

        **只適用 global / machine / work**：project 有多個 bank，而且工作 git dir 存在
        不代表每個專案 bank 都該存在（部分 clone、新專案尚未建庫都是合法的）。
        """
        p = self.bank_for_scope(scope)
        try:
            if p.is_dir():
                return "installed" if os.access(p, os.R_OK) else "unavailable"
            if p.exists():
                return "unavailable"            # 存在但不是目錄
        except OSError:
            return "unavailable"
        return "damaged_install" if self.git_dir_for_scope(scope).exists() else "not_installed"


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
