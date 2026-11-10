# High-Level Security Rules

Rules for the security of services: authentication, sessions, authorization, tokens, cryptography and TLS use, input handling, browser-facing behavior, API design, service networking, cloud, credentials, supply chain and logging. Each rule cites its source. Parameters such as iteration counts, key sizes and timeouts are what the sources recommend today; re-check them before you rely on them. Statistics are dated and come from the authors' own data.

Companion to [low-level-security-rules.md](low-level-security-rules.md), which covers memory safety, undefined behavior, `unsafe` code, hardening flags and constant-time code.

## How to use this file

- **Rule IDs are stable.** Cite a rule as `AUTHZ-4` or `TOKEN-13` in reviews, findings and commit messages. When you add a rule, append it to its section with the next number. Never renumber existing rules. Family names differ from those in the other rule files in this directory, so an ID identifies its file.
- **Families:**
  - `DESIGN`: security design principles
  - `AUTHN`: authentication, passwords, multi-factor and recovery
  - `SESSION`: sessions and session cookies
  - `AUTHZ`: authorization and access control
  - `TOKEN`: OAuth, JWT, API keys and other tokens
  - `CRYPTO`: choice of primitives, password hashing and key handling
  - `TLS`: transport security and certificates
  - `INPUT`: injection, validation, deserialization, file handling and server-side requests
  - `WEB`: browser-facing headers, cross-site request forgery and cross-origin rules
  - `SERVICE`: API and service behavior, limits, errors and inventory
  - `NET`: network trust, service identity and segmentation
  - `CLOUD`: cloud accounts, storage, metadata, containers and Kubernetes
  - `CRED`: secrets, keys and credential lifecycle
  - `SUPPLY`: source, build, dependencies and deployment
  - `LOG`: logging, detection, incident response and disclosure
- **Order of work.** `DESIGN` applies to everything. For a review, start where untrusted requests enter (`AUTHN`, `AUTHZ`, `INPUT`), then follow credentials (`TOKEN`, `CRED`), then the platform (`NET`, `CLOUD`, `SUPPLY`), then what you could see after a breach (`LOG`).
- **Vendor terms.** Some rules name an AWS, Google or Kubernetes mechanism as an example. The rule is the general statement; the mechanism shows one way to meet it.

## Sources

### Primary

| Source | Author | Why it matters |
|---|---|---|
| "The Protection of Information in Computer Systems" (1975) [1] and *Building Secure and Reliable Systems* (2020) [2] | Saltzer and Schroeder; Google | The classic design principles, and how a large operator applies them to access, deployment and recovery. |
| ASVS 5.0.0 [3], the Cheat Sheet Series [4], API Security Top 10 (2023) [5], Top 10:2025 [6] | OWASP | ASVS gives numbered, testable requirements. The cheat sheets give parameters and named pitfalls. The two lists rank what fails most. |
| SP 800-63B-4, Digital Identity Guidelines (July 2025) [8] | NIST | Normative rules for passwords, multi-factor authentication, recovery and session lifetime. |
| RFC 9700 (OAuth 2.0 security) [9] and RFC 8725 (JWT) [10] | IETF | Each recommendation is paired with the attack it stops. |
| RFC 9325 (TLS) [11], TLSRef Server-Side TLS 6.0 [12], "Cryptographic Right Answers" [13, 14] | IETF; TLSRef; Latacora | Concrete choices of protocol versions, cipher suites and primitives. |
| SP 800-207 (Zero Trust) [15], BeyondProd [16], Google infrastructure security design overview [17] | NIST; Google | The zero-trust tenets and a worked design for service identity. |
| AWS Well-Architected Security Pillar (November 2024) [20] and the NSA/CISA cloud information sheets (2024) [21] | AWS; NSA and CISA | Cloud identity, storage, network and logging practice, with stated anti-patterns. |
| CSRB review of the 2023 Microsoft Exchange Online intrusion [28] and CISA Secure by Design alerts [29] | Cyber Safety Review Board; CISA | What failed in a real identity-system breach, and how to remove whole classes of defect. |

### Additional (best hits only)

| Source | Author | Focus |
|---|---|---|
| CWE Top 25 (2025) [7] | MITRE | Ranking data for cross-site request forgery, path traversal and deserialization. |
| SP 800-204 [18] and Zanzibar [19] | NIST; Google | Microservice security strategies; a consistent, central authorization system. |
| Kubernetes Security Checklist [22] and NSA/CISA Kubernetes Hardening Guide 1.2 [23] | Kubernetes project; NSA and CISA | Cluster hardening. The guide is from 2022 and partly dated. |
| MDN practical security guides [24] and Mozilla web security guidelines [25] | Mozilla | Exact header and cookie values. Where they differ, the newer MDN guides win. |
| SLSA 1.2 [26] and SP 800-218 (SSDF) [27] | OpenSSF; NIST | Build provenance and secure development practices. |
| *Security Engineering*, 3rd edition [30] | Ross Anderson | Protocol, naming and incentive lessons. |

---

## 0. Design principles

### Mechanism

1. **DESIGN-1** **Keep security mechanisms small and simple.** "Keep the design as simple and small as possible." Flaws that open unwanted access paths do not show in normal use, so only inspection finds them [1].
2. **DESIGN-2** **Do not depend on the design being secret.** "The mechanisms should not depend on the ignorance of potential attackers, but rather on the possession of specific, more easily protected, keys or passwords" [1].
3. **DESIGN-3** **Layer defenses so that each layer assumes the one before it fails.** "Defense in depth is like N+1 redundancy for your defenses" [2 ch. 8].
4. **DESIGN-4** **Security-critical checks fail closed.** "Security-critical operations should not fail open. Failing open could permit an attacker to degrade the security of a system by using DoS attacks alone" [2 ch. 8]. When a transaction fails part-way, "roll back every part of the transaction and start again" [6 A10].
5. **DESIGN-5** **Make the secure state the default and the easy path.** "Services must be secure by default and insecure only after an explicit decision is made to accept the risks" [16]. "The easiest way to use your system had better be the safest" [30 §3.3.3]. Ship secure default settings and document each security-relevant one [27 PW.9].
6. **DESIGN-6** **Put cross-cutting controls in a shared framework or choke point, not in each handler.** A framework can ensure "authentication, authorization, and logging for every RPC method according to a policy that's defined centrally" [2 ch. 6]. "Choke points allow for policies to be consistently enforced across services" [16].
7. **DESIGN-7** **Remove defect classes by design, and enforce the safe path with tooling.** Give developers safe building blocks "to ensure that a single developer error does not compromise the data of millions of users" [29 Directory Traversal]. Prefer compile-time rejection of risky APIs: "compiler errors provide immediate and actionable feedback" [2 ch. 12].
8. **DESIGN-8** **Keep the trusted computing base small, and minimize what tenants share.** Exclude "any components that aren't actually involved in upholding the security policy" [2 ch. 6]. Every shared mechanism "represents a potential information path between users" [1].
9. **DESIGN-9** **Design so that one stolen secret cannot unlock everything.** Identity systems should be built "in such a way that substantially reduces the risk of complete system-level compromise" [28 Rec. 6]. In the 2023 intrusion, one consumer signing key gave access to enterprise mailboxes.

### Attackers and assumptions

10. **DESIGN-10** **Assume the attacker is already a legitimate user or an insider.** "You must assume that the attackers are already legitimate users, and see to it that no-one can use the service at someone else's expense" [30 §3.4.7]. "Any permissions or privileges you assign to your insiders become available to an attacker" [2 ch. 2].
11. **DESIGN-11** **Size each control against what the attacker can spend.** "Compare the cost of circumventing the mechanism with the resources of a potential attacker" [1]. A control that stops a person typing may be no barrier to automation.
12. **DESIGN-12** **Threat-model early and keep the model current.** "An insecure design cannot be fixed by a perfect implementation" [6 A06]. Keep "an up-to-date register of potential threats and associated mitigations" [20 SEC01-BP07]. List the assets an attacker can obtain, such as a signup, as well as those you protect [30 §27.3.5].
13. **DESIGN-13** **Re-check assumptions when the environment changes.** "A common cause of protocol failure is that the environment changes, so that the design assumptions no longer hold and the security protocols cannot cope with the new threats" [30 §4.5].
14. **DESIGN-14** **Align incentives with outcomes.** "If the people who guard a system are not the people who suffer when it fails, then you can expect trouble" [30 §8.1].
15. **DESIGN-15** **Get hostile review, and do not design your own security protocols.** "Friendly reviews, by people who want the system to pass, are essentially useless" [30 §28.3.2].
16. **DESIGN-16** **Classify data and actions by risk, and scale controls to match.** "You shouldn't protect all access to the same degree" [2 ch. 5]. Applying "the same level of protection controls across all data" is an anti-pattern [20 SEC07-BP02]. Data that is only encoded, such as Base64 or a JWT payload, still counts as sensitive [3 14.1.1].

## 1. Authentication

### Passwords

