# Contributing to FlipClaw

Thanks for your interest! FlipClaw is a small, focused toolkit, so contributions that improve reliability, cover new agent environments, or add to the upstream patch registry are especially welcome.

## Reporting Issues

- Use GitHub Issues for bugs, feature requests, and questions
- Include your OpenClaw version (`openclaw --version`), OS, and steps to reproduce
- For install failures, attach the output of `bash $WORKSPACE/scripts/claude-code-update-check.sh` (redact API keys)

## Submitting Changes

1. Fork the repo and create a branch from `main`
2. Make your changes
3. Test on a clean environment — see "Testing changes" below
4. Submit a pull request with a clear description of what changed and why
5. Link the PR to any relevant GitHub issues

## Testing changes

FlipClaw's installer touches a user's real agent workspace, so blast radius on a bad change is high. Before sending a PR:

**Syntax checks (always, local):**
```bash
# Python scripts
python3 -m py_compile scripts/*.py extensions/*/scripts/*.py

# Shell scripts
bash -n install.sh install-memory.sh install-claude-code.sh scripts/*.sh

# JSON
python3 -m json.tool < scripts/upstream-patches.json > /dev/null
python3 -m json.tool < extensions/auto-skill-capture/openclaw.plugin.json > /dev/null
```

**Fresh-install smoke test (recommended for any installer change):**

Run the full install flow inside a clean Ubuntu container so you catch config validation, PM2 command-form bugs, and missing prerequisites before they reach a user. LXD works on any Linux host and doesn't need nested virtualization:

```bash
# Host setup (one time)
sudo snap install lxd
sudo lxd init --minimal

# Spin up a clean Ubuntu 24.04 container
sudo lxc launch ubuntu:24.04 fc-test
sudo lxc exec fc-test -- bash -c "
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl python3 git jq openssl
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs
  npm install -g pm2 openclaw@latest
"

# Push your working copy into the container
sudo lxc file push -r ./ fc-test/root/flipclaw/

# Run the full install flow (the steps from BOOTSTRAP.md Branch 1)
sudo lxc exec fc-test -- bash -c '
  mkdir -p /root/fcw
  OPENCLAW_CONFIG_PATH=/root/fcw/openclaw.json openclaw onboard \
    --non-interactive --accept-risk --flow manual --mode local \
    --gateway-port 3050 --gateway-bind loopback \
    --gateway-auth token --gateway-token "$(openssl rand -hex 16)" \
    --auth-choice skip --workspace /root/fcw --skip-health
  jq ".env = {\"vars\": {\"OPENAI_API_KEY\": \"sk-test\", \"GEMINI_API_KEY\": \"AIza-test\", \"GOOGLE_AI_API_KEY\": \"AIza-test\"}}" \
    /root/fcw/openclaw.json > /tmp/c && mv /tmp/c /root/fcw/openclaw.json
  bash /root/flipclaw/install.sh --agent-name fcw --workspace /root/fcw --port 3050 --gemini-key "AIza-test"
  OPENCLAW_CONFIG_PATH=/root/fcw/openclaw.json pm2 start --name fcw-gateway "openclaw gateway run"
  sleep 5
  curl -sS http://localhost:3050/health
  bash /root/fcw/scripts/claude-code-update-check.sh
'

# Cleanup
sudo lxc stop fc-test --force && sudo lxc delete fc-test
```

Expected: `/health` returns `{"ok":true,"status":"live"}` and the health check reports `12 passed / 0 failed`.

If your host's LXD bridge can't reach the internet from inside the container, add a MASQUERADE rule for `lxdbr0` (Docker/Multipass rules can prevent LXD from installing its own). See the test notes in recent commit messages.

## Adding new upstream patches

Found a new OpenClaw bug that FlipClaw should work around? The patch registry makes this cheap:

1. Add a new entry to `scripts/upstream-patches.json` with `broken_from`, `fixed_in` (or `null` if unfixed), workaround artifacts, and an optional runtime probe
2. If the workaround installs a new script, drop the script template in `scripts/` and reference it from the registry entry
3. Document the issue in `docs/KNOWN-ISSUES.md` with symptoms, root cause, and workaround behavior
4. Test both the APPLY and CLEAN paths via a fake registry (see `scripts/apply-upstream-patches.sh --help`)

See the existing `dreaming-cron-reconciler` and `wiki-bridge-zero-artifacts` entries for the expected shape.

## Code Style

- Python: Follow PEP 8, use type hints where practical
- Shell scripts: Use `set -o pipefail`, quote variables, handle errors
- TypeScript: Follow the existing extension patterns
- JSON registries (`upstream-patches.json`, plugin manifests): keep 2-space indent, always valid JSON (no trailing commas or comments)

## What We'd Love Help With

- Support for additional AI coding tools (Codex CLI, Aider, etc.)
- Improved skill extraction quality
- Better deduplication algorithms
- Platform-specific fixes (macOS, WSL edge cases)
- New upstream patch registry entries for OpenClaw bugs you've run into
- Documentation improvements and translations

## License

By contributing, you agree that your contributions will be licensed under the MIT License (see [LICENSE](LICENSE)).
