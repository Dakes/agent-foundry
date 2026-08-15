# Getting Started

A complete first run, from nothing to an agent that responds to a comment on
your Forgejo instance. Every command is shown in the order you run it, with
what should happen and what to do when it doesn't.

Assumed: Linux, and a Forgejo instance you can create tokens on. Roughly 30
minutes, most of it waiting for the image build.

- [1. Install](#1-install)
- [2. Set the sandbox network policy](#2-set-the-sandbox-network-policy-manual-once)
- [3. Build the agent image](#3-build-the-agent-image)
- [4. Create a project](#4-create-a-project)
- [5. Add an SSH key](#5-add-an-ssh-key-for-git)
- [6. Declare your repositories](#6-declare-your-repositories)
- [7. Start it](#7-start-it)
- [8. Add the watcher](#8-add-the-watcher-optional)
- [9. Talk to the agent](#9-talk-to-the-agent)

---

## 1. Install

Foundry runs on [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/).
Install that first and sign in:

```bash
sbx version          # must print a version
sbx login            # opens a browser
```

Then Foundry itself:

```bash
git clone https://github.com/user/agent-foundry.git
cd agent-foundry
./install.sh --prefix ~/.local
```

The installer sets permissions, resolves library paths and updates your shell
rc file. Open a new shell, then:

```bash
foundry doctor
```

It reports what is missing. `foundry doctor --fix` repairs what it can.

---

## 2. Set the sandbox network policy (manual, once)

**This step cannot be automated and everything else depends on it.**

Docker Sandboxes asks once, interactively, which network policy to install.
There is no flag for it, so Foundry cannot do it for you:

```bash
sbx policy reset
```

Choose **Open** (option 1) with the arrow keys.

Foundry's posture is *open internet, closed LAN*: it wants full egress from
sbx and applies the LAN denials itself. `foundry doctor --fix` adds those:

```bash
foundry doctor --fix
```

> **Why Open matters.** sbx gates DNS on the policy. On *Balanced* or
> *Locked Down*, a host that isn't allowed doesn't merely get refused — it
> doesn't resolve. The error is `Could not resolve hostname`, which reads like
> broken DNS rather than a missing rule, and it will cost you an afternoon.

Check what's active at any time with `foundry doctor`.

---

## 3. Build the agent image

```bash
foundry image build
```

This takes several minutes. It produces `foundry-agent:base` containing every
agent CLI (`claude`, `gemini`, `codex`, `agy`), the Forgejo watcher, git, the
GitHub and Forgejo CLIs, a compiler toolchain, and a Docker engine.

Two details worth knowing:

- The image's agent user gets **your** UID/GID, so files the agent writes stay
  editable by you rather than landing as root.
- It is loaded into the sandbox runtime's **separate image store**. A locally
  built image is invisible to `sbx` until that happens, which is why builds go
  through `foundry image build` rather than plain `docker build`.

Extra apt packages: add them to `config/packages.txt` and rebuild.

---

## 4. Create a project

A project is a directory on the host, mounted into its sandbox at the same
path, and it is the agent's home:

```bash
foundry init my-project
```

This scaffolds `~/.local/share/foundry/volumes/my-project/`, applies the
network baseline, and creates and starts the sandbox. With no repositories
declared yet, nothing is cloned.

```
my-project/
├── foundry.json     # the project's settings - init and up both read this
├── AGENT.md         # standing instructions, loaded by every agent CLI
├── repos/           # clones land here
├── secrets/         # tokens (0700)
├── logs/
└── .ssh/            # per-project git keys (0700)
```

`foundry.json` is **input**, not output. Editing it and re-running `up` is the
normal way to change a project.

---

## 5. Add an SSH key for git

Foundry never reads `~/.ssh` and never generates a key for you. Create one for
this project and add the public half to your forge as a deploy key or on a
dedicated agent account:

```bash
cd ~/.local/share/foundry/volumes/my-project
ssh-keygen -t ed25519 -f .ssh/id_agent -C "foundry my-project"
cat .ssh/id_agent.pub          # paste into Forgejo
```

Then point `.ssh/config` at it — `init` seeds that file with commented
examples, including how to give the agent a separate identity on a forge you
already use:

```
Host git.example.com
    HostName git.example.com
    Port 2222
    User git
    IdentityFile ~/.ssh/id_agent
    IdentitiesOnly yes
```

> The agent's home inside the sandbox is `/home/agent`, symlinked to this
> directory. That symlink exists **because of ssh**: OpenSSH resolves `~/.ssh`
> from the passwd entry, not from `$HOME`, so without it ssh would read an
> empty `/home/agent/.ssh` and your keys would be invisible.

---

## 6. Declare your repositories

Edit `foundry.json`:

```json
{
  "name": "my-project",
  "agent": "claude-goal",
  "repos": [
    { "url": "ssh://git@git.example.com:2222/you/backend.git", "dir": "backend" },
    { "url": "ssh://git@git.example.com:2222/you/frontend.git", "dir": "frontend" }
  ]
}
```

Pick the agent now, because it decides what else is possible:

| `.agent` | Kind | Use when |
|---|---|---|
| `claude`, `gemini`, `codex` | interactive | you drive it yourself in a terminal |
| `claude-goal`, `codex-goal`, `agy-goal` | autonomous | it should work unattended, and for **any watcher** |

A watcher can only drive a `*-goal` agent: it runs headless, and an
interactive CLI would sit waiting for a human nobody can provide.

Git remotes are allowed through the network policy automatically — you don't
add rules for them by hand.

---

## 7. Start it

```bash
foundry up my-project
```

`up` reconciles: it starts the sandbox, publishes ports, clones any repository
that is declared but missing, and starts the agent. It is safe to re-run, and
re-running is how you apply a config change.

```bash
foundry status my-project     # sandbox, agent, repos, ports, policy
foundry logs -f my-project    # follow the agent
foundry shell my-project      # a shell inside, as the agent user
```

If the clone fails, the error names the cause — a missing key, an unreachable
host, a denied policy — rather than passing git's message through.

---

## 8. Add the watcher (optional)

The watcher turns issue and pull-request comments into agent runs.

### 8a. Create a Forgejo token

In Forgejo: **Settings → Applications → Generate New Token**. Scopes:

- `read:issue` and `write:issue` — to read comments and reply
- `read:repository` and `write:repository` — for pull requests
- `write:admin` on the repo **only if** you want Foundry to register the
  webhook for you (step 8c). Registering by hand needs no extra scope.

Save it into the project:

```bash
cd ~/.local/share/foundry/volumes/my-project
install -m 600 /dev/null secrets/forgejo-token.txt
$EDITOR secrets/forgejo-token.txt        # paste the token, nothing else
```

### 8b. Configure the watcher

Add to `foundry.json`:

```json
{
  "watcher": {
    "kind": "forgejo",
    "instance_url": "https://git.example.com",
    "receiver_port": 9174,
    "trigger_keyword": "@mybot",
    "watched_repos": ["you/backend"],
    "token_file": "secrets/forgejo-token.txt",
    "public_url": "http://localhost"
  }
}
```

- **`receiver_port`** is the port the watcher *listens on* — what Forgejo
  POSTs **to**, not a port it talks to. It must be 1024 or above.
- **`public_url`** is that receiver as **Forgejo sees it**. On the same
  machine as your forge, `http://localhost` is right. The receiver port and
  the `/webhook` path are appended for you, so this becomes
  `http://localhost:9174/webhook`.
- **`trigger_keyword`** is what people type to summon the agent.

Then:

```bash
foundry up my-project
```

The watcher now starts automatically whenever the project is up, and stops
with `foundry down`. Check it:

```bash
foundry watcher status my-project
foundry watcher logs my-project
```

### 8c. Register the webhook

**Automatically** (needs the admin scope from 8a):

```bash
foundry watcher register my-project
```

**By hand** — in the repository: **Settings → Webhooks → Add Webhook →
Forgejo**, then:

| Field | Value |
|---|---|
| Target URL | `http://localhost:9174/webhook` (your `public_url`, port and path included) |
| HTTP Method | `POST` |
| POST Content Type | `application/json` |
| Secret | the contents of `.config/forgejo-watcher/webhook-secret` in the volume root |
| Trigger On | Custom Events: **Issues**, **Issue Comment**, **Pull Request**, **Pull Request Comment** |
| Branch filter | `*` |
| Active | ✓ |

The secret is generated on the first `foundry up` and then kept, because
changing it would silently break every hook already registered:

```bash
cat ~/.local/share/foundry/volumes/my-project/.config/forgejo-watcher/webhook-secret
```

Forgejo's **Test Delivery** button should return 200. A connection error means
`public_url` is wrong or the port isn't reachable from the forge; a 4xx means
the request arrived but the path or secret is wrong.

---

## 9. Talk to the agent

Comment on an issue or pull request, stating the **mode** as the first word
after your keyword:

```
@mybot review          read the diff and comment; never pushes, never opens a PR
@mybot implement       new branch, code, pull request
@mybot fix             push to the existing branch; never opens a new PR
@mybot answer          comment only; changes nothing
```

The mode is never guessed from your phrasing. A comment that states no mode
gets a reply listing this syntax and **starts no agent** — asking costs one
comment, while guessing wrong costs an unwanted pull request.

Watch it work:

```bash
foundry watcher logs my-project     # what the watcher decided
foundry logs -f my-project          # what the agent is doing
foundry attach my-project           # attach to the live session
```

---

## Where things live

| What | Where |
|---|---|
| Project settings | `<volume root>/foundry.json` |
| Standing instructions | `<volume root>/AGENT.md` |
| Host defaults | `~/.config/foundry/config.conf` |
| Watcher config + state | `<volume root>/.config/forgejo-watcher/` |
| Agent logs | `<volume root>/logs/` |
| Extra apt packages | `config/packages.txt` in the checkout (rebuild after) |

The watcher's `config.conf` is **generated** from `foundry.json` on every `up`.
Edit `foundry.json`, not that file.

## When something is wrong

| Symptom | Cause |
|---|---|
| `Could not resolve hostname` | The policy isn't Open, and sbx gates DNS on it. See step 2. |
| `Permission denied (publickey)` | The key isn't in `<volume root>/.ssh/`, or `.ssh/config` doesn't point at it. |
| `403` when creating a sandbox | The image isn't in the sandbox runtime's store. Re-run `foundry image build`. |
| Watcher exits right after starting | Read `<volume root>/.config/forgejo-watcher/watcher.log` — the config failed to validate. |
| Webhook delivers, nothing happens | Wrong secret, or the URL is missing `/webhook`. |
| Agent refuses to start with a watcher | `.agent` is interactive; a watcher needs a `*-goal` agent. |

`foundry doctor <project>` checks the host, policy, ports and keys in one go.
