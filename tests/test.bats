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
  export STATE_VOLUME="ddev-${PROJNAME}-assistant"
  mkdir -p "${HOME}/tmp"
  export TESTDIR="$(mktemp -d "${HOME}/tmp/${PROJNAME}.XXXXXX")"
  export DDEV_NONINTERACTIVE=true
  export DDEV_NO_INSTRUMENTATION=true
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
  docker volume rm "${STATE_VOLUME}" >/dev/null 2>&1 || true
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
  # Space-separated, so the loop below can check every published binding.
  local expected_direct_bind_addresses="${4:-}"
  local expected_direct_port="${5:-}"
  local expected_address

  assert_file_exists ".ddev/commands/web/t3"
  run test -x ".ddev/commands/web/t3"
  assert_success
  assert_file_exists ".ddev/config.assistant-t3.yaml"
  assert_file_exists ".ddev/web-build/Dockerfile.assistant-t3"
  assert_file_exists ".ddev/.env.assistant-t3"
  assert_file_exists ".ddev/t3/settings.json"

  # The compose file always mounts the T3 state volume, and only publishes
  # ports when a direct bind address is set.
  assert_file_exists ".ddev/docker-compose.assistant-t3.yaml"
  run grep -F -- "- assistant-t3-state:/mnt/ddev-global-cache/assistant-t3" ".ddev/docker-compose.assistant-t3.yaml"
  assert_success
  if [ -z "${expected_direct_bind_addresses}" ]; then
    run grep -E "^[[:space:]]*ports:" ".ddev/docker-compose.assistant-t3.yaml"
    assert_failure
  else
    for expected_address in ${expected_direct_bind_addresses}; do
      run grep -F "\"${expected_address}:${expected_direct_port}:${expected_container_port}\"" ".ddev/docker-compose.assistant-t3.yaml"
      assert_success
      run docker port "ddev-${PROJNAME}-web" "${expected_container_port}"
      assert_success
      assert_output --partial "${expected_address}:${expected_direct_port}"
    done
  fi

  run grep -F '"enableAssistantStreaming": false' ".ddev/t3/settings.json"
  assert_success
  run grep -F '"automaticGitFetchInterval": 30000' ".ddev/t3/settings.json"
  assert_success
  run grep -F '"instanceId": "codex"' ".ddev/t3/settings.json"
  assert_success
  run grep -F '"model": "gpt-5.4-mini"' ".ddev/t3/settings.json"
  assert_success
  run grep -F '"opencode":' ".ddev/t3/settings.json"
  assert_success

  # The t3 npm package is a launcher with no dependencies, so the image needs
  # no compilers, and running it during the build would download the runtime
  # into the image.
  run grep -E "apt-get|t3 --version" ".ddev/web-build/Dockerfile.assistant-t3"
  assert_failure

  run grep -E "container_port: ${expected_container_port}$" ".ddev/config.assistant-t3.yaml"
  assert_success
  run grep -E "http_port: ${expected_http_port}$" ".ddev/config.assistant-t3.yaml"
  assert_success
  run grep -E "https_port: ${expected_https_port}$" ".ddev/config.assistant-t3.yaml"
  assert_success
  run grep -E "^nodejs_version:" ".ddev/config.assistant-t3.yaml"
  assert_failure

  run ddev exec sudo test -e /root/.t3
  assert_failure

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
  refute_output --partial "EROFS"

  if [ -n "${expected_direct_bind_addresses}" ]; then
    assert_output --partial ":${expected_direct_port} (direct"
    assert_direct_port_answers "${expected_direct_port}"
  fi

  assert_settings_link_writable
  assert_state_persists
}

# T3 keeps pairings, server identity and its database in T3CODE_HOME, so that
# directory has to be on the project's state volume, not on the container's
# writable layer that every recreate of the web container throws away.
assert_state_persists() {
  local state_dir="/mnt/ddev-global-cache/assistant-t3"
  local marker="${state_dir}/${PROJNAME}/persistence-marker"

  run docker volume inspect --format '{{.Name}}' "${STATE_VOLUME}"
  assert_success
  assert_output "${STATE_VOLUME}"

  run ddev exec findmnt -n -o TARGET,FSTYPE -T "${state_dir}"
  assert_success
  assert_output --regexp "^${state_dir}[[:space:]]"
  refute_output --partial "overlay"

  # Write as the web container user, the user "ddev t3 start" runs as.
  run ddev exec bash -c "echo kept > '${marker}'"
  assert_success
  run ddev restart -y
  assert_success
  run ddev exec cat "${marker}"
  assert_success
  assert_output "kept"
}

