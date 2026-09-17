# Design

## Context

The node's own `config.json` and its per-repo seeding policies are two stores
the module has never been able to read or write. This change adds that surface
to the core module and to `radicle_ui.rep`, and makes the `listen` field the
start path already reads actually reach the socket layer.

No UI. The panel is a separate piece, and the two view requirements in
`node-config` and `node-seeding` are not satisfied here — see
`proposal.md`'s "Not covered".

## Decisions

### `config.json` is edited as raw JSON, never round-tripped through `Config`

**Chosen:** `nodeconfig.rs` reads `config.json` into a `serde_json::Value`,
mutates the individual members of its `node` object in place, validates by
deserializing the result into `radicle::profile::Config`, and writes the
`Value` back.

**Rejected:** the obvious `Config::load` → mutate a field → `Config::write`.
It silently deletes data, and the deletion is invisible until someone looks at
the file. Two mechanisms:

- `node::Config.extra` is `#[serde(flatten, skip_serializing)]`
  (`radicle-0.25.1/src/node/config.rs:658`). Every key this build does not know
  is collected on deserialize and **never written back**. A user on a newer
  `rad` whose config carries a field this build predates would lose it the
  first time the panel changed their alias.
- Several known fields carry `skip_serializing_if`, so a value that happens to
  equal the default disappears too. `user_agent` is `some_default`,
  `web`/`database`/`fetch` are `is_default`, `proxy`/`secret` are
  `Option::is_none`. Round-tripping is lossy in more places than `extra`.

The spec states this as an observable requirement — "a key this build does not
know survives a write". `tests/node_config.rs` has
`a_key_this_build_does_not_know_survives_a_write`, whose fixture plants a
`mysteriousFutureField` in the `node` object and asserts it is still there,
**with its value**, after an alias change.

Verified by mutation rather than claimed: replacing `write_document` with
`Config::write` leaves that test as the **only** failing one in the file
(13 pass, 1 fails, `left: Null, right: String("keep me")`). Its sibling
`an_unrelated_known_field_survives_a_write` stays green under that mutation,
because `workers` is a real field of the crate's type and a round-trip carries
it through — recorded in the test itself so nobody reads it as discriminating.

**Rejected:** `radicle::profile::config::RawConfig`, which does exactly this
and is the crate's own answer. It is `#[deprecated]` on every item
(`profile/config.rs:222`, `:408`, `:468`), and its `ConfigValue` guesses a
value's type from a string (`From<&str> for ConfigValue`, `:422`) — it cannot
express an array of addresses or the `{"type":"static"}` object `peers` needs.
Using it would mean `#[allow(deprecated)]` across the module for an API that
does not fit. Its *validate-then-write* idea is kept; its types are not.

### Validation is the crate's own parsers, called on the submitted string

Each field is validated by handing the submitted value to the type the crate
would have parsed it into anyway:

| Field | Validator | Why this one |
|---|---|---|
| `alias` | `Alias::from_str` | The spec requires the crate's own rule passed through rather than paraphrased. `node.rs:416-431` is non-empty, no control/whitespace chars, ≤32 **bytes** — and its `AliasError` messages are what the refusal carries. |
| `listen` | `std::net::SocketAddr::from_str` | The field is `Vec<net::SocketAddr>`, not `Vec<Address>`, so it is stricter than `connect`: an IP and a port, no DNS name. |
| `connect` | `PeerAddr::<NodeId, Address>::from_str` | What `ConnectAddress`'s `serde_ext::string` uses. Requires the `<nid>@` half. |
| `externalAddresses` | `Address::from_str` | `node.rs:623`. Host and port, no node id. |
| `peers` | an explicit two-arm match | See below. |

Writing our own regex or length check for any of these would mean a value this
module accepts and the node then refuses at start — the deferred failure the
whole validate-on-write rule exists to prevent.

**The one place a crate parser is not sufficient, and it was measured.**
`Address::from_str` splits on the *last* colon and parses the remainder as a
`HostName`, whose DNS arm accepts anything host-shaped. A probe against
radicle 0.25.1 confirmed that

```
Address::from_str("z6MkrLMM…@seed.example.test:8776")
  -> Ok("z6MkrLMM…@seed.example.test:8776")
```

— it parses, and round-trips unchanged. So a `connect`-shaped value in
`externalAddresses` would be stored, and the node would advertise a public
address nobody can reach. `parse_external_addresses` therefore rejects a bare
`@` before parsing, and names the field the value belongs in.

`an_external_address_with_a_node_id_is_refused_although_the_crate_accepts_it`
carries a **control assertion** that the crate's own parser says yes to the
string, so the test cannot pass because the crate happened to start refusing it.
Removing the `@` check turns that test red.

The reverse direction needs no check of ours: `ConnectAddress`'s deserializer
refuses a bare `host:port` with "Peer address must contain peer key … separated
by '@'", which is a message worth showing as it stands.