1. **AUTHN-1** **Require length, not composition.** A password used alone must be "a minimum of 15 characters in length"; eight is the minimum when it is one factor of several. Permit at least 64 characters, and do not "impose other composition rules" [8 §3.1.1.2][3 6.2.1].
2. **AUTHN-2** **Do not expire passwords on a schedule; force a change on evidence of compromise** [8 §3.1.1.2]. Under forced expiry, "over 40% of passwords could be guessed from previous ones" [30 §3.4.4.3].
3. **AUTHN-3** **Check new passwords against a blocklist** "that contains known commonly used, expected, or compromised passwords" [8 §3.1.1.2].
4. **AUTHN-4** **Allow password managers and paste. Never use hints or security questions.** "Verifiers SHALL allow the use of password managers and autofill functionality" [8 §3.1.1.2]. One study found "a 19.7% success rate against 'Favourite food?' in English" [30 §3.4.1].
5. **AUTHN-5** **Give the same response for existing and missing accounts.** Match the message, status code and timing on login, signup and reset. A response that returns "a 200 for a positive result and a 403 for a negative result" lets an attacker list accounts [4 Authentication].
6. **AUTHN-6** **Throttle guessing without handing attackers a lockout.** Disable an authenticator after at most 100 consecutive failures, and add growing delays before that [8 §3.2.2]. "The counter of failed logins should be associated with the account itself, rather than the source IP address" [4 Authentication]. A hard freeze after three attempts opens "a denial-of-service attack" [30 §3.4.6].
7. **AUTHN-7** **Protect recovery and one-time-code endpoints as strictly as login, and count operations, not HTTP requests.** Recovery endpoints "should be treated as login endpoints in terms of brute force, rate limiting, and lockout protections" [5 API2]. Batched queries otherwise bypass per-request limits (`SERVICE-2`).

### Multi-factor authentication

8. **AUTHN-8** **Require two different kinds of factor.** Two secrets the user knows count as one: "a user-generated PIN and a password do not constitute two factors" [8 §2.2.1]. ASVS requires multi-factor authentication from Level 2 [3 6.3.3].
9. **AUTHN-9** **Enforce it on every login path.** "Disable legacy authentication protocols and endpoints that cannot enforce MFA consistently" [4 Multifactor Authentication]. Attackers use the weakest path.
10. **AUTHN-10** **Prefer phishing-resistant authenticators, and require them for staff and administrators.** Codes a user types "SHALL NOT be considered phishing-resistant because the manual entry does not bind the authenticator output to the specific session" [8 §3.2.5]. Google "replaced OTP second-factor authentication with the mandatory use of U2F-compatible security keys" [17].
11. **AUTHN-11** **Do not use email as a second factor, and treat SMS and voice codes as restricted.** "Email SHALL NOT be used for out-of-band authentication" [8 §3.1.3.1]. Before sending a code by phone, check for signs of "device swap, SIM change, number porting" [8 §3.1.3.3].
12. **AUTHN-12** **Do not accept a bare "approve" tap.** Make the user carry a code or number between the two channels, and limit how many prompts can be sent; plain approval prompts enable "authentication fatigue" attacks [8 §3.1.3].
13. **AUTHN-13** **Make one-time codes single-use and short-lived.** An out-of-band code is invalid "unless completed within 10 minutes", is accepted "only once", and "generating a new authentication secret SHALL NOT reset the failed authentication count" [8 §3.1.3.2].
14. **AUTHN-14** **Accept synced passkeys only up to the middle assurance level, and check the user-verification flag.** "If the user is not verified, agencies SHALL treat the authenticator as a single-factor cryptographic authenticator" [8 App. B]. The highest level needs "a non-exportable private key" [8 §2.3.2].
15. **AUTHN-15** **Use biometrics only together with a physical authenticator.** "Biometrics SHALL only be used as part of multi-factor authentication with a physical authenticator" [8 §3.2.3].

### Recovery and account changes

16. **AUTHN-16** **Make recovery as strong as login.** Authentication is "only as strong as the weakest fall-back mechanism" [30 §3.4.1]. A password reset must not "bypass any enabled multi-factor authentication mechanisms" [3 6.4.3]. For accounts with multi-factor authentication, require two recovery proofs obtained by different methods [8 §4.2].
17. **AUTHN-17** **Make reset tokens random, single-use, short-lived and stored like passwords.** They should be "invalidated after they have been used" [4 Forgot Password]. Build the emailed link from a fixed origin, not the request's Host header [4 Forgot Password]. A code sent by SMS is valid for at most 10 minutes, and by email for 24 hours [8 §4.2.1.2].
18. **AUTHN-18** **Re-authenticate before changing email, phone, factors or password.** "Do not rely solely on the active session, as it may be hijacked" [4 Multifactor Authentication]. Without this, a stolen token can "take over the victim's account by starting the reset" flow [5 API2].
19. **AUTHN-19** **Notify the user of security events, and let them kill a lost authenticator at once.** A notice must give "clear instructions, including contact information" for disputing the event [8 §4.6]. Provide a way "to invalidate the authenticator immediately" on a report of loss or theft [8 §3.2.1].

### Identity

20. **AUTHN-20** **Send the workforce through one identity provider tied to the HR lifecycle.** Without federation, "workforce users create separate user accounts and credentials in multiple applications" [20 SEC02-BP04]. Vendors should support single sign-on "at no additional cost to the customer" [29 Default Passwords].
21. **AUTHN-21** **With federated login, identify a user by the provider and the user's ID at that provider together** [3 6.8.1]. Otherwise one provider can assert another provider's user.
22. **AUTHN-22** **Ship no default accounts and no shared default passwords.** "Provide instance-unique setup passwords with the product" [29 Default Passwords]. Default accounts such as root or admin must be absent or disabled [3 6.3.2].
23. **AUTHN-23** **Require authentication on every interface,** "especially on critical interfaces such as administrator portals" [29 Web Management Interfaces].
24. **AUTHN-24** **An identifier is not a secret, and names are not stable.** "It's a bad idea to assume that today's name won't be tomorrow's password or capability" [30 §7.4.1]. "Once an identifier has been used for a given entity, it must not be reused" [2 ch. 6].

## 2. Sessions

1. **SESSION-1** **Issue a fresh random session ID at login and on every privilege change.** Generate it with a secure random generator, with "at least 128 bits of entropy" [3 7.2.3, 7.2.4]. Accept only IDs the server issued [4 Session Management].
2. **SESSION-2** **Enforce idle and absolute timeouts on the server.** NIST gives, by assurance level: about 30 days overall; 24 hours overall and 1 hour idle; 12 hours overall and 15 minutes idle [8 §2.1.3, §2.2.3, §2.3.3]. "When either timeout expires, the session SHALL be terminated" [8 §5.2]. An idle timeout alone lets a hijacked session live forever [4 Session Management].
3. **SESSION-3** **Logout and account disablement must end the session on the server.** For self-contained tokens this means "maintaining a list of terminated tokens, disallowing tokens produced before a per-user date and time or rotating a per-user signing key" [3 7.4.1].
4. **SESSION-4** **Carry the session in a host-locked, script-proof cookie.** For example: `Set-Cookie: __Host-SessionID=<value>; Secure; HttpOnly; SameSite=Strict; Path=/` [4 Session Management]. The `__Host-` prefix stops a sibling subdomain from overwriting the cookie [24 Cookies]. Do not keep bearer session secrets in browser local storage [8 §5.1].
5. **SESSION-5** **Do not treat "remember me" or a live token as proof the user is present.** Such features "SHALL NOT be used instead of authentication" [8 §5.1]. A relying party "SHALL NOT interpret the presence of an access token as an indicator of the subscriber's presence" [8 §5.1.2].
6. **SESSION-6** **Give cookies the shortest life and narrowest scope that work.** "Session identifiers in particular should expire as quickly as possible", and set a `Domain` only when another host needs the cookie [24 Cookies].

## 3. Authorization

### Core rules

1. **AUTHZ-1** **Deny by default.** "Base access decisions on permission rather than exclusion" [1]. Configure the denial explicitly, not through a framework default that may change [4 Authorization]. "Except for public resources, deny by default" [6 A01].
2. **AUTHZ-2** **Check every access.** "Every access to every object must be checked for authority", and remembered results need systematic updating when authority changes [1]. "Validating permissions correctly on just the majority of requests is insufficient" [4 Authorization].
3. **AUTHZ-3** **Decide on the server.** "Access control is only effective when implemented in trusted server-side code or serverless APIs, where the attacker cannot modify the access control check or metadata" [6 A01].
4. **AUTHZ-4** **Check object-level access in every function that takes an ID from the client.** Verify that "the logged-in user has access to perform the requested action on the record in every function that uses an input from the client" [5 API1]. Look objects up inside the caller's scope: `@current_user.projects.find(params[:id])`, not `Project.find(params[:id])` [4 IDOR]. Hard-to-guess IDs are defense in depth only.
5. **AUTHZ-5** **Route every function through one authorization module, and do not infer privilege from the URL.** "Don't assume that an API endpoint is regular or administrative only based on the URL path" [5 API5]. Use "a framework that requires every request handler or RPC to have well-defined access control restrictions" [2 ch. 12].
6. **AUTHZ-6** **Return only the fields the caller may read.** "Avoid using generic methods such as to_json() and to_string(). Instead, cherry-pick specific object properties" [5 API3].
7. **AUTHZ-7** **Bind request input only to fields the caller may write.** "Allow changes only to the object's properties that should be updated by the client" [5 API3]. Use an allow-list or a separate input type: with a blocklist, "a new or overlooked sensitive field remains bindable" [4 Mass Assignment].
8. **AUTHZ-8** **Enforce the order of multi-step flows on the server, and make check and action atomic.** A caller authorized for each endpoint can otherwise call `POST /checkout/confirm` "without completing payment" [4 REST Security]. Races occur when "access rights are verified at the first stage and something sensitive is done at the second" [30 §6.4.2].

### Privilege

