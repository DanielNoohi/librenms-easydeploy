# AGENTS.md — LibreNMS EasyDeploy

Guidance for AI agents improving or fixing this repository. Read this before making changes.

**Repo:** https://github.com/DanielNoohi/librenms-easydeploy  
**Stack:** Bash installer + Docker Compose for official LibreNMS Docker images  
**Audience:** labs, homelabs, small single-node deployments — **not** HA / multi-node production

---

## Project reality (read first)

| Claimed / implied | Actual state |
|-------------------|--------------|
| “Production-ready” (GitHub description) | **Overstated.** README correctly says not production-hardened: HTTP only, single node, no backups built-in |
| Full TLS / Let’s Encrypt via `--le-email` | **Not implemented.** Flags exist; stack is HTTP on host `:80` → container `:8000`. TLS = external reverse proxy |
| `--force` = “skip pre-flight checks” (help text) | **Misleading.** `--force` mainly overwrites `.env`; pre-flight (root, docker) still runs |
| UFW rules secure the stack | **Partial.** Docker publishes ports via iptables and **bypasses UFW** — README already documents this |
| Installer always produces a valid `.env` | **BUG — see Critical #1** |
| CI proves full install works | Lint/Bats/compose often green; **E2E HTTP check has been failing** — treat as red until fixed |
| Embedded compose always matches `docker-compose.yml` | **Drift risk** — installer embeds a base64 copy for `curl \| bash` |

**Rule:** Prefer fixing correctness and wiring existing flags over adding new features. Do not claim “production-ready” or “HTTPS configured” unless the code path actually does it. Keep README caveats honest.

---

## Priority order

1. **Correctness bugs** that break install or `.env` / credentials
2. **Make CI green** (especially E2E) and add tests that catch installer bugs
3. **Align docs / flags with reality** (SSL flags, `--force` help text, GitHub description)
4. **Hardening** appropriate for single-node Compose (Redis auth, fewer public ports, etc.)
5. New features only if asked

---

## Known bugs & gaps to fix

### Critical / high

1. **`generate_env()` writes a broken `.env` (showstopper)**  
   - Location: `librenms-auto-install.sh` → `generate_env`  
   - Current code roughly does:
     ```bash
     printf '%s\n' "$ENV_CONTENT_TPL" "${ENV_VALUES[@]}"
     ```
   - That prints the template **with literal `%s`**, then each value on its **own line** (no `KEY=`). Docker Compose will not get `DB_PASSWORD` / `DB_ROOT_PASSWORD` correctly on first install.  
   - **Fix:** format the template with the values, e.g.:
     ```bash
     # shellcheck disable=SC2059  # template intentionally holds %s placeholders
     printf "${ENV_CONTENT_TPL}\n" "${ENV_VALUES[@]}"
     ```
     Or better: avoid `printf` format strings — write `.env` with a quoted here-doc or line-by-line `KEY=value` (safer if values ever contain `%`).  
   - **Test:** Bats (or a unit-style test) must assert generated `.env` contains `DB_PASSWORD=<non-empty>` and **no** literal `TZ=%s`. Prefer testing a extracted function or `--dry-run` + a small refactor so you don’t need root/Docker for this check.  
   - **Note:** CI E2E **writes `.env` by hand** and does **not** exercise the installer — that is why this bug survived.

2. **E2E job fails at “Verify HTTP from host”**  
   - Workflow: `.github/workflows/ci.yml` job `e2e`  
   - Symptoms historically: services start / some healthy, but `curl http://localhost:80` never returns 2xx/3xx within the probe window.  
   - **Fix approach:**  
     - Inspect failed-run logs for `librenms` / `db` (migrations, permission on `./data`, missing env, slow first boot).  
     - Ensure E2E `.env` matches what Compose expects (`DB_*`, `BASE_URL`, etc.).  
     - Consider waiting on `docker compose exec librenms curl -f http://localhost:8000` (in-container) before host curl.  
     - Keep job under timeout; don’t paper over flakes with huge sleeps only — fix root cause.  
   - Optionally add a second E2E (or extend existing) that runs `./librenms-auto-install.sh -n -u http://localhost --no-ssl --no-firewall` so the **installer** is covered.