### `peers` is matched explicitly rather than deserialized

`PeerConfig` is `#[serde(tag = "type")]`, so on disk it is
`{"type":"static"}` — an object, not the string the module's surface exposes.
The module converts in both directions rather than letting the caller see the
tagged form, for two reasons the spec states: a caller must not be able to
submit addresses through `peers` (they belong in `connect`), and a refusal must
name both valid disciplines. `serde`'s own error for an unknown tag names
neither `static` nor `dynamic` in a form worth showing a user.

`static` with an empty `connect` is refused in `nodeconfig.rs` rather than by
any crate check, because the crate has none: it configures a node to maintain
connections to nobody, which reaches no peer and reports no error at any later
point. The check reads the `connect` the write is *about to produce*, not the
one on disk, so setting both in one call is accepted — which is the scenario
that distinguishes a real check from one that refuses `static` outright.

### Seeding writes `policies.db`, not `config.json`

**`docs/PLAN.md` said otherwise, and this is where that correction now lives.**
Its panel paragraph described seeding as one of `node/config.rs`'s fields.
Per-repo seeding policies are **not** in `config.json`: they are rows in
`<home>/node/policies.db`, reached through `Home::policies_mut()` →
`policy::store::StoreWriter` (`profile.rs:719`). `config.json` holds only the
*default* policy, as `node.seedingPolicy`, and this change does not touch it.

So this piece writes two different stores, and the difference is observable:
only `node-config` sets `restartRequired`. A configuration change reaches the
node at its next start because the node reads `config.json` when it is
constructed; a seeding change applies at once because the node reads
`policies.db` as it works. That is the distinction a panel has to put in front
of the user, and it is the reason these are two capabilities rather than one.

**The same paragraph was wrong about a second thing: there is no
"persistent peers" list.** The addresses live in `connect`
(`IndexSet<ConnectAddress>`), and `peers` is only a `{"type":"static"|"dynamic"}`
discipline — a fact the surface has to expose as two separate fields, because a
caller reaching for `peers` with a list of addresses has the right idea in the
wrong field. `parse_peers` says exactly that when handed an array.

Two details the store's API makes easy to get wrong:

- **The `seeding` table holds block rows as well as allow rows.**
  `seed_policies()` returns every row (`store.rs:320`), and a `Block` row is
  not a seeded repository. `list_seeded` filters on `policy.is_allow()`;
  without that filter a blocked RID would be reported as seeded, which is the
  opposite of what it is.
- **`Store::seed`/`unseed` return `change_count() > 0`, not "it is now so".**
  Re-seeding at the same scope changes no row and returns `false`
  (`store.rs:136-147`). `seedRepo` therefore does not report that boolean —
  the spec's success shape is the policy, and "you asked for a scope it already
  had" is not a failure. `unseedRepo` *does* report it, because
  `{"unseeded":bool}` is precisely the distinction the spec asks for and a
  `DELETE`'s change count answers it exactly.

### `listen` is honoured at both sites, and `listening` is what was bound

`node.rs` overrode the configuration in two places: `config.listen = vec![]`
before handing the config to `Runtime::init`, and a second `vec![]` as `init`'s
own `listen` argument. Both now carry the configured value.

**Changing one without the other leaves the config honoured in name only, and
this was measured both ways.** With only the `config.listen` field carrying the
value and `init`'s argument left as `vec![]`,
`a_configured_listen_address_is_what_the_node_binds` fails with
`"listening":[]` — the argument is what reaches `bind`, and the config field is
only what the node advertises about itself. Reinstating the original override at
the first site turns *two* tests red, and the second is the one worth naming:
`a_listen_port_that_cannot_be_bound_fails_the_start_rather_than_falling_back`
shows the old code reporting `"started":true` for a port it never tried to bind.
That is the failure shape this change removes — success reported for a
configuration that was discarded.

Outbound-only remains the default, because it is the default *in the file*: a
home whose `config.json` has never set `listen` deserializes it as `vec![]`
(`#[serde(default)]`). That is a better guarantee than the override was — the
default now comes from the same place a user's choice would, so there is one
mechanism rather than a default that silently outranks a setting.

`listening` in the start reply is built from `runtime.local_addrs`, which is
what the reactor actually bound. It was already so, and it is now load-bearing
rather than incidental: the spec requires two configurations to produce two
different bound states, which a reply echoing its own input satisfies whether
the configuration was honoured or ignored.

**This reasoning moved out of `docs/PLAN.md`**, whose `listen: []` paragraph
is now struck through and points here.

### The mode decides which methods are allowed, on the C++ side

Neither capability's methods take a home. `radicle_impl.cpp` resolves it from
the mode in force, exactly as `startNode` and `createEmbeddedIdentity` already
do, and the refusals are the mode's:

| Mode | `getNodeConfig` / `listSeeded` | `setNodeConfig` / `seedRepo` / `unseedRepo` |
|---|---|---|
| `explore` | refused, naming the mode | refused, naming the mode |
| `local` | allowed | refused, naming the mode |
| `embedded` | allowed | allowed |