9. **AUTHZ-9** **Grant least privilege.** "Every program and every user of the system should operate using the least set of privileges necessary to complete the job" [1]. In practice that means "specific actions on specific resources under specific conditions" [20 SEC03-BP02]. Avoid wildcards, which also grant rights to "all object types which are created in the future" [22 RBAC].
10. **AUTHZ-10** **Require two parties for risky actions.** "A protection mechanism that requires two keys to unlock it is more robust and flexible than one that allows access to the presenter of only a single key" [1]. Approvers must be free to refuse: "make sure the technology and social dynamics allow someone to say no" [2 ch. 5].
11. **AUTHZ-11** **Grant elevated access for a limited time.** "Temporary access also reduces ambient authority" [2 ch. 5]. Remove access when a person changes role or leaves; "inactive or terminated identities with active access privileges" are a standing risk [20 SEC03-BP06].
12. **AUTHZ-12** **Give operators narrow APIs, not shells.** "Avoid open-ended interactive interfaces—instead, design around small functional APIs" [2 ch. 5]. Make production changes "by automation (instead of humans), prevalidated by software, or triggered through an audited breakglass mechanism" [2 ch. 3].
13. **AUTHZ-13** **Gate staff access to customer data on a verified reason.** "Block access by default, and to only allow access to specific data when you can verify the business need" [2 ch. 5].
14. **AUTHZ-14** **Keep an emergency path that is restricted, monitored and tested.** "The ability to use a breakglass mechanism should be highly restricted" [2 ch. 5]. It must not "depend on the same systems (such as a centralized identity provider) as your normal access mechanisms" [20 SEC03-BP03].

### Services and tenants

15. **AUTHZ-15** **Act on the caller's authority, not your own.** "If A does some task on behalf of B, and its authority comes from both A and B, and A's authority exceeds B, things can go wrong" [30 §6.4.3]. Base downstream decisions "on the originating subject's (e.g. consumer's) permissions, not on the permissions of any intermediary" [3 8.3.3]. Google passes a short-lived end-user ticket on each call for this reason [17].
16. **AUTHZ-16** **Filter at the gateway, but authorize in every service.** "Gateway checks complement these controls; they do not establish that a downstream operation is authorized" [4 Microservices Security]. Fine-grained rules belong "closer to the location of the microservices" [18 MS-SS-2].
17. **AUTHZ-17** **Derive the tenant from verified membership, and carry it into every layer.** "Treat client-supplied tenant identifiers as selectors only" [4 Multi-Tenant Security]. Cross-tenant controls must ensure operations "will never affect tenants with which they do not have permissions to interact" [3 8.4.1].
18. **AUTHZ-18** **Access to one resource never implies access to another.** "Authentication and authorization to one resource will not automatically grant access to a different resource" [15 §2.1].
19. **AUTHZ-19** **Use one authorization model across services.** "A unified authorization system offers important advantages over maintaining separate access control mechanisms for individual applications" [19 §1]. With one shared library, "you can add support for MFA or MPA to all service endpoints with a single library change" [2 ch. 5].
20. **AUTHZ-20** **Never check new content against an old permission list.** If a user is removed and content is then added, a check against stale permissions lets the removed user see it. "The ACL check evaluation snapshot must not be staler than the causal timestamp assigned to the content update" [19 §2.2]. Use cached policy only as a short fallback when the decision service is down [18 MS-SS-2].

## 4. Tokens: OAuth, JWT and API keys

### OAuth flows

1. **TOKEN-1** **Match redirect URIs exactly, and expose no open redirectors.** Authorization servers "MUST utilize exact string matching", and neither side may forward the browser "to arbitrary URIs obtained from a query parameter" [9 §2.1].
2. **TOKEN-2** **Use PKCE with the S256 method for every client.** "Authorization servers MUST support PKCE", and the advice "applies to all kinds of OAuth clients, including web applications" [9 §2.1.1]. The server must reject a `code_verifier` when the request carried no challenge [9 §4.8.2].
3. **TOKEN-3** **Do not use the implicit grant or the password grant.** Clients should not use response types "issuing access tokens in the authorization response" [9 §2.1.2]. "The resource owner password credentials grant [RFC6749] MUST NOT be used" [9 §2.4].
4. **TOKEN-4** **Make authorization codes single-use.** They "MUST be invalidated by the authorization server after their first use at the token endpoint" [9 §4.2.4]. On reuse, revoke the tokens issued from that code.
5. **TOKEN-5** **A client that uses several authorization servers must check the issuer.** "The client MUST compare the received issuer identifier to the stored issuer identifier. If there is a mismatch, the client MUST abort the interaction" [9 §4.4.2.1].
6. **TOKEN-6** **After a credential form, redirect with 303, not 307.** A 307 makes the browser re-send the password to the client [9 §4.12].

### Access and refresh tokens

7. **TOKEN-7** **Bind tokens to the client that holds them.** Use "mechanisms for sender-constraining access tokens, such as mutual TLS for OAuth 2.0 [RFC8705] or OAuth 2.0 Demonstrating Proof of Possession (DPoP) [RFC9449]" [9 §2.2.1]. "By digitally binding tokens to specific requests or network sessions, token theft and token replay attacks can be eliminated" [28 Rec. 6].
8. **TOKEN-8** **Restrict each token's audience and privileges.** Every resource server must verify "whether the access token sent with that request was meant to be used for that particular resource server". Privileges "SHOULD be restricted to the minimum required" [9 §2.3]. Narrow the scope further as requests move inward [18 MS-SS-12].
9. **TOKEN-9** **Protect refresh tokens.** "Refresh tokens for public clients MUST be sender-constrained or use refresh token rotation" [9 §2.2.2]. With rotation, reuse of an old token must "revoke all refresh tokens for that authorization" [3 10.4.5].
10. **TOKEN-10** **Never put a token, key or password in a URL.** URLs are "captured in web server logs" [4 REST Security]. "Clients MUST NOT pass access tokens in a URI query parameter" [9 §4.3.2].
11. **TOKEN-11** **Keep tokens away from parties that do not need them.** With a backend-for-frontend, "access and refresh tokens shall only be accessible for the backend" [3 10.1.1]. "Internal authorization tokens must not be provided back to the user, and the user's session tokens must not be passed beyond the gateway" [18 MS-SS-10].
12. **TOKEN-12** **Authenticate clients with asymmetric credentials where you can,** so that authorization servers "do not need to store sensitive symmetric keys" [9 §2.5].

### Token validation

13. **TOKEN-13** **The verifier chooses the algorithm, not the token.** "Libraries MUST enable the caller to specify a supported set of algorithms and MUST NOT use any other algorithms", and "each key MUST be used with exactly one algorithm" [10 §3.1]. Otherwise an attacker can set the algorithm to `none`, or sign with a public key used as an HMAC secret.
14. **TOKEN-14** **Validate issuer, audience, expiry and type, and write rules that reject the wrong kind of token.** Validation rules "MUST be written such that they are mutually exclusive, rejecting JWTs of the wrong kind" [10 §3.12]. "The claims 'nbf' and 'exp' must be verified" [3 9.2.1].
15. **TOKEN-15** **Bind each key to its issuer.** "Never verify against a union of keys from several issuers" [4 JSON Web Token]. Microsoft published consumer and enterprise keys through one endpoint, and its libraries did not tell them apart, so a consumer key signed tokens that enterprise services accepted [28 §1.2.3.2].
16. **TOKEN-16** **Treat token headers as attacker input.** For key URLs in the header, the mitigation is "matching the URL to a whitelist of allowed locations and ensuring no cookies are sent in the GET request" [10 §3.10]. Otherwise the header becomes a server-side request forgery or injection vector.
17. **TOKEN-17** **Use real keys, and assume claims are readable.** "Do not use a password as MAC secret." A JWT payload "is only base64url encoded, not encrypted" [4 JSON Web Token].
18. **TOKEN-18** **Validate tokens with one shared library.** "By ensuring that all CSP services use the same authentication libraries, CSPs can more effectively enforce consistent token validation behavior" [28 Rec. 6].

### Lifetime and kind

19. **TOKEN-19** **Keep self-contained tokens short-lived, because they cannot be revoked.** "The token expiry times should be as short as possible since they determine the duration of the session and an active session cannot be revoked" [18 MS-SS-1]. Where the issuer also consumes the token, record issued tokens and check that record: Microsoft's system "accepted a token that it had not issued" [28 Rec. 6].
20. **TOKEN-20** **API keys identify client applications, not users.** "OAuth is not authentication, and neither are API keys" [5 API2]. "Do not rely exclusively on API keys to protect sensitive, critical or high-value resources" [4 REST Security].
21. **TOKEN-21** **Say what you mean inside the signed message.** "The interpretation of a protocol should depend only on its content, not its context; so everything of importance (such as principals' names) should be stated explicitly in the messages" [30 §4.8]. Check freshness with a remembered nonce, a counter or a bounded time, not with "different from the last one" [30 §4.3].

## 5. Cryptography

