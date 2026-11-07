#!/usr/bin/env bats

# Bats is a testing framework for Bash
# Documentation https://bats-core.readthedocs.io/en/stable/
# Bats libraries documentation https://github.com/ztombol/bats-docs

# For local tests, install bats-core, bats-assert, bats-file, bats-support
# And run this in the add-on root directory:
#   bats ./tests/test.bats
# To exclude release tests:
#   bats ./tests/test.bats --filter-tags '!release'
# For debugging:
#   bats ./tests/test.bats --show-output-of-passing-tests --verbose-run --print-output-on-failure

setup() {
  set -eu -o pipefail

  export GITHUB_REPO=trebormc/ddev-agents-sync

  TEST_BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  export BATS_LIB_PATH="${BATS_LIB_PATH}:${TEST_BREW_PREFIX}/lib:/usr/lib/bats"
  bats_load_library bats-assert
  bats_load_library bats-file
  bats_load_library bats-support

  export DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." >/dev/null 2>&1 && pwd)"
  export PROJNAME="test-$(basename "${GITHUB_REPO}")"
  mkdir -p "${HOME}/tmp"
  export TESTDIR="$(mktemp -d "${HOME}/tmp/${PROJNAME}.XXXXXX")"
  export DDEV_NONINTERACTIVE=true
  export DDEV_NO_INSTRUMENTATION=true
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
  cd "${TESTDIR}"
  run ddev config --project-name="${PROJNAME}" --project-tld=ddev.site
  assert_success
  run ddev start -y
  assert_success
}

health_checks() {
  sleep 10
  # Verify agents-sync container is running
  run ddev exec -s agents-sync bash -c "echo ok"
  assert_success
  # Verify sync script is available
  run ddev exec -s agents-sync test -x /usr/local/bin/sync.sh
  assert_success
}

teardown() {
  set -eu -o pipefail
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1
  if [ -n "${GITHUB_ENV:-}" ]; then
    [ -e "${GITHUB_ENV:-}" ] && echo "TESTDIR=${HOME}/tmp/${PROJNAME}" >> "${GITHUB_ENV}"
  else
    [ "${TESTDIR}" != "" ] && rm -rf "${TESTDIR}"
  fi
}

@test "install from directory" {
  set -eu -o pipefail
  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks
}

@test "sync removes what no repo provides, unless a repo could not be read" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks

  local plant='mkdir -p /agents-claude/skills/gone && touch /agents-claude/skills/gone/SKILL.md /agents-opencode/rules/gone.md'

  # A repo that cannot be read: the merge is incomplete, so nothing goes.
  run ddev exec -s agents-sync bash -c "${plant}; AGENTS_REPOS=\"\${AGENTS_REPOS},/nonexistent/repo\" /usr/local/bin/sync.sh"
  assert_success
  assert_output --partial "Incomplete merge"
  run ddev exec -s agents-sync test -f /agents-claude/skills/gone/SKILL.md
  assert_success
  run ddev exec -s agents-sync test -f /agents-opencode/rules/gone.md
  assert_success

  # A complete merge removes both, and leaves the real content in place.
  run ddev exec -s agents-sync /usr/local/bin/sync.sh
  assert_success
  assert_output --partial "Removed skills/gone from /agents-claude"
  run ddev exec -s agents-sync test ! -e /agents-claude/skills/gone
  assert_success
  run ddev exec -s agents-sync test ! -e /agents-opencode/rules/gone.md
  assert_success
  run ddev exec -s agents-sync test -f /agents-claude/skills/arena-protocol/SKILL.md
  assert_success
}

# bats test_tags=release
@test "install from release" {
  set -eu -o pipefail
  echo "# ddev add-on get ${GITHUB_REPO} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${GITHUB_REPO}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks
}
