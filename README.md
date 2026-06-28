[![add-on registry](https://img.shields.io/badge/DDEV-Add--on_Registry-blue)](https://addons.ddev.com)
[![tests](https://github.com/e0ipso/ddev-assistant-t3/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/e0ipso/ddev-assistant-t3/actions/workflows/tests.yml?query=branch%3Amain)
[![last commit](https://img.shields.io/github/last-commit/e0ipso/ddev-assistant-t3)](https://github.com/e0ipso/ddev-assistant-t3/commits)
[![release](https://img.shields.io/github/v/release/e0ipso/ddev-assistant-t3)](https://github.com/e0ipso/ddev-assistant-t3/releases/latest)

# DDEV Assistant T3

## Overview

This add-on installs [T3 Code](https://github.com/pingdotgg/t3code) in the DDEV `web` container and adds a `ddev t3 start` command that runs `t3 serve` in the foreground.

T3 is exposed through the active DDEV project hostname:

- `http://<project>.ddev.site:<http-port>`
- `https://<project>.ddev.site:<https-port>`

The default ports are calculated from the DDEV project name so multiple projects usually get different port pairs without manual coordination.

## Installation

```bash
ddev add-on get e0ipso/ddev-assistant-t3
ddev restart
```

After installation, make sure to commit the `.ddev` directory to version control.

## Usage

| Command | Description |
| ------- | ----------- |
| `ddev t3 start` | Start `t3 serve` in the web container and stream logs |
| `ddev t3 help` | Show command help |

`ddev t3 start` prints the HTTP and HTTPS URLs before starting T3. Press `Ctrl-C` to stop T3.

This add-on does not install or validate assistant provider CLIs such as Claude, Codex, Gemini, Grok, OpenCode, or Cursor Agent. Install those separately in the `web` container when needed.

## Advanced Customization

Configuration lives in these files:

| File | Purpose |
| ---- | ------- |
| `.ddev/.env.assistant-t3` | T3 version and port overrides |
| `.ddev/config.assistant-t3.yaml` | Generated DDEV web port exposure |
| `.ddev/t3/settings.json` | T3 server settings, using T3's settings schema |

T3 runtime state is stored outside the project `.ddev` directory in DDEV's global cache. The add-on links T3's runtime `settings.json` back to `.ddev/t3/settings.json` so the user-editable server settings remain safe to commit.

To override the exposed ports or installed T3 version:

```bash
ddev dotenv set .ddev/.env.assistant-t3 --assistant-t3-http-port=21000
ddev dotenv set .ddev/.env.assistant-t3 --assistant-t3-https-port=21001
ddev dotenv set .ddev/.env.assistant-t3 --assistant-t3-version=0.0.27
ddev add-on get e0ipso/ddev-assistant-t3
ddev restart
```

Port and version changes are rendered into generated DDEV files during `ddev add-on get`, so re-run the add-on installation and restart after editing `.ddev/.env.assistant-t3`.

All customization options (use with caution):

| Variable | Flag | Default |
| -------- | ---- | ------- |
| `ASSISTANT_T3_VERSION` | `--assistant-t3-version` | `latest` |
| `ASSISTANT_T3_HTTP_PORT` | `--assistant-t3-http-port` | Calculated from `DDEV_SITENAME` |
| `ASSISTANT_T3_HTTPS_PORT` | `--assistant-t3-https-port` | Calculated from `DDEV_SITENAME` |
| `ASSISTANT_T3_CONTAINER_PORT` | `--assistant-t3-container-port` | `3773` |

The default port pair uses this algorithm:

```bash
hash="$(printf '%s' "${DDEV_SITENAME}" | cksum | awk '{print $1}')"
offset="$(( (hash % 4500) * 2 ))"
http_port="$(( 20000 + offset ))"
https_port="$(( http_port + 1 ))"
```

Hash collisions are possible. Override the ports if two projects calculate the same pair.

## Credits

**Contributed and maintained by [@e0ipso](https://github.com/e0ipso)**