1. **CRYPTO-1** **Do not assemble cryptography yourself.** "Code involving cryptographic primitives that was not developed and reviewed by experienced cryptographers commonly has serious flaws" [2 ch. 6]. "Don't freelance public key encryption, and don't use a low-level crypto library like OpenSSL or BouncyCastle" [13].
2. **CRYPTO-2** **Encrypt only with authenticated encryption.** Latacora's order is a key management service, then NaCl secretbox, then XChaCha20-Poly1305, and "Avoid: Non-authenticated encryption" [14]. ASVS allows "approved ciphers and modes such as AES with GCM" and bans "insecure block modes (e.g., ECB) and weak padding schemes (e.g., PKCS#1 v1.5)" [3 11.3.1, 11.3.2].
3. **CRYPTO-3** **Use 256-bit symmetric keys and no cipher cascades.** "Things like large keys and cipher \"cascades\" are not just something to avoid, they're red flags" [14].
4. **CRYPTO-4** **Authenticate messages with HMAC over SHA-2, and compare tags in constant time.** HMAC secures "APIs, cookies, tokens, and so on", and it is "important to compare the tag with a time-constant function" [14].
5. **CRYPTO-5** **Hash with SHA-2. Never use MD5 or SHA-1.** "Disallowed hash functions, such as MD5, must not be used for any cryptographic purpose" [3 11.4.1]. Identify artifacts only with "cryptographic hashes with strong collision resistance" [26 threats].
6. **CRYPTO-6** **Generate every secret value from the operating system's secure generator.** "Use 256-bit random numbers. Be careful with the source: use /dev/urandom" [14]. A secret needs "at least 128 bits of entropy. Note that UUIDs do not respect this condition" [3 11.5.1].
7. **CRYPTO-7** **Store passwords with a slow, salted, memory-hard hash.** "Use Argon2id with a minimum configuration of 19 MiB of memory, an iteration count of 2, and 1 degree of parallelism" [4 Password Storage]. Latacora's order is "argon2id, scrypt, bcrypt, and PBKDF2 only if FIPS compliance is forcing you" [14]. Set the cost "as high as practical without negatively impacting verifier performance" [8 §3.1.1.2].
8. **CRYPTO-8** **Know bcrypt's 72-byte limit, and keep any pepper out of the database.** "You should enforce a maximum password length of 72 bytes" with bcrypt [4 Password Storage]. A keyed pepper "SHALL be stored separately from the hashed passwords" [8 §3.1.1.2].
9. **CRYPTO-9** **Sign with Ed25519, and plan for long-lived keys.** "If you have to deal with long-standing keys and signatures, we'd recommend Ed25519+ML-DSA-65" [14]. Avoid "RSA-PKCS1v15, RSA, ECDSA, DSA" [13].
10. **CRYPTO-10** **Move key exchange to a hybrid post-quantum scheme when a major library offers it.** The target is "X25519+ML-KEM-768", and "if you can, wait for a major library to expose this" [14]. Traffic recorded today can be decrypted later, so key exchange matters before signatures.
11. **CRYPTO-11** **Keep keys in a key management service or hardware module, one key per purpose.** "Standard application level code never reads or uses raw cryptographic keys in any way", and "a single key should be used for only one purpose" [4 Key Management]. "You do not allow key material to be accessed by human operators" [20 SEC08-BP01].
12. **CRYPTO-12** **Store less, and encrypt the rest by default.** "The best way to protect sensitive information is to not store it in the first place" [4 Cryptographic Storage]. Do not use "the same encryption key for all data regardless of data usage" [20 SEC08-BP02].
13. **CRYPTO-13** **Build so that algorithms can be replaced.** Algorithms, key lengths and modes should be able to "be reconfigured, upgraded, or swapped at any time, to protect against cryptographic breaks" [3 11.2.2].

## 6. Transport security

1. **TLS-1** **Refuse SSL and TLS 1.0 and 1.1. Use TLS 1.2 as the floor and prefer 1.3.** "Implementations MUST NOT negotiate TLS version 1.0", and they "MUST prefer to negotiate TLS 1.3 over earlier versions" [11 §3.1.1]. Two later RFCs tighten this for new protocols (see reference 11).
2. **TLS-2** **Never fall back to plaintext.** Set "a strict local policy that forbids use of plaintext in the absence of a negotiated TLS channel" [11 §3.2]. APIs "should fail requests made over unencrypted HTTP connections instead of redirecting them" [4 TLS]; with a silent redirect, "the leakage of sensitive data goes undiscovered" [3 4.1.2].
3. **TLS-3** **Offer only forward-secret, authenticated cipher suites.** "Implementations MUST NOT negotiate RC4 cipher suites", and they "MUST support and prefer to negotiate cipher suites offering forward secrecy" [11 §4.1].
4. **TLS-4** **Start from a maintained profile.** TLSRef's Intermediate profile is the "recommended configuration for a general-purpose server"; Modern is for clients "that support TLS 1.3, with no need for backwards compatibility" [12]. Pin generated configuration to a versioned guideline file; the rolling one "may change without warning" [12].
5. **TLS-5** **Validate the hostname and the whole certificate chain.** "Host name validation is security-critical for all common TLS use cases" [11 §7.1]. For internal services, "only trust specific internal CAs and specific self-signed certificates" [3 12.3.4].
6. **TLS-6** **Encrypt internal traffic too.** Use TLS "regardless of whether it is an internal or public-facing API" [5 API8]. In a cloud, "traffic between customer resources in the cloud does not necessarily stay within the cloud" [21 Network Segmentation].
7. **TLS-7** **Automate certificates and keep them short-lived.** "90 days is the recommended maximum certificate lifespan, to encourage certificate issuance automation" [12]. Manual renewal steps are an anti-pattern [20 SEC09-BP01]. Have "a strategy to distrust revoked certificates" [11 §7.5].
8. **TLS-8** **Send HSTS with a long lifetime.** "Set a `max-age` value of at least six months (`15768000`). Longer periods, such as two years (`63072000`), are recommended" [24 TLS]. Add `includeSubDomains` and preloading only after every subdomain serves HTTPS.
9. **TLS-9** **Redirect HTTP to HTTPS on the same host first.** Redirecting to a different host "prevents `Strict-Transport-Security` from being set for the first host" [24 TLS].
10. **TLS-10** **Turn off the risky extras.** Do not use TLS-level compression [11 §3.3]. Rotate session-ticket keys "regularly, e.g., once every week" [11 §3.4]. Avoid 0-RTT data "unless an explicit specification exists for the application protocol" [11 §3.10].
11. **TLS-11** **Meet minimum key sizes.** "DH key lengths of at least 2048 bits are REQUIRED", and "SHA-1 or MD5 MUST NOT be used" for signatures [11 §4.5].
12. **TLS-12** **For your own client and server, use TLS 1.3 with your own trust anchors.** "In custom protocols, you don't have to (and shouldn't) depend on third-party CAs" [13]. Avoid "designing your own encrypted transport, which is a genuinely hard engineering problem" [14].

## 7. Input handling

### Interpreters

1. **INPUT-1** **Keep data separate from commands.** "The best means to prevent injection requires keeping data separate from commands and queries" [6 A05]. Prefer "safer APIs, such as parameterized queries, auto-escaping, or templating frameworks" [3 V1].
2. **INPUT-2** **Parameterize every SQL statement, and make the unsafe form impossible.** Enforce "the use of parametrized queries across their applications"; sanitizing input is "brittle, difficult to enforce at scale, and frequently can be bypassed" [29 SQL Injection]. "You can design the database API so that mixing user input and SQL becomes impossible by design" [2 ch. 12]. "Binding procedure arguments protects the call, not dynamic SQL constructed inside the procedure" [4 SQL Injection Prevention].
3. **INPUT-3** **Map table names, column names and sort order to fixed values.** They cannot be bound, so "map user choices to a strict allow-list of fixed, application-owned values" [4 SQL Injection Prevention].
4. **INPUT-4** **Do not run input through a shell.** "The primary defense is to avoid calling OS commands directly." If you must, do not pass input "to command interpreters such as cmd.exe, powershell.exe, or sh -c" [4 OS Command Injection Defense]. Use library functions "that separate commands from their arguments" [29 OS Command Injection].
5. **INPUT-5** **Encode output for its exact context, at render time.** "An application that protects 99 places and misses one is still vulnerable" [4 XSS Prevention]. Typed HTML values and auto-escaping templates cut reported defects "by two orders of magnitude" at Google [2 ch. 12]. Allow only safe URL schemes: "disallow javascript: or data:" [3 1.2.2].
6. **INPUT-6** **Sanitize rich content with a known library, and never evaluate input.** User HTML must pass "a well-known and secure HTML sanitization library", and the application "avoids the use of eval() or other dynamic code execution features" [3 1.3.1, 1.3.2].

### Files and formats

7. **INPUT-7** **Do not build file paths from user input.** "Consider generating a random identifier for each file and storing associated metadata separately (e.g., in a database)" [29 Directory Traversal]. Where the set of files is known, "create a mapping from a set of fixed input values (such as numeric IDs) to the actual filenames" [7 CWE-22].
8. **INPUT-8** **Validate uploads, and store them where they cannot run.** Check the extension against an allow-list "after decoding the filename"; the declared content type "cannot be trusted, as it is trivial to spoof" [4 File Upload]. "Ensure that uploaded files do not have executable permissions" [29 Directory Traversal].
9. **INPUT-9** **Do not deserialize untrusted data with native object formats.** "Filtering does not make arbitrary untrusted deserialization safe" [4 Deserialization]. Verify a signature first and allow only listed types: "Add only acceptable classes to an allowlist" [7 CWE-502].
10. **INPUT-10** **Disable document type definitions in every XML parser.** "Reject DOCTYPE declarations if the parser supports it", and "treat an unsupported security setting as a configuration failure" [4 XXE Prevention].

### Validation

11. **INPUT-11** **Validate on the server with positive rules, and do not mistake validation for the injection defense.** Client-side validation "must not be relied upon as a security control" [3 2.2.2]. "Validation of a value does not make it safe to concatenate into SQL" [4 Input Validation].
12. **INPUT-12** **Limit size before parsing, and decode once.** "A schema check after parsing cannot protect a parser that has already exhausted resources." Validate "the representation that will actually be used, and avoid decoding it again downstream" [4 Input Validation].
13. **INPUT-13** **Treat data from other services and third-party APIs as untrusted.** "Developers tend to trust data received from third-party APIs more than user input" [5 API10].

### Server-side requests

