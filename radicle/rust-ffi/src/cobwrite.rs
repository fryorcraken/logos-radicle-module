//! Writing Collaborative Objects: the first thing in this module that changes
//! state rather than reporting it.
//!
//! Kept apart from `cobs.rs` deliberately. That module's contract is that it
//! cannot write — it opens every store with `store::access::ReadOnly`, a
//! zero-field unit struct that holds no signer, which is what lets local
//! browsing work with an encrypted key and no agent. Putting a write beside it
//! would make that guarantee a matter of reading each function rather than
//! reading one file, and the guarantee is load-bearing: a read path that could
//! prompt for a passphrase would break offline browsing.
//!
//! Three things a write needs that a read does not, all confirmed against the
//! crate rather than assumed (see `docs/M2.2-write-actions-design.md`):
//!
//! 1. **A signer**, via `WriteAs::new(&signer)`. `signer()` below is the whole
//!    story of where one comes from, and why it can fail.
//! 2. **A cache handle.** Every mutating method takes `&mut impl
//!    cob::cache::Update`. `NoCache` satisfies it, so M2.1's decision to own no
//!    SQLite file carries over unchanged.
//! 3. **Nothing else.** A COB write is a purely local git operation — there is
//!    no `announce` anywhere under the crate's `cob/` module. Telling the
//!    network is a separate, optional step; see `announce()`.

use radicle::cob::store::access::WriteAs;
use radicle::cob::{issue, thread};
use radicle::crypto::ssh::Keystore;
use radicle::storage::git::Repository;
use serde_json::json;

use crate::local::{error, open_storage, parse_rid};

/// Load a signer for the local node's key.
///
/// This mirrors `Profile::signer()` (`radicle-0.25.1/src/profile.rs:324`)
/// rather than calling it, for the same reason `local::open_storage` mirrors
/// `Profile::load()`: `Profile::load` resolves `RAD_HOME`/`HOME` itself
/// (redundant — the C++ side already did that, and doing it twice is how the
/// two drift), opens databases, and runs a COB cache migration. A module that
/// posts one comment should not migrate the user's SQLite cache as a side
/// effect.
///
/// The source selection is copied exactly, because it is the whole of the
/// signing UX:
///
/// - plaintext keystore -> load it, no prompt;
/// - encrypted + `RAD_PASSPHRASE` -> decrypt it, no prompt;
/// - encrypted, no env var -> ssh-agent, which is where `rad auth` puts the
///   key and therefore the ordinary case.
///
/// The fourth case — encrypted, no env var, agent does not hold the key — is
/// the only one that genuinely needs a passphrase prompt, and this module does
/// not have one. It returns an error naming the fix instead of failing
/// obscurely at signing time, because `can_write` is what the UI asks before
/// it offers a compose box at all.
fn signer(home: &str) -> Result<radicle::profile::Signer, String> {
    let keys_dir = std::path::Path::new(home).join("keys");
    let keystore = Keystore::new(&keys_dir);

    let public = keystore
        .public_key()
        .map_err(|e| format!("could not read the local node key: {e}"))?
        .ok_or_else(|| format!("no Radicle key found at {}", keys_dir.display()))?;

    let encrypted = keystore
        .is_encrypted()
        .map_err(|e| format!("could not read the local node key: {e}"))?;

    if !encrypted {
        let key = radicle::crypto::SigningKey::load(&keystore, None)
            .map_err(|e| format!("could not load the local node key: {e}"))?;
        return Ok(radicle::profile::Signer::Key(key));
    }

    if let Ok(passphrase) = std::env::var("RAD_PASSPHRASE") {
        let key = radicle::crypto::SigningKey::load(
            &keystore,
            Some(radicle::crypto::ssh::keystore::Passphrase::from(passphrase)),
        )
        .map_err(|e| format!("RAD_PASSPHRASE did not decrypt the local node key: {e}"))?;
        return Ok(radicle::profile::Signer::Key(key));
    }

    // "An agent is running" and "the agent holds this key" are different
    // facts, and only the second makes a write signable — so both failures are
    // reported separately, and both name the command that fixes them.
    let agent = radicle::crypto::ssh::agent::Agent::connect().map_err(|e| {
        format!(
            "your Radicle key is encrypted and ssh-agent is not reachable ({e}) \
             — run `rad auth` in a terminal to unlock it for this session"
        )
    })?;

    let verifying = (&public)
        .try_into()
        .map_err(|e| format!("the local node key is not a valid signing key: {e}"))?;

    let agent_signer = agent.into_signer(verifying).map_err(|e| {
        format!(
            "your Radicle key is encrypted and ssh-agent does not hold it ({e}) \
             — run `rad auth` in a terminal to unlock it for this session"
        )
    })?;

    Ok(radicle::profile::Signer::Agent(agent_signer))
}

