"""Custom / Ollama (local) provider profile.

Covers any endpoint registered as provider="custom", including local
Ollama instances. Key quirks:
  - ollama_num_ctx → extra_body.options.num_ctx (local context window)
  - reasoning_config disabled → extra_body.think = False
"""

from typing import Any

from providers import register_provider
from providers.base import ProviderProfile


class CustomProfile(ProviderProfile):
    """Custom/Ollama local provider — think=false and num_ctx support."""

    def build_api_kwargs_extras(
        self,
        *,
        reasoning_config: dict | None = None,
        ollama_num_ctx: int | None = None,
        base_url: str | None = None,
        **ctx: Any,
    ) -> tuple[dict[str, Any], dict[str, Any]]:
        extra_body: dict[str, Any] = {}

        # `options` (num_ctx) and `think` are Ollama-native extensions: OpenAI's
        # API (and other clouds) reject them with HTTP 400 "Unrecognized request
        # argument". This "custom" profile is shared by local Ollama AND any
        # OpenAI-compatible cloud registered as provider=custom (e.g. an OpenAI
        # endpoint), so only emit the Ollama-isms when the endpoint is local.
        from agent.model_metadata import is_local_endpoint
        _local = bool(base_url) and is_local_endpoint(base_url)

        # Ollama context window (local only)
        if _local and ollama_num_ctx:
            options = extra_body.get("options", {})
            options["num_ctx"] = ollama_num_ctx
            extra_body["options"] = options

        # Disable Ollama thinking when reasoning is turned off (local only)
        if _local and reasoning_config and isinstance(reasoning_config, dict):
            _effort = (reasoning_config.get("effort") or "").strip().lower()
            _enabled = reasoning_config.get("enabled", True)
            if _effort == "none" or _enabled is False:
                extra_body["think"] = False

        return extra_body, {}

    def fetch_models(
        self,
        *,
        api_key: str | None = None,
        timeout: float = 8.0,
    ) -> list[str] | None:
        """Custom/Ollama: base_url is user-configured; fetch if set."""
        if not self.base_url:
            return None
        return super().fetch_models(api_key=api_key, timeout=timeout)


custom = CustomProfile(
    name="custom",
    aliases=(
        "ollama",
        "local",
        "vllm",
        "llamacpp",
        "llama.cpp",
        "llama-cpp",
    ),
    env_vars=(),  # No fixed key — custom endpoint
    base_url="",  # User-configured
)

register_provider(custom)