14. **INPUT-14** **When input chooses where the server connects, accept a host from an allow-list and build the URL yourself.** "Do not accept complete URLs from the user because URL are difficult to validate and the parser can be abused" [4 SSRF Prevention]. "Disable HTTP redirections", and "do not send raw responses to clients" [5 API7].
15. **INPUT-15** **Check the resolved address and connect only to it.** "Domain allowlisting alone does not prevent DNS rebinding." "A second, unchecked DNS lookup between validation and connection" bypasses the check [4 SSRF Prevention].
16. **INPUT-16** **Use an address denylist only as a last resort, and compare canonical addresses.** "Deny-lists are bypass-prone. Prefer allow-lists." Addresses such as `::ffff:169.254.169.254` must be mapped to their IPv4 form first [4 SSRF Prevention]. See `NET-10` and `CLOUD-8`.

## 8. Browser-facing behavior

### Cross-site requests

1. **WEB-1** **Protect form-based state changes with the framework's anti-forgery tokens.** The server "embeds an unpredictable value in the page", then "carries out the request only if it matches" [24 CSRF]. "Cross-Site Scripting (XSS) can defeat all CSRF mitigation techniques!" [4 CSRF Prevention]
2. **WEB-2** **Reject cross-site state-changing requests using Fetch Metadata.** "By default, reject non-safe methods (POST / PUT / PATCH / DELETE) when Sec-Fetch-Site: cross-site." "Missing headers and Origin: null are not evidence of a same-origin request" [4 CSRF Prevention].
3. **WEB-3** **Treat `SameSite` cookies as defense in depth.** "It's not a complete defense, and is best considered as an addition to one of the other defenses." Use `Strict` for cookies that authorize state changes [24 CSRF]. The older Mozilla guideline that calls it the best defense is superseded [25].
4. **WEB-4** **Never change state on GET.** "Avoid using the `GET` method to issue state-changing requests", and beware frameworks' method override [24 CSRF]. Cross-site request forgery ranks third in the 2025 CWE Top 25 [7 CWE-352].
5. **WEB-5** **Make script-issued state changes non-simple requests, and do not undo that with credentialed CORS.** A site "can defend against CSRF by ensuring that the state-changing requests that it issues are never simple requests" [24 CSRF].

### Cross-origin and content rules

6. **WEB-6** **Send CORS headers only where needed, from a fixed allow-list.** For credentialed access, set the allowed origin "only to those origins, rather than reflecting the `Origin` header" [24 CORS]. If the request's origin is used, it must be "validated against an allowlist of trusted origins" [3 3.4.2].
7. **WEB-7** **Deploy a strict, nonce- or hash-based Content Security Policy.** "Implementing a strict CSP is the best way to mitigate XSS vulnerabilities with CSP" [24 CSP]. At minimum include "the directives object-src 'none' and base-uri 'none'" [3 3.4.3]. Roll it out with the report-only header first [24 CSP].
8. **WEB-8** **Prevent framing.** Send the `frame-ancestors` directive, with `X-Frame-Options` for older browsers: "the `frame-ancestors` directive is a replacement for `X-Frame-Options`" [24 Clickjacking].
9. **WEB-9** **Stop browsers from guessing types or rendering data as pages.** "All sites must set the `X-Content-Type-Options` header with a value of `nosniff`" [24 MIME types]. Serve uploads and API output with "the attachment disposition type in the Content-Disposition header field" or a sandboxing policy [3 3.2.1]. For APIs, Mozilla suggests `Content-Security-Policy: default-src 'none'; frame-ancestors 'none'` [25].
10. **WEB-10** **Set a strict referrer policy.** "Choose the strictest one that still allows your site to function properly"; URLs can carry "URL parameters containing sensitive information" [24 Referrer policy].
11. **WEB-11** **Mark private responses as not cacheable.** Send `Cache-Control: no-store` "so that sensitive data is not cached in browsers" [3 14.3.2]. "Be aware that no-cache does not prevent caching" [4 HTTP Headers].
12. **WEB-12** **Redirect off-site only to destinations on an allow-list** [3 3.7.2].
13. **WEB-13** **Pin third-party scripts with Subresource Integrity.** "If the file is modified after this point, the hash won't match, and supporting web browsers will refuse to load it" [24 SRI].
14. **WEB-14** **Send `Cross-Origin-Resource-Policy: same-origin` on private responses.** It "is recommended for URLs that reply with sensitive user information or private APIs" [24 CORP].
15. **WEB-15** **Do not hide paths in robots.txt.** Listing sensitive paths there means "you are showing their locations to potential attackers" [24 Robots.txt].

## 9. API and service behavior

1. **SERVICE-1** **Put a limit on everything a request can consume.** "Nothing in information technology should be limitless" [6 A10]. Set timeouts, memory and payload limits, page sizes and operations per request, and spending limits on paid third-party services [5 API4]. For query languages, use "depth limiting, amount limiting, or query cost analysis" [3 4.3.1].
2. **SERVICE-2** **Rate-limit by operation, not by HTTP request.** A batched query "will likely bypass existing rate limits in tools like Nginx or other proxies/gateways since they rely on looking at the raw number of requests" [4 GraphQL].
3. **SERVICE-3** **Find the business flows that hurt when automated, and limit them.** An endpoint is vulnerable "if it exposes a sensitive business flow, without appropriately restricting the access to it" [5 API6]. The risks include "data exfiltration, garbage-data creation, quota exhaustion" [3 2.4.1].
4. **SERVICE-4** **Return generic errors and keep the details in server logs.** There must be "no exposure of sensitive internal system data such as stack traces, queries, secret keys, and tokens" [3 16.5.1]. Use one global handler [4 Error Handling].
5. **SERVICE-5** **Pin down methods, content types and schemas, and make every hop parse requests the same way.** "All other HTTP verbs should be disabled." All servers in the chain must "process incoming requests in a uniform manner" [5 API8]. Disagreement about message boundaries enables request smuggling [3 4.2.1].
6. **SERVICE-6** **Do not let clients forge headers that intermediaries set.** Headers set by a proxy or load balancer "cannot be overridden by the end-user" [3 4.1.3]. "A reverse proxy MUST therefore sanitize any inbound requests to ensure the authenticity and integrity of all header values relevant for the security of the application servers" [9 §4.13].
7. **SERVICE-7** **Keep an inventory of every API host and version, and protect them all.** Apply protections to "all exposed versions of your APIs, not just for the current production version", and "avoid using production data with non-production API deployments" [5 API9].
8. **SERVICE-8** **Bound what an integrated service can make you do.** "Maintain an allowlist of well-known locations integrated APIs may redirect yours to: do not blindly follow redirects" [5 API10]. Set timeouts on their responses.
9. **SERVICE-9** **Deploy a minimal, hardened build.** Run "a minimal platform without any unnecessary features, components, documentation, or samples" [6 A02]. Deploy "without any source control metadata, including the .git or .svn folders" [3 13.4.1]. "Use a single flag to enable all debug features", and monitor that it is off [2 ch. 12].
10. **SERVICE-10** **Do not expose management interfaces by default.** Options include "disabling the product's web interface by default" and refusing to operate "while in a vulnerable state, such as when the product is directly exposed to the internet" [29 Web Management Interfaces].
11. **SERVICE-11** **Isolate clients of a shared service from each other.** "Performance isolation is indispensable to protect against misbehaving clients" [19 §4.5]. Put circuit breakers and quotas in a proxy, with limits "based on well-defined API usage plans" [18 MS-SS-8].
12. **SERVICE-12** **Treat the availability of the authorization service as a security requirement.** Without it, "client services would be forced to deny their users access" [19 §1], which tempts teams to fail open. Replicate the decision and enforcement points [15 §5.2].
13. **SERVICE-13** **Delete in two stages.** "By scheduling the data for deletion or disabling the keys first, we can recover from unintentional deletions" [17].

## 10. Network trust and service identity

1. **NET-1** **Network location grants no trust.** Zero trust means "no implicit trust granted to assets or user accounts based solely on their physical or network location" [15]. "A VPN connection alone must not authorize access to other resources" [4 Zero Trust Architecture]. At Google, "being connected to the corporate LAN is not our primary mechanism for granting access privileges" [17].
2. **NET-2** **Authenticate and encrypt all communication, and assume an attacker is on the network.** "All communication is secured regardless of network location." "Assets should always act as if an attacker is present on the enterprise network" [15 §2.1, §2.2].
3. **NET-3** **Bind identity to the workload, not to an address.** "Identities are bound to services instead of to a specific server name or host" [16]. "IP addresses simply don't provide a suitable identifier to identify services" [2 ch. 6].
4. **NET-4** **Services do not trust each other by default.** "Only authenticated, trusted, and specifically authorized callers or services can access any other service" [16]. A service "can restrict incoming RPCs solely to an allowed list of other services" [17].
5. **NET-5** **Make sure nothing can bypass the gateway.** Otherwise "any component suitably positioned on the network can make anonymous connections to the services bypassing the API gateway and its protections" [18 MS-SS-2]. Require mutual authentication for service-to-service calls [18 MS-SS-4].
6. **NET-6** **Make resources unreachable except through an enforcement point.** "Enterprise resources should not be reachable without accessing a PEP" [15 §3.4.1].
7. **NET-7** **Keep the control plane separate, and guard the policy system.** There should be "a separation (logical or possibly physical)" between control flows and application flows [15 §3.4]. Changes to the policy engine "must be logged and subject to audit" [15 §5.1].
8. **NET-8** **Authenticate the device as well as the user.** "Subject credentials alone are insufficient for device authentication to an enterprise resource" [15 §2.2]. Use device posture in each access decision: "No asset is inherently trusted" [15 §2.1].
9. **NET-9** **Segment by sensitivity, and allow only the flows a workload needs.** "If two applications deployed in an organization's cloud environment do not need to communicate, no communication path between them should exist" [21 Network Segmentation]. Do not "assume all traffic within a network layer is authenticated and authorized" [20 SEC05-BP02].
10. **NET-10** **Restrict outbound traffic.** Controlling "either your ingress traffic or your egress traffic, but not both" is an anti-pattern [20 SEC05-BP02]. Egress limits stop a server-side request forgery from reaching internal hosts [4 SSRF Prevention].
11. **NET-11** **Publish services through a hardened edge.** "A perimeter approach helps protect as much infrastructure as possible against unauthorized traffic and potential attacks from the internet, such as volume-based DoS attacks" [16].
12. **NET-12** **Protect service discovery.** "Only legitimate services" should be able to register, and "service self-registration/deregistration patterns should be avoided" [18 MS-SS-3].
13. **NET-13** **Back a service mesh with lower-layer segmentation.** Add network-layer segmentation against "malicious actors circumventing or bypassing the sidecar proxy" [18 MS-SS-13].
14. **NET-14** **Roll out new access policy in audit-only mode, but enforce basic denials from the start.** Rules such as "denying requests that fail MFA" should be "enforced and logged" throughout [15 §7.3.6].
15. **NET-15** **Assess an acquired company before its devices and accounts join your network.** "Large enterprises need robust compromise assessment and remediation processes for entities they acquire" [28 Rec. 9].

