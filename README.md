# Enterprise Ansible Sandbox

I built this to have somewhere to break things on purpose.

## What This Is

I set up a sandbox to play inside with the intention of learning enterprise-level
Ansible skills — how to bootstrap infrastructure, automate it properly, and find out
what actually breaks when you do it on real hardware instead of a tutorial VM.

Five physical and virtual nodes. Two Linux families. Everything managed by Ansible
from first boot. If something isn't automated here, it doesn't exist.

## Lab Environment

| Node  | OS              | Role                          | Environment |
|-------|-----------------|-------------------------------|-------------|
| node1 | Rocky Linux 8.9 | Physical server (KVM host)    | prod        |
| node2 | Ubuntu 22.04    | Physical server (KVM host)    | test        |
| node3 | Rocky Linux 8.9 | VM on node1 — bridged         | dev         |
| node4 | Rocky Linux 8.9 | VM on node1 — bridged         | dev         |
| node5 | Ubuntu 22.04    | VM on node2 — NAT/ProxyJump   | test        |

**node2's wifi drops on purpose.** I wanted a test environment that actually misbehaves.
Playbooks that only run against stable nodes don't teach you anything. Every time node2
drops it's a chance to practice handling partial failures gracefully.

## What's Built

### Phase 0 — Lab Foundation

Before Ansible touches anything, the substrate has to exist. I built it by hand so I
understood what I was actually automating:

- KVM bridge networking on node1 — the VMs needed real LAN addresses, not NAT, so I
  moved node1's IP onto a bridge (`br0`) and enslaved the physical interface to it
- Provisioned 3 VMs with cloud-init (Rocky 8.9 × 2, Ubuntu 22.04 × 1) — more on what
  broke during this in the section below
- SSH ProxyJump for node5, which lives behind NAT on node2 and has no direct route out
- `bootstrap` role: ansible service account, SSH key, passwordless sudo — Molecule
  tested before it ever ran on real hardware

### Phase 1 — Base Configuration

- `common` role covers the baseline every node needs: hostname, NTP, SSH hardening,
  firewall, MOTD — same role runs on Rocky and Ubuntu using OS-family conditionals
- Vault for secrets — encrypted in the repo, password file gitignored
- Wrote the assert playbook before the role — define what done looks like first, then
  make it pass
- Killed node2's wifi mid-run on purpose to see what happened. Partial completion,
  clean re-run when it came back. That's what idempotency is actually for.

### Phase 3 — Gitea (self-hosted Git server)

Gitea runs on node1, backed by MariaDB. The interesting part was the role
dependency — `meta/main.yml` declares mariadb as a dependency of gitea, so there's
no playbook-level ordering to manage. Apply the gitea role, MariaDB comes with it.

Wrote verify.yml for both roles before writing a single task. Ran molecule, confirmed
it failed, then made it pass. Both roles hit zero changed on second run before anything
touched a real node. Deployed to dev first, idempotency confirmed, then the same
playbook ran against prod with different vault secrets. That's the whole point of
environment-aware structure — the role doesn't know or care which environment it's in.

## Problems I Hit and How I Diagnosed Them

This section exists because debugging is the actual job. These are real failures from
building this, not hypotheticals.

---

**cloud-init silently ignoring configuration files**

Provisioned a VM, it booted, but no user appeared and the static IP wasn't assigned.
cloud-init logs showed `config-users_groups: SUCCESS` — which made no sense.

Root cause: cloud-init's NoCloud datasource requires files named *exactly* `user-data`,
`meta-data`, and `network-config`. I had named them `node3-user-data` etc. cloud-init
found no valid files and silently used defaults.

Fix: always create files as `/tmp/user-data`, `/tmp/meta-data`, `/tmp/network-config`.
Verify before building the seed ISO: `sudo mount -o loop seed.iso /mnt/iso && ls /mnt/iso`

---

**Rocky 8 VMs falling back to DHCP instead of using the static IP**

