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
# Model tokens in .claude/agents/*.md frontmatter (${MODEL_GENIUS},
# ${MODEL_SMART}, ${MODEL_NORMAL}, ${MODEL_CHEAP}, ${MODEL_APPLIER},
# ${MODEL_VISION}, ${MODEL_MAIN}) are replaced with real model names from
# .env.agents during generation. When the env files do not define them,
# GENIUS (hardest tasks) falls back to the SMART model, VISION (image input)
# falls back to the NORMAL model, and MAIN (the orchestrator / main
# conversation loop) falls back to CHEAP on OpenCode and NORMAL on Claude
# Code. MAIN is also injected as the default model: top-level "model" in
# opencode.json and "model" in the generated Claude Code settings.
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
# Variable-level cascade — files are sourced in ascending priority, so each
# level only needs to define the variables it wants to override:
#   1. repo default  (.env.agents in the agents repo)
#   2. host shared   (~/.ddev/agents-sync/.env.agents — all DDEV projects)
#   3. project       (.ddev/.env.agents — this project only)
load_env() {
  local loaded=""

  set -a
  for f in "$MERGED_DIR/.env.agents" "/tmp/env-agents-host" "/tmp/env-agents-override"; do
    # Only source files with uncommented variable assignments
    if [ -f "$f" ] && grep -q '^[A-Z]' "$f" 2>/dev/null; then
      # shellcheck disable=SC1090
      source "$f"
      loaded="${loaded:+$loaded, }$f"
    fi
  done
  set +a

  if [ -z "$loaded" ]; then
    log "ERROR: No .env.agents found. Sync the repo or create .ddev/.env.agents"
    return 1
  fi

  # Backward-compatible defaults for tokens added after the original four —
  # an older agents repo or override file may not define them (set -u safe):
  : "${OC_MODEL_GENIUS:=$OC_MODEL_SMART}"
  : "${OC_MODEL_VISION:=$OC_MODEL_NORMAL}"
  : "${OC_MODEL_MAIN:=$OC_MODEL_CHEAP}"
  : "${CC_MODEL_GENIUS:=$CC_MODEL_SMART}"
  : "${CC_MODEL_VISION:=$CC_MODEL_NORMAL}"
  : "${CC_MODEL_MAIN:=$CC_MODEL_NORMAL}"
  export OC_MODEL_GENIUS OC_MODEL_VISION OC_MODEL_MAIN \
    CC_MODEL_GENIUS CC_MODEL_VISION CC_MODEL_MAIN

  log "Model config loaded from: $loaded"
}

# Per-tool git-access policy. Two cascade flags — GIT_ALLOW_COMMIT and
# GIT_ALLOW_OPERATIONS — each hold a COMMA-SEPARATED LIST of the AI tools the
# capability is granted to. Valid tool ids: "opencode", "claude". An empty
# value grants the capability to no tool (the safe default). The flags are
# loaded by load_env like any other .env.agents variable, so they follow the
# same repo < host < project cascade.
#   GIT_ALLOW_COMMIT       git add + git commit
#   GIT_ALLOW_OPERATIONS   git push (non-force), pull, fetch, merge, rebase,
#                          checkout/switch, reset, restore, stash, tag,
#                          cherry-pick — the normal workflow of a senior dev
# Anything destructive to the REMOTE is ALWAYS blocked, whatever the flags:
# force-push (--force/-f/--force-with-lease) and remote-branch deletion
# (git push --delete/-d).

# Return 0 if tool $1 appears in the comma-separated list $2 (spaces ignored).
git_tool_allowed() {
  local tool="$1" list="$2"
  list=$(echo "$list" | tr -d '[:space:]')
  case ",$list," in
    *",$tool,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Warn about entries in flag $2 (named $1) that are not valid tool ids —
# typos and legacy true/false values silently resolve to "deny" otherwise.
warn_unknown_git_tools() {
  local flag_name="$1" list="$2" item
  local IFS=','
  set -f  # no pathname expansion of list items
  for item in $(echo "$list" | tr -d '[:space:]'); do
    case "$item" in
      opencode|claude|'') ;;
      *) log "WARNING: $flag_name contains unknown tool id '$item' (valid: opencode, claude) — it grants nothing" ;;
    esac
  done
  set +f
}