## 11. Cloud, containers and Kubernetes

### Accounts and data

1. **CLOUD-1** **Know which controls are yours.** "Customers often incorrectly assume that the cloud service provider (CSP) manages important aspects of safeguarding resources in the cloud that are not the CSP's responsibility" [21 Shared Responsibility].
2. **CLOUD-2** **Separate environments and unrelated workloads into different accounts.** "Account-level separation is strongly recommended, as it provides a strong isolation boundary" [20 SEC01-BP01]. Do not "rely solely on attribute-based access control for environment isolation" [20 SEC03-BP02].
3. **CLOUD-3** **Lock down the root identity.** "Do not create access keys for the root user" [20 SEC01-BP02]. Treat its email, DNS and phone recovery channels as critical.
4. **CLOUD-4** **Cap what can ever be granted with organization-wide guardrails.** Do not rely "on the implicit deny foundation" of the permission system alone [20 SEC03-BP05].
5. **CLOUD-5** **Grant at the lowest level of the hierarchy.** "Granting access to a \"folder\" or \"organizational unit\" grants access to all resources within that unit" [21 IAM].
6. **CLOUD-6** **Block public storage by default, across the organization.** "Data storage services should never be placed into publicly accessible networks unless justified by a mission requirement that is periodically reassessed" [21 Secure Data]. Keep an inventory of shared resources [20 SEC03-BP07].
7. **CLOUD-7** **Give third parties scoped roles, and hold them to your standards.** Avoid "long-term IAM credentials and access keys" and "reusing external IDs" for vendors [20 SEC03-BP09]. An operator with weaker access rules "can reintroduce risks that the customer previously mitigated" [21 MSP].
8. **CLOUD-8** **Harden the instance metadata service, and block it from workloads that do not need it.** It can return "IAM credentials that malicious actors can use to gain additional access to the cloud tenant" [21 IAM]. The hardened version uses "session authentication, blocking requests that contain an X-Forwarded-For HTTP header, and a network TTL of 1" [20 SEC06-BP05].
9. **CLOUD-9** **Keep immutable backups outside the source environment, and verify them on restore.** "Automated processes create data backups and store immutable copies outside of the original environment" [20 SEC08-BP03]. "Your backups need the same level of integrity protection as your primary storage" [2 ch. 9].
10. **CLOUD-10** **Know what "delete" means before relying on it.** "Destruction of deleted key material is frequently only guaranteed after several months" [21 Key Management]. Stopping a resource "does not mean that the data is deleted or inaccessible" [21 Secure Data].
11. **CLOUD-11** **Remove interactive access to machines.** "Interactive access to Amazon EC2 instances with protocols such as SSH or RDP" and shared keys are anti-patterns; operate through audited automation [20 SEC06-BP03].
12. **CLOUD-12** **Isolate workloads that share a host, more strongly when they handle untrusted input.** "We use more layers of isolation for riskier workloads", including those "that process unsanitized input from the internet" [17].

### Kubernetes

13. **CLOUD-13** **Keep the control plane off the internet.** "The Kubernetes API, kubelet API and etcd are not exposed publicly on Internet" [22]. "Disable anonymous login (enabled by default)" [23].
14. **CLOUD-14** **Do not use the superuser group for routine access.** A member of `system:masters` "bypasses all RBAC rights checks and will always have unrestricted superuser access" [22 RBAC].
15. **CLOUD-15** **Treat workload creation and secret listing as privileged.** "Granting permission to create workloads also implicitly grants the API access levels of any service account in that namespace" [22 RBAC].
16. **CLOUD-16** **Apply default-deny network policies in every namespace.** "Pods and services in different namespaces can still communicate with each other unless additional separation is enforced" [23].
17. **CLOUD-17** **Enforce a restrictive pod baseline at admission.** "Containers must be required to run as non-root users", and they must drop all capabilities [22 Pod Security Standards]. Giving a container the Docker socket "is equivalent to giving unrestricted root access to your host" [4 Docker Security].
18. **CLOUD-18** **Encrypt cluster secrets at rest, and do not mount tokens that are not needed.** "By default, Kubernetes stores Secrets as unencrypted base64-encoded strings that can be retrieved by anyone with API access" [23]. Use bound, expiring service account tokens [22].
19. **CLOUD-19** **Ship minimal images, referenced by digest.** "The image behind a tag can be easily modified in a registry. Prefer using the complete `sha256` digest" [22].
20. **CLOUD-20** **Set resource limits on workloads,** to "prevent potential DoS attacks from malicious or breached workloads" [22].
21. **CLOUD-21** **Turn on audit logging and send it off the cluster.** "Enable audit logging (disabled by default)", and "aggregate logs external to the cluster" [23].

## 12. Secrets and credential lifecycle

### Fewer, shorter-lived secrets

1. **CRED-1** **Prefer credentials you never store.** "The most secure credential is one that you do not have to store, manage, or handle" [20 SEC02-BP03]. Use "identity federation, short-lived credentials, or role-based access mechanisms provided by the underlying platform instead of embedding static keys or secrets" [6 A02]. Backend components should not use "unchanging credentials such as passwords, API keys, or shared accounts" [3 13.2.1].
2. **CRED-2** **Keep the remaining secrets in a secrets manager.** "Secrets must not be included in application source code or included in build artifacts" [3 13.3.1]. "Never pass secrets in plaintext anywhere in the pipeline" [21 CI/CD].
3. **CRED-3** **Scan for secrets before commit, and when one leaks, revoke it first.** "Keys that were exposed should undergo immediate revocation" [4 Secrets Management]. Deleting the commit does not help, and "restarting the application does not itself revoke stolen credentials" [4 Secrets Management].
4. **CRED-4** **Confine any long-lived key you cannot avoid.** Grant it "only the AssumeRole operation for one specific role", limit the networks that may use it [20 SEC02-BP02], and rotate it at least every 90 days [20 SEC02-BP05].
5. **CRED-5** **Treat pipelines and software agents as privileged identities.** Do not share secrets "across pipelines having different levels of sensitivity or value" [4 CI/CD Security]. Authenticate runners "using short-lived OpenID Connect (OIDC) tokens and workload identity federation" [4 Secrets Management]. An agent "may have a lower bar for authentication (e.g., API key versus MFA)" than a person with the same power [15 §5.7].

### Signing keys

6. **CRED-6** **Rotate signing keys automatically and often, and monitor the rotation.** The Board recommends "rotating encryption keys frequently (e.g., monthly) and in an automated manner with monitoring of rotation systems" [28 Rec. 6]. The stolen 2016 key was still valid in 2023; Microsoft "stopped the rotation entirely in 2021" and had no "automated alerting system" for key age [28 §1.2.3.2].
7. **CRED-7** **Scope each key narrowly.** "Tying encryption keys to customer tenancy would limit the scope of key compromise" [28 Rec. 6]. Likewise, a job credential shared across a role lets one compromised job "impersonate the job's corresponding role across the network" [2 ch. 8].
8. **CRED-8** **Keep signing keys where they cannot leave.** "By storing key material in isolated systems and leveraging, where feasible, technologies such as dedicated HSMs, the risk of key compromise can be reduced" [28 Rec. 6]. "Keys generated on an HSM should never be exported in plain text" [21 Key Management].
9. **CRED-9** **Write key policies that deny by default, and separate key administration from key use.** Policies "should specifically grant access to each API operation needed" [21 Key Management].
10. **CRED-10** **Keep build signing keys away from user-defined build steps.** Such material "MUST NOT be accessible to the environment running the user-defined build steps" [26 build-requirements].

### Rotation, revocation and recovery