`local` is readable but not writable because the home is the user's own: this
module did not create that node and does not run it, and writing there changes
the configuration of something outside its control. Reading it is what lets a
view show the user what their own node is set to.

The gate is in C++ rather than in Rust because that is where the mode lives —
the Rust side takes a home path and has no opinion about how it was chosen,
which is the same split `startNode` uses and the reason
`Profile::load()` is not called anywhere in `rust-ffi`.

### `restartRequired` compares against what the running node started with

`getNodeConfig` reports `restartRequired` true exactly when a node is running
**and** the configuration on disk differs from the one that node was started
with. It is not "a write happened since the node started": a write that changes
nothing, or one that is undone, must not leave a restart banner up for ever.

`node.rs` therefore records the configuration it started with — `Node.started_with` —
alongside the home and socket it already keeps. The comparison is against that
snapshot, so stopping and starting the node clears the flag by construction
rather than by anyone remembering to reset it.

**It is read inside `nodeconfig::get`/`set` rather than passed in, and the
ordering is why.** The flag has to be read *after* a write, or a panel that
saved a change and re-rendered from the reply would show no banner for a change
the running node has not picked up. An earlier draft made it a `bool` parameter
on the FFI boundary, filled by the C++ side; that put a correctness-critical
ordering in the hands of every caller, and the first caller written got it
wrong. Computing it at the point the reply is assembled makes the ordering
unrepresentable-wrong, and removes the only non-string argument the FFI boundary
would have had. `a_configuration_change_while_a_node_runs_asks_for_a_restart_and_a_restart_clears_it`
asserts the write's own reply carries `true`, which is the assertion that would
have caught the earlier shape.

### The new C++ class is bound to a home, and is none of the three that existed

`NodeConfig` is a new class rather than methods on an existing one, and each
candidate was rejected for a different reason:

- **`LocalReader`** reads repository storage and says so in its own doc comment.
  Three of these five methods write, and two write to SQLite rather than to git
  storage at all.
- **`LocalWriter`** takes a home *and a socket*, and every method on it needs a
  signing key — a write there appends to a COB's operation DAG and announces it.
  None of that applies: neither store is signed, neither is announced, and the
  socket would be an unused member.
- **`EmbeddedNode`** is static because **the node is process-global and there is
  at most one**. A configuration and a policy store belong to a *home*, and two
  homes have two of each. Making these static would assert the opposite of what
  is true and give up the one thing an instance buys — being bound to the home
  `LocalStore` resolved, so no call site can pass a different one.

### `rebuildFromSettings()` exists because the fourth guard was about to be written

Two sites repointed `RadicleImpl` at a different profile by spelling the rebuild
out by hand, and this change adds a fourth home-derived member. That is exactly
the signal CLAUDE.md names: a hand-written guard about to be copied again, where
the copy that is forgotten keeps answering for the previous profile with nothing
failing. One method, one list.

**`setDependenciesForTest` deliberately does not call it**, and the comment there
says why: that method derives the store *from the settings*, which would discard
the store a test injected. Collapsing the two is the obvious next move and would
make an injected store silently ignored — the kind of change that leaves every
test green while testing the wrong home.

## Unspecified behaviour chosen here

Three things the spec does not say, each chosen to keep moving and each marked
`NO SPEC:` at its test so the spec-writer can evaluate it rather than inherit it
by accident:

- **`seedRepo`'s success shape.** The spec gives `listSeeded`'s and
  `unseedRepo`'s and not this one. `{"rid":…,"scope":…}` was chosen — the policy
  that now holds, which is what a view re-renders from. It deliberately does not
  report the store's `change_count()` boolean, because that is `false` for a
  re-seed at the same scope, which is success.
- **A `config.json` that parses but has no `node` section.** Covered as an error
  naming the file, on the same reasoning as the unparseable case: an empty
  configuration on screen is indistinguishable from a real one.
- **An exposed field holding the wrong JSON type on a READ.** Rendered as empty
  rather than failing the whole read, so a `getNodeConfig` does not decline to
  show four good fields because a fifth is odd. A *write* of the same value is
  still refused, which is the case that matters.

## Risks / Trade-offs

- **Raw JSON editing means this module owns the shape of a write.** If the
  crate changes how a field serializes, a round-trip would have followed it and
  this does not. The mitigation is the validate-before-write step: the edited
  `Value` must deserialize into `radicle::profile::Config` or the write is
  refused, so a shape the crate cannot read never reaches disk.
- **`restartRequired` cannot see a node started by anything else.** It compares
  against the configuration *this process's* node was started with, so a node
  the user started from a terminal reports `restartRequired` false. That is
  consistent with `getNodeStatus`, which is also about this process's node, and
  it is the honest answer: the module does not know what an outside node read
  at its start.
