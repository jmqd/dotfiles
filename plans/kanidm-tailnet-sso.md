# Kanidm Tailnet SSO Plan

Status: **Shelved. Do not implement or deploy until explicitly resumed.**

Decision date: 2026-09-06.
Selected identity provider: **Kanidm**, not Pocket ID or authentik.

## Goal

Enroll three YubiKeys once with a central identity provider and use any of them
interchangeably to sign in to OMP and other OIDC-enabled services over the tailnet.
Replace OMP's manually handled machine-token pairing with browser SSO. Keep device
inventory and deployment configuration in this repository.

This plan authorizes no service deployment, hardware provisioning, credential
registration, tailnet changes, or removal of the current OMP authentication.

## Current State

- `home/yubikeys.nix` records one verified device: `yubikey-36766394`, a YubiKey 5C
  NFC. Service-specific WebAuthn records are now managed under its inventory entry.
- The other two devices have not been inventoried or enrolled in this work.
- `projects/omp-phone` contains the Rust companion, browser UI, and OMP extension.
  The interim implementation uses service-specific WebAuthn enrollment and login,
  with browser sessions invalidated on restart. Machine-token pairing is removed.
  Kanidm remains shelved; its different relying-party identity will require fresh
  enrollment rather than reuse of the OMP credential.
- `projects/omp-phone/home-module.nix` manages the companion's deployment.
  `home/hosts/jmq-macos.nix` sets its public URL to
  `https://jordans-macbook-pro-1.taild6d9b.ts.net/omp/`.
- HTTPS-mode OMP requests require the permitted Tailscale login and application
  capability. The companion also checks host/origin and rejects Funnel requests.

## Architecture and Decisions

- Host Kanidm on an always-on tailnet machine, preferably a declaratively managed
  NixOS host. The actual machine and final hostname remain undecided.
- Give Kanidm a stable, dedicated HTTPS hostname. Its WebAuthn relying-party
  identity and OIDC issuer must not depend on a laptop's changing hostname.
- Expose it privately through Tailscale Serve, never Funnel. Verify Kanidm's
  supported reverse-proxy and upstream TLS configuration before choosing the
  exact proxy setup; do not assume plaintext upstream support.
- Both browsers and application backends must be able to reach the issuer. Keep
  Tailscale's own sign-in independent of this private-only provider to avoid a
  circular dependency.
- Enroll one distinct WebAuthn credential per physical YubiKey on the same Kanidm
  account. No cloning or sharing private keys between devices. All three enrolled
  keys should be interchangeable for that account.
- OMP becomes an OIDC relying party. It does not implement its own WebAuthn
  enrollment or maintain a second hardware-key allowlist. Other applications
  integrate with Kanidm once, rather than enrolling each YubiKey separately.
- Preserve OMP's tailnet authorization, host/origin protections, and Funnel
  rejection. SSO complements those boundaries rather than replacing them.
- Remove manual pairing tokens, not cryptographic randomness or browser sessions.
  OIDC transactions and authenticated sessions still require protected state.

## Inventory and Credential Authority

The desired policy is that the repository identifies the approved hardware and
credentials, without a separately maintained per-application key list. A serial
number cannot authenticate a device; credentials require an actual enrollment
ceremony. Browser enrollment also does not prove the inventory serial: associate
and label each credential while handling the intended physical key.

Before promising Git-authoritative credential management, verify Kanidm's supported
provisioning, public-credential export/import, and revocation interfaces for the
pinned version. Configuration provisioning does not imply credential provisioning.

- Keep hardware names, serials, and supported public credential references or
  exports in the inventory. Never commit PINs, private keys, recovery material,
  client secrets, session data, or database backups.
- Keep Kanidm's operational database, mutable credential state, signing secrets,
  and audit records outside Git and the Nix store, with protected backups.
- If supported, reconcile the declared credential trust set through Kanidm's
  documented interfaces. Define how additions, removals, and existing sessions
  are handled; deleting a Nix entry alone must not be described as revocation.
- If Kanidm cannot support the desired credential authority, stop for an explicit
  decision: provider-managed enrollment with a repo inventory, or another supported
  design. Do not silently abandon the requirement or manipulate database internals.