# T3 saves settings.json by creating a temp file beside the symlink target, so
# the directory the link resolves to has to be writable inside the container.
assert_settings_link_writable() {
  local settings_link="/mnt/ddev-global-cache/assistant-t3/${PROJNAME}/userdata/settings.json"

  run ddev exec bash -c "readlink -f '${settings_link}'"
  assert_success
  assert_output "/var/www/html/.ddev/t3/settings.json"
  run ddev exec mktemp /var/www/html/.ddev/t3/settings.json.XXXXXX
  assert_success
  ddev exec rm -f "${output}"
}

# Starts T3, then checks that the directly published port answers HTTP on the host
# rather than only inside the web container.
assert_direct_port_answers() {
  local direct_port="${1}"
  local t3_pid status=""

  ddev t3 start > "${TESTDIR}/t3-direct.log" 2>&1 &
  t3_pid=$!

  for _ in $(seq 1 30); do
    status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${direct_port}" || true)"
    [ "${status}" != "000" ] && [ -n "${status}" ] && break
    sleep 2
  done

  kill "${t3_pid}" 2>/dev/null || true
  wait "${t3_pid}" 2>/dev/null || true
  ddev exec bash -c "pkill -f 't3 serve'" >/dev/null 2>&1 || true

  if [ "${status}" = "000" ] || [ -z "${status}" ]; then
    fail "T3 did not answer on http://127.0.0.1:${direct_port}: $(cat "${TESTDIR}/t3-direct.log")"
  fi
}

expected_ports_for_project() {
  local project_name="${1}"
  local hash offset http_port https_port

  hash="$(printf '%s' "${project_name}" | cksum | awk '{print $1}')"
  offset="$(( (hash % 4500) * 2 ))"
  http_port="$(( 20000 + offset ))"
  https_port="$(( http_port + 1 ))"
  printf '%s %s %s\n' "${http_port}" "${https_port}" "$(( 10000 + offset ))"
}

teardown() {
  set -eu -o pipefail
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1
  docker volume rm "${STATE_VOLUME}" >/dev/null 2>&1 || true
  # Persist TESTDIR if running inside GitHub Actions. Useful for uploading test result artifacts
  # See example at https://github.com/ddev/github-action-add-on-test#preserving-artifacts
  if [ -n "${GITHUB_ENV:-}" ]; then
    [ -e "${GITHUB_ENV:-}" ] && echo "TESTDIR=${HOME}/tmp/${PROJNAME}" >> "${GITHUB_ENV}"
  else
    [ "${TESTDIR}" != "" ] && rm -rf "${TESTDIR}"
  fi
}

# Starts T3 in the background and waits until it answers through ddev-router.
start_t3_in_background() {
  local https_port="${1}"
  local status=""

  ddev t3 start > "${TESTDIR}/t3-background.log" 2>&1 &
  T3_BACKGROUND_PID=$!

  for _ in $(seq 1 45); do
    status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "https://${PROJNAME}.ddev.site:${https_port}/.well-known/t3/environment" || true)"
    [ "${status}" = "200" ] && return 0
    sleep 2
  done

  stop_t3_in_background
  fail "T3 did not answer on https://${PROJNAME}.ddev.site:${https_port}: $(cat "${TESTDIR}/t3-background.log")"
}

stop_t3_in_background() {
  kill "${T3_BACKGROUND_PID}" 2>/dev/null || true
  wait "${T3_BACKGROUND_PID}" 2>/dev/null || true
  ddev exec bash -c "pkill -f 't3 serve'" >/dev/null 2>&1 || true
}

