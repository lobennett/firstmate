# Labmate

Talk to one lab manager.
Work with a research lab of agents.

Labmate is a public fork of [kunchenguid/firstmate](https://github.com/kunchenguid/firstmate), preserving its history, MIT license, original copyright, and attribution.
This fork develops at [lobennett/labmate](https://github.com/lobennett/labmate).
The original project's authors and tooling remain credited; Labmate is not an official rename of the upstream project.

## What it is

You are the PI.
Your lab manager takes requests, assigns isolated tasks, supervises the lab, and brings back finished PRs, approved local changes, or investigation reports.
You make the research and approval decisions without juggling agent terminals.

Labmate is an agent distribution, not a new model or agent runtime.
The cloned directory supplies instructions, skills, tooling, policies, and durable records to an existing terminal coding agent.
It retains Firstmate's tested orchestration rather than replacing it.

### Responsibilities

- **Lab manager** - your coordinating point of contact, responsible for assignments, supervision, the research agenda, and escalation.
- **Postdoc** - senior investigation and persistent domain coordination, using the existing isolated-domain architecture.
- **Graduate researcher** - bounded implementation and analysis.
- **Research coordinator** - routine operations and tracking.
- **Lab member** - the generic term when no specific role fits.

Postdoc, graduate researcher, and research coordinator express responsibility and priority, in that order, not permanent model rankings.
The lab manager routes a task directly to the appropriate role; there is no mandatory delegation chain or extra supervision tier.
An investigation or review is work assigned to an appropriate role, not a separate rank.
Every role retains the same task-specific isolation, validation, credential, and approval requirements.

## Features

- **One liaison** - the lab manager assigns work, supervises, and reports concrete outcomes and decisions.
- **Visible parallel work** - each lab member works in an isolated git copy and a visible session endpoint.
- **Two deliverables** - implementation tasks produce authorized changes; investigations produce standalone reports.
- **Explicit delivery and approval** - existing `no-mistakes`, `direct-PR`, and `local-only` modes remain available, with merge approval required unless explicitly authorized otherwise.
- **Persistent domain support** - optional postdocs run in isolated homes locally or on SSH-reachable hosts.
- **Event-driven supervision** - monitoring wakes the lab manager only when action is needed, with supported session-end safeguards.
- **Durable research agenda** - assignments, decisions, and work records survive restarts.
- **Optional Relay** - public mentions use the same authority and approval boundaries as chat.
- **Compatible interfaces** - `bin/fm-*`, `FM_*`, existing command names, configuration paths, schemas, IDs, and integration protocols remain unchanged.

The [supervisor contract](AGENTS.md) owns the lab vocabulary and its compatibility mapping.
Older records remain readable without a forced migration.
Installing this fork does not migrate or replace an existing Firstmate installation.

## Quick Start

### Requirements

- A verified primary agent runtime: Claude Code, Grok, Pi, `pi-signed`, Oh My Pi (`omp`), Codex, OpenCode, or Cursor Agent CLI.
- Git and GitHub CLI authentication.
- Dependencies for the selected session backend; tmux is the reference default.

### Install and launch

```sh
gh auth login
git clone https://github.com/lobennett/labmate
cd labmate
```

Launch a supported runtime in this directory; `AGENTS.md` supplies the lab manager's instructions.
For example:

```sh
claude
# or
grok --trust
# or
pi
# or
FM_PI_HARNESS=pi-signed pi-signed
# or
omp
# when launching omp from inside a Claude Code pane
FM_OMP_HARNESS=omp omp
```

Claude Code, Grok, and Pi retain the upstream co-primary support posture.
Approve project trust where required so the tracked supervision hooks or extensions load.
Cursor Agent CLI requires an interactive launch with `--trust`.
Oh My Pi auto-discovers the tracked `.omp/extensions/*.ts` files; do not load them twice with `-e`.
Detailed runtime setup and current limits belong in [configuration](docs/configuration.md) and the backend guides below.

### Talk to it

```text
> Investigate the flaky analysis test, then fix it and add a reproducibility check.

PI, the fix is ready for review: https://github.com/you/project/pull/42
The checks are green.

> Merge it.
```

The lab manager reads project material, while lab members make project changes in isolated copies, subject to the existing narrow exceptions and approval safeguards.
It never discards unlanded work or treats a new role label as permission to merge.

## Built-in skills

Command names remain compatible with existing installations.

| Skill | Purpose |
| --- | --- |
| `/afk` | Supervise authorized work while you are away. |
| `/quiet` | Keep routine supervision out of the main conversation while you remain present; `/quiet off` exits. |
| `/ahoy` | Recap the visible session and guide you through unanswered decisions. |
| `/bearings` | Summarize the lab, decisions, research agenda, and contribution follow-up; `file` writes a dated report, and `include PRs` requests live forge enrichment. |
| `/updatefirstmate` | Guardedly update this installation and registered postdoc homes. |
| `/stow` | Curate durable knowledge and the session's open work records before a reset. |

The existing `/calm` presentation feature remains available where supported; explicitly select `/resting-state` for its lab-themed slowly drifting wave alternative.
See [Calm and Resting State](docs/calm.md) for current behavior and supported limits.
Pi's `/supervision-model` command selects a model and reasoning effort for supervision alone, without permanently assigning a model to a lab role.

### Two-tier skill layout

Agent-loaded skills live under `.agents/skills/` and assume an operational home.
They retain `metadata.internal: true` so standalone installers do not advertise them.
The public `skills/` directory contains independent installer-facing skills, currently the generic `stow` skill, not Labmate supervision instructions.

## Documentation

- [Architecture](docs/architecture.md) - supervision, isolated work, domain delegation, and delivery modes.
- [Configuration](docs/configuration.md) - `FM_HOME`, stable configuration and record formats, runtime selection, optional Relay, and external integrations.
- [Remote domain homes](docs/remote-secondmates.md) - setup, routing, transfer, recovery, and safety for remote postdocs.
- Session backends: [tmux](docs/tmux-backend.md), [Herdr](docs/herdr-backend.md), [Zellij](docs/zellij-backend.md), [Orca](docs/orca-backend.md), [cmux](docs/cmux-backend.md), [Paseo](docs/paseo-backend.md), and [Rex](docs/rex-backend.md).
- [Codex App boundary](docs/codex-app-backend.md) - current supported limits.
- [Calm](docs/calm.md), [voice interface](docs/voice-relay.md), [activity ledger](docs/fleet-ledger.md), [escalation alarm](docs/wedge-alarm.md), and [usage warnings](docs/usage-warner.md).
- [Extension bindings](docs/extension-bindings.md) - trusted process-event adapters.
- [Session-end protection](docs/turnend-guard.md) and [supervision protocols](docs/supervision-protocols/).
- Active verification: [runtime backends](docs/verification/runtime-backends.md) and [supervision](docs/verification/supervision.md).
- [Scripts](docs/scripts.md), [documentation audiences](docs/documentation-audiences.md), and [contributing](CONTRIBUTING.md).

## Contributing and attribution

Contribute to **lobennett/labmate**, not the original upstream, unless separately authorized to contribute there.
Follow [CONTRIBUTING.md](CONTRIBUTING.md) and the normal green-check PR path; never push directly to `main`.
Changing a running installation to this fork is a separate operator decision, not a side effect of contributing.

Labmate retains the original [MIT license](LICENSE), including Copyright (c) 2026 Kun Chen, and attribution to Firstmate's authors.
External tools linked by the documentation remain independent projects with their own names and licenses.
