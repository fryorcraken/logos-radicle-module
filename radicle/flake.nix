{
  description = "Radicle core module — seed-node and local-node repository access";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder/0.2.6";

    # Used for ONE thing: fetching the Rust crate's dependencies. The builder's
    # own pinned nixpkgs (25.11, Sept 2025) has a `fetchCargoVendor` whose
    # downloader sends no User-Agent, and crates.io answers those with HTTP
    # 403 — which surfaces as "cannot download crate-<arbitrary>.tar.gz from
    # any mirror" and looks like a dead mirror rather than a policy. The
    # current fetcher sets one. Nothing from this input ends up in the built
    # artefact: it produces a vendor directory of crate *sources*, which the
    # builder's own rustPlatform then compiles, so there is no risk of the two
    # nixpkgs' libc or OpenSSL meeting.
    nixpkgs-fetch.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = inputs@{ logos-module-builder, nixpkgs-fetch, ... }:
    let
      # The builder's own pinned nixpkgs, reached through its inputs rather
      # than declared separately: the Rust staticlib is linked into the plugin
      # the builder compiles, so both must come from one nixpkgs or the two
      # halves see different libc/libgit2/openssl.
      nixpkgs = logos-module-builder.inputs.nixpkgs;
      lib = nixpkgs.lib;

      # ── The local-node backend ────────────────────────────────────────────
      #
      # `radicle/rust-ffi/` compiles to a staticlib the C++ module links, so
      # `local*` can read ~/.radicle through the `radicle` crate. It is built
      # here rather than through the builder's own `codegen.rust` path because
      # that path is for Rust-*authored* modules: it generates the
      # `logos_module_*` C ABI scaffold from a LIDL contract and links the
      # logos-rust-sdk. This module is C++-authored (`interface: "universal"`,
      # whose codegen derives its LIDL from `radicle_impl.h`), and the crate is
      # a plain FFI helper behind that — setting `codegen.rust` would make the
      # builder look for a `codegen.lidl` a universal module never has.
      #
      # Dependencies are vendored by one fixed-output derivation, which is what
      # keeps the build itself offline as the Nix sandbox requires. The
      # vendoring is done by `nixpkgs-fetch` (see the input's comment for why)
      # while the *compile* uses the builder's pinned rustPlatform, so the
      # staticlib and the plugin it links into still come from one toolchain.
      #
      # The cost is a `hash` that must be updated whenever Cargo.lock changes.
      # A stale one fails loudly, printing the value it expected, so it cannot
      # drift silently.
      rustFfiFor = system:
        let
          pkgs = import nixpkgs { inherit system; };
          fetchPkgs = import nixpkgs-fetch { inherit system; };
          # The builder's pinned nixpkgs ships rustc 1.89, which cannot compile
          # `radicle` 0.25.1 — it fails on match ergonomics in the crate's own
          # `cob/identity.rs` ("use of moved value: `action`"), an error in
          # library code this module cannot patch. The newer nixpkgs' rustc
          # compiles it, so the toolchain comes from there.
          #
          # This is a compiler, not a runtime dependency: what crosses into the
          # plugin is a static archive of machine code plus the C ABI in
          # `src/radicle_ffi.h`. It links against the same glibc either way,
          # because `buildRustPackage`'s stdenv is still the builder's.
          rustPlatform = pkgs.makeRustPlatform {
            cargo = fetchPkgs.cargo;
            rustc = fetchPkgs.rustc;
          };
        in
        rustPlatform.buildRustPackage {
          pname = "radicle-local-ffi";
          # Hand-mirrors `rust-ffi/Cargo.toml`'s `version`, and nothing checks
          # that they agree — buildRustPackage does not read it back. Leaving
          # the crate at 0.1.0 across a *module* version bump is correct, not
          # an oversight: it is `publish = false` and located by path, so its
          # number names nothing anyone resolves. Only bump it if the crate's
          # own API changes in a way worth naming.
          version = "0.1.0";
          src = ./rust-ffi;
          cargoDeps = fetchPkgs.rustPlatform.fetchCargoVendor {
            src = ./rust-ffi;
            hash = "sha256-sbh9xX8T/NaCibhw4tQfppkODZHTKW1qOEmFg7WEkwc=";
          };
          # libgit2-sys / libssh2-sys / openssl-sys need these to find system
          # libraries rather than vendoring their own copies.
          nativeBuildInputs = [ pkgs.pkg-config ];
          buildInputs = [ pkgs.openssl pkgs.zlib ];
          # The crate's own tests build real Radicle profiles on disk. They run
          # in `cargo test` and in CI, not here: keeping them out of the module
          # build means a plugin rebuild does not pay for them, and a test
          # failure surfaces in the job that is about tests.
          doCheck = false;
        };

      # ── Getting the RIGHT staticlib into a per-system build ───────────────
      #
      # This is the part that was broken until 0.2.1, and the fix is not the
      # one the comment here used to describe. Both are worth writing down,
      # because the wrong one looks obviously right.
      #
      # The constraint: `mkLogosModule` fans out over four systems
      # (aarch64-darwin, x86_64-darwin, aarch64-linux, x86_64-linux) but takes
      # `preConfigure` as ONE value shared by all of them. It is spliced into
      # each per-system derivation unchanged, and its function form receives
      # only `{ externalLibs }` — never the system. So a caller cannot simply
      # hand it a per-system store path, and `stageRustFfi "x86_64-linux"`
      # baked the amd64 archive into all four. arm64 then failed in the module
      # catalog's release workflow in ~65s: not a slow cross-compile, but Nix
      # declining to realise an x86_64 derivation with no x86_64 builder.
      #
      # THE OBVIOUS FIX THAT DOES NOT WORK, so nobody re-tries it: emit a
      # `case "$system" in` over the supported systems and let the shell pick
      # its own arm at build time. `$system` really is in the builder env
      # (verified: `aarch64-linux` in the aarch64 derivation), so it looks
      # sound. It is not. Every arm's store path sits in the string, so EVERY
      # arm is an inputDrv of EVERY system's derivation, whether or not it
      # runs. Nix therefore tries to build the aarch64 staticlib before running
      # an x86_64 build, and `nix build .#packages.x86_64-linux.lgx` fails on
      # this machine with "Required system: 'aarch64-linux'". That trades an
      # arm64 failure for an amd64 one — strictly worse than the bug.
      #
      # WHAT ACTUALLY WORKS: `externalLibInputs`, the builder's own per-system
      # escape hatch. `resolveExtInput` resolves each entry as
      # `value.packages.${system}.default` INSIDE the per-system `let`
      # (mkLogosModule.nix:219), and `mkExternalLib.buildExternalLibs` passes a
      # value that is already a derivation straight through
      # (mkExternalLib.nix:115-117). The resolved result reaches `preConfigure`
      # as `{ externalLibs }`. So one staticlib is selected per system, and
      # only that one is an inputDrv — which is the property the `case` cannot
      # have.
      #
      # The entry is shaped like a flake (`{ packages.<system>.default = …; }`)
      # rather than being one; `resolveExtInput` only checks for that attr path,
      # so this stays a plain attrset in this file with no self-reference.
      #
      # The STRUCTURED form (`{ input = …; }`) is used rather than the bare one
      # for the sake of the error message on an unsupported system. Given a
      # bare value, `resolveExtInput`'s last line falls through to `else value`
      # and hands the raw attrset on, which surfaces much later and much less
      # helpfully as "cannot coerce a set to a string". The structured form
      # takes the `throw` branch instead and names the missing
      # `packages.<system>.default` — so a Darwin build says which platform is
      # unsupported rather than leaking this attrset into a shell script.

      # Linux only, and deliberately: the crate links a native libgit2/openssl
      # through the *-sys crates, so a Darwin entry would mean cross-compiling
      # Rust for Darwin from a Linux builder. Nothing needs that. A Darwin
      # build now fails in `resolveExtInput` with the builder's own
      # "does not provide packages.<system>.default" message, which names the
      # unsupported platform instead of silently linking a Linux archive.
      ffiSystems = [ "x86_64-linux" "aarch64-linux" ];

      rustFfiInput = {
        input = {
          packages = lib.genAttrs ffiSystems (system: {
            default = rustFfiFor system;
          });
        };
      };

      # Nothing stages the archive by hand any more, and that is the point:
      # declaring it as an external lib makes BOTH builds stage it themselves,
      # per-system, before any hook of ours runs.
      #
      #   - the plugin build: logos-plugin-qt's own "Copy external libraries"
      #     block emits `mkdir -p lib` + a `cp` of every resolved entry
      #   - the unit-test build: `mkLogosModuleTests` composes its preConfigure
      #     with `copyExternals = true`, which emits the same thing
      #
      # Both land it in exactly the `lib/` that the two CMakeLists.txt files
      # already search with `find_library`, so no `preConfigure` is needed on
      # either side and no store path is chosen at eval time.
      #
      # Do NOT add a `cp` of your own back on top. The builder's copy arrives
      # mode-444 from the store, so a second one fails the build outright with
      # "cp: cannot create regular file 'lib/libradicle_local_ffi.a':
      # Permission denied" — which is how this was found.
      #
      # This also means `tests.extraCmakeFlags` no longer carries an absolute
      # store path. It used to, and that was the same per-system bug in a
      # second place: mkLogosModule resolves `tests` OUTSIDE its
      # `forAllSystems`, so all four `checks.<system>.unit-tests` shared one
      # list, and unlike a shell string there is nothing in a cmake flag to
      # resolve at build time.
    in
    logos-module-builder.lib.mkLogosModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
      # Keyed by the `name` of the `nix.external_libraries` entry in
      # metadata.json — that entry is what makes the builder resolve this at
      # all, so the two must keep the same spelling.
      externalLibInputs.radicle_local_ffi = rustFfiInput;
      tests = {
        dir = ./tests;
        # The C++ unit tests link the same staticlib the plugin does, so the
        # FFI boundary is exercised at the C++ layer and not only through Rust.
        # They need no staging of their own — see the note above.
        # zlib, for the libgit2 inside that archive. The plugin build gets it
        # transitively through Qt6::Network; this one has to ask.
        #
        # STILL HARDCODED to x86_64-linux, and this is the one site the fix
        # above does not reach: `extraBuildInputs` is resolved outside
        # `forAllSystems` and is not an `externalLibInputs` entry, so nothing
        # selects it per system. `checks.aarch64-linux.unit-tests` therefore
        # still asks for an x86_64 zlib and will not realise on an arm64
        # machine.
        #
        # Left as-is deliberately, because unlike the plugin build nothing
        # depends on it: `checks` are not part of the release path — CI runs
        # only `checks.x86_64-linux.unit-tests`, and the module catalog builds
        # `packages.<system>.lgx`, which this does not touch. Fixing it
        # properly means either an upstream per-system `tests` hook or calling
        # mkLogosModule once per system, both of which are more change than the
        # arm64 regression warrants. Revisit if the unit tests ever need to run
        # on arm64.
        extraBuildInputs = [ (import nixpkgs { system = "x86_64-linux"; }).zlib ];
      };
    };
}