11. **CRED-11** **Rotate routinely, and confirm the old credential is dead.** "If you rotate your keys and credentials over time and expire the old ones, the adversary must maintain their presence to reacquire the new secrets" [2 ch. 8].
12. **CRED-12** **Build explicit revocation that does not fail open and has no exempt accounts.** Manage keys centrally and distribute "state to servers through a revocation list" [2 ch. 9]. One safeguard is to have a server "refuse any update that revokes its own credentials" [2 ch. 9].
13. **CRED-13** **Do not let security hang on wall-clock time.** "Tying events to wall-clock time is often an anti-pattern", and disabling validity checks to recover from an outage is worse than the outage [2 ch. 9].
14. **CRED-14** **Prepare emergency credentials that do not depend on the normal identity systems.** "Remote access credentials cannot depend on typical credential services" [2 ch. 9]. Keep them offline and make them "set off high-confidence alarms" when used [2 ch. 15].
15. **CRED-15** **After a key compromise, revoke, purge, rotate and keep watching.** Microsoft "revoked the key's ability to sign tokens". Once a key is inactive, every later signature with it is "nefarious activity" and a reliable alarm [28 §1.3.2.1, §1.3.4].

## 13. Source, build, dependencies and deployment

### Source and build

1. **SUPPLY-1** **Require a second person to approve every change, and enforce it technically.** "Code review is a form of multi-party authorization, meaning that no individual has the privilege to submit changes on their own" [2 ch. 14]. "All changes require review by two people, even changes authored by robots" [26 source-requirements].
2. **SUPPLY-2** **Protect history and release tags.** Prohibit force-pushes on protected branches, and prevent tags "from being moved or deleted" [26 source-requirements]. Platform administrators need controls too, such as "two-person approvals, audit logging" [26 threats].
3. **SUPPLY-3** **Build releases on locked-down automation, not on workstations.** "Move all build, test, and deployment steps to automated systems" [2 ch. 14]. Provenance "MUST be generated by the control plane", not by the tenant's build steps [26 build-requirements].
4. **SUPPLY-4** **Run each build in a fresh, isolated environment with declared inputs.** "An ephemeral build environment MUST be provisioned for each build" [26 build-requirements]. "The build process should declare all inputs up front, and only the orchestrator should fetch those inputs" [2 ch. 14].
5. **SUPPLY-5** **Separate and harden development and build environments.** "Ensure that all components of the environments for software development are strongly protected from internal and external threats" [27 PO.5].

### Verification and deployment

6. **SUPPLY-6** **Verify what is being deployed, not only who deploys it.** "It is not sufficient to verify who initiated a deployment, because that actor may make a mistake or may be intentionally deploying a malicious change" [2 ch. 14]. Check the provenance signature, the artifact digest and the expected source and builder [26 verifying-artifacts].
7. **SUPPLY-7** **Trust a few hardened platforms, and trace releases to source.** "Securely trace all software back to source code rather than trust individuals who have write access to package registries." "Require explicit attestations about an artifact's provenance; do not infer security properties from a platform's configurations" [26 principles].
8. **SUPPLY-8** **Enforce deployment policy where it cannot be bypassed.** "Adversaries can bypass deployment decisions that don't occur at choke points" [2 ch. 14].
9. **SUPPLY-9** **Sign what you build, and verify signatures, not only hashes.** "Hashes establish that artifacts have not been modified from the original version", but they do not show who published it [20 SEC06-BP04]. If a signature fails in the pipeline, "investigate the cause" [21 CI/CD].
10. **SUPPLY-10** **Treat configuration and infrastructure as code.** "Treat configuration as code by requiring that configuration changes be checked in, reviewed, and tested prior to deployment" [2 ch. 14]. After deployment, "manual updates to resources should be avoided to prevent resource drift" [21 IaC].
11. **SUPPLY-11** **Prevent rollback to a known-vulnerable version.** Keep a minimum acceptable security version, "a low-water mark below which your systems should never operate" [2 ch. 9].
12. **SUPPLY-12** **Deliver security updates automatically and signed.** Updates should be "automated and signed", "ideally without any user intervention" [29 SOHO].

### Dependencies

13. **SUPPLY-13** **Pin dependencies, verify their hashes, and resolve them from one private feed.** "Configure the package manager to use only a single private feed" [4 CI/CD Security]. Without this, a public package with an internal name can be installed in its place [26 threats].
14. **SUPPLY-14** **Keep an inventory of all dependencies, including transitive ones, and watch it.** "Track not just your direct dependencies, but their (transitive) dependencies, and so on" [6 A03]. An SBOM is itself a pipeline artifact: "SBOMs cannot be presumed accurate" [21 CI/CD].
15. **SUPPLY-15** **Set deadlines for fixing vulnerable components, and keep the patch path fast.** Define "risk based remediation time frames for 3rd party component versions with vulnerabilities" [3 15.1.1]. "New releases and their security patches won't make it into your environment until you rebuild" [2 ch. 7].
16. **SUPPLY-16** **Prefer maintained, well-secured components to writing your own,** especially "cryptographic modules and protocols" [27 PW.4]. "Do not pick components that have a history of unfixed or slowly fixed security issues" [2 ch. 12].
17. **SUPPLY-17** **Treat build tools and base images as artifacts to verify.** "The SLSA level of an artifact is independent of the level of its dependencies" [26 about].

## 14. Logging, detection and response

### What to log

1. **LOG-1** **Log every security decision with who, what, when and where.** "Ensure that every part of your app that contains a security control is logged, whether it succeeds or fails" [6 A09]. "All authentication operations are logged, including successful and unsuccessful attempts" [3 16.3.1]. Also log "input validation errors and extra parameters errors" [18 MS-SS-5].
2. **LOG-2** **Never log credentials or tokens.** Session tokens "may only be logged by being hashed or masked" [3 16.2.5]. A log of failed logins "usually contains a large number of passwords", because users type the password into the username field [30 §3.4.9].
3. **LOG-3** **Log administrative actions in detail, with a reason.** "The most useful audit logs capture a granular series of actions" [2 ch. 5]. Recording interactive sessions only keeps "the honest people honest" [2 ch. 5].
4. **LOG-4** **Record permission changes in the same transaction as the change.** "Every Zanzibar write is committed to both the tuple storage and the changelog shard in a single transaction" [19 §3.1.2].
5. **LOG-5** **Link each derived token to the sign-in that produced it.** "By linking all tokens derived from a single root authentication event together and exposing this linking to their customers in logs", defenders can trace identity attacks [28 Rec. 6].

### Protecting and keeping logs

6. **LOG-6** **Send logs off the host to a separate, tamper-resistant system.** "Attackers commonly erase traces of their activity on a system from all log sources as soon as they establish a solid foothold" [2 ch. 15]. Use a "logically separate system for analysis, detection, alerting, and escalation" [3 16.4.3], with a log administrator role "distinct and isolated from other administrator roles" [21 Logs].
7. **LOG-7** **Encode log data, and notice when logging stops.** "Parameterized logging alone does not prevent CR/LF log injection; use a structured encoder that escapes values correctly." "Enable processes to detect whether logging has stopped" [4 Logging].
8. **LOG-8** **Protect logs as sensitive data.** "Be sure to protect logs and metadata just as you protect other data" [2 ch. 15].
9. **LOG-9** **Turn on the logs a provider leaves off.** "CSPs may not enable critical logs by default" [21 Logs]. Control-plane, network-flow and DNS logs are "the basic logging sources to support security investigations" [20 SEC04-BP01]. "Sampling user authentication logs may not" be appropriate [21 Logs].
10. **LOG-10** **Keep logs for as long as a slow investigation needs.** For key systems, "retention should include all time the key was in active use and extend at least two years beyond the expiration of that key" [28 Rec. 5].
11. **LOG-11** **A service's audit logs belong in the base product.** "All access (including access by the CSP itself) to customer business data in the cloud produces logs that are available to the customer without additional charges" [28 Rec. 10]. The 2023 intrusion was found by a customer with premium logging.

### Detection

12. **LOG-12** **Test that forbidden operations fail, and alert when they succeed.** "Operations that attempt to cross boundaries of role, location, or time separation should fail. If your logs record unexpected successes instead, these successes should be flagged" [2 ch. 8].
13. **LOG-13** **Make forged credentials detectable.** Alerting on tokens "that do not conform to Microsoft's own token generation algorithms" could have stopped the 2023 intrusion [28 §2.1.1].
14. **LOG-14** **Declare the intended state of systems, and detect deviations.** "Thoroughly encoding the intended state is the foundation of excellent automation, security, intrusion detection, and recovery to a known state" [2 ch. 9].

### Response and disclosure

15. **LOG-15** **Prepare the response before the incident.** Write playbooks "for incidents you anticipate" [20 SEC10-BP04]. "It's a best practice to have out-of-band communication as a backup for incident communication" [20 SEC10-BP02]; an attacker who controls email or chat "may choose to join the distribution group used to coordinate the response" [2 ch. 16].
16. **LOG-16** **Fix the class of defect, not only the instance.** Run a disclosure and remediation process [27 RV.1], and analyze root causes so the same kind of defect does not recur [27 RV.3].
17. **LOG-17** **In disclosures, separate fact from hypothesis and correct mistakes quickly.** Providers "should promptly correct significant factual inaccuracies as they discover them in their public or customer statements" [28 Rec. 16].
18. **LOG-18** **Make breach notices unmistakable, and confirm they arrived.** "Some victims ignored or did not see the notifications, and some who saw them believed them to be spam or phishing" [28 §2.1.6].

---

## Checklist for one review

