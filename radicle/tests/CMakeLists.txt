cmake_minimum_required(VERSION 3.14)
project(RadicleModuleTests LANGUAGES CXX)

include(LogosTest)

# Guard against the exact regression that shipped once already: this module
# has "interface": "universal" and no `.rep` file, so
# logos-cpp-generator/logos-qt-generator derives the module's RPC dispatch
# table by scanning src/radicle_impl.h's `public:` section for callable
# members. A public constructor that TAKES PARAMETERS (even all-defaulted
# ones, so it is callable with zero arguments) is textually
# `RadicleImpl(<something>)`, and the generator does not exclude constructors
# from that scan — it reads that as a zero-arg RPC method named RadicleImpl
# and emits a bogus `lidlImpl().RadicleImpl()` dispatch case that fails to
# compile. A genuinely PARAMETERLESS public `RadicleImpl()` is fine — it is
# what generated_code's own `static RadicleImpl impl;` needs, and is not
# scanned as a candidate method (verified empirically: a plain nix build
# with only that constructor present compiles and links). So the check below
# flags only a public `RadicleImpl(` with something other than a bare `()`
# — the parameterized shape — not the parameterless one.
#
# This suite (logos_test(), above) compiles radicle_impl.cpp directly via
# MODULE_SOURCES and never invokes the generator or touches generated_code/,
# so it structurally cannot see that bug — only `nix build '.#lgx'`
# (the real logos_module() plugin build, in ../CMakeLists.txt) does, because
# only that path runs the generator. This check closes that gap cheaply, at
# configure time, without needing a full plugin build: a plain text search
# over the header. It is necessarily a narrower net than actually running the
# generator — it cannot see every way a header could confuse a
# text-scanning codegen, only this specific, already-shipped-once shape —
# but it is a one-line-of-CMake price for catching a regression that
# otherwise waits for a full `lgx` build (or a release) to surface.
file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/../src/radicle_impl.h"
     RADICLE_IMPL_H_LINES)
set(RADICLE_IMPL_IN_PUBLIC_SECTION FALSE)
foreach(LINE IN LISTS RADICLE_IMPL_H_LINES)
    if(LINE MATCHES "^[ \t]*class[ \t]+RadicleImpl[ \t]*:")
        set(RADICLE_IMPL_IN_PUBLIC_SECTION FALSE)
    elseif(LINE MATCHES "^[ \t]*public:[ \t]*$")
        set(RADICLE_IMPL_IN_PUBLIC_SECTION TRUE)
    elseif(LINE MATCHES "^[ \t]*(private|protected|logos_events):[ \t]*$")
        set(RADICLE_IMPL_IN_PUBLIC_SECTION FALSE)
    elseif(RADICLE_IMPL_IN_PUBLIC_SECTION AND LINE MATCHES "^[ \t]*(explicit[ \t]+)?RadicleImpl[ \t]*\\([ \t]*[^) \t]")
        message(FATAL_ERROR
            "src/radicle_impl.h declares a public RadicleImpl(...) constructor "
            "that TAKES PARAMETERS, in its `public:` section: '${LINE}'. This "
            "module has \"interface\": \"universal\" and no .rep file, so its "
            "RPC dispatch table is derived by scanning that section, and a "
            "public, parameterized constructor (even all-defaulted, so "
            "callable with zero arguments) is misread as a zero-arg method "
            "named RadicleImpl — it compiled here (this suite never runs the "
            "generator) but WILL break `nix build '.#lgx'` with 'invalid use "
            "of RadicleImpl::RadicleImpl' in "
            "generated_code/radicle_module_impl.cpp. Keep the public "
            "constructor genuinely parameterless — `RadicleImpl();` — which "
            "generated_code's own `static RadicleImpl impl;` needs and which "
            "is NOT scanned as a candidate method, and add any test-only "
            "dependency injection through a differently-named, non-constructor "
            "method instead — see setDependenciesForTest() and its doc "
            "comment in radicle_impl.h.")
    endif()
endforeach()

# AUTOMOC needs metadata.json alongside the sources it moc's.
configure_file(${CMAKE_CURRENT_SOURCE_DIR}/../metadata.json
               ${CMAKE_CURRENT_BINARY_DIR}/metadata.json COPYONLY)