3. **Embedded compose vs `docker-compose.yml` drift**  
   - `EMBEDDED_COMPOSE_B64` in the installer must match `docker-compose.yml`.  
   - **Fix:** CI check that fails if `base64 -d` of embedded blob ≠ file contents (normalize newlines). Document update procedure in a short comment above `EMBEDDED_COMPOSE_B64`, or generate the blob in CI/release instead of hand-editing.

### Medium

4. **SSL / `--le-email` are stubs**  
   - Either implement a documented optional path (e.g. emit Caddy/Traefik snippet, or clearly refuse with “use reverse proxy”) **or** remove/hide the flags until implemented.  
   - Do not leave flags that imply Let’s Encrypt works.

5. **Help text for `--force`**  
   - Update to: overwrite `.env` / regenerate credentials (with backup), not “skip pre-flight checks” — unless you actually implement skip behavior.

6. **GitHub repo description vs README**  
   - Soften “Production-ready” to match caveats (e.g. “Easy Docker Compose deploy for LibreNMS (lab/homelab)”).

7. **MariaDB healthcheck embeds password on CLI**  
   - `mysqladmin ... -p${DB_ROOT_PASSWORD}` can leak via process list. Prefer `MYSQL_PWD` env on the healthcheck command (as the installer wait loop already does) or a dedicated health user — within Compose constraints.

