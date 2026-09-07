# Tailnet Telemetry Implementation Plan

Status: **Planned. Implementation and deployment have not started.**

Decision date: 2026-09-06.

This document records the agreed design. It does not authorize deployment,
credential provisioning, permission escalation, hardware changes, or tailnet
policy changes. Implement the stages below when explicitly requested, in
separate coherent, verified commits.

## Goal

Collect resource metrics and user-visible security context from the user's
macOS and Linux computers. Store the data in PostgreSQL on `jmws`, make it
available through SQL, and provide a private Grafana dashboard.

`jmws` is the explicitly designated telemetry server, not a dynamically elected
leader. This is a single-server design, without automatic failover. A server
outage makes dashboards unavailable and delays ingestion according to each
collector's documented buffering limits.

## Architecture

```text
Each participating computer, including jmws
  Existing Home Manager user context
    Telegraf: resource metrics
    Rust collector: inventory and change observations
      Local SQLite outbox for pending inventory batches
                 |
         Batched writes over Tailscale
                 v
jmws: system-managed services
  Dedicated PostgreSQL instance with TimescaleDB
    Hypertables: numeric metrics
    Ordinary tables: inventory, collection status, change events
                 ^
  Grafana: read-only telemetry database access
    Private HTTPS and its own authentication
```

- Use native Nix-managed services, not Docker.
- Run collectors under the existing Home Manager account, deriving the username
  and home directory from configuration. Do not hardcode an account name or
  create a dedicated collector OS account.
- System services on `jmws` still use their normal service accounts. Collector
  OS identity and database authentication are separate concerns.
- Keep OMP Phone separate and unchanged. Grafana does not inherit its YubiKey
  authentication. The Kanidm SSO plan remains shelved.
- Do not add a broker, custom ingestion/web service, automatic leader election,
  database failover, or privileged surveillance agent.

## Existing Repository Integration

- `nixos/hosts/jmws.nix` defines the designated NixOS server, exposed through
  `nixosConfigurations.jmws` in `flake.nix`.
- `home/common.nix` imports shared Home Manager modules.
- `home/postgresql.nix` already manages a personal PostgreSQL 17 instance. It
  accepts connections through a private Unix socket, not TCP, and sets personal
  `PGHOST`, `PGPORT`, `PGUSER`, and `PGDATABASE` defaults.
- Leave that personal instance, its data, and its connection defaults untouched.
  Add a separate system-owned metrics instance with distinct data and socket
  directories. Always supply explicit telemetry connection settings rather
  than inheriting the personal PostgreSQL environment.
- Add one shared collector module, one `jmws`-only server module, a small Rust
  collector package, versioned database migrations, and a provisioned Grafana
  datasource/dashboard. Keep implementation and configuration in this repo.

## Collection Scope

| Category | Initial collection |
| --- | --- |
| Resource metrics | Total CPU utilization and load, memory, swap, filesystem capacity, disk and network counters, uptime, and collector health. |
| Login sessions | Logged-in accounts, session start times, and local/remote classification where observable. |
| SSH activity | Established SSH connections and associated users/processes where visible; authentication failures only where accessible logs support them. Do not assume every SSH connection uses port 22. |
| Processes | Executable name/path, owner, parent PID, start time, and resource usage. |
| Network state | Interface and Tailscale addresses, default routes, listening sockets, and established connections where permitted. |
| Wi-Fi and location | SSID/BSSID when accessible, plus configured labels such as home or office derived from known networks. Record the basis for an inferred label and allow an unknown location. |
| Persistence | Changes to accessible launch agents, user services, scheduled jobs, and SSH authorized-key fingerprints. Store metadata or fingerprints, not file contents. |

Collection boundaries:

- **Full CLI invocations, command-line arguments, and environment variables are
  deferred.** Revisit only through a separate explicit opt-in design covering
  secret redaction, access controls, and shorter retention.
- Do not collect private keys, arbitrary file contents, or general application
  logs. Accessible SSH authentication observations are the narrow exception to
  the initial exclusion of log collection.
- Do not enable precise location tracking, external IP geolocation, or automatic
  permission escalation. Interface addresses are not necessarily the public
  egress address; do not silently add an external IP-discovery service.
- macOS may restrict Wi-Fi data behind location permissions. Record missing
  access rather than granting permissions automatically.