# Unit tests for the pure logic — URL building, ref resolution, pagination,
# error shapes and local-profile detection. These do not hit the network:
# anything that would is exercised through the seam in test_seed_client.cpp.
#
# The local-reader tests DO touch the filesystem, deliberately: they build a
# scratch Radicle home and read it back through the same Rust archive the
# module links, which is the only way to prove the FFI boundary and the JSON
# shapes at this layer rather than trusting the Rust-side tests alone.
#
# radicle_impl.cpp (RadicleImpl, the module's actual public API surface) is
# tested here too, in test_radicle_impl.cpp. It used to be missing from this
# list entirely, and its dependencies (SeedClient/LocalStore/LocalReader/
# LocalWriter) were function-local `static`s constructed once per process —
# together that made the 28-method API untestable: no test file exercised it,
# and even a test that tried to would have been at the mercy of whichever
# other test happened to build the singletons first. RadicleImpl now takes its
# dependencies through its constructor (defaulted for production callers), so
# each test builds its own independent instance.
#
# radicle_impl_events_test.cpp supplies test-only bodies for RadicleImpl's
# `logos_events:` methods (remoteSeedChanged/localAvailabilityChanged) — see
# logos_test_events.h. A universal-module unit test constructs the impl
# directly with no Qt provider, so the codegen-emitted `_events.cpp` that
# normally implements those methods is never linked in; without a forwarder
# body here, linking radicle_module_tests fails with an undefined reference.
logos_test(
    NAME radicle_module_tests
    MODULE_SOURCES
        ../src/radicle_impl.cpp
        ../src/seed_client.cpp
        ../src/local_store.cpp
        ../src/local_reader.cpp
        ../src/local_writer.cpp
        # Not just an incidental link target: test_http_client.cpp exercises
        # this file's pure isGenuineTimeout()/applyHttpOutcome() directly.
        # It also stays linked for SeedClient, which references httpGet as
        # its default even in tests that inject their own transport.
        ../src/http_client.cpp
    TEST_SOURCES
        main.cpp
        radicle_impl_events_test.cpp
        test_radicle_impl.cpp
        test_seed_client.cpp
        test_http_client.cpp
        test_local_store.cpp
        test_local_reader.cpp
        test_local_writer.cpp
    EXTRA_INCLUDES
        ../src
)

# The Rust local-node backend, found rather than handed over as an absolute
# path. It used to arrive as `-DRADICLE_RUST_FFI_LIB=<store path>` from
# flake.nix's `tests.extraCmakeFlags`, but that list is ONE value shared by
# every `checks.<system>.unit-tests` the builder generates, so the store path
# it named was whichever system evaluated — the same per-system bug that made
# the aarch64 plugin link an amd64 archive.
#
# The archive is now declared as a `nix.external_libraries` entry, which the
# test builder resolves per-system and stages into the source root's `lib/`
# before this file is read. cmake is invoked from `build/` with this directory
# as its source, so that staged copy sits one level up.
#
# Searched for, like the plugin build's own CMakeLists.txt does, so a missing
# archive is a sentence at configure time rather than a wall of undefined
# `radicle_local_*` symbols at link time.
find_library(RADICLE_RUST_FFI_LIB
    NAMES libradicle_local_ffi.a radicle_local_ffi
    PATHS "${CMAKE_CURRENT_SOURCE_DIR}/../lib"
    NO_DEFAULT_PATH
)
if(NOT RADICLE_RUST_FFI_LIB)
    message(FATAL_ERROR
        "The Rust local-node backend (libradicle_local_ffi.a) was not found in "
        "${CMAKE_CURRENT_SOURCE_DIR}/../lib. The local-reader tests link it; "
        "the nix build stages it there from metadata.json's "
        "nix.external_libraries entry. Building these tests directly, outside "
        "`nix build`, needs "
        "`cargo build --release --manifest-path rust-ffi/Cargo.toml` and the "
        "resulting archive copied into lib/ first.")
endif()
# zlib is named explicitly here but not in the plugin build, which picks it up
# transitively through Qt6::Network. The archive's libgit2 needs it
# (`inflateEnd`), and a single-pass linker only resolves symbols from libraries
# that appear *after* the archive that wants them — hence the ordering.
find_package(ZLIB REQUIRED)
target_link_libraries(radicle_module_tests PRIVATE
    ${RADICLE_RUST_FFI_LIB}
    ZLIB::ZLIB
    pthread
    dl
    m
)
