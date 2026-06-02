# Enterprise Ansible Sandbox

I built this to have somewhere to break things on purpose.

## What This Is

I built this to learn enterprise Ansible on real hardware — how to bootstrap
infrastructure, automate it properly, and find out what actually breaks when you do it
instead of a tutorial VM.

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

**node2's wifi is unreliable.** It drops periodically and I haven't fixed it yet.
Turns out that's useful — playbooks that only run against stable nodes don't teach
you anything about partial failures.

## What's Built

### Building the Substrate

Before Ansible touches anything, the substrate has to exist. I built it by hand so I
understood what I was actually automating:

- KVM bridge networking on node1 — the VMs needed real LAN addresses, not NAT, so I
  moved node1's IP onto a bridge (`br0`) and enslaved the physical interface to it
- Provisioned 3 VMs with cloud-init (Rocky 8.9 × 2, Ubuntu 22.04 × 1) — more on what
  broke during this in the section below
- SSH ProxyJump for node5, which lives behind NAT on node2 and has no direct route out
- `bootstrap` role: ansible service account, SSH key, passwordless sudo — Molecule
  tested before it ever ran on real hardware

### Getting the Baseline Right

- `common` role covers the baseline every node needs: hostname, NTP, SSH hardening,
  firewall, MOTD — same role runs on Rocky and Ubuntu using OS-family conditionals
- Vault for secrets — encrypted in the repo, password file gitignored
- Wrote the assert playbook before the role — define what done looks like first, then
  make it pass
- Killed node2's wifi mid-run on purpose to see what happened. Partial completion,
  clean re-run when it came back. That's what idempotency is actually for.

### Gitea (self-hosted Git server)

Gitea runs on node1, backed by MariaDB. The interesting part was the role
dependency — `meta/main.yml` declares mariadb as a dependency of gitea, so there's
no playbook-level ordering to manage. Apply the gitea role, MariaDB comes with it.

Wrote verify.yml for both roles before writing a single task. Ran molecule, confirmed
it failed, then made it pass. Both roles hit zero changed on second run before anything
touched a real node. Deployed to dev first, idempotency confirmed, then the same
playbook ran against prod with different vault secrets. That's the whole point of
environment-aware structure — the role doesn't know or care which environment it's in.

### Woodpecker CI (self-hosted CI/CD)

Every push to the Gitea repo now triggers ansible-lint automatically. No third-party
CI service — Woodpecker runs on node1, watches the local Gitea instance via OAuth, and
executes the pipeline. The whole pipeline definition is a `.woodpecker.yml` file in the
repo root. Change the file, change what runs. That's pipeline as code.

Pipeline steps run inside containers. Rather than installing ansible-lint at runtime on
every run, I built a custom image with a pinned version and pushed it to Gitea's
built-in container registry. The image tag is `ansible-lint:6.22.2` — that version is
what this repo gets linted against until I deliberately change it. Pinning both
ansible-lint and ansible-core in the Containerfile matters: unpinned, pip resolves to
whatever is latest — and latest breaks things, as the debugging section covers.

A few deliberate decisions worth noting:

**Lint only, no auto-deploy.** The pipeline runs ansible-lint and stops. It doesn't
run `ansible-playbook` on push. That's intentional — gating lint and gating deployment
are separate concerns. A commit that passes lint hasn't necessarily been reviewed for
whether it should actually run against prod. Auto-deploy comes later, with more
guardrails in place.

**Separate OAuth apps for dev and prod.** Woodpecker on node3 (dev) and node1 (prod)
each have their own Gitea OAuth application with separate client credentials. Sharing
one set of credentials across environments means a leaked dev secret is also a leaked
prod secret. The extra five minutes to create a second app is worth it.

**Dedicated woodpecker service account, not the ansible account.** The agent runs as
`woodpecker` — a system user with no login shell and no sudo. The ansible service
account has broad sudo access across the infrastructure; giving the CI agent the same
identity would mean a compromised pipeline has the keys to everything. Least privilege
from the start.

