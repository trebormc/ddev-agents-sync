#!/bin/bash

# =============================================================================
# Agents Sync — Clones/updates AI agent repositories and merges into /agents
# =============================================================================
#
# Reads AGENTS_REPOS (comma-separated list of git URLs) and syncs each one.
# Files are merged into /agents in order — later repos override earlier ones.
# Fails silently on network errors (keeps existing files).
#
# Environment:
#   AGENTS_REPOS        Comma-separated git URLs (default: trebormc/drupal-ai-agents)
#   AGENTS_AUTO_UPDATE  "true" (default) or "false" to skip sync on start
# =============================================================================

set -uo pipefail

AGENTS_DIR="/agents"
REPOS_DIR="/tmp/agent-repos"
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
  log "Merging repositories into $AGENTS_DIR"

  # Directories to merge
  local dirs="agent rules skills"

  # First pass: copy everything from each repo in order (later repos override)
  local index=0
  IFS=',' read -ra REPO_LIST <<< "$REPOS"
  for url in "${REPO_LIST[@]}"; do
    url=$(echo "$url" | xargs) # trim whitespace
    local repo_dir="$REPOS_DIR/repo-$index"

    if [ -d "$repo_dir" ]; then
      # Copy top-level config files (opencode.json, CLAUDE.md, etc.)
      for f in "$repo_dir"/*.json "$repo_dir"/*.json.example "$repo_dir"/CLAUDE.md; do
        [ -f "$f" ] && cp "$f" "$AGENTS_DIR/"
      done

      # Merge agent/rules/skills directories
      for dir in $dirs; do
        if [ -d "$repo_dir/$dir" ]; then
          mkdir -p "$AGENTS_DIR/$dir"
          cp -r "$repo_dir/$dir"/* "$AGENTS_DIR/$dir/" 2>/dev/null || true
        fi
      done

      # Copy skills subdirectories (preserve structure)
      if [ -d "$repo_dir/skills" ]; then
        for skill_dir in "$repo_dir"/skills/*/; do
          [ -d "$skill_dir" ] && cp -r "$skill_dir" "$AGENTS_DIR/skills/"
        done
      fi
    fi

    index=$((index + 1))
  done

  log "Merge complete"
}

main() {
  log "Starting sync"
  mkdir -p "$AGENTS_DIR" "$REPOS_DIR"

  # Sync each repo
  local index=0
  IFS=',' read -ra REPO_LIST <<< "$REPOS"
  for url in "${REPO_LIST[@]}"; do
    url=$(echo "$url" | xargs)
    [ -n "$url" ] && sync_repo "$url" "$index"
    index=$((index + 1))
  done

  # Merge all repos into the shared volume
  merge_repos

  log "Done — $(ls "$AGENTS_DIR"/agent/*.md 2>/dev/null | wc -l) agents, $(ls -d "$AGENTS_DIR"/skills/*/ 2>/dev/null | wc -l) skills available"
}

main