environment_id() {
  local https_port="${1}"

  curl -sS --max-time 5 "https://${PROJNAME}.ddev.site:${https_port}/.well-known/t3/environment" \
    | sed -n 's/.*"environmentId":"\([^"]*\)".*/\1/p'
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
  read -r _ _ expected_direct_port < <(expected_ports_for_project "${PROJNAME}")
  health_checks 21000 21001 3774 127.0.0.1 "${expected_direct_port}"

  # "ddev t3 start" refuses a Node.js version outside the engines field of the
  # installed t3 package. Raising it in place checks that without a rebuild.
  run ddev exec npm root --global
  assert_success
  run ddev exec bash -c "cd '${output}/t3' && sudo npm pkg set 'engines.node=>=99'"
  assert_success
  run ddev t3 start
  assert_failure
  assert_output --partial "needs Node.js >=99, but the web container has v"
  refute_output --partial "Starting T3"
}

# T3 prints pairing links with the web container's IP, which changes when DDEV
# recreates the container. "ddev t3 pair" must put the token on the project URL
# through ddev-router instead, and that URL must reach the same T3 environment,
# WebSocket included, after a restart. Direct publishing is off, so nothing
# here can pass through the direct port.
@test "pair uses the project URL" {
  set -eu -o pipefail
  local https_port=21001 pairing_base first_environment_id

  mkdir -p .ddev
  cat > .ddev/.env.assistant-t3 <<'EOF'
ASSISTANT_T3_VERSION=latest
ASSISTANT_T3_HTTP_PORT=21000
ASSISTANT_T3_HTTPS_PORT=21001
ASSISTANT_T3_DIRECT_BIND_ADDRESS=
EOF
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
  pairing_base="https://${PROJNAME}.ddev.site:${https_port}"

  # "install from release" shares health_checks, so the pair command's help
  # and start hints are checked here.
  run ddev t3 help
  assert_success
  assert_output --partial "ddev t3 pair"
  run timeout 20s ddev t3 start
  assert_failure 124
  assert_output --partial 'run "ddev t3 pair"'
  ddev exec bash -c "pkill -f 't3 serve'" >/dev/null 2>&1 || true

  # Bad options fail before T3 is involved.
  run ddev t3 pair --base-url "http://example.test/path"
  assert_failure
  assert_output --partial "--base-url must look like"
  run ddev t3 pair --unknown
  assert_failure
  assert_output --partial "unknown pair option '--unknown'"

  # Without a running server, "t3 pair" fails and the command says why.
  run ddev t3 pair
  assert_failure
  assert_output --partial "Is T3 running?"

  start_t3_in_background "${https_port}"

  run ddev t3 pair --ttl 10m --label bats
  assert_success
  assert_output --partial "Pairing URL: ${pairing_base}/pair#token="
  assert_output --partial "App link: t3code://pair?pairingUrl=https%3A%2F%2F${PROJNAME}.ddev.site%3A${https_port}%2Fpair%23token%3D"
  assert_output --regexp "Token: [A-Z0-9]+"
  assert_output --partial "Expires: "
  assert_output --partial "The app saves ${pairing_base} and"
  refute_output --regexp "https?://(172|10|192\.168)\."

  run ddev t3 pair --base-url "http://laptop.example.ts.net:12345/"
  assert_success
  assert_output --partial "Pairing URL: http://laptop.example.ts.net:12345/pair#token="
  assert_output --partial "pairingUrl=http%3A%2F%2Flaptop.example.ts.net%3A12345%2Fpair%23token%3D"

  # The pairing page and the WebSocket endpoint answer through ddev-router.
  # Without a credential T3 itself refuses the upgrade with 401, so a 401 from
  # T3's auth, not a 502 or 404 from the router, shows the upgrade got through.
  run curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "${pairing_base}/pair"
  assert_success
  assert_output "200"
  run curl -sS -i --max-time 5 --http1.1 \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    "${pairing_base}/ws?orchestrationProtocol=2"
  assert_output --partial "401 Unauthorized"
  assert_output --partial "auth_invalid"

  first_environment_id="$(environment_id "${https_port}")"
  [ -n "${first_environment_id}" ] || fail "no environmentId from ${pairing_base}"
  stop_t3_in_background

  # A saved connection is the URL plus the environment it paired with; both
  # have to survive the web container being recreated.
  run ddev restart -y
  assert_success
  start_t3_in_background "${https_port}"
  run environment_id "${https_port}"
  assert_success
  assert_output "${first_environment_id}"
  run ddev t3 pair
  assert_success
  assert_output --partial "Pairing URL: ${pairing_base}/pair#token="
  stop_t3_in_background
}

