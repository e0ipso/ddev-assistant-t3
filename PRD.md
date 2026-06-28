# DDEV Assistant T3 PRD

## Summary

Build a DDEV add-on that installs and runs T3 inside the existing DDEV `web` container. The add-on provides a manual `ddev t3 start` command that launches `t3 serve` and exposes it through the DDEV project domain with deterministic HTTP and HTTPS ports.

## Problem

DDEV projects need a first-class way to run T3 alongside the local site while following DDEV conventions. T3 must run where assistant CLIs are installed: the `web` container. Users should be able to run T3 in multiple DDEV projects at once without manually coordinating ports.

## Goals

- Install and configure T3 for use inside the DDEV `web` container.
- Provide `ddev t3 start` as the primary way to start `t3 serve`.
- Expose T3 at stable project-specific URLs:
  - `http://<project>.ddev.site:<http-port>`
  - `https://<project>.ddev.site:<https-port>`
- Calculate default HTTP and HTTPS ports deterministically from the DDEV project identity to reduce collisions across projects.
- Allow users to override calculated ports through normal DDEV add-on configuration.
- Forward supported T3 configuration options through customary DDEV add-on config files.
- Keep the add-on focused on T3 only.

## Non-Goals

- Do not install assistant provider CLIs such as Claude, Gemini, or Codex.
- Do not validate assistant provider availability or credentials before starting T3.
- Do not start T3 automatically with `ddev start`.
- Do not run T3 as a separate long-lived DDEV service container.
- Do not bind T3 directly as a host-managed process.

## Users

- DDEV users who want to run T3 alongside one or more local web projects.
- Users who already install assistant provider CLIs into the `web` container through separate DDEV assistant add-ons.

## User Stories

- As a DDEV user, I can install the add-on and start T3 with `ddev t3 start`.
- As a DDEV user, I can open T3 using a stable URL based on my project domain.
- As a DDEV user running multiple projects, I can start T3 in each project without manually choosing unique ports by default.
- As a DDEV user with port constraints, I can override the generated HTTP and HTTPS ports.
- As a DDEV user, I can pass T3 options through add-on configuration rather than editing generated files manually.

## Functional Requirements

### Runtime

- T3 must run inside the DDEV `web` container.
- `ddev t3 start` must execute `t3 serve` in the `web` container.
- T3 must bind inside the container to `0.0.0.0` so DDEV can expose it outside the container.
- The add-on must not run T3 in the current separate `assistant-t3` service container model.
- The add-on must not validate assistant provider dependencies before startup; T3 is responsible for provider-level validation.

### Commands

- Provide a DDEV command named `t3`.
- Support at least:
  - `ddev t3 start`
- The start command should print the HTTP and HTTPS URLs after launching T3.
- The command should fail with a clear error if T3 is not available in the `web` container.

### Networking

- Expose T3 through DDEV-managed ports for both HTTP and HTTPS.
- Default HTTP and HTTPS ports must be deterministic per DDEV project identity.
- Port calculation must be stable across restarts for the same project.
- Users must be able to override both HTTP and HTTPS ports.
- The exposed URLs must use the DDEV project hostname:
  - `http://<project>.ddev.site:<http-port>`
  - `https://<project>.ddev.site:<https-port>`

### Configuration

- Use customary DDEV add-on configuration files for user-editable options.
- Generated files should remain clearly marked as DDEV-generated where appropriate.
- Configuration must support:
  - HTTP port override.
  - HTTPS port override.
  - Forwarded `t3 serve` options.
- Configuration must be safe to commit with the project `.ddev` directory.
- Secrets and provider credentials must not be stored by this add-on.

### Installation

- The add-on must install cleanly with:

```bash
ddev add-on get e0ipso/ddev-assistant-t3
ddev restart
```

- Installation must prepare the `web` container environment so `ddev t3 start` can run T3.
- The add-on should compose cleanly with separate assistant-provider add-ons.

## Acceptance Criteria

- After installation and restart, `ddev t3 start` starts `t3 serve` in the `web` container.
- The command prints the HTTP and HTTPS T3 URLs for the active project.
- The printed URLs use `<project>.ddev.site` and the configured or calculated ports.
- Two DDEV projects with different project identities calculate different default ports.
- Overriding HTTP and HTTPS ports through the add-on config changes the printed and exposed ports.
- The add-on does not install or validate assistant provider CLIs.
- The add-on does not create or require a separate `assistant-t3` runtime service.
- Automated tests cover installation from directory and release.
- Tests verify command availability, port configuration behavior, and basic T3 startup behavior where feasible.

## Implementation Decisions

### Port Calculation

