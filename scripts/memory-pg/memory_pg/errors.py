"""錯誤與結束碼。

三個 exit code 的語意是整套系統的契約（與 memory.sh 一致）：
  0  查詢/操作成功執行。搜尋查無也是 0，且 stderr 靜默。
  1  無法判定結果正確性（DB 連不上、schema 不符、取代關係不明、embedding 不一致…）。
     stdout 必須零輸出，stderr 至少一行 `WARN -: <code> <原因>`。
     理由：「失敗不可以長得像查無」——回空結果會被呼叫端當成「沒有相關記憶」照著做決定。
     這條對【所有】子命令成立，含診斷類（doctor / migrate --status / verify 報告）：它們在
     失敗時把報告整份改印到 stderr，不留「部分成功」形狀的 stdout 給自動化呼叫端誤讀。
  2  用法或設定錯誤（參數、.env 缺）。
"""

EXIT_OK = 0
EXIT_UNDETERMINED = 1
EXIT_USAGE = 2


class MemoryError_(Exception):
    """基底：帶 code 與 exit code。命名加底線避免遮蔽內建 MemoryError。"""

    exit_code = EXIT_UNDETERMINED
    code = "error"

    def __init__(self, message: str = "", *, code: str | None = None):
        super().__init__(message)
        if code:
            self.code = code
        self.message = message

    def stderr_line(self) -> str:
        return f"WARN -: {self.code} {self.message}".rstrip()


class ConfigError(MemoryError_):
    exit_code = EXIT_USAGE
    code = "config_missing"


class UsageError(MemoryError_):
    exit_code = EXIT_USAGE
    code = "usage"


class BackendUnavailable(MemoryError_):
    code = "backend_unavailable"


class BackendTimeout(MemoryError_):
    code = "backend_timeout"


class SchemaMismatch(MemoryError_):
    code = "schema_mismatch"


class SearchAborted(MemoryError_):
    code = "search_aborted"


class RetrievalUnavailable(MemoryError_):
    code = "retrieval_unavailable"