VM booted, got an IP — but not the one specified in `network-config`. It was a random
DHCP address.

Root cause: Rocky 8 GenericCloud uses `eth0` as the network interface inside KVM.
I had specified `enp1s0:` in `network-config`. NetworkManager wrote an `ifcfg-enp1s0`
file which it then ignored because the actual interface was `eth0`.

Diagnosed via: `virsh domifaddr node3` to see what IP the VM actually got, then
`virt-cat -d node3 /var/log/messages | grep NetworkManager` to see what interface
the VM reported.

Fix: `eth0:` for Rocky 8 GenericCloud. `enp1s0:` for Ubuntu Jammy. They're different
because Ubuntu's udev rules rename the interface; Rocky's GenericCloud image doesn't
include those rules.

---

**SSH key split across multiple lines in cloud-init user-data**

VM provisioned, cloud-init reported user creation success, but SSH as the new user
failed with `Permission denied (publickey)`.

Root cause: pasting a long SSH public key into a heredoc caused the terminal to wrap
it visually. The key ended up broken across two lines in the file. cloud-init requires
the full key on a single unbroken line.

Diagnosed via: `grep ssh- /tmp/user-data` — the key was split.

Fix: inject the key as a shell variable rather than pasting directly:
```bash
PUBKEY=$(cat ~/.ssh/ansible_id_rsa.pub)
# reference $PUBKEY in the heredoc — the variable expands to one line
```

---

**Molecule verify failing on Rocky 8 container: `passwd` command not found**

`verify.yml` used `passwd -S ansible` to check whether the account password was locked.
Passed locally, failed in the Molecule container with `command not found`.

Root cause: the Rocky 8 minimal container image doesn't include the `passwd` binary
from the `shadow-utils` package in its default install.

Fix: replaced `passwd -S ansible` with `getent shadow ansible`. Accomplishes the same
check — verifies the account exists in the shadow database — and works in both
containers and full OS installs.

---

**community.general 12.x requires Python 3.7+ — Rocky 8 ships Python 3.6**

The `ansible.posix.sefcontext` and `community.general.seport` modules failed on
node3 and node4 with `SyntaxError: future feature annotations is not defined`. These
modules use Python 3.7 syntax (`from __future__ import annotations`) but the Rocky 8
VMs run Python 3.6 by default.

Diagnosed via: the traceback pointed directly to line 7 of the module file — a syntax
the interpreter couldn't parse, not a logic error.

Fix: replaced both modules with `ansible.builtin.command` tasks calling `semanage`
directly. Same outcome, no Python version dependency. The `changed_when` condition
checks for "already defined" in stdout (not stderr — semanage returns rc=0 with the
message in stdout when the entry already exists).

---

**Gitea rewrites app.ini after startup — breaks idempotency**

The template deployed correctly on first run. Second run showed `changed` on
`Deploy Gitea app.ini config` every time, triggering a restart handler on every
subsequent run.

Root cause: Gitea generates `INTERNAL_TOKEN` and `JWT_SECRET` on first boot and
writes them into `app.ini`. Our template didn't include these. Every subsequent run
overwrote Gitea's additions with the original template, Gitea re-added them on
restart, and the cycle repeated.

Additional wrinkle: Gitea strips alignment spaces and normalises the file. Template
had `DOMAIN    = node1` (aligned), file had `DOMAIN = node1` (single space). Same
difference, same cycle.

Fix: pre-populate all generated values in vault. Add them to the template so Gitea
sees its own values already in place and has no reason to modify the file. The
JWT_SECRET must be valid URL-safe base64 — a human-readable placeholder string will
cause Gitea to regenerate it.

---

**Node2-Down Drill: understanding UNREACHABLE vs FAILED**

Ran `common.yml` against the test environment with node2's wifi killed. Some tasks
completed on reachable nodes; node2 and node5 showed as UNREACHABLE.