- Every category distinguishes observed data, unavailable capability,
  permission denial, and collection failure. Empty results must not stand in
  for failed or unauthorized collection.
- User-level visibility is incomplete. Periodic snapshots can miss short-lived
  processes and connections. This is situational awareness, not a forensic
  audit log or a claim that a machine is free of compromise.
- Unfamiliar processes or new listeners are observations to investigate, not
  automatic declarations of spying or compromise.

## Initial Data and Retention Policy

- Collect resource metrics every **30 seconds**.
- Collect inventory approximately every **60 seconds**.
- Preserve original collection timestamps and distinguish them from receipt
  times when displaying delayed data or last-seen status.
- Retain numeric metrics for **30 days** and detailed inventory/change
  observations for **7 days**.
- Keep process lists, connection inventories, and security events out of metric
  labels. Store them in ordinary PostgreSQL tables rather than creating large
  numbers of time series.
- Start without compression, rollups, or a general log pipeline. Measure actual
  volume on two computers before expanding the fleet.
- A sleeping computer produces no samples. Do not synthesize observations for
  the time it was asleep or collection was unavailable.

## Implementation Stages

### 1. Establish Collection and Delivery Contracts

Run small capability probes on this Mac and `jmws`, under their existing user
accounts, covering every category in the collection scope.

Record actual support and permissions per platform. Define the observation
schema and explicit unavailable/permission-denied/error states before choosing
platform adapters. Do not silently omit categories that cannot be observed.

Resolve the metrics delivery question early. Upstream Telegraf currently marks
its disk-backed output buffer as experimental. Test the repository-pinned
release for:

- Network or database disconnection and recovery.
- Collector restart with queued samples.
- Database restart and uncertain write outcomes.
- Storage exhaustion, queue limits, and visible dropped-data reporting.
- Preservation of original timestamps and replay behavior.

Do not assume the memory buffer's size limit also bounds disk storage. Establish
and verify an actual storage bound and overflow policy. Do not promise lossless
or exactly-once metric delivery based on configuration alone.

If the tested disk buffer cannot meet the agreed contract, return with explicit
alternatives and tradeoffs. **Do not silently substitute memory-only buffering.**
A memory-only mode would require acceptance of gaps across collector restarts
and sufficiently long outages.

Acceptance: a concrete capability report and a demonstrated, bounded delivery
contract for the pinned collector version, with limitations stated explicitly.

### 2. Add the Central Database on jmws

Create the NixOS telemetry-server module using a supported, pinned
PostgreSQL/TimescaleDB pairing.

- Provision the separate system-owned metrics instance and a `metrics` database.
- Create a small fixed set of hypertables for numeric measurements.
- Create ordinary tables for sources, inventory snapshots, observation status,
  and change events.
- Apply explicit, versioned schema migrations and retention policies.
- Keep schema authority on the server; collectors must not create or alter
  tables.
- Leave the existing personal PostgreSQL instance untouched.

Acceptance: the schema and retention policies work in an isolated database;
service startup does not depend on an interactive login, and personal
PostgreSQL remains separate.

### 3. Define Identity, Credentials, and Network Access

- Give each collector installation a stable source identity and restricted
  database credentials. Distinguish separate user-context collectors on the
  same computer rather than merging their observations accidentally.
- Associate source identity with authenticated credentials on the server. A
  supplied hostname or source label is not authorization.
- Give each collector only the rights needed to ingest its permitted data,
  without schema administration or access to other sources' private inventory.
- Give Grafana read-only access to telemetry data.
- Listen for remote database connections only on the intended tailnet address;
  restrict access with both Tailscale policy and the host firewall.
- Keep credentials in private runtime files, outside Git and the Nix store.
- Set telemetry connection parameters explicitly; never implicitly reuse the
  personal PostgreSQL superuser or inherited `PG*` defaults.

Acceptance: permitted ingestion succeeds, unauthorized writes fail, and a
collector cannot impersonate another source by changing a payload label.

### 4. Add Standard Metrics Collection

Create the shared Home Manager Telegraf module with launchd and systemd-user
integration. Collect the resource measurements listed above every 30 seconds.

- Configure the buffer and overflow behavior established in stage 1.
- Preserve sample timestamps during delayed delivery.
- Expose collector health, delivery failures, and dropped-data observations.
- Keep tags bounded and omit detailed process inventories from metric labels.
- Disable automatic schema creation or alteration; migrations own the tables.

