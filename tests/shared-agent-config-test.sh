#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

fake_bin="$test_root/bin"
test_home="$test_root/home"
default_skills="$test_root/default-skills"
mkdir -p \
  "$fake_bin" \
  "$test_home/.codex/skills/.system" \
  "$test_home/.codex/skills/existing-skill" \
  "$default_skills/example-skill"

cat >"$fake_bin/npm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" != "list" ]] || exit 1
printf '%s\n' "$*" >>"$AI_SANDBOX_TEST_NPM_LOG"
EOF
chmod +x "$fake_bin/npm"

export HOME="$test_home"
export CODEX_HOME="$test_home/.codex"
export PATH="$fake_bin:/usr/bin:/bin"
export NPM_CONFIG_PREFIX="$test_home/.npm-global"
export AI_SANDBOX_TEST_NPM_LOG="$test_root/npm.log"

bash "$repo_root/ai-sandbox/ai-sandbox-default-install.sh" \
  --only pi
grep -Fx \
  'install -g --ignore-scripts @earendil-works/pi-coding-agent@latest' \
  "$AI_SANDBOX_TEST_NPM_LOG"

printf '%s\n' '# Shared instructions' >"$test_root/AGENTS.md"
printf '%s\n' 'managed' >"$CODEX_HOME/skills/.system/marker"
printf '%s\n' '---' 'name: existing-skill' \
  'description: Existing fixture' '---' \
  >"$CODEX_HOME/skills/existing-skill/SKILL.md"
printf '%s\n' '---' 'name: example-skill' \
  'description: Test fixture' '---' \
  >"$default_skills/example-skill/SKILL.md"

AI_SANDBOX_DEFAULT_AGENTS="$test_root/AGENTS.md" \
AI_SANDBOX_DEFAULT_SKILLS="$default_skills" \
  bash "$repo_root/ai-sandbox/ai-sandbox-agent-config.sh"

cmp "$CODEX_HOME/AGENTS.md" "$test_root/AGENTS.md"
[[ "$(readlink -f "$HOME/.config/opencode/AGENTS.md")" == \
  "$CODEX_HOME/AGENTS.md" ]]
[[ "$(readlink -f "$HOME/.pi/agent/AGENTS.md")" == \
  "$CODEX_HOME/AGENTS.md" ]]
[[ -f "$HOME/.agents/skills/example-skill/SKILL.md" ]]
[[ -f "$HOME/.agents/skills/existing-skill/SKILL.md" ]]
[[ "$(readlink -f "$CODEX_HOME/skills/example-skill")" == \
  "$HOME/.agents/skills/example-skill" ]]
[[ "$(readlink -f "$CODEX_HOME/skills/existing-skill")" == \
  "$HOME/.agents/skills/existing-skill" ]]
grep -Fx managed "$CODEX_HOME/skills/.system/marker"

sync_home="$test_root/sync-home"
export AI_SANDBOX_HOME_STORAGE="$sync_home"
"$repo_root/ai-sandbox/ai-sandbox" skills push \
  --dir "$default_skills"
cmp \
  "$default_skills/example-skill/SKILL.md" \
  "$sync_home/.agents/skills/example-skill/SKILL.md"

mkdir -p "$default_skills/.system"
if "$repo_root/ai-sandbox/ai-sandbox" skills push \
  --dir "$default_skills" --force \
  >"$test_root/system-sync.out" \
  2>"$test_root/system-sync.err"; then
  echo "skills sync unexpectedly accepted .system" >&2
  exit 1
fi
grep -F 'Refusing to sync Codex-managed .system' \
  "$test_root/system-sync.err"

printf '%s\n' '# Host-synced instructions' \
  >"$test_root/project-AGENTS.md"
"$repo_root/ai-sandbox/ai-sandbox" agents push \
  --file "$test_root/project-AGENTS.md"
[[ "$(readlink "$sync_home/.config/opencode/AGENTS.md")" == \
  '../../.codex/AGENTS.md' ]]
[[ "$(readlink "$sync_home/.pi/agent/AGENTS.md")" == \
  '../../.codex/AGENTS.md' ]]
cmp \
  "$sync_home/.config/opencode/AGENTS.md" \
  "$sync_home/.codex/AGENTS.md"

echo "ai-sandbox shared agent config tests passed"