Getting the pipeline green took longer than expected. Four separate failures stacked on
each other across two sessions. The debugging section has the full write-up.

### Self-Hosted Services

With the infrastructure and CI/CD in place, I deployed four real services on top of it.
Same workflow as everything before: write verify.yml first, write the role to make it
pass, confirm zero changes on second run, deploy to dev before prod.

**Pi-hole** — network-wide DNS ad-blocking. Every guide online was written for v5, which
stores config in a simple key=value file. Pi-hole v6 replaced that entirely with a TOML
format file in a different location. The v5 approach does nothing on v6. The fix was the
capture-and-template pattern: install Pi-hole once on the dev node, capture the config it
generates, sanitize it into a Jinja2 template, automate future installs from that. The
installer also has an `--unattended` flag that only works if the config file already
exists — so the role writes the template before running the installer.

**Jellyfin** — self-hosted media server. This was the first custom SELinux policy in
the project. Every containerized service that writes to host directories needs one —
SELinux's default policy doesn't know about your `/srv/jellyfin`, so it denies access
until you define the rules. I created two custom file types: `jellyfin_data_t` for
config and cache (read/write), and `jellyfin_media_t` for the media library (read-only).
The kernel enforces that split regardless of what the application or any attacker tries
to do. Also established the UID pinning pattern here — without explicit UID pins,
redeploys on different nodes silently get different UIDs, which breaks file ownership
when you restore from backup.

**Nextcloud** — self-hosted file sync and storage. Most complex role in the project:
PHP-FPM, nginx, MariaDB, and Nextcloud's CLI management tool (`occ`) all working together.
The non-obvious dependency: Rocky Linux's default PHP is too old for Nextcloud 30.x, so
the role pulls PHP 8.3 from the Remi repository (GPG key imported first, then the release
RPM — get the order wrong and yum refuses to install it). The `occ` CLI also needs the
`php-process` package for its POSIX calls — not in Nextcloud's documented requirements,
not pulled in automatically, and the web interface works fine without it, so it only shows
up when you actually run an `occ` command.

**Immich** — self-hosted photo and video management. Unlike the previous services, Immich
is a four-container stack: application server, machine learning inference, PostgreSQL with
vector extensions, and Redis. Orchestrated with Podman Compose. This introduced CIL policy
authoring (newer than TE — no compilation step, loaded directly with `semodule -i`) and
`udica` for generating first-draft policies from running containers. Before any prod
deployment, a dedicated security hardening pass closed 10 findings: `no-new-privileges`
on all containers, `cap_drop: ALL` with only empirically-proven caps added back, and a
dedicated SELinux type (`immich_ml_cache_t`) scoping the ML container's write access to
its own cache directory rather than all container storage on the host.

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

---

**Woodpecker agent couldn't reach the Podman socket on prod**

Deployed Woodpecker to dev (node3) without issue. Same playbook ran against prod
(node1) and the agent couldn't pull container images — permission denied on the Podman
socket.

Root cause: `/run/podman` was created at boot with mode `700` (root only) on node1.
On node3 the directory happened to have looser permissions from a previous Podman
invocation. The woodpecker user was in the `podman` group, but group permissions don't
help if the directory itself blocks traversal.

Fix: a `tmpfiles.d` drop-in that sets `/run/podman` to `0750 root podman` on every
boot. `tmpfiles.d` is the right tool here — it runs before services start and persists
across reboots, unlike a one-shot chmod that disappears on restart.

Lesson: dev and prod nodes have history. A directory permission that happens to be
correct on a VM you provisioned recently can be wrong on a physical server that's been
running for months. Always test on prod-equivalent hardware.

---

**Woodpecker health check conflicting with Gitea on node1**

After deploying to prod, the Woodpecker agent kept restarting. Gitea was still running
fine. The agent log showed it was trying to bind a health check endpoint to `:3000` —
the same port Gitea already owned.

Root cause: Woodpecker 3.x changed the default health check address to `:3000`.
On node3 (dev) there's no Gitea, so the port was free. On node1 (prod) Gitea holds it.

