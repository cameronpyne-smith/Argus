"""Configurable budget constants for tool result persistence.

Per-tool resolution: pinned > config overrides > registry > default.
"""

from dataclasses import dataclass, field
from typing import Dict

# Tools whose thresholds must never be overridden.
# read_file=inf prevents infinite persist->read->persist loops.
PINNED_THRESHOLDS: Dict[str, float] = {
    "read_file": float("inf"),
}

# Defaults matching the current hardcoded values in tool_result_storage.py.
# Kept here as the single source of truth; tool_result_storage.py imports these.
DEFAULT_RESULT_SIZE_CHARS: int = 100_000
DEFAULT_TURN_BUDGET_CHARS: int = 200_000
DEFAULT_PREVIEW_SIZE_CHARS: int = 1_500


@dataclass(frozen=True)
class BudgetConfig:
    """Immutable budget constants for the 3-layer tool result persistence system.

    Layer 2 (per-result): resolve_threshold(tool_name) -> threshold in chars.
    Layer 3 (per-turn):   turn_budget -> aggregate char budget across all tool
                          results in a single assistant turn.
    Preview:              preview_size -> inline snippet size after persistence.
    """

    default_result_size: int = DEFAULT_RESULT_SIZE_CHARS
    turn_budget: int = DEFAULT_TURN_BUDGET_CHARS
    preview_size: int = DEFAULT_PREVIEW_SIZE_CHARS
    tool_overrides: Dict[str, int] = field(default_factory=dict)
    # When scaled down for a small context window, per-tool registry thresholds
    # (terminal/write_file/etc. register 100K) would otherwise outrank the
    # scaled default and let one chatty result blow the window. Clamp them.
    clamp_registry_to_default: bool = False

    def resolve_threshold(self, tool_name: str) -> int | float:
        """Resolve the persistence threshold for a tool.

        Priority: pinned -> tool_overrides -> registry per-tool -> default.
        """
        if tool_name in PINNED_THRESHOLDS:
            return PINNED_THRESHOLDS[tool_name]
        if tool_name in self.tool_overrides:
            return self.tool_overrides[tool_name]
        from tools.registry import registry
        registry_value = registry.get_max_result_size(tool_name, default=self.default_result_size)
        if self.clamp_registry_to_default:
            return min(registry_value, self.default_result_size)
        return registry_value


# Default config -- matches current hardcoded behavior exactly.
DEFAULT_BUDGET = BudgetConfig()


def scale_for_context(context_length: int | None, base: BudgetConfig = DEFAULT_BUDGET) -> BudgetConfig:
    """Scale the char budgets down when the model's context window is small.

    The defaults above were calibrated for large-context cloud models. On a
    num_ctx-capped local server (e.g. a 64K-token window) a single turn's
    tool results could legally reach ~50K tokens — twice the compression
    headroom — and the server then silently front-truncates the prompt.
    Cap one turn's aggregate at ~25% of the window and a single result at
    ~12.5%, never raising them above the calibrated defaults.
    """
    if not context_length or context_length <= 0:
        return base
    approx_chars = context_length * 4
    turn = min(base.turn_budget, int(approx_chars * 0.25))
    result = min(base.default_result_size, int(approx_chars * 0.125))
    if turn == base.turn_budget and result == base.default_result_size:
        return base
    return BudgetConfig(
        default_result_size=result,
        turn_budget=turn,
        preview_size=base.preview_size,
        tool_overrides=base.tool_overrides,
        clamp_registry_to_default=True,
    )
