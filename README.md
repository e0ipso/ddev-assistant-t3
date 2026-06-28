[![add-on registry](https://img.shields.io/badge/DDEV-Add--on_Registry-blue)](https://addons.ddev.com)
[![tests](https://github.com/e0ipso/ddev-assistant-t3/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/e0ipso/ddev-assistant-t3/actions/workflows/tests.yml?query=branch%3Amain)
[![last commit](https://img.shields.io/github/last-commit/e0ipso/ddev-assistant-t3)](https://github.com/e0ipso/ddev-assistant-t3/commits)
[![release](https://img.shields.io/github/v/release/e0ipso/ddev-assistant-t3)](https://github.com/e0ipso/ddev-assistant-t3/releases/latest)

# DDEV Assistant T3

## Overview

This add-on integrates Assistant T3 into your [DDEV](https://ddev.com/) project.

## Installation

```bash
ddev add-on get e0ipso/ddev-assistant-t3
ddev restart
```

After installation, make sure to commit the `.ddev` directory to version control.

## Usage

| Command | Description |
| ------- | ----------- |
| `ddev describe` | View service status and used ports for Assistant T3 |
| `ddev logs -s assistant-t3` | Check Assistant T3 logs |

## Advanced Customization

To change the Docker image:

```bash
ddev dotenv set .ddev/.env.assistant-t3 --assistant-t3-docker-image="ddev/ddev-utilities:latest"
ddev add-on get e0ipso/ddev-assistant-t3
ddev restart
```

Make sure to commit the `.ddev/.env.assistant-t3` file to version control.

All customization options (use with caution):

| Variable | Flag | Default |
| -------- | ---- | ------- |
| `ASSISTANT_T3_DOCKER_IMAGE` | `--assistant-t3-docker-image` | `ddev/ddev-utilities:latest` |

## Credits

**Contributed and maintained by [@e0ipso](https://github.com/e0ipso)**