# T3 accepts the desktop app's DPoP proofs only when it rebuilds the request URL
# with the scheme the app used. Through ddev-router that comes from
# X-Forwarded-Proto, which Traefik sets to "wss" for WebSocket upgrades, a value
# T3 doesn't read as TLS. The add-on's router override sends "https" instead.
# A header-echo server on the T3 container port shows what reaches T3.
@test "router forwards WebSocket upgrades on the HTTPS port as https" {
  set -eu -o pipefail
  local echo_pid

  mkdir -p .ddev
  cat > .ddev/.env.assistant-t3 <<'EOF'
ASSISTANT_T3_HTTP_PORT=21000
ASSISTANT_T3_HTTPS_PORT=21001
EOF
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
  # The override must not make DDEV warn about custom router configuration.
  refute_output --partial "traefik/config/assistant-t3.yaml"
  run grep -F "${PROJNAME}-assistant-t3-https" "${HOME}/.ddev/traefik/config/${PROJNAME}_merged.yaml"
  assert_success

  cat > header-echo.py <<'EOF'
import http.server

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = "".join(f"{k}: {v}\n" for k, v in self.headers.items()).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

http.server.HTTPServer(("0.0.0.0", 3773), Handler).serve_forever()
EOF
  ddev exec python3 /var/www/html/header-echo.py > /dev/null 2>&1 &
  echo_pid=$!
  for _ in $(seq 1 15); do
    curl -sf -o /dev/null --max-time 2 "http://${PROJNAME}.ddev.site:21000/" && break
    sleep 1
  done

  run curl -sS --max-time 5 --http1.1 \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    "https://${PROJNAME}.ddev.site:21001/ws"
  assert_output --partial "X-Forwarded-Proto: https"
  run curl -sS --max-time 5 "https://${PROJNAME}.ddev.site:21001/"
  assert_output --partial "X-Forwarded-Proto: https"
  # The plain HTTP port keeps reporting http.
  run curl -sS --max-time 5 "http://${PROJNAME}.ddev.site:21000/"
  assert_output --partial "X-Forwarded-Proto: http"
  refute_output --partial "X-Forwarded-Proto: https"

  kill "${echo_pid}" 2>/dev/null || true
  ddev exec pkill -f header-echo.py >/dev/null 2>&1 || true
}

# An empty ASSISTANT_T3_DIRECT_BIND_ADDRESS turns direct publishing off, leaving
# only the ddev-router ports.
@test "install with direct publishing disabled" {
  set -eu -o pipefail
  mkdir -p .ddev
  cat > .ddev/.env.assistant-t3 <<'EOF'
ASSISTANT_T3_VERSION=latest
ASSISTANT_T3_HTTP_PORT=21000
ASSISTANT_T3_HTTPS_PORT=21001
ASSISTANT_T3_CONTAINER_PORT=3774
ASSISTANT_T3_DIRECT_BIND_ADDRESS=
EOF
  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks 21000 21001 3774
}

@test "install with remote access enabled" {
  set -eu -o pipefail
  mkdir -p .ddev
  cat > .ddev/.env.assistant-t3 <<'EOF'
ASSISTANT_T3_VERSION=latest
ASSISTANT_T3_HTTP_PORT=21000
ASSISTANT_T3_HTTPS_PORT=21001
ASSISTANT_T3_CONTAINER_PORT=3774
ASSISTANT_T3_DIRECT_BIND_ADDRESS=0.0.0.0
ASSISTANT_T3_DIRECT_PORT=11000
EOF
  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks 21000 21001 3774 0.0.0.0 11000
}

