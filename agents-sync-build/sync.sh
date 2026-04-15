#!/bin/bash
#ddev-generated

# =============================================================================
# Agents Sync — Clones/updates AI agent repositories and generates configs
# =============================================================================
#
# Reads AGENTS_REPOS (comma-separated list of git URLs) and syncs each one.
# Files are merged in order — later repos override earlier ones.
# Then generates tool-specific agent directories:
#   /agents-opencode  — agents with OpenCode model names (provider/model-id)
#   /agents-claude    — agents with Claude Code model names (native aliases)
#
# Model tokens in .claude/agents/*.md frontmatter (${MODEL_SMART},
# ${MODEL_NORMAL}, ${MODEL_CHEAP}, ${MODEL_APPLIER}) are replaced with
# real model names from .env.agents during generation.
#
# Source repos must use the .claude/ directory layout:
#   .claude/agents/, .claude/rules/, .claude/skills/
#
# Environment:
#   AGENTS_REPOS        Comma-separated git URLs (default: trebormc/drupal-ai-agents)
#   AGENTS_AUTO_UPDATE  "true" (default) or "false" to skip sync on start
# =============================================================================

set -uo pipefail

MERGED_DIR="/tmp/agents-merged"
REPOS_DIR="/tmp/agent-repos"
OPENCODE_DIR="/agents-opencode"
CLAUDE_DIR="/agents-claude"
DEFAULT_REPO="https://github.com/trebormc/drupal-ai-agents.git"
REPOS="${AGENTS_REPOS:-$DEFAULT_REPO}"
AUTO_UPDATE="${AGENTS_AUTO_UPDATE:-true}"
TIMEOUT=30

log() { echo "[agents-sync] $*"; }

sync_repo() {
  local url="$1"
  local index="$2"
  local repo_dir="$REPOS_DIR/repo-$index"

  if [ -d "$repo_dir/.git" ]; then
    if [ "$AUTO_UPDATE" = "true" ]; then
      log "Updating repo $index: $url"
      cd "$repo_dir"
      timeout "$TIMEOUT" git pull --ff-only 2>/dev/null && log "  Updated successfully" || log "  Update skipped (no network or conflicts)"
      cd /
    else
      log "Auto-update disabled, using cached repo $index"
    fi
  else
    log "Cloning repo $index: $url"
    timeout "$((TIMEOUT * 2))" git clone --depth 1 "$url" "$repo_dir" 2>/dev/null && log "  Cloned successfully" || log "  Clone failed (no network)"
  fi
}