Fix: set `WOODPECKER_HEALTHCHECK_ADDR=:3002` in the agent environment file. Port 3002
is unused. The tradeoff is a non-default port that future-me will have to remember
— documented in the template and in this section so it's findable.

---

**Gitea blocking webhook delivery to its own IP**

Woodpecker was deployed and running. Pushed a commit — no pipeline triggered.
The webhook showed as failed in Gitea's delivery log with a network error.

Root cause: Gitea has a security feature that blocks webhook delivery to private IP
ranges by default. This prevents server-side request forgery attacks. The problem:
Woodpecker is running on the same machine as Gitea, so the webhook target is a private
IP on the LAN — exactly what the protection blocks.

Fix: add `ALLOWED_HOST_LIST = {{ ansible_default_ipv4.address }}` to Gitea's `app.ini`
under `[webhook]`. This allowlists only node1's own IP — not the entire private range,
just the one address that needs to receive webhooks. The variable substitution keeps
the IP out of the repo; the actual value is resolved at playbook runtime.

The tradeoff: we're explicitly loosening a security control. The justification is that
we're only allowing the server's own address, not a wildcard, and this is a private LAN
with no external access. On a public-facing server this decision would need more thought.

---

**CI pipeline: four failures stacked on each other**

Getting ansible-lint to run cleanly in the Woodpecker container took four separate
fixes. Each one exposed the next.

*Layer 1 — stale image cache.* The pipeline pulled a cached image from before
ansible-core was added to the Containerfile. Cleared the cache on node1 and added
`pull: true` to the pipeline definition to prevent it recurring.

*Layer 2 — unpinned ansible-core.* Even with the cache cleared, the fresh image failed
with `ModuleNotFoundError: No module named 'ansible.parsing.yaml.constructor'`.
ansible-lint 6.22.2 was released when ansible-core 2.16 was current. Unpinned install
resolved to 2.18, which reorganised internal modules that ansible-lint expected at the
old paths. Fix: pin `ansible-core==2.16.13` in the Containerfile.

*Layer 3 — wrong flag.* The `-c` flag on ansible-lint sets its own config file, which
must be YAML. I was pointing it at `ansible.cfg`, which is INI. Fix: use the
`ANSIBLE_CONFIG` environment variable instead, which ansible-core respects regardless
of directory permissions.

*Layer 4 — vault password missing in CI.* The container had no vault password file, so
ansible-lint's syntax-check couldn't decrypt vault variables. Fix: store the vault
password in Woodpecker's secret store, inject it as an environment variable at runtime,
write it to the expected path before lint runs, delete it after. The password never
touches the repo or the logs.

---

**Postgres container failing with permission denied — host UID vs container UID**

The Immich Postgres container kept failing to start. `podman logs immich_postgres` showed:

```
initdb: error: could not change permissions of directory "/var/lib/postgresql/data"
Permission denied
```

I had created a system user called `immich-postgres` with UID 966 and chowned the data
directory to it. The container disagreed.

Root cause: the official Postgres image runs its process as UID 999 internally. The
container doesn't care about the host user I created — it cares about the UID of
whoever owns the files in the bind mount. The host kernel checks whether the
container's internal UID (999) owns the files. It didn't — UID 966 did.

Diagnosed via: reading the image's Dockerfile in the vectorchord/pgvecto.rs repository
to find the baked-in UID, then comparing it to `ls -lan /srv/immich/postgres/`.

Fix: `chown -R 999:999 /srv/immich/postgres/` on the host, and removed the host user
creation tasks from the role entirely. The host directory owned by UID 999 belongs to
nobody on the host — that's fine. Only the Postgres container should ever touch it.

Key lesson: when a container image has a baked-in UID (Postgres, Redis, and many
official images do), you don't create a host user. You chown the data directory to
the container's internal UID.

---

**SELinux blocking container bind mounts — the :Z flag**