/// Whether a write could succeed right now, and why not when it could not.
///
/// This exists so the UI can decide whether to *offer* a compose box, rather
/// than offering one and discovering at submit time that nothing can be
/// signed. Losing a composed comment to an error the user could have been
/// warned about is the specific failure this milestone must not have.
///
/// -> `{"canWrite":true,"nodeId":"z6Mk…"}`
/// -> `{"canWrite":false,"reason":"…"}`
///
/// Note it deliberately reports `canWrite:false` **with a 200-shaped body**
/// rather than an `{"error":...}`: "you cannot write" is an answer to the
/// question asked, not a failure to answer it. `getCapabilities` merges this
/// into its own reply.
pub fn can_write(home: &str) -> String {
    match signer(home) {
        Ok(s) => {
            use radicle::crypto::Signer as _;
            json!({
                "canWrite": true,
                "nodeId": radicle::identity::Did::from(*s.public_key()).to_string(),
            })
            .to_string()
        }
        Err(reason) => json!({ "canWrite": false, "reason": reason }).to_string(),
    }
}

fn open_repo_for_write(home: &str, rid: &str) -> Result<Repository, String> {
    let storage = open_storage(home)?;
    let id = parse_rid(rid)?;
    radicle::storage::ReadStorage::repository(&storage, id)
        .map_err(|e| format!("repository {rid} not found in local storage: {e}"))
}

/// Tell the node that this repository's refs moved, so it announces them.
///
/// Returns `None` on success, or the reason it could not, which the caller
/// reports **alongside a successful write rather than instead of one**. A COB
/// that is written locally but not yet announced is an ordinary Radicle state
/// — the node announces on next start — so reporting it as a failed write
/// would be wrong and would invite the user to post the same comment twice.
///
/// `Handle::announce_refs_for` is one control-socket round-trip. The richer
/// `Node::announce` subscribes to an event stream and blocks until seeds
/// acknowledge or a timeout expires, which is the wrong shape for a
/// synchronous FFI call that a UI thread is waiting on.
fn announce(home: &str, rid: &str) -> Option<String> {
    use radicle::node::Handle as _;

    let id = parse_rid(rid).ok()?;
    let socket = std::path::Path::new(home).join("node").join("control.sock");
    let mut node = radicle::node::Node::new(&socket);

    let nid = match node.nid() {
        Ok(nid) => nid,
        Err(e) => return Some(format!("the local node is not running ({e})")),
    };

    match node.announce_refs_for(id, [nid]) {
        Ok(_) => None,
        Err(e) => Some(format!("the local node did not announce the change ({e})")),
    }
}

/// Post a comment on an issue's discussion thread.
///
/// The comment lands on the thread root. `reply_to` is not a parameter
/// because `ThreadView.qml` renders a flat list and reads no `replyTo` — an
/// argument the view cannot supply and cannot display would be dead API, and
/// threaded replies are a UI feature first.
///
/// -> `{"id":"<entry id>","announced":bool[,"announceError":"…"]}`
pub fn comment_on_issue(home: &str, rid: &str, id: &str, body: &str) -> String {
    match comment_on_issue_inner(home, rid, id, body) {
        Ok(v) => v,
        Err(e) => error(e),
    }
}

