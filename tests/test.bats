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

  # Override this variable for your add-on:
  export GITHUB_REPO=e0ipso/ddev-assistant-t3

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
  local expected_http_port="${1}"
  local expected_https_port="${2}"
  local expected_container_port="${3:-3773}"

  assert_file_exists ".ddev/commands/web/t3"
  run test -x ".ddev/commands/web/t3"
  assert_success
  assert_file_exists ".ddev/config.assistant-t3.yaml"
  assert_file_exists ".ddev/web-build/Dockerfile.assistant-t3"
  assert_file_exists ".ddev/.env.assistant-t3"
  assert_file_exists ".ddev/t3/settings.json"
  assert_file_not_exists ".ddev/docker-compose.assistant-t3.yaml"

  run grep -E "container_port: ${expected_container_port}$" ".ddev/config.assistant-t3.yaml"
  assert_success
  run grep -E "http_port: ${expected_http_port}$" ".ddev/config.assistant-t3.yaml"
  assert_success
  run grep -E "https_port: ${expected_https_port}$" ".ddev/config.assistant-t3.yaml"
  assert_success

  run ddev exec bash -lc "command -v t3 && t3 --version"
  assert_success
  assert_output --partial "t3"

  run ddev t3 help
  assert_success
  assert_output --partial "ddev t3 start"

  run timeout 20s ddev t3 start
  assert_failure 124
  assert_output --partial "http://${PROJNAME}.ddev.site:${expected_http_port}"
  assert_output --partial "https://${PROJNAME}.ddev.site:${expected_https_port}"
  assert_output --partial "Starting T3 in the web container"
}

expected_ports_for_project() {
  local project_name="${1}"
  local hash offset http_port https_port

  hash="$(printf '%s' "${project_name}" | cksum | awk '{print $1}')"
  offset="$(( (hash % 4500) * 2 ))"
  http_port="$(( 20000 + offset ))"
  https_port="$(( http_port + 1 ))"
  printf '%s %s\n' "${http_port}" "${https_port}"
}

teardown() {
  set -eu -o pipefail
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1
  # Persist TESTDIR if running inside GitHub Actions. Useful for uploading test result artifacts
  # See example at https://github.com/ddev/github-action-add-on-test#preserving-artifacts
  if [ -n "${GITHUB_ENV:-}" ]; then
    [ -e "${GITHUB_ENV:-}" ] && echo "TESTDIR=${HOME}/tmp/${PROJNAME}" >> "${GITHUB_ENV}"
  else
    [ "${TESTDIR}" != "" ] && rm -rf "${TESTDIR}"
  fi
}

@test "install from directory" {
  set -eu -o pipefail
  mkdir -p .ddev
  cat > .ddev/.env.assistant-t3 <<'EOF'
ASSISTANT_T3_VERSION=latest
ASSISTANT_T3_HTTP_PORT=21000
ASSISTANT_T3_HTTPS_PORT=21001
ASSISTANT_T3_CONTAINER_PORT=3774
EOF
  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks 21000 21001 3774
}

# bats test_tags=release
@test "install from release" {
  set -eu -o pipefail
  echo "# ddev add-on get ${GITHUB_REPO} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${GITHUB_REPO}"
  assert_success
  run ddev restart -y
  assert_success
  read -r expected_http_port expected_https_port < <(expected_ports_for_project "${PROJNAME}")
  health_checks "${expected_http_port}" "${expected_https_port}"
}