After fixing the UID issue, the Postgres container was still being blocked. AVC denials
in `/var/log/audit/audit.log` showed the container process couldn't write to the data
directory even though ownership was correct.

Root cause: SELinux was checking the file label on the host directory, not just the
owner. The directory had a label that the container process type wasn't allowed to
write. Ownership is a DAC (discretionary access control) check. SELinux is a MAC
(mandatory access control) check. They're independent — you can pass the ownership
check and still fail the SELinux check.

Fix: the `:Z` flag on the volume mount in `docker-compose.yml`:

```yaml
volumes:
  - "{{ immich_postgres_dir }}:/var/lib/postgresql/data:Z"
```

`:Z` tells Podman to relabel the host directory with a private label that only this
container is allowed to access. Podman handles the label automatically.

One catch: `:Z` only works with the short volume notation (a string). If you use the
long YAML dict form (`type`/`source`/`target` keys), Podman silently ignores the flag.
Found this by checking `podman inspect` and seeing no SELinux options applied — the
compose file looked right but the flag wasn't taking effect.

---

**SELinux AVC denials appearing in waves**

Each time I fixed an AVC denial and restarted the affected container, the AVC count
would stabilize — then climb again 60 seconds later when the application reached a
different code path.

The instinct is to declare success after the immediate denial stops. The correct
approach: wait the full minute, then run the count twice with `sleep 30` between,
comparing the two numbers. If they're identical, the policy is stable. If the second
is higher, there's another denial being generated by a less frequently executed path.

This is a general pattern for any iterative SELinux debugging: you're chasing the
application's execution paths, not a single static rule. The AVC log tells you exactly
what was denied — process type, file type, permission class — which is unusually clear
as far as error messages go. Each denial is a one-line addition to the CIL policy.

---

**SELinux label not updating after policy change — restorecon needs -F**

After rewriting the ML container's CIL policy to use a dedicated `immich_ml_cache_t`
type, the model-cache directory still showed the old `container_file_t` label even
after `semanage fcontext` had been updated and `restorecon -Rv` had been run.

Root cause: `restorecon` without `-F` only relabels files that "don't match" the policy.
If the filesystem extended attribute is present — even with the wrong value — restorecon
considers the label "already handled" and skips it.

`restorecon -F` forces a relabel regardless of the existing attribute. After adding `-F`,
the directory showed `immich_ml_cache_t` as expected.

Symptom: `ls -laZ /srv/immich/` showed the old label even after the policy was updated
and `restorecon` had reported it ran successfully. The `-v` flag on restorecon shows
which files it actually changed — when it reports no files changed on a freshly updated
policy, `-F` is usually the fix.

---

**node1 drive failure mid-project — real infrastructure dies on its own schedule**

Partway through building out the self-hosted services, node1 started throwing kernel errors mid-session. `smartctl`
confirmed the culprit: a Toshiba DT01ACA100 with 104 pending and uncorrectable sectors
and swap write errors. It eventually hit a `blk_update_request` kernel panic.

Quick note on the `Seek_Error_Rate FAILING_NOW` flag — on Toshiba drives that's a
known false positive. Their internal units don't map to the standard scale and it reads
as critical when it isn't. The pending sectors, though, are real.

While the drive was still talking, I:

1. Ran `smartctl -a /dev/sda` and `dmesg | grep -i error` to confirm what I was actually dealing with
2. Copied `/etc`, `/home`, `/srv`, and both VM disk images (node3 13GB, node4 4GB) to node2 over SSH before things got worse
3. Booted to a live USB, mounted LVM read-only, confirmed the backup was intact
4. Pushed everything in-progress to GitHub before Gitea — which runs on node1 — went dark

Nothing was lost. The whole point of keeping everything in a git repo and running Ansible
from a separate control node is exactly this — the lab can be rebuilt from scratch on
new hardware with `ansible-playbook`. The backup is insurance; the repo is the recovery procedure.