## Implementation Sequence When Resumed

### 1. Resolve deployment and provisioning prerequisites

Select the host and stable HTTPS identity. Verify the supported NixOS module,
Kanidm release, reverse-proxy/TLS arrangement, hardware-authentication policy, and
credential-management interfaces. Pin executable dependencies through the repo's
existing Nix conventions. Resolve the inventory-authority question above before
building synchronization tooling.

### 2. Deploy and establish recovery

Declare Kanidm's service, storage, network restrictions, and supported account,
group, and OIDC-client configuration. Inject secrets from private runtime storage.
Complete initial administration locally or through a deliberately restricted setup
path. Define and exercise protected backup/restore and an explicit administrative
recovery procedure. Do not enable public signup or routine email/password bypasses
of the intended hardware login policy.

### 3. Inventory and enroll all three YubiKeys

Inspect and name the remaining devices without resetting or overwriting existing
applications. Perform each WebAuthn enrollment with the user present, requiring
user verification and physical-key approval according to Kanidm's supported policy.
Keep PIN entry in the browser/OS prompt, never chat or command arguments. Verify
each key independently before putting backup keys into separate safe storage.
Record the supported public metadata and physical-device association.

### 4. Integrate OMP using OIDC

Use a maintained Rust OIDC implementation and authorization-code flow with PKCE.
Register an exact callback URL under `/omp/`. Bind short-lived, single-use login
transactions to the initiating browser using state and nonce; verify issuer,
audience, signature, expiry, and the authorized account on the trusted server.
Identify the account by issuer and subject, not an unverified email claim.

Add the browser sign-in redirect and server callback, then establish an HttpOnly,
Secure, SameSite-protected session scoped to `/omp/`. Define session expiry,
restart, logout, and revocation behavior explicitly, including existing SSE
connections and the distinction between OMP logout and provider-wide logout.
Preserve session controls, prompts, aborts, and push-notification behavior. Provider
failure must deny new authentication rather than fall back to per-service login.

### 5. Perform a clean authentication cutover

Only after the complete OIDC path works, remove the interim per-service WebAuthn
enrollment/login routes, CLI enrollment command, browser ceremony UI, and obsolete
helpers. Update extension messages, configuration, tests, and README instructions
together. Invalidate old browser sessions and retire per-service credentials and
runtime state through an explicit migration; do not retain a parallel login path.

The primary affected files are under `projects/omp-phone/src/`, `web/`, and
`extension/`, plus its Home Manager module and the host-specific configuration.

## Acceptance and Verification

- Each of the three physical YubiKeys can sign in to the same Kanidm account.
- A second OIDC application works with those same enrollments; it requires no new
  service-specific YubiKey credential.
- An unknown key, wrong account, incorrect origin/issuer/audience, expired or
  replayed transaction, and altered callback are rejected.
- Actual desktop and phone browsers complete hardware login over the tailnet,
  including supported NFC/USB interaction, cancellation, and retry after failure.
- OMP sessions, streaming updates, prompts, aborts, logout, and notifications work
  after the cutover. Tailnet restrictions and Funnel rejection still apply.
- Provider outages fail closed. Credential revocation and the chosen existing-
  session policy are demonstrated, and backup/restore recovery is exercised.
- No routine pairing command or manually copied machine token remains. No secrets
  enter Git, the Nix store, URLs intended for sharing, or logs.
- Keep focused security regression tests for meaningful failure cases; run the
  actual hardware/browser flow and the repository's standard checks before deploy.

## Out of Scope

Migrating SSH, Git signing, OpenPGP, PIV, or Tailscale's own identity provider is
not part of this plan. Those uses may share the hardware inventory, but they have
distinct credentials and integration requirements. No custom OIDC provider or
cross-domain browser signing protocol will be built.

## References

- [Kanidm administration](https://kanidm.github.io/kanidm/master/)
- [Kanidm supported features, including OIDC and WebAuthn](https://kanidm.github.io/kanidm/master/supported_features.html)
- [Tailscale Serve](https://tailscale.com/docs/reference/tailscale-cli/serve)
- [Yubico WebAuthn overview](https://developers.yubico.com/WebAuthn/)