Key learning: UNREACHABLE means Ansible couldn't connect via SSH — it's a connectivity
problem. FAILED means Ansible connected but the task returned an error — it's a logic
problem. They look similar in output but require completely different diagnosis.

Re-ran after node2 came back. Zero changes on all nodes that had already completed —
idempotency confirmed even across a split run.

## Engineering Practices

| Practice | Why |
|----------|-----|
| No default inventory in `ansible.cfg` | Forces explicit `-i environments/{env}/hosts.ini` on every run — impossible to accidentally target prod when you meant dev |
| Fully qualified module names | `ansible.builtin.copy` not `copy` — FQCN is permanent across Ansible versions; short names resolve through a lookup table that changes |
| ansible-lint production profile via pre-commit | Lint runs before every commit, not after — you can't commit broken playbooks |
| Assert playbook before role | `assert_common.yml` written first — defines what done actually looks like before implementation starts |
| Idempotency verified, not assumed | Every playbook runs twice — zero changes required on the second run |
| Dedicated ansible service account | Automation never runs as a human user — the account rotates independently, audit logs show `ansible` not a person |
| SELinux enforcing on all Rocky nodes | Contexts managed with `seboolean`/`sefcontext` — disabling SELinux to make something work is not a solution |

## Project Structure

```
ansible-sandbox/
├── environments/
│   ├── dev/        # node3, node4 (Rocky 8.9 VMs — disposable)
│   ├── test/       # node2, node5 (Ubuntu 22.04 — intentionally unstable)
│   └── prod/       # node1 (Rocky 8.9 physical — real services)
├── roles/
│   ├── bootstrap/  # service account creation (one-shot, Molecule verified)
│   ├── common/     # hardened baseline — all nodes, all environments
│   ├── mariadb/    # MariaDB install + gitea DB/user — TDD, Molecule tested
│   └── gitea/      # Gitea binary deploy, systemd, SELinux, firewalld, vault secrets
├── playbooks/
│   ├── bootstrap.yml
│   ├── common.yml
│   ├── assert_common.yml
│   ├── deploy_gitea.yml
│   └── assert_gitea.yml
└── collections/
    └── requirements.yml
```

## Running It

```bash
# Pre-flight
ansible all -m ping -i environments/dev/hosts.ini

# Dry run then apply
ansible-playbook --check -i environments/dev/hosts.ini playbooks/common.yml
ansible-playbook -i environments/dev/hosts.ini playbooks/common.yml

# Verify idempotency — second run must show zero changes
ansible-playbook -i environments/dev/hosts.ini playbooks/common.yml

# Run tests
cd roles/common && molecule test
```

## What's Next

The lab is still running. A few things on the roadmap:

- **Self-hosted services** — Gitea is live. Next: DNS filtering (Pi-hole), media
  server (Jellyfin), and file sync (Nextcloud) — all deployed via Ansible roles using
  the same TDD pattern. If the playbook doesn't do it, it doesn't happen.
- **CI/CD pipeline** — automating playbook runs on git push using a self-hosted
  Woodpecker CI instance. The goal is no manual `ansible-playbook` commands at all.
- **Red Hat ecosystem depth** — this lab doubles as a practice environment for going
  further in the Red Hat certification track. Building toward that on real hardware
  instead of a sandboxed exam environment.
- **Kubernetes** — I have some exposure and want to go deeper. Plan is to stand up a
  small cluster here and manage it with Ansible — the automation patterns carry over
  directly.
- **Terraform** — the bare-metal foundation is in place. The next gap is cloud
  provisioning. Terraform is the tool for that and I'm starting to explore it as a
  parallel track alongside this project.

## Certifications

- Red Hat Certified System Administrator (RHCSA)

## Tech Stack

Ansible · Rocky Linux 8.9 · Ubuntu 22.04 · KVM/libvirt · Molecule · Podman ·
ansible-vault · ansible-lint · MariaDB · Gitea · firewalld · ufw · SELinux · chrony · Python 3
