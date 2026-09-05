cmake_minimum_required(VERSION 3.14)
project(RadicleModuleTests LANGUAGES CXX)

include(LogosTest)

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
logos_test(
    NAME radicle_module_tests
    MODULE_SOURCES
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
