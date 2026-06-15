# Antigravity CLI Tools

This agent is running in Google's Antigravity CLI (`agy`).

## Launch Contract

- Shogun launches Antigravity with `agy --dangerously-skip-permissions`.
- If `settings.yaml` provides a concrete `model`, Shogun passes it as `--model <model>`.
- If the model is `auto` or omitted, Antigravity uses the host user's default or last-used model.
- The legacy CLI type names `gemini` and `agy` are treated as aliases for `antigravity`.

## Auth And Secrets

- Authentication is managed by the host Antigravity CLI, outside this repository.
- Do not write API keys, OAuth tokens, browser cookies, or keyring data into the repo.
- If authentication is missing, report the required `agy` login/setup step instead of trying to store credentials yourself.

## Operating Rules

- Follow the same role, queue, and reporting protocol as the other CLI integrations.
- Read your assigned `queue/tasks/<agent_id>.yaml` and `queue/inbox/<agent_id>.yaml` before acting.
- Use the repository files as the source of truth for task state and reports.
