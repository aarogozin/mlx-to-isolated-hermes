# Provider Roadmap

The current release keeps one inference backend: host oMLX serving an OpenAI-compatible API.

Future provider work should keep the agent sandbox abstraction unchanged. Hermes/OpenClaw should continue to receive an OpenAI-compatible base URL, API key, and selected model, while the host decides which model provider backs that URL.

## Candidates

- `MODEL_BACKEND=omlx`: current default, MLX models served by oMLX on the Mac host.
- `MODEL_BACKEND=ollama`: local Ollama server and model store.
- `MODEL_BACKEND=lmstudio`: LM Studio local server for direct OpenAI-compatible serving.
- `MODEL_BACKEND=openai-compatible`: cloud or self-hosted OpenAI-compatible APIs.
- Anthropic-compatible providers can be added through parallel `ANTHROPIC_BASE_URL`/`ANTHROPIC_API_KEY` wiring where the agent runtime supports it.

## Matrix E2E Scope

The v0.4 matrix test validates only the current oMLX backend. Provider expansion should add backend-specific smoke tests later, without weakening the four sandbox/runtime combinations already covered.
