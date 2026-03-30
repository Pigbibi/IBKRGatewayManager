# Contributing

Thanks for contributing to `IBKRGatewayManager`.

## Ground Rules

- Prefer small, low-risk pull requests.
- Keep refactors separate from behavior changes.
- Add or update tests when changing runtime behavior.
- Do not use deployment or scheduled workflows as a substitute for local verification.

## Branching and Pull Requests

- Create a topic branch for each change.
- Open a pull request with a short summary and a concrete test plan.
- Wait for CI to pass before merging.

## Local Verification

Run the main verification command before opening a pull request:

```bash
bash tests/test_install_2fa_bot_watcher.sh && bash tests/test_workflow_shared_config.sh && bash tests/test_docker_compose_ports.sh
```