In the meantime, work continues on node5 (Ubuntu 22.04 VM on node2). The plan is to
extend the existing service roles to support Ubuntu — the `common` role already handles
both OS families, and the service roles are the natural next step. That gets services
running on node5 without waiting for new hardware. The other priority is writing a
recovery playbook: bootstrap a fresh OS, restore `/srv` from the node2 backup,
re-provision the VMs — so the day the replacement drive arrives, the lab comes back up
without any manual steps.

## Security Hardening

Before deploying any public-facing services I ran through CIS benchmarks section by
section and fixed what came up. The changes:

- **Local CA + TLS throughout** — self-signed CA, certs distributed to all nodes,
  Gitea and Woodpecker both behind HTTPS. Login tokens aren't going over plain HTTP anymore.
- **Binary checksum verification** — every `get_url` task now has a pinned SHA256.
  If the download doesn't match, Ansible refuses to install it.
- **Systemd sandboxing** — `NoNewPrivileges`, `PrivateTmp`, `ProtectSystem`, scoped
  `ReadWritePaths` on every service unit. A compromised Gitea or Woodpecker process
  can't read `/home` or write outside its own directories.
- **MariaDB hardened** — anonymous users and test database removed post-install.
- **gitleaks in pre-commit hook** — staged files scanned for secrets before every
  commit. One accidental vault password paste gets caught before it reaches git history.
- **Pinned collection versions** — `requirements.yml` has exact version pins. Fresh
  installs get exactly what was tested, not whatever is latest.
- **Separate SSH keys** — the ansible service account uses a dedicated ed25519 key.
  Rotating automation credentials doesn't affect interactive access and vice versa.

For the containerized services, a second layer of hardening on top of the infrastructure baseline:

- **Custom SELinux policies** — every containerized service has its own CIL or TE policy
  file that defines exactly what it's allowed to do at the kernel level. Jellyfin has two
  types: read/write access to its own data, read-only access to the media library. The
  Immich ML container has a dedicated `immich_ml_cache_t` type scoping its writes to its
  own cache directory only. If a container is compromised, SELinux limits what it can
  actually reach.
- **`cap_drop: ALL` with empirical adds** — all capabilities stripped first, deployed to
  the dev node, observed what the AVC log reported as denied, added back only what the
  audit log proved was needed. Immich dropped `net_raw`, `setfcap`, `setpcap`, `sys_chroot`,
  and `kill` entirely. CIS Benchmark 5.3.
- **`no-new-privileges`** on every container — prevents privilege escalation inside a
  running process. Even if an attacker gains code execution and tries to run a setuid
  binary, the kernel rejects it. CIS Benchmark 5.4.
- **Pinned image digests** — container images referenced by SHA256 digest, not just tag.
  Tags are mutable; a digest pins the exact image layer.

One thing that didn't go as planned: scoping the ansible service account's sudoers
to specific commands. Ansible's pipelining model executes modules via `sudo /bin/sh`,
which makes command-level scoping equivalent to `NOPASSWD: ALL` in practice — you'd
need per-task `become:` throughout every playbook to do it properly. Every sudo
invocation is logged to `/var/log/ansible-sudo.log` on each node instead.
At least I'll know if something weird happens.

**On the vault password file.** `ansible.cfg` sets `vault_password_file = secret.txt`.
That's a plaintext file on the control node, mode 0600, gitignored. If someone gets
to the control node, vault is broken. In this environment the realistic threat is
physical access to the control node — 0600 and gitignore is the call. On a shared or
cloud-hosted control node, pull the password from HashiCorp Vault or SSM at runtime
instead.

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
| Pipeline as code | `.woodpecker.yml` lives in the repo — the pipeline is versioned, reviewed, and changes with the codebase |
| Pinned CI tool versions | ansible-lint and ansible-core both pinned in the Containerfile — the lint environment is reproducible and can't drift |

## Project Structure