Acceptance: the same declarative module produces correctly attributed metrics
on macOS and Linux, without requiring a dedicated OS account or elevated
collector privileges.

### 5. Add the User-Scoped Inventory Collector

Implement a small Rust program with macOS and Linux adapters, using the agreed
observation schema.

- Collect the requested inventory approximately every 60 seconds.
- Submit structured snapshots and change observations.
- Preserve capability and permission status alongside the data.
- Maintain a bounded local SQLite outbox for pending inventory batches.
- Persist each batch and its stable ID before attempting remote delivery.
- Commit each batch atomically at the destination and deduplicate retried batch
  IDs, including retries after an uncertain database commit.
- Define and expose outbox overflow behavior; do not let it fill the user's disk
  silently or claim unlimited offline retention.
- Collect only the allowed executable metadata. Exclude full invocations,
  arguments, environments, private keys, and configuration contents.
- Derive optional location labels from explicitly configured network mappings,
  retaining an unknown state when the evidence is absent or ambiguous.

Acceptance: realistic macOS/Linux observations are stored, permission failures
are visible, queued batches survive restart within the documented limits, and
uncertain retries do not duplicate inventory batches.

### 6. Provision One Grafana Dashboard

Keep datasource and dashboard provisioning in Git. Include:

- Fleet overview, machine/source selector, and last-seen information.
- CPU, memory, disk, and network history.
- Current login sessions, SSH observations, processes, and connections.
- Wi-Fi and configured location labels.
- Recent persistence changes.
- Prominent visibility gaps, collection errors, and stale-data indications.

Distinguish current observations from delayed historical uploads. Handle
counter resets and missing samples correctly in metric queries.

Expose Grafana through private HTTPS with its own authentication and no
anonymous access. Do not implicitly extend OMP authentication or resume Kanidm.

Acceptance: verify the actual dashboard in a browser, including phone-sized
layout, authenticated access, stale data, and unavailable observations. A lack
of observations must not be presented as proof that the computer is safe.

### 7. Verify, Back Up, and Roll Out

Start with `jmws` and this Mac before enabling other computers.

Verify the integrated result:

- Both platforms produce correctly attributed observations.
- Permission failures and unsupported capabilities remain visible.
- Network disconnections, collector restarts, and database restarts follow the
  documented buffering contract.
- Retried inventory batches are not duplicated.
- Unauthorized writes and cross-source identity spoofing are rejected.
- Retention policies remove expired data as intended.
- No deferred command-line arguments or environment data are collected.
- A database backup can be restored successfully.
- The private dashboard accurately shows healthy, stale, and partial data.

Choose an **off-host backup destination** before calling deployment complete.
A second directory or NAS share hosted by `jmws` is not an off-host backup.
Protect backups as sensitive telemetry. Manage backup jobs and database
upgrades as system operations, not processes dependent on an interactive user
session.

Run focused behavioral checks first, then the repository's standard checks.
Remove temporary probes and profiling/verification artifacts after use. Commit
only related changes, preserving unrelated repository work.

Acceptance: two-host operation, outage behavior, access boundaries, retention,
and restore are demonstrated; the configuration is ready for deliberate rollout
to the remaining computers.

## Explicitly Deferred or Excluded

- Full CLI invocations, command-line arguments, and environment capture.
- Precise location tracking and external geolocation lookups.
- General application log collection and distributed tracing.
- Privileged auditing, automatic permission grants, and guaranteed detection of
  spying or compromise.
- Remote administrative actions or a general-purpose web shell.
- Automatic leader election, database replication, and failover.
- A custom ingestion/web application or message broker.
- Changes to OMP Phone authentication or the shelved Kanidm SSO project.

## References

- [Telegraf PostgreSQL output and TimescaleDB integration](https://github.com/influxdata/telegraf/tree/master/plugins/outputs/postgresql)
- [Telegraf configuration and buffer settings](https://github.com/influxdata/telegraf/blob/master/docs/CONFIGURATION.md#agent)
- [TimescaleDB](https://github.com/timescale/timescaledb)
- [PostgreSQL row security](https://www.postgresql.org/docs/current/ddl-rowsecurity.html)
- [Grafana provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/)