merge_repos() {
  log "Merging repositories into $MERGED_DIR"
  rm -rf "$MERGED_DIR"
  mkdir -p "$MERGED_DIR"

  local index=0
  IFS=',' read -ra REPO_LIST <<< "$REPOS"
  for url in "${REPO_LIST[@]}"; do
    url=$(echo "$url" | xargs)
    local repo_dir="$REPOS_DIR/repo-$index"

    if [ -d "$repo_dir" ]; then
      # Copy top-level config files
      for f in "$repo_dir"/*.json "$repo_dir"/*.json.example "$repo_dir"/CLAUDE.md "$repo_dir"/.env.agents; do
        [ -f "$f" ] && cp "$f" "$MERGED_DIR/"
      done

      # Merge .claude/ subdirectories (agents, rules, skills)
      for dir in agents rules skills; do
        if [ -d "$repo_dir/.claude/$dir" ]; then
          mkdir -p "$MERGED_DIR/$dir"
          cp -r "$repo_dir/.claude/$dir"/* "$MERGED_DIR/$dir/" 2>/dev/null || true
        fi
      done

      # Note: .claude/settings.json is NOT synced — user-level settings
      # in the Claude Code container handle permissions (bypassPermissions mode)
    fi

    index=$((index + 1))
  done

  log "Merge complete"
}

# Load model aliases from .env.agents
# Priority: local override (.ddev/.env.agents) > repo default
load_env() {
  local repo_file="$MERGED_DIR/.env.agents"
  local override_file="/tmp/env-agents-override"
  local env_file=""

  # Local override takes priority over repo default
  # Only use override if it has uncommented variable assignments
  if [ -f "$override_file" ] && grep -q '^[A-Z]' "$override_file" 2>/dev/null; then
    env_file="$override_file"
    log "Using local model config from .ddev/.env.agents"
  elif [ -f "$repo_file" ]; then
    env_file="$repo_file"
    log "Using model config from repo .env.agents"
  fi

  if [ -z "$env_file" ]; then
    log "ERROR: No .env.agents found. Sync the repo or create .ddev/.env.agents"
    return 1
  fi

  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
}

# Generate agent files for a specific tool (OpenCode or Claude Code)
generate_agents() {
  local target_dir="$1"
  local model_smart="$2"
  local model_normal="$3"
  local model_cheap="$4"
  local model_applier="$5"
  local tool_name="$6"

  mkdir -p "$target_dir/agents" "$target_dir/rules" "$target_dir/skills"

  # Copy rules and skills as-is (no token substitution needed)
  [ -d "$MERGED_DIR/rules" ] && cp -r "$MERGED_DIR/rules"/* "$target_dir/rules/" 2>/dev/null || true
  [ -d "$MERGED_DIR/skills" ] && cp -r "$MERGED_DIR/skills"/* "$target_dir/skills/" 2>/dev/null || true

  # Copy config files
  [ -f "$MERGED_DIR/CLAUDE.md" ] && cp "$MERGED_DIR/CLAUDE.md" "$target_dir/"

  # Process agent files with envsubst for model tokens
  export MODEL_SMART="$model_smart"
  export MODEL_NORMAL="$model_normal"
  export MODEL_CHEAP="$model_cheap"
  export MODEL_APPLIER="$model_applier"

  local count=0
  for src in "$MERGED_DIR"/agents/*.md; do
    [ -f "$src" ] || continue
    local name
    name=$(basename "$src")

    # Substitute model tokens
    envsubst '${MODEL_SMART},${MODEL_NORMAL},${MODEL_CHEAP},${MODEL_APPLIER}' \
      < "$src" > "$target_dir/agents/$name"

    # For Claude Code: transform frontmatter to Claude Code format
    if [ "$tool_name" = "claude" ]; then
      transform_for_claude "$target_dir/agents/$name"
    else
      # For OpenCode: just remove the allowed_tools line
      sed -i '/^allowed_tools:/d' "$target_dir/agents/$name"
    fi

    count=$((count + 1))
  done

  log "Generated $count agents for $tool_name"
}

# Transform agent .md from fat frontmatter to Claude Code format
# Removes: mode, temperature, maxSteps, tools (object), permission (block)
# Renames: allowed_tools → tools
transform_for_claude() {
  local file="$1"
  local tmp
  tmp=$(mktemp)

  # Derive agent name from filename (e.g., drupal-dev.md → drupal-dev)
  local agent_name
  agent_name=$(basename "$file" .md)

  awk -v agent_name="$agent_name" '
  BEGIN { in_fm=0; fm_count=0; skip_block=0; name_added=0 }
  /^---$/ {
    fm_count++
    if (fm_count == 1) { in_fm=1; print; next }
    if (fm_count == 2) {
      # Add name before closing frontmatter if not yet added
      if (!name_added) { print "name: " agent_name; name_added=1 }
      in_fm=0; print; next
    }
  }
  !in_fm { print; next }

  # Inside frontmatter processing
  in_fm {
    # Add name: right after opening ---
    if (!name_added) { print "name: " agent_name; name_added=1 }

    # Skip mode, temperature, maxSteps lines
    if ($0 ~ /^(mode|temperature|maxSteps):/) next

    # Skip tools: block (YAML object, not the CSV line)
    if ($0 ~ /^tools:$/) { skip_block=1; next }
    if (skip_block && $0 ~ /^  [a-z]/) next
    if (skip_block && $0 !~ /^  /) skip_block=0

    # Skip permission: block
    if ($0 ~ /^permission:$/) { skip_block=1; next }
    if (skip_block && $0 ~ /^  /) next
    if (skip_block && $0 !~ /^  /) skip_block=0

    # Rename allowed_tools → tools
    if ($0 ~ /^allowed_tools:/) {
      sub(/^allowed_tools:/, "tools:")
      print
      next
    }

    print
  }
  ' "$file" > "$tmp"

  mv "$tmp" "$file"
}

# Copy OpenCode-specific config files with model token substitution
# .example files are generated as final config (without .example suffix)
copy_opencode_configs() {
  export MODEL_SMART="$OC_MODEL_SMART"
  export MODEL_NORMAL="$OC_MODEL_NORMAL"
  export MODEL_CHEAP="$OC_MODEL_CHEAP"
  export MODEL_APPLIER="$OC_MODEL_APPLIER"

  for f in "$MERGED_DIR"/*.json "$MERGED_DIR"/*.json.example; do
    [ -f "$f" ] || continue
    local name
    name=$(basename "$f")
    # Strip .example suffix — the output is a final config, not a template
    name="${name%.example}"
    # Apply envsubst only to MODEL_* tokens (preserve $WEB_CONTAINER, $FILE, etc.)
    envsubst '${MODEL_SMART},${MODEL_NORMAL},${MODEL_CHEAP},${MODEL_APPLIER}' \
      < "$f" > "$OPENCODE_DIR/$name"
  done
}

main() {
  log "Starting sync"

  # Create all subpath mount targets FIRST. Dependent containers (claude-code,
  # opencode) mount these via Docker volume subpath and fail if they don't exist.
  # The healthcheck gates on CLAUDE.md, so this must complete before anything else.
  mkdir -p "$REPOS_DIR" \
    "$OPENCODE_DIR/agents" "$OPENCODE_DIR/rules" "$OPENCODE_DIR/skills" \
    "$CLAUDE_DIR/agents" "$CLAUDE_DIR/rules" "$CLAUDE_DIR/skills"
  [ -f "$OPENCODE_DIR/CLAUDE.md" ] || touch "$OPENCODE_DIR/CLAUDE.md"
  [ -f "$CLAUDE_DIR/CLAUDE.md" ] || touch "$CLAUDE_DIR/CLAUDE.md"

  # Sync each repo
  local index=0
  IFS=',' read -ra REPO_LIST <<< "$REPOS"
  for url in "${REPO_LIST[@]}"; do
    url=$(echo "$url" | xargs)
    [ -n "$url" ] && sync_repo "$url" "$index"
    index=$((index + 1))
  done

  # Merge all repos into temp dir
  merge_repos

  # Load model aliases
  load_env

  # Generate for OpenCode (OC_* model values)
  generate_agents "$OPENCODE_DIR" \
    "$OC_MODEL_SMART" "$OC_MODEL_NORMAL" "$OC_MODEL_CHEAP" "$OC_MODEL_APPLIER" \
    "opencode"

  # Copy OpenCode-specific configs (json, notifier, etc.)
  copy_opencode_configs

  # Generate for Claude Code (CC_* model values)
  generate_agents "$CLAUDE_DIR" \
    "$CC_MODEL_SMART" "$CC_MODEL_NORMAL" "$CC_MODEL_CHEAP" "$CC_MODEL_APPLIER" \
    "claude"

  local oc_count
  oc_count=$(ls "$OPENCODE_DIR"/agents/*.md 2>/dev/null | wc -l)
  local cc_count
  cc_count=$(ls "$CLAUDE_DIR"/agents/*.md 2>/dev/null | wc -l)
  local skills_count
  skills_count=$(ls -d "$OPENCODE_DIR"/skills/*/ 2>/dev/null | wc -l)

  log "Done — OpenCode: $oc_count agents, Claude: $cc_count agents, $skills_count skills"
}

main