Decision: calculate deterministic HTTP and HTTPS ports from `DDEV_SITENAME`.

- Use the external port range `20000-28999`.
- Reserve adjacent port pairs so each project gets one HTTP port and one HTTPS port.
- Calculate the pair from a stable hash of `DDEV_SITENAME`.
- Use the first port in the pair for HTTP and the second port for HTTPS.
- Keep the internal T3 container port fixed.
- Allow explicit overrides for both external ports.

Recommended algorithm:

```bash
hash="$(printf '%s' "${DDEV_SITENAME}" | cksum | awk '{print $1}')"
offset="$(( (hash % 4500) * 2 ))"
http_port="$(( 20000 + offset ))"
https_port="$(( http_port + 1 ))"
```

Rationale: ports below `30000` avoid common Linux ephemeral port ranges, adjacent pairs are easy to reason about, and hashing the project name keeps values stable across restarts while reducing cross-project collisions. Hash collisions remain possible, so overrides are still required.

### Network Exposure

Decision: expose T3 through DDEV `web_extra_exposed_ports`.

- T3 must listen inside the `web` container on a fixed internal port.
- T3 must bind to `0.0.0.0`, not `127.0.0.1`.
- DDEV must expose the fixed internal port through the calculated or overridden HTTP and HTTPS ports.
- The add-on should generate or install a DDEV config fragment for this wiring.

Rationale: this keeps T3 under DDEV's project-domain model and avoids a separate host-managed process.

### Configuration Files

Decision: split add-on configuration into environment overrides and T3 server settings.

- Use `.ddev/.env.assistant-t3` for add-on-level options.
- Use `.ddev/config.assistant-t3.yaml` for DDEV web port exposure.
- Use `.ddev/t3/settings.json` for forwarded T3 server settings.
- Treat generated files as replaceable unless clearly documented as user-owned.

Required `.ddev/.env.assistant-t3` options:

- `ASSISTANT_T3_VERSION`
- `ASSISTANT_T3_HTTP_PORT`
- `ASSISTANT_T3_HTTPS_PORT`
- `ASSISTANT_T3_CONTAINER_PORT`

Forwarded T3 settings should be written to `.ddev/t3/settings.json` using the same shape as T3's server settings schema. Do not store secrets in this file.

Rationale: DDEV add-ons commonly use `.env.<addon>` files for user overrides, while JSON is a better fit for nested T3 server settings.

### Process Lifecycle

Decision: `ddev t3 start` runs `t3 serve` in the foreground for v1.

- The command should print the HTTP and HTTPS URLs before or immediately after starting T3.
- The command should stream T3 logs to the terminal.
- `Ctrl-C` should stop T3.
- The add-on should not create PID files, background daemons, or log files in v1.

Rationale: foreground execution is simpler, avoids orphaned web-container processes, and matches the explicit requirement that T3 should not auto-start with `ddev start`.

### Command Surface

Decision: v1 supports only the minimal command surface.

- Required: `ddev t3 start`
- Optional: `ddev t3 help`
- Out of scope for v1:
  - `ddev t3 stop`
  - `ddev t3 restart`
  - `ddev t3 logs`
  - `ddev t3 status`

Rationale: these commands are only useful if T3 is background-managed. Since v1 runs in the foreground, process control belongs to the active terminal session.

### T3 Installation

Decision: install T3 globally from npm during the DDEV web image build.

- Install `t3@${ASSISTANT_T3_VERSION:-latest}`.
- Use a shared global npm prefix so the binary is available consistently at runtime.
- Ensure the T3 binary is available in the `web` container `PATH`.
- Fail the web image build clearly if npm is unavailable.

Rationale: npm is the selected distribution path for v1 and keeps installation straightforward inside the DDEV web image. Revisit this only if T3 upstream changes its recommended installation method.

### Assistant Provider Handling

Decision: do not inspect, install, or validate provider CLIs.

- Do not check for binaries such as `claude`, `codex`, `grok`, `opencode`, or `agent`.
- Do not validate provider credentials.
- Do not write provider secrets.
- Let T3 report provider-level errors at runtime.

Rationale: this add-on owns only T3. Assistant providers are installed by separate DDEV add-ons or by the user.

### Current Scaffold Migration

Decision: replace the current separate `assistant-t3` service scaffold with web-container integration.

- Remove the separate long-running `assistant-t3` service container from the intended architecture.
- Add web image build files for T3 installation.
- Add a web container custom command for `ddev t3`.
- Add DDEV config for `web_extra_exposed_ports`.

Rationale: the confirmed requirement is that T3 must run inside the `web` container where assistant CLIs are available.