fn comment_on_issue_inner(home: &str, rid: &str, id: &str, body: &str) -> Result<String, String> {
    // Refused here rather than by the store, which accepts an empty body
    // happily and produces a comment nothing renders. The UI disables its
    // button too; this is the backstop, because the UI is not the only caller.
    if body.trim().is_empty() {
        return Err("a comment needs a body".to_string());
    }

    let repo = open_repo_for_write(home, rid)?;
    let signer = signer(home)?;
    let oid = id
        .parse::<radicle::cob::ObjectId>()
        .map_err(|e| format!("invalid issue id '{id}': {e}"))?;

    let entry = {
        let mut store = issue::Issues::open(&repo, WriteAs::new(&signer))
            .map_err(|e| format!("could not open the issue store for writing: {e}"))?;
        let mut cache = radicle::cob::cache::NoCache;

        let mut issue = store
            .get_mut(&oid, &mut cache)
            .map_err(|e| format!("could not open issue {id}: {e}"))?;

        // The root comment id is the thread anchor. `root()` is infallible on
        // a loaded issue: an issue's first operation *is* its root comment, so
        // there is no "issue with no thread" state to handle.
        let root: thread::CommentId = *issue.root().0;

        issue
            .comment(body, root, [])
            .map_err(|e| format!("could not post the comment: {e}"))?
    };

    let announce_error = announce(home, rid);

    Ok(json!({
        "id": entry.to_string(),
        "announced": announce_error.is_none(),
        "announceError": announce_error,
    })
    .to_string())
}

/// Open a new issue.
///
/// `description` becomes the issue's root comment — that is how the crate
/// models it, and it is why `get_issue` returns the description as
/// `discussion[0].body` rather than as a field of its own.
///
/// Labels and assignees are not parameters. Both are real COB features, but
/// assignment is by DID and needs a peer picker the module does not have, and
/// neither is rendered anywhere today. Passing empty slices matches what the
/// `New issue` modal in Radicle Desktop does before its "Add labels" /
/// "Add assignees" buttons are used.
///
/// -> `{"id":"<issue id>","announced":bool[,"announceError":"…"]}`
///
/// Note `id` here is the **issue's** id, not an entry id — it is what a view
/// passes straight back to `localGetIssue` to open what was just created.
pub fn create_issue(home: &str, rid: &str, title: &str, description: &str) -> String {
    match create_issue_inner(home, rid, title, description) {
        Ok(v) => v,
        Err(e) => error(e),
    }
}

fn create_issue_inner(
    home: &str,
    rid: &str,
    title: &str,
    description: &str,
) -> Result<String, String> {
    // Validated before anything is opened, so a bad title costs no work and
    // cannot half-create anything.
    //
    // `Title::new` rejects a title containing `\n` or `\r` outright — not
    // merely trimming them. That is a live case rather than a theoretical one:
    // pasting a line of text into a single-line field carries the newline with
    // it, and the crate's error ("invalid characters in title") does not say
    // which character or what to do, so it is translated here into something
    // actionable.
    let title = radicle::cob::Title::new(title).map_err(|e| match e {
        radicle::cob::common::TitleError::EmptyTitle => "an issue needs a title".to_string(),
        radicle::cob::common::TitleError::InvalidTitle => {
            "an issue title must be a single line — remove the line break".to_string()
        }
    })?;

    // The crate would accept an empty description and produce an issue whose
    // thread opens with a blank comment. Refused for the same reason an empty
    // comment body is: the UI disables its button too, and the two must agree
    // on what counts as empty or the button offers what the write rejects.
    if description.trim().is_empty() {
        return Err("an issue needs a description".to_string());
    }

    let repo = open_repo_for_write(home, rid)?;
    let signer = signer(home)?;

    let id = {
        let mut store = issue::Issues::open(&repo, WriteAs::new(&signer))
            .map_err(|e| format!("could not open the issue store for writing: {e}"))?;
        let mut cache = radicle::cob::cache::NoCache;

        let issue = store
            .create(title, description, &[], &[], [], &mut cache)
            .map_err(|e| format!("could not create the issue: {e}"))?;
        issue.id().to_string()
    };

    let announce_error = announce(home, rid);

    Ok(json!({
        "id": id,
        "announced": announce_error.is_none(),
        "announceError": announce_error,
    })
    .to_string())
}