8. **Redis has no auth**  
   - Acceptable on internal bridge for labs; for hardening, add `requirepass` + wire LibreNMS Redis password env if the official image supports it. Don’t invent unsupported env vars — check [librenms/docker](https://github.com/librenms/docker) docs first.

9. **UFW allows `161/udp` inbound**  
   - SNMP polling is usually **outbound** from this host. Inbound 161 is often unnecessary; traps are 162. Revisit whether 161 allow is needed; keep README accurate.

10. **`curl | sudo bash` install path**  
    - Keep for convenience but ensure embedded compose + script stay in sync (see #3). Prefer documenting `git clone` / wget then run as the safer primary path.

### Low / polish

11. Floating tags `redis:7-alpine`, `memcached:1.6-alpine`, `mariadb:10.11` — consider digest or minor pins when touching compose.  
12. Bats coverage is **args-only** — extend after fixing `generate_env`.  
13. No release tags — optional; not required for bugfix batch.

---

## Architecture map (what to touch)

```
librenms-easydeploy/
├── librenms-auto-install.sh   # main installer (CLI, .env, UFW, compose up, admin user)
├── docker-compose.yml         # services: librenms, dispatcher, syslogng, snmptrapd, db, memcached, redis
├── .env.example               # placeholders only (changeme) — never real secrets
├── test/test_args.bats        # CLI argument / dry-run tests
├── .github/workflows/ci.yml   # lint, bats, compose validate, secret-scan, e2e
├── README.md                  # user docs + caveats (keep honest)
└── LICENSE                    # GPL-3.0
```

**Runtime layout after install (default `/opt/librenms-easydeploy`):**
- `.env` (chmod 600), `docker-compose.yml`
- `data/{librenms,db,redis}`, `logs/librenms`, `config/librenms`, `rrd`

**Patterns already in use (follow them):**
- `set -euo pipefail`, ERR trap with line number
- Passwords via `python3` + `secrets` (not `/dev/urandom` ad-hoc); never pass secrets on argv in installer wait loops where avoidable (`MYSQL_PWD`)
- Idempotent reruns: `load_env` reuses existing DB/admin secrets unless `--force`
- Official LibreNMS Docker sidecars via `SIDECAR_DISPATCHER=1`, `SIDECAR_SYSLOGNG=1`, `SIDECAR_SNMPTRAPD=1` (separate containers — do not collapse into one)
- Healthchecks + `depends_on: condition: service_healthy` for db/redis/memcached
- No `shell=True`-style unsanitized eval of `.env` — `load_env` allowlists keys (keep it that way)

---

## Suggested fix batches

### Batch A — Correctness (do first)
- Fix `generate_env()` / `.env` writing
- Add Bats (or script unit test) proving `.env` shape
- Add CI check: embedded compose ↔ `docker-compose.yml`
- Fix or triage E2E HTTP failure; make `e2e` green
- Optional: E2E path that runs the real installer script

### Batch B — Truth in flags & docs
- Align `--force` / SSL / `--le-email` help + README
- Soften GitHub description “Production-ready”
- Confirm firewall port rationale (161 vs 162/514/80)

### Batch C — Hardening (only after A)
- Redis auth if supported
- Safer DB healthcheck secrets
- Document reverse-proxy HTTPS as the supported TLS path (snippet OK)

---

## Testing expectations

- Keep existing Bats green: `bats test/`
- `shellcheck librenms-auto-install.sh`
- `shfmt -d -i 2 librenms-auto-install.sh`
- `docker compose -f docker-compose.yml config`
- After Batch A: new test must fail on the old `printf '%s\n' "$ENV_CONTENT_TPL" ...` bug
- Do not require a full LibreNMS UI login flow in unit tests; E2E may assert HTTP 200/302 from host or in-container

**Manual check after installer fix:**
```bash
# dry-run
sudo ./librenms-auto-install.sh --dry-run -n -u http://librenms.example.com

# real (lab VM): inspect .env immediately after generate, before assuming UI works
sudo ./librenms-auto-install.sh -n -u http://127.0.0.1 --no-ssl --no-firewall -s /tmp/lnms-creds.txt
grep -E '^(TZ|DB_PASSWORD|DB_ROOT_PASSWORD|ADMIN_PASS)=' /opt/librenms-easydeploy/.env
# values must be real strings, not %s; keys must be present
```

---

## Security / product constraints

- Authorized / owned networks only; this is a monitoring deploy helper, not a scanner/exploit toolkit
- No hardcoded real passwords in git; `.env.example` stays `changeme`
- Do not weaken `chmod 600` on `.env` / creds files
- Do not enable wide-open management ports beyond what LibreNMS needs
- Prefer stdlib + Docker + existing tools; avoid new heavy dependencies
- License is GPL-3.0 — keep LICENSE and README aligned

---

## Do / Don’t

**Do**
- Fix one coherent batch at a time
- Match existing bash style (2-space indent per shfmt `-i 2`, `info`/`warn`/`die`, long flags)
- Update README when behavior or flags change
- Regenerate / sync `EMBEDDED_COMPOSE_B64` whenever `docker-compose.yml` changes
- Add tests for any bug you fix

**Don’t**
- Claim HTTPS or production-hardening without implementing it
- Eval arbitrary `.env` content
- Commit `.env`, credential files, `data/`, or live DB dumps
- Expand into Kubernetes/HA rewrites unless explicitly asked
- “Fix” E2E by deleting the job — fix the stack or the wait conditions

---

## Quick verification checklist

- [ ] `generate_env` / first-install `.env` has real `KEY=value` lines (no `%s`)
- [ ] `bats test/` passes locally
- [ ] `shellcheck` + `shfmt -d -i 2` clean
- [ ] Embedded compose matches `docker-compose.yml`
- [ ] CI E2E: HTTP check green
- [ ] README caveats still accurate (HTTP-only, not prod-hardened)
- [ ] `--help` text matches real flag behavior

---

## Kickoff prompt (paste to an agent)

```
Read AGENTS.md in this repo, then execute Batch A only:
1) Fix generate_env() so .env is valid KEY=value (no literal %s).
2) Add a test that would have caught the bug.
3) Add CI drift check for EMBEDDED_COMPOSE_B64 vs docker-compose.yml;
   regenerate the blob if needed so they match.
4) Investigate and fix the failing E2E “Verify HTTP from host” job.
Do not implement TLS or new features. Keep README honest.
```