# Resolve the two list flags into per-tool booleans, exported for downstream
# use. Called once after load_env.
#   OC_GIT_ALLOW_COMMIT / OC_GIT_ALLOW_OPERATIONS  -> OpenCode
#   CC_GIT_ALLOW_COMMIT / CC_GIT_ALLOW_OPERATIONS  -> Claude Code
resolve_git_flags() {
  : "${GIT_ALLOW_COMMIT:=}"
  : "${GIT_ALLOW_OPERATIONS:=}"

  warn_unknown_git_tools GIT_ALLOW_COMMIT "$GIT_ALLOW_COMMIT"
  warn_unknown_git_tools GIT_ALLOW_OPERATIONS "$GIT_ALLOW_OPERATIONS"

  git_tool_allowed opencode "$GIT_ALLOW_COMMIT"     && OC_GIT_ALLOW_COMMIT=true     || OC_GIT_ALLOW_COMMIT=false
  git_tool_allowed opencode "$GIT_ALLOW_OPERATIONS" && OC_GIT_ALLOW_OPERATIONS=true || OC_GIT_ALLOW_OPERATIONS=false
  git_tool_allowed claude   "$GIT_ALLOW_COMMIT"     && CC_GIT_ALLOW_COMMIT=true     || CC_GIT_ALLOW_COMMIT=false
  git_tool_allowed claude   "$GIT_ALLOW_OPERATIONS" && CC_GIT_ALLOW_OPERATIONS=true || CC_GIT_ALLOW_OPERATIONS=false

  export OC_GIT_ALLOW_COMMIT OC_GIT_ALLOW_OPERATIONS \
    CC_GIT_ALLOW_COMMIT CC_GIT_ALLOW_OPERATIONS

  log "Git flags: commit=[${GIT_ALLOW_COMMIT:-<none>}] operations=[${GIT_ALLOW_OPERATIONS:-<none>}] -> opencode(commit=$OC_GIT_ALLOW_COMMIT,ops=$OC_GIT_ALLOW_OPERATIONS) claude(commit=$CC_GIT_ALLOW_COMMIT,ops=$CC_GIT_ALLOW_OPERATIONS) (force-push always blocked)"
}

