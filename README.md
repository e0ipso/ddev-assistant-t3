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

T3 runs on the project's Node.js version, and `ddev t3 start` refuses versions that the installed T3 doesn't support, according to the `engines` field of its npm package. The npm package `t3` is a launcher: the first `ddev t3 start` of each T3 version downloads T3's prebuilt runtime, several hundred MB, into the project's T3 state volume, so it needs network access.

## Usage

| Command | Description |
| ------- | ----------- |
| `ddev t3 start` | Start `t3 serve` in the web container and stream logs |
| `ddev t3 help` | Show command help |

`ddev t3 start` prints the HTTP and HTTPS URLs before starting T3. Press `Ctrl-C` to stop T3.

Those URLs only work on the machine running DDEV. To reach T3 from another machine, see [Remote access](#remote-access-tailscale-lan).

This add-on does not install or validate assistant provider CLIs such as Claude, Codex, Gemini, Grok, OpenCode, or Cursor Agent. Install those separately in the `web` container when needed.

## Remote access (Tailscale, LAN)

Two things get in the way of a request arriving from a Tailscale peer or another host on
the LAN:

1. `ddev-router` binds its host ports to `localhost` unless the global
   [`router_bind_all_interfaces`](https://ddev.readthedocs.io/en/stable/users/configuration/config/#router_bind_all_interfaces)
   setting is enabled.
2. `ddev-router` routes by `Host` header. It only answers to the project hostnames, so a
   request for `http://laptop.tailnet.ts.net:20500` gets a 404 even once the port is
   reachable.

T3 itself is not the problem: it already binds `0.0.0.0` inside the web container.

`ASSISTANT_T3_DIRECT_BIND_ADDRESS` publishes the T3 port straight from the web container
to one or more host addresses, skipping `ddev-router` and its hostname matching. It takes
a comma-separated list, and each entry becomes its own host binding on the same port. It
defaults to `127.0.0.1`, so out of the box T3 is also available at
`http://127.0.0.1:<direct-port>` and nothing is published beyond the machine.

Add the machine's Tailscale IP, from `tailscale ip -4`, to reach T3 from the tailnet:

```bash
ddev dotenv set .ddev/.env.assistant-t3 --assistant-t3-direct-bind-address=127.0.0.1,100.91.141.70
ddev add-on get e0ipso/ddev-assistant-t3
ddev restart
```

Local browsers keep using `http://127.0.0.1:<direct-port>` and tailnet peers use
`http://100.91.141.70:<direct-port>`, with nothing exposed to any other network. Setting
the value to `0.0.0.0` publishes on every interface instead, and setting it to nothing at
all leaves only the `ddev-router` ports.

`ddev t3 start` then prints the direct address alongside the project URLs. The direct
port defaults to `10000 + offset`, using the same offset as the router ports, and can be
overridden with `--assistant-t3-direct-port`.

Installation fails with an explanation if the list repeats an address, or if it mixes
`0.0.0.0` or `[::]` with a specific one; both cases would otherwise leave the web
container unable to bind its ports and take `ddev start` down with it.

To turn remote access off again, clear the value and re-run the add-on; the generated
`.ddev/docker-compose.assistant-t3.yaml` then publishes no ports.

### Choosing bind addresses

| Value | Reachable from | If Tailscale is not running |
| ----- | -------------- | --------------------------- |
| `127.0.0.1` (default) | The DDEV machine only | Unaffected |
| `127.0.0.1,<tailscale-ip>` | The DDEV machine and the tailnet | `ddev start` fails until the address exists or the entry is removed |
| `0.0.0.0` | The DDEV machine, the tailnet, and every other network the machine is on | Unaffected |

Docker binds published ports when the container starts and fails if the address is not on
the host, so listing a Tailscale IP ties `ddev start` to `tailscaled` running:

```text
Error response from daemon: failed to bind host port for 100.91.141.70:16060:
cannot assign requested address
```

The whole project fails to start, not just T3. The address itself is stable, and it is
present whenever `tailscaled` is running, including while the machine is offline. Only
stopping the daemon removes it. If that happens, drop the entry from
`ASSISTANT_T3_DIRECT_BIND_ADDRESS`, re-run the add-on, and `ddev start` again. `0.0.0.0`
avoids the coupling entirely, at the price of publishing T3 on every attached network.

The direct port is plain HTTP. Traffic across the tailnet is still encrypted by
WireGuard, but browsers withhold some APIs outside a secure context, and the port carries
no TLS for LAN clients.

### Security

T3 drives assistant CLIs that execute code in the web container, so a client connected to
T3 controls those assistants and, through them, the project. Reaching the port is not
enough on its own: T3 only lets in clients that have paired with a one-time pairing token
or link, and each paired client gets a session that you can revoke.

To make a new pairing link while `ddev t3 start` is running:

```bash
ddev exec 't3 pair --base-dir "/mnt/ddev-global-cache/assistant-t3/${DDEV_SITENAME}"'
```

It prints a one-time token and a pairing URL. The URL uses the web container's own
address, so open its `/pair#token=...` part on one of the URLs `ddev t3 start` prints
instead, for example `http://127.0.0.1:<direct-port>/pair#token=<token>`.

The link expires after 5 minutes unless you pass `--ttl`, for example `--ttl 15m`. Until
then anyone who has it can pair, so treat pairing links, tokens and their QR codes like
passwords. To list the paired sessions and revoke one:

```bash
ddev exec 't3 auth session list --base-dir "/mnt/ddev-global-cache/assistant-t3/${DDEV_SITENAME}"'
ddev exec 't3 auth session revoke <session-id> --base-dir "/mnt/ddev-global-cache/assistant-t3/${DDEV_SITENAME}"'
```

Pairing is then the only thing between a network and the project. Prefer listing the
specific addresses you need over `0.0.0.0`, which also publishes T3 on coffee-shop Wi-Fi
and every other attached network, and leave remote access off when it is not needed.

## Advanced Customization

Configuration lives in these files:

| File | Purpose |
| ---- | ------- |
| `.ddev/.env.assistant-t3` | T3 version and port overrides |
| `.ddev/config.assistant-t3.yaml` | Generated DDEV web port exposure |
| `.ddev/docker-compose.assistant-t3.yaml` | Generated T3 state volume mount, and direct host port publishing when remote access is enabled |
| `.ddev/t3/settings.json` | T3 server settings, using T3's settings schema |

T3 keeps its runtime state outside the project `.ddev` directory, in the Docker volume `ddev-<project>-assistant`, which the `web` container mounts at `/mnt/ddev-global-cache/assistant-t3`. The state includes device pairings, the server identity, T3's database and the downloaded runtime, so it survives `ddev restart`, `ddev poweroff` and web image rebuilds. Each project has its own volume, so no other project's containers can read its T3 credentials. The add-on links T3's runtime `settings.json` back to `.ddev/t3/settings.json` so the user-editable server settings remain safe to commit.

To override the exposed ports or installed T3 version:

```bash
ddev dotenv set .ddev/.env.assistant-t3 --assistant-t3-http-port=21000
ddev dotenv set .ddev/.env.assistant-t3 --assistant-t3-https-port=21001
ddev dotenv set .ddev/.env.assistant-t3 --assistant-t3-version=0.1.11
ddev add-on get e0ipso/ddev-assistant-t3
ddev restart
```

Port and version changes are rendered into generated DDEV files during `ddev add-on get`, so re-run the add-on installation and restart after editing `.ddev/.env.assistant-t3`.

`ASSISTANT_T3_VERSION` accepts an npm dist-tag such as `latest` or an exact version. With a dist-tag, `ddev restart` installs the version the tag currently points to; the web image build checks the npm registry, so it needs network access. Updates installed inside a running container are lost when DDEV recreates it.

All customization options (use with caution):

| Variable | Flag | Default |
| -------- | ---- | ------- |
| `ASSISTANT_T3_VERSION` | `--assistant-t3-version` | `latest` |
| `ASSISTANT_T3_HTTP_PORT` | `--assistant-t3-http-port` | Calculated from `DDEV_SITENAME` |
| `ASSISTANT_T3_HTTPS_PORT` | `--assistant-t3-https-port` | Calculated from `DDEV_SITENAME` |
| `ASSISTANT_T3_CONTAINER_PORT` | `--assistant-t3-container-port` | `3773` |
| `ASSISTANT_T3_DIRECT_BIND_ADDRESS` | `--assistant-t3-direct-bind-address` | `127.0.0.1`. Comma-separated list of host addresses; empty publishes nothing |
| `ASSISTANT_T3_DIRECT_PORT` | `--assistant-t3-direct-port` | Calculated from `DDEV_SITENAME` |

The default port pair uses this algorithm:

```bash
hash="$(printf '%s' "${DDEV_SITENAME}" | cksum | awk '{print $1}')"
offset="$(( (hash % 4500) * 2 ))"
http_port="$(( 20000 + offset ))"
https_port="$(( http_port + 1 ))"
```

Hash collisions are possible. Override the ports if two projects calculate the same pair.

## Upgrading from versions without the state volume

Earlier versions of this add-on kept T3's state in DDEV's shared `ddev-global-cache` volume. DDEV v1.25.6 and later no longer mount that volume in the `web` container, so T3 lost its state, and paired devices their access, each time DDEV recreated the container.

The add-on does not migrate the old state. After you upgrade the add-on and run `ddev restart`, pair your devices with T3 again one time. State written by earlier versions stays in the `ddev-global-cache` volume, where nothing uses it any more. To free that space, remove it through a throwaway container that mounts the volume:

```bash
docker run --rm -v ddev-global-cache:/mnt/ddev-global-cache ddev/ddev-utilities rm -rf /mnt/ddev-global-cache/assistant-t3/<project>
```

## Removal

```bash
ddev add-on remove assistant-t3
ddev restart
```

Removal deletes the generated DDEV files but keeps `.ddev/.env.assistant-t3` and `.ddev/t3/settings.json`, so a later reinstall picks your settings up again. Delete them by hand if you don't need them.

Removal also keeps the `ddev-<project>-assistant` volume, because it holds your T3 pairings and data. `ddev delete` removes it with the project. To remove it without deleting the project, stop the project and remove the volume:

```bash
ddev stop
docker volume rm ddev-<project>-assistant
```

## Credits

**Contributed and maintained by [@e0ipso](https://github.com/e0ipso)**