1. List where untrusted requests enter and what each one can reach. Check that every entry point authenticates (`AUTHN-23`) and that every handler authorizes, down to the object and field (`AUTHZ-4` to `AUTHZ-7`).
2. Follow each input into interpreters, parsers, file paths and outbound requests (`INPUT-1`, `INPUT-7`, `INPUT-9`, `INPUT-14`).
3. For login, check throttling, uniform responses, multi-factor coverage and the recovery path (`AUTHN-5`, `AUTHN-6`, `AUTHN-9`, `AUTHN-16`).
4. For tokens, check who chooses the algorithm, what is validated, lifetime and where tokens travel (`TOKEN-13`, `TOKEN-14`, `TOKEN-19`, `TOKEN-10`).
5. List every stored secret and ask whether it can be removed, shortened or scoped (`CRED-1`, `CRED-4`, `CRED-7`). Check key rotation and revocation (`CRED-6`, `CRED-12`).
6. Check that internal calls are authenticated and encrypted, and that nothing bypasses the gateway (`NET-2`, `NET-5`, `TLS-6`).
7. For cloud resources, check account separation, public exposure, the metadata service and backups (`CLOUD-2`, `CLOUD-6`, `CLOUD-8`, `CLOUD-9`).
8. Check that a release can be traced to reviewed source, and that deployment verifies it (`SUPPLY-1`, `SUPPLY-6`).
9. Ask what an investigator would have after a breach: which logs exist, where they are stored and for how long (`LOG-1`, `LOG-6`, `LOG-10`).

---

## References

**Design**

1. Jerome H. Saltzer and Michael D. Schroeder, "The Protection of Information in Computer Systems" (1975), Section I.A.3: https://web.mit.edu/Saltzer/www/publications/protection/Basic.html
2. Adkins, Beyer, Blankinship, Lewandowski, Oprea and Stubblefield, *Building Secure and Reliable Systems* (Google and O'Reilly, 2020): https://google.github.io/building-secure-and-reliable-systems/raw/toc.html. Cited by chapter, e.g. ch. 5 → `raw/ch05.html`.

**OWASP and MITRE**

3. OWASP Application Security Verification Standard 5.0.0 (May 2025): https://github.com/OWASP/ASVS/tree/v5.0.0/5.0/en. Cited by requirement number, e.g. 6.2.1; V1 means the chapter introduction.
4. OWASP Cheat Sheet Series: https://cheatsheetseries.owasp.org/. Cited by sheet name. IDOR is "Insecure Direct Object Reference Prevention"; TLS is "Transport Layer Security"; XSS and XXE are the "Cross Site Scripting Prevention" and "XML External Entity Prevention" sheets.
5. OWASP API Security Top 10 (2023): https://api-security.owasp.org/editions/2023/en/0x11-t10/. Cited by risk number, e.g. API1.
6. OWASP Top 10:2025: https://top10.owasp.org/2025/. Cited by category, e.g. A01.
7. 2025 CWE Top 25 Most Dangerous Software Weaknesses: https://cwe.mitre.org/top25/archive/2025/2025_cwe_top25.html. Cited by CWE number; mitigations are on each weakness page, e.g. https://cwe.mitre.org/data/definitions/22.html.

**Authentication and tokens**

8. NIST SP 800-63B-4, *Digital Identity Guidelines: Authentication and Authenticator Management* (July 2025): https://pages.nist.gov/800-63-4/sp800-63b.html. Cited by section.
9. RFC 9700, "Best Current Practice for OAuth 2.0 Security" (January 2025): https://www.rfc-editor.org/rfc/rfc9700.html
10. RFC 8725, "JSON Web Token Best Current Practices" (February 2020): https://www.rfc-editor.org/rfc/rfc8725.html. A replacement draft is in progress.

**TLS and cryptography**

11. RFC 9325, "Recommendations for Secure Use of Transport Layer Security (TLS) and Datagram Transport Layer Security (DTLS)" (November 2022): https://www.rfc-editor.org/rfc/rfc9325.html. Updated by RFC 9852 (new protocols must support TLS 1.3) and RFC 10015 (static RSA and finite-field Diffie-Hellman suites become "MUST NOT" in TLS 1.2): https://www.rfc-editor.org/info/rfc9852/ and https://www.rfc-editor.org/info/rfc10015/
12. TLSRef, "Server-Side TLS", guideline version 6.0 (successor to Mozilla's guidelines): https://docs.tlsref.org/server-side-tls.html
13. Latacora, "Cryptographic Right Answers" (2018-04-03): https://www.latacora.com/blog/cryptographic-right-answers/
14. Latacora, "Cryptographic Right Answers: Post Quantum Edition" (2024-07-29, updated 2026-06-24): https://www.latacora.com/blog/post-quantum-cryptographic-right-answers/

**Network and service identity**

15. NIST SP 800-207, *Zero Trust Architecture* (August 2020): https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-207.pdf
16. Google, "BeyondProd": https://docs.cloud.google.com/docs/security/beyondprod
17. Google, "Google infrastructure security design overview": https://docs.cloud.google.com/docs/security/infrastructure/design
18. NIST SP 800-204, *Security Strategies for Microservices-based Application Systems* (August 2019): https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-204.pdf. Cited by strategy ID, e.g. MS-SS-2.
19. Pang et al., "Zanzibar: Google's Consistent, Global Authorization System" (USENIX ATC 2019): https://www.usenix.org/conference/atc19/presentation/pang

**Cloud and Kubernetes**

20. AWS Well-Architected Framework, Security Pillar (2024-11-06): https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/welcome.html. Cited by best-practice ID, e.g. SEC02-BP02.
21. NSA and CISA, cloud security Cybersecurity Information Sheets (March 2024; the CI/CD sheet is June 2023). Announcement: https://www.cisa.gov/news-events/alerts/2024/03/07/cisa-and-nsa-release-cybersecurity-information-sheets-cloud-security-best-practices. Cited by sheet name. The PDFs are on media.defense.gov, which refuses automated requests, so each link below is the Internet Archive copy that was read; the original URL is the part after `id_/`.
    - Shared Responsibility: https://web.archive.org/web/20250130093128id_/https://media.defense.gov/2024/Mar/07/2003407863/-1/-1/0/CSI-CLOUDTOP10-SHARED-RESPONSIBILITY-MODEL.PDF
    - IAM: https://web.archive.org/web/20250121151902id_/https://media.defense.gov/2024/Mar/07/2003407866/-1/-1/0/CSI-CLOUDTOP10-IDENTITY-ACCESS-MANAGEMENT.PDF
    - Key Management: https://web.archive.org/web/20250121191330id_/https://media.defense.gov/2024/Mar/07/2003407858/-1/-1/0/CSI-CLOUDTOP10-KEY-MANAGEMENT.PDF
    - Network Segmentation: https://web.archive.org/web/20250121190300id_/https://media.defense.gov/2024/Mar/07/2003407861/-1/-1/0/CSI-CLOUDTOP10-NETWORK-SEGMENTATION.PDF
    - Secure Data: https://web.archive.org/web/20250126161035id_/https://media.defense.gov/2024/Mar/07/2003407862/-1/-1/0/CSI-CloudTop10-Secure-Data.PDF
    - MSP: https://web.archive.org/web/20250121151854id_/https://media.defense.gov/2024/Mar/07/2003407859/-1/-1/0/CSI-CloudTop10-Managed-Service-Providers.PDF
    - IaC: https://web.archive.org/web/20250121185307id_/https://media.defense.gov/2024/Mar/07/2003407857/-1/-1/0/CSI-CLOUDTOP10-INFRASTRUCTURE-AS-CODE.PDF
    - Logs: https://web.archive.org/web/20240315142351id_/https://media.defense.gov/2024/Mar/07/2003407864/-1/-1/0/CSI_CloudTop10-Logs-for-Effective-Threat-Hunting.PDF
    - CI/CD: https://web.archive.org/web/20250107213329id_/https://media.defense.gov/2023/Jun/28/2003249466/-1/-1/0/CSI_DEFENDING_CI_CD_ENVIRONMENTS.PDF
22. Kubernetes documentation, "Security Checklist": https://kubernetes.io/docs/concepts/security/security-checklist/. "RBAC" is https://kubernetes.io/docs/concepts/security/rbac-good-practices/ and "Pod Security Standards" is https://kubernetes.io/docs/concepts/security/pod-security-standards/.
23. NSA and CISA, *Kubernetes Hardening Guide* version 1.2 (August 2022): https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_1.2_20220829.PDF. That host refuses automated requests; the copy read is https://web.archive.org/web/20231212041314id_/https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_1.2_20220829.PDF

**Web platform**

24. MDN, "Practical security implementation guides": https://developer.mozilla.org/en-US/docs/Web/Security/Practical_implementation_guides. Cited by guide name. CSRF and Clickjacking are at https://developer.mozilla.org/en-US/docs/Web/Security/Attacks/CSRF and https://developer.mozilla.org/en-US/docs/Web/Security/Attacks/Clickjacking.
25. Mozilla, "Web Security" guidelines (last changed March 2024): https://infosec.mozilla.org/guidelines/web_security

**Supply chain**

26. SLSA specification v1.2: https://slsa.dev/spec/v1.2/. Cited by page name, e.g. threats → https://slsa.dev/spec/v1.2/threats.
27. NIST SP 800-218, *Secure Software Development Framework (SSDF) Version 1.1* (February 2022): https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-218.pdf. Cited by practice ID, e.g. PW.4.

**Incident evidence**

28. Cyber Safety Review Board, *Review of the Summer 2023 Microsoft Exchange Online Intrusion* (March 2024): https://www.cisa.gov/sites/default/files/2025-03/CSRBReviewOfTheSummer2023MEOIntrusion508.pdf. Cited by recommendation or section number.
29. CISA, Secure by Design Alerts (2023–2024): https://www.cisa.gov/securebydesign/alerts. Cited by alert topic: Web Management Interfaces, Default Passwords, SOHO, SQL Injection, Directory Traversal, OS Command Injection.

**General**

30. Ross Anderson, *Security Engineering*, 3rd edition (2020): https://www.cl.cam.ac.uk/archive/rja14/book.html. Cited by section number; chapter PDFs are linked from that page.
