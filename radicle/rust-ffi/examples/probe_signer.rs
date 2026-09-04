//! Is this machine's Radicle key encrypted, and can a signer be obtained
//! without prompting?
//!
//! Not a test — it reads whatever is on this machine, so it can neither pass
//! nor fail meaningfully in CI. It exists because M2.2's whole scope hinges on
//! one empirical fact that cannot be assumed: `rad auth` writes the secret key
//! encrypted by default, and if this machine's is, `Profile::signer()` falls
//! back to `RAD_PASSPHRASE` and then to ssh-agent — neither of which a Basecamp
//! module has by default.
//!
//! Run with: cargo run --example probe_signer
//!
//! It reads only the *header* of the key file via `Keystore::is_encrypted`,
//! and never decrypts anything. The final step asks ssh-agent whether it holds
//! this profile's key, which is the difference between "an agent is running"
//! and "a write would actually be signable".

use radicle::crypto::ssh::Keystore;

fn main() {
    let home = std::env::var("RAD_HOME").unwrap_or_else(|_| {
        format!(
            "{}/.radicle",
            std::env::var("HOME").expect("HOME must be set")
        )
    });
    println!("home: {home}");

    let keys = std::path::Path::new(&home).join("keys");
    let keystore = Keystore::new(&keys);

    let public = match keystore.public_key() {
        Ok(Some(key)) => {
            println!("public key: {key}");
            key
        }
        Ok(None) => {
            println!("no public key — this is not a Radicle profile");
            return;
        }
        Err(e) => {
            println!("could not read public key: {e}");
            return;
        }
    };

    match keystore.is_encrypted() {
        Ok(true) => println!("secret key: ENCRYPTED (a passphrase or ssh-agent is required)"),
        Ok(false) => println!("secret key: PLAINTEXT (a signer loads with no passphrase)"),
        Err(e) => println!("could not determine encryption: {e}"),
    }

    println!(
        "RAD_PASSPHRASE in env: {}",
        std::env::var("RAD_PASSPHRASE").is_ok()
    );
    println!(
        "SSH_AUTH_SOCK in env: {:?}",
        std::env::var("SSH_AUTH_SOCK").ok()
    );

    // "An agent is running" and "the agent holds this key" are different
    // facts, and only the second one makes a write signable.
    match radicle::crypto::ssh::agent::Agent::connect() {
        Ok(agent) => {
            println!("ssh-agent: reachable");
            match (&public).try_into() {
                Ok(verifying) => match agent.into_signer(verifying) {
                    Ok(_) => println!("ssh-agent HOLDS this profile's key — writes are signable"),
                    Err(e) => println!("ssh-agent does NOT hold this profile's key: {e}"),
                },
                Err(e) => println!("public key is not a valid verifying key: {e}"),
            }
        }
        Err(e) => println!("ssh-agent: unreachable ({e})"),
    }
}