# Build the git-access prompt text + opencode.json permission tokens for ONE
# tool, from its two resolved booleans. Call once per tool right before
# generating that tool's config. Sets and exports:
#   GIT_COMMIT_PERMISSION / GIT_OPERATIONS_PERMISSION  -> opencode.json values
#   GIT_POLICY                                         -> prompt text (rules)
build_git_policy() {
  local allow_commit="$1"
  local allow_operations="$2"

  [ "$allow_commit" = "true" ] \
    && GIT_COMMIT_PERMISSION="allow" || GIT_COMMIT_PERMISSION="deny"
  [ "$allow_operations" = "true" ] \
    && GIT_OPERATIONS_PERMISSION="allow" || GIT_OPERATIONS_PERMISSION="deny"

  local commit_block ops_block
  if [ "$allow_commit" = "true" ]; then
    commit_block="- You MAY stage and commit locally. To commit: generate the message with the **commit-message** skill (it writes \`commit-msg.txt\`), then run \`git add\` the relevant files, \`git commit -F commit-msg.txt\`, and \`rm commit-msg.txt\`."
  else
    commit_block="- You MUST NOT create commits: never run \`git add\` or \`git commit\`. Present a summary and a suggested commit message instead."
  fi
  if [ "$allow_operations" = "true" ]; then
    ops_block="- You MAY run normal repository operations: \`git push\`, \`git pull\`, \`git fetch\`, \`git merge\`, \`git rebase\`, \`git checkout\`/\`git switch\`, \`git reset\`, \`git restore\`, \`git stash\`, \`git tag\`, \`git cherry-pick\`."
  else
    ops_block="- You MUST NOT run repository operations: never \`git push\`, \`git pull\`, \`git merge\`, \`git rebase\`, \`git checkout\`, \`git reset\`, \`git stash\`, or \`git tag\`. Leave them to the user."
  fi

  GIT_POLICY="## Git access (current policy)

${commit_block}
${ops_block}

**Never act proactively:** even when a git write command is allowed above, run it ONLY when the user explicitly asks for it or it is an explicit part of the task you were given. Never commit, push, or run any other git write on your own initiative.

**Always blocked, no matter the configuration:** never rewrite or destroy remote history — no force-push (\`git push --force\`, \`-f\`, \`--force-with-lease\`) and no remote-branch deletion (\`git push --delete\`/\`-d\`).

Read-only git is always allowed: \`git status\`, \`git diff\`, \`git log\`, \`git branch\`, \`git show\`."

  export GIT_COMMIT_PERMISSION GIT_OPERATIONS_PERMISSION GIT_POLICY
}

# Generate the Claude Code settings fragment that enforces the git policy.
# Claude Code runs in bypassPermissions mode, so declarative deny lists are not
# enough — enforcement is a PreToolUse hook that denies blocked git commands.
# The hook matches the command as a substring, so it also catches chained
# commands (e.g. `foo && git push`). Force-push and remote-branch deletion are
# always denied. The two booleans are passed explicitly so this can be called
# with a safe (block-all) default before the real flags are known. The optional
# 4th argument sets the default (orchestrator) model — empty omits the key so
# the CLI default applies.
write_claude_settings() {
  local allow_commit="$1"
  local allow_operations="$2"
  local dest="$3"
  local model="${4:-}"

  # case(1) patterns matched against the full command line. Force-push and
  # remote-branch deletion are matched with the flag in ANY position after
  # `git push` (e.g. `git push origin --force`), not just immediately after.
  local patterns=(
    "*'git push'*'--force'*"
    "*'git push'*' -f'*"
    "*'git push'*'--delete'*"
    "*'git push'*' -d'*"
    "*'git push'*' :'*"
  )
  [ "$allow_commit" = "true" ] || patterns+=("*'git add '*" "*'git commit'*")
  if [ "$allow_operations" != "true" ]; then
    patterns+=(
      "*'git push'*" "*'git pull'*" "*'git fetch'*" "*'git merge'*"
      "*'git rebase'*" "*'git checkout'*" "*'git switch'*" "*'git reset'*"
      "*'git restore'*" "*'git stash'*" "*'git tag'*" "*'git cherry-pick'*"
    )
  fi

  local case_patterns
  case_patterns=$(IFS='|'; echo "${patterns[*]}")

  local reason="This git command is blocked. Add 'claude' to GIT_ALLOW_COMMIT and/or GIT_ALLOW_OPERATIONS in .env.agents to allow it. Force-push and remote-branch deletion are never allowed."

  # Shell command run by the hook inside the container. $cmd / $(jq ...) must
  # stay literal (escaped here); ${case_patterns} and ${reason} are baked in now.
  local hook_cmd="cmd=\$(jq -r '.tool_input.command'); case \"\$cmd\" in ${case_patterns}) printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"${reason}\"}}'; exit 2;; esac"

  # jq --arg handles JSON escaping of the (quote-heavy) hook command.
  jq -n --arg cmd "$hook_cmd" --arg model "$model" '{
    hooks: {
      PreToolUse: [
        {
          matcher: "Bash",
          hooks: [ { type: "command", command: $cmd, timeout: 5 } ]
        }
      ]
    }
  } + (if $model == "" then {} else {model: $model} end)' > "$dest"
}

# Generate agent files for a specific tool (OpenCode or Claude Code)
generate_agents() {
  local target_dir="$1"
  local model_genius="$2"
  local model_smart="$3"
  local model_normal="$4"
  local model_cheap="$5"
  local model_applier="$6"
  local model_vision="$7"
  local model_main="$8"
  local tool_name="$9"

  mkdir -p "$target_dir/agents" "$target_dir/rules" "$target_dir/skills"

  # Copy skills as-is (no token substitution needed)
  [ -d "$MERGED_DIR/skills" ] && cp -r "$MERGED_DIR/skills"/* "$target_dir/skills/" 2>/dev/null || true

  # Copy rules, substituting only ${GIT_POLICY} (git-workflow.md is dynamic).
  # The envsubst whitelist keeps every other $VAR reference (e.g. $DDEV_DOCROOT
  # in shell examples) literal.
  if [ -d "$MERGED_DIR/rules" ]; then
    for rsrc in "$MERGED_DIR"/rules/*.md; do
      [ -f "$rsrc" ] || continue
      envsubst '${GIT_POLICY}' < "$rsrc" > "$target_dir/rules/$(basename "$rsrc")"
    done
  fi

  # Copy config files
  [ -f "$MERGED_DIR/CLAUDE.md" ] && cp "$MERGED_DIR/CLAUDE.md" "$target_dir/"

  # Process agent files with envsubst for model tokens
  export MODEL_GENIUS="$model_genius"
  export MODEL_SMART="$model_smart"
  export MODEL_NORMAL="$model_normal"
  export MODEL_CHEAP="$model_cheap"
  export MODEL_APPLIER="$model_applier"
  export MODEL_VISION="$model_vision"
  export MODEL_MAIN="$model_main"

  local count=0
  for src in "$MERGED_DIR"/agents/*.md; do
    [ -f "$src" ] || continue
    local name
    name=$(basename "$src")

    # Substitute model tokens
    envsubst '${MODEL_GENIUS},${MODEL_SMART},${MODEL_NORMAL},${MODEL_CHEAP},${MODEL_APPLIER},${MODEL_VISION},${MODEL_MAIN}' \
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
  export MODEL_GENIUS="$OC_MODEL_GENIUS"
  export MODEL_SMART="$OC_MODEL_SMART"
  export MODEL_NORMAL="$OC_MODEL_NORMAL"
  export MODEL_CHEAP="$OC_MODEL_CHEAP"
  export MODEL_APPLIER="$OC_MODEL_APPLIER"
  export MODEL_VISION="$OC_MODEL_VISION"
  export MODEL_MAIN="$OC_MODEL_MAIN"

  for f in "$MERGED_DIR"/*.json "$MERGED_DIR"/*.json.example; do
    [ -f "$f" ] || continue
    local name
    name=$(basename "$f")
    # Strip .example suffix — the output is a final config, not a template
    name="${name%.example}"
    # Apply envsubst to MODEL_* tokens and the git permission tokens
    # (preserve $WEB_CONTAINER, $FILE, etc.)
    envsubst '${MODEL_GENIUS},${MODEL_SMART},${MODEL_NORMAL},${MODEL_CHEAP},${MODEL_APPLIER},${MODEL_VISION},${MODEL_MAIN},${GIT_COMMIT_PERMISSION},${GIT_OPERATIONS_PERMISSION}' \
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

  # Secure default: write the block-all Claude settings BEFORE loading flags so
  # that if the claude-code container starts mid-sync it never sees an unguarded
  # config. Overwritten below with the flag-derived version once flags are known.
  write_claude_settings false false "$CLAUDE_DIR/settings.generated.json"

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

  # Load model aliases and git-access flags
  load_env

  # Resolve the per-tool git flags (each flag is a comma-separated tool list).
  resolve_git_flags

  # Generate for OpenCode (OC_* model values). Build OpenCode's git policy first
  # so its prompt text + opencode.json permission tokens match ITS flags.
  build_git_policy "$OC_GIT_ALLOW_COMMIT" "$OC_GIT_ALLOW_OPERATIONS"
  generate_agents "$OPENCODE_DIR" \
    "$OC_MODEL_GENIUS" "$OC_MODEL_SMART" "$OC_MODEL_NORMAL" "$OC_MODEL_CHEAP" \
    "$OC_MODEL_APPLIER" "$OC_MODEL_VISION" "$OC_MODEL_MAIN" \
    "opencode"

  # Copy OpenCode-specific configs (json, notifier, etc.) — consumes the git
  # permission tokens just exported by build_git_policy.
  copy_opencode_configs

  # Generate for Claude Code (CC_* model values). Rebuild the policy with
  # Claude's flags, then regenerate its rules + settings hook (which also
  # carries the default orchestrator model, CC_MODEL_MAIN).
  build_git_policy "$CC_GIT_ALLOW_COMMIT" "$CC_GIT_ALLOW_OPERATIONS"
  write_claude_settings "$CC_GIT_ALLOW_COMMIT" "$CC_GIT_ALLOW_OPERATIONS" \
    "$CLAUDE_DIR/settings.generated.json" "$CC_MODEL_MAIN"
  generate_agents "$CLAUDE_DIR" \
    "$CC_MODEL_GENIUS" "$CC_MODEL_SMART" "$CC_MODEL_NORMAL" "$CC_MODEL_CHEAP" \
    "$CC_MODEL_APPLIER" "$CC_MODEL_VISION" "$CC_MODEL_MAIN" \
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
