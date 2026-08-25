#!/usr/bin/env bash
set -euo pipefail

codex_home="${CODEX_HOME:-$HOME/.codex}"
codex_agents="$codex_home/AGENTS.md"
codex_skills="$codex_home/skills"
shared_skills="$HOME/.agents/skills"
default_agents="${AI_SANDBOX_DEFAULT_AGENTS:-/usr/local/share/ai-sandbox/default-AGENTS.md}"
default_skills="${AI_SANDBOX_DEFAULT_SKILLS:-/usr/local/share/ai-sandbox/default-skills}"
disable_seed="$codex_home/.disable_default_agents_seed"

link_shared_file() {
  local source="$1"
  local target="$2"
  local relative_source

  mkdir -p "$(dirname "$target")"
  relative_source="$(realpath -m \
    --relative-to="$(dirname "$target")" \
    "$source")"
  if [[ -L "$target" && "$(readlink "$target")" == "$relative_source" ]]; then
    return
  fi
  if [[ -L "$target" ]]; then
    ln -sfn "$relative_source" "$target"
    return
  fi
  if [[ -e "$target" ]]; then
    echo "AI_SANDBOX_WARNING: preserving existing shared-resource path: $target" >&2
    return
  fi
  ln -s "$relative_source" "$target"
}

seed_default_instructions() {
  mkdir -p "$codex_home"
  if [[ ! -e "$disable_seed" && ! -f "$codex_agents" && -f "$default_agents" ]]; then
    cp "$default_agents" "$codex_agents"
  fi
}

seed_default_skills() {
  local source target

  mkdir -p "$shared_skills"
  [[ -d "$default_skills" ]] || return

  for source in "$default_skills"/*; do
    [[ -d "$source" && -f "$source/SKILL.md" ]] || continue
    target="$shared_skills/$(basename "$source")"
    [[ -e "$target" || -L "$target" ]] || cp -a "$source" "$target"
  done
}

migrate_codex_skills() {
  local source target

  mkdir -p "$codex_skills" "$shared_skills"
  for source in "$codex_skills"/*; do
    [[ -d "$source" && ! -L "$source" && -f "$source/SKILL.md" ]] || continue
    target="$shared_skills/$(basename "$source")"
    if [[ -e "$target" || -L "$target" ]]; then
      echo "AI_SANDBOX_WARNING: preserving divergent Codex skill: $source" >&2
      continue
    fi
    mv "$source" "$target"
    link_shared_file "$target" "$source"
  done
}

link_codex_skills() {
  local source target

  mkdir -p "$codex_skills"
  for source in "$shared_skills"/*; do
    [[ -d "$source" && -f "$source/SKILL.md" ]] || continue
    target="$codex_skills/$(basename "$source")"
    link_shared_file "$source" "$target"
  done
}

seed_default_instructions
if [[ -f "$codex_agents" ]]; then
  link_shared_file "$codex_agents" "$HOME/.config/opencode/AGENTS.md"
  link_shared_file "$codex_agents" "$HOME/.pi/agent/AGENTS.md"
fi
migrate_codex_skills
seed_default_skills
link_codex_skills
