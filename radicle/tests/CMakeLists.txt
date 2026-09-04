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
        # Linked even though the tests inject their own transport: SeedClient
        # still references httpGet as its default.
        ../src/http_client.cpp
    TEST_SOURCES
        main.cpp
        test_seed_client.cpp
        test_local_store.cpp
        test_local_reader.cpp
    EXTRA_INCLUDES
        ../src
)

# `RADICLE_RUST_FFI_LIB` is an absolute store path passed by flake.nix's
# `tests.extraCmakeFlags`. The test derivation is a separate build that gets no
# preConfigure staging of its own, so unlike the plugin build there is no
# `lib/` to search — the path is handed over directly.
if(NOT RADICLE_RUST_FFI_LIB)
    message(FATAL_ERROR
        "RADICLE_RUST_FFI_LIB was not set. The local-reader tests link the Rust "
        "backend; flake.nix passes its path via tests.extraCmakeFlags.")
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