# Binding several host addresses at once is what keeps a project usable both
# locally and over Tailscale, so the loopback binding has to survive alongside
# a second one. 127.0.0.2 stands in for the second address because the whole
# 127.0.0.0/8 range is bindable on the Linux runners; macOS only has 127.0.0.1.
@test "install with several direct bind addresses" {
  set -eu -o pipefail
  mkdir -p .ddev
  cat > .ddev/.env.assistant-t3 <<'EOF'
ASSISTANT_T3_VERSION=latest
ASSISTANT_T3_HTTP_PORT=21000
ASSISTANT_T3_HTTPS_PORT=21001
ASSISTANT_T3_CONTAINER_PORT=3774
ASSISTANT_T3_DIRECT_BIND_ADDRESS=127.0.0.1,127.0.0.2
ASSISTANT_T3_DIRECT_PORT=11000
EOF
  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks 21000 21001 3774 "127.0.0.1 127.0.0.2" 11000
}

@test "remote access rejects an invalid bind address" {
  set -eu -o pipefail
  mkdir -p .ddev
  cat > .ddev/.env.assistant-t3 <<'EOF'
ASSISTANT_T3_DIRECT_BIND_ADDRESS=127.0.0.1,laptop.tailnet.ts.net
EOF
  run ddev add-on get "${DIR}"
  assert_failure
  assert_output --partial "ASSISTANT_T3_DIRECT_BIND_ADDRESS entries must be an IPv4 address"
  assert_file_not_exists ".ddev/docker-compose.assistant-t3.yaml"
}

# post_install_actions generate most files, so DDEV only removes them through
# the add-on's removal_actions.
@test "removal deletes the generated files" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  assert_file_exists ".ddev/docker-compose.assistant-t3.yaml"
  assert_file_exists ".ddev/traefik/config/assistant-t3.yaml"

  run ddev add-on remove assistant-t3
  assert_success
  assert_file_not_exists ".ddev/commands/web/t3"
  assert_file_not_exists ".ddev/traefik/config/assistant-t3.yaml"
  assert_file_not_exists ".ddev/config.assistant-t3.yaml"
  assert_file_not_exists ".ddev/docker-compose.assistant-t3.yaml"
  assert_file_not_exists ".ddev/web-build/Dockerfile.assistant-t3"
  assert_file_exists ".ddev/.env.assistant-t3"
  assert_file_exists ".ddev/t3/settings.json"

  # Only the user settings stay behind.
  run find .ddev -name '*.assistant-t3*' ! -name .env.assistant-t3
  assert_success
  assert_output ""
}

# Like DDEV does for project_files, removal keeps a file once its
# #ddev-generated marker is gone.
@test "removal keeps generated files the user took over" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  # DDEV deletes #ddev-generated files from traefik/config, so this one has
  # its own marker.
  sed -i.bak '/^# assistant-t3-generated$/d' .ddev/traefik/config/assistant-t3.yaml
  rm -f .ddev/traefik/config/assistant-t3.yaml.bak
  echo "# kept" >> .ddev/traefik/config/assistant-t3.yaml

  # A reinstall leaves the taken-over router file alone too.
  run ddev add-on get "${DIR}"
  assert_success
  run tail -n 1 .ddev/traefik/config/assistant-t3.yaml
  assert_output "# kept"

  sed -i.bak '/#ddev-generated/d' .ddev/config.assistant-t3.yaml
  rm -f .ddev/config.assistant-t3.yaml.bak

  run ddev add-on remove assistant-t3
  assert_success
  assert_file_exists ".ddev/config.assistant-t3.yaml"
  assert_file_exists ".ddev/traefik/config/assistant-t3.yaml"
  assert_file_not_exists ".ddev/web-build/Dockerfile.assistant-t3"
}

# bats test_tags=release
@test "install from release" {
  set -eu -o pipefail
  echo "# ddev add-on get ${GITHUB_REPO} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${GITHUB_REPO}"
  assert_success
  run ddev restart -y
  assert_success
  read -r expected_http_port expected_https_port expected_direct_port < <(expected_ports_for_project "${PROJNAME}")
  health_checks "${expected_http_port}" "${expected_https_port}" 3773 127.0.0.1 "${expected_direct_port}"
}
