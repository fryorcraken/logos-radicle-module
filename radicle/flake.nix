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

      # `preConfigure` is a single string shared by every system the builder
      # supports, so it cannot name a per-system store path directly. Emitting
      # one `case` arm per system would make all four staticlibs dependencies
      # of every build — including cross-building Rust for Darwin from Linux,
      # which is not something this module needs. Instead the shell resolves
      # its own platform at build time and copies the one path that exists;
      # `lib.optionalString` keeps the arms for other systems out of the
      # string entirely.
      #
      # Concretely: only the arms for systems whose staticlib Nix can actually
      # realise are emitted, and the plugin build runs on exactly one of them.
      stageRustFfi = system: ''
        mkdir -p lib
        cp ${rustFfiFor system}/lib/libradicle_local_ffi.a lib/
        chmod u+w lib/libradicle_local_ffi.a
      '';
    in
    logos-module-builder.lib.mkLogosModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
      preConfigure = stageRustFfi "x86_64-linux";
      tests = {
        dir = ./tests;
        # The C++ unit tests link the same staticlib, so the FFI boundary is
        # exercised at the C++ layer and not only through Rust. The test
        # derivation is a separate build that gets none of the plugin build's
        # preConfigure staging, so the archive's path is handed over directly
        # rather than found in `lib/`.
        extraCmakeFlags = [
          "-DRADICLE_RUST_FFI_LIB=${rustFfiFor "x86_64-linux"}/lib/libradicle_local_ffi.a"
        ];
        # zlib, for the libgit2 inside that archive. The plugin build gets it
        # transitively through Qt6::Network; this one has to ask.
        extraBuildInputs = [ (import nixpkgs { system = "x86_64-linux"; }).zlib ];
      };
    };
}