```
ansible-sandbox/
├── ci/
│   └── Containerfile.ansible-lint  (pinned ansible-lint image for CI)
├── environments/
│   ├── dev/        # node3, node4 (Rocky 8.9 VMs — disposable)
│   ├── test/       # node2, node5 (Ubuntu 22.04 — intentionally unstable)
│   └── prod/       # node1 (Rocky 8.9 physical — real services)
├── roles/
│   ├── bootstrap/   # service account creation (one-shot, Molecule verified)
│   ├── common/      # hardened baseline — all nodes, both OS families
│   ├── mariadb/     # MariaDB install + database/user provisioning
│   ├── gitea/       # Gitea binary deploy, systemd, SELinux, TLS, vault secrets
│   ├── woodpecker/  # Woodpecker CI server + agent — binary deploy, podman backend
│   ├── pihole/      # Pi-hole v6 DNS sinkhole — capture-and-template pattern
│   ├── jellyfin/    # Jellyfin media server — SELinux TE policy, PKCS12 TLS
│   ├── nextcloud/   # Nextcloud — PHP-FPM, nginx, MariaDB, occ idempotency
│   └── immich/      # Immich photo stack — Podman Compose, CIL policy, hardened
├── playbooks/
│   ├── bootstrap.yml
│   ├── common.yml
│   ├── assert_common.yml
│   ├── deploy_gitea.yml
│   ├── deploy_woodpecker.yml
│   ├── deploy_pihole.yml
│   ├── deploy_jellyfin.yml
│   ├── deploy_nextcloud.yml
│   └── deploy_immich.yml
├── .woodpecker.yml                  (pipeline definition — ansible-lint on push)
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

The lab is still running. node1 is down with a drive failure — see the incident entry
above for the full write-up.

**While node1 is down:**

- **Cross-distro service deployment** — the existing service roles (Pi-hole, Jellyfin,
  Nextcloud, Immich) are Rocky-only right now. Extending them to support Ubuntu means
  the same playbook runs on node5 without changes — package names, firewall, and config
  paths vary by OS family, the role logic doesn't. The `common` role already does this;
  the service roles are the obvious next step. Gets services running on node5 immediately
  and makes every role more useful to anyone cloning the repo.
- **Node1 recovery playbook** — I have the full backup on node2 and every service
  already automated. Writing `recover_node1.yml` that bootstraps a fresh OS, restores
  `/srv` from the backup, and re-provisions the VMs is Ansible doing exactly what Ansible
  is for. The goal is to run it the day the replacement drive arrives and have the lab
  back up without touching anything manually.
- **Local housekeeping** — ansible-lint upgrade from 6.22.2 to 26.4.0 (long deferred),
  and fixing the Immich stack so it survives a reboot. Neither needs a node.

**Once node1 is restored:**

- **Run the recovery playbook** — prove it actually works against real hardware, not
  just in theory.
- **Immich prod deploy** — the role has passed molecule and all local gate checks.
  Final live verification on node3, then it goes to prod.
- **Chaos engineering** — node2's wifi has been dropping since day one and I've been
  treating it as a feature. Time to make that intentional: structured failure injection,
  not just waiting for the wifi to die at a convenient moment.

**Further out:**

- **Terraform + cloud** — once the on-prem foundation is complete this is the natural
  next step. Terraform provisions a cloud VM, Ansible configures it with the same roles
  that run here, dynamic inventory replaces the static hosts file. The patterns don't
  change; the target does.
- **Kubernetes** — k3s on node1's VMs, Ansible-managed, find out where the automation
  model starts to show its limits.
- **Terraform on-prem** — provision local VMs through Terraform, configure through
  Ansible. Full IaC stack from the ground up.

## Certifications

- Red Hat Certified System Administrator (RHCSA)

## Tech Stack

Ansible · Rocky Linux 8.9 · Ubuntu 22.04 · KVM/libvirt · Molecule · Podman · Podman Compose ·
ansible-vault · ansible-lint · MariaDB · Gitea · Woodpecker CI · Pi-hole · Jellyfin · Nextcloud · Immich ·
nginx · PHP-FPM · firewalld · ufw · SELinux (CIL + TE policy authoring) · chrony · Python 3

