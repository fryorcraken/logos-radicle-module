cmake_minimum_required(VERSION 3.14)
project(RadicleModulePlugin LANGUAGES CXX)

if(DEFINED ENV{LOGOS_MODULE_BUILDER_ROOT})
    include($ENV{LOGOS_MODULE_BUILDER_ROOT}/cmake/LogosModule.cmake)
elseif(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/cmake/LogosModule.cmake")
    include(cmake/LogosModule.cmake)
else()
    message(FATAL_ERROR "LogosModule.cmake not found")
endif()

# Derive the module name from metadata.json — single source of truth.
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/metadata.json" METADATA_JSON)
string(JSON MODULE_NAME GET ${METADATA_JSON} name)

# The Rust local-node backend. `flake.nix` compiles `rust-ffi/` with
# buildRustPackage and its preConfigure drops the archive into `lib/` before
# cmake runs, so by the time this file is read the file is simply there.
#
# Searched for rather than assumed so a build without it fails at configure
# time with a sentence, instead of at link time with a wall of undefined
# `radicle_local_*` symbols.
find_library(RADICLE_LOCAL_FFI
    NAMES libradicle_local_ffi.a radicle_local_ffi
    PATHS "${CMAKE_CURRENT_SOURCE_DIR}/lib"
    NO_DEFAULT_PATH
)
if(NOT RADICLE_LOCAL_FFI)
    message(FATAL_ERROR
        "The Rust local-node backend (libradicle_local_ffi.a) was not found in "
        "${CMAKE_CURRENT_SOURCE_DIR}/lib. It is built and staged by flake.nix's "
        "preConfigure; building this CMake project directly, outside `nix build`, "
        "needs `cargo build --release --manifest-path rust-ffi/Cargo.toml` and the "
        "resulting archive copied into lib/ first.")
endif()

# All Radicle business logic lives in this module: HTTP to seed nodes, reads of
# the local node's storage, JSON parsing, SHA resolution and local-profile
# detection. UI modules are thin views over the API in src/radicle_impl.h.
#
# Qt6Network supplies the HTTP client. Qt Core and RemoteObjects are linked by
# logos_module() already; Network is the one extra component we need.
#
# The Rust archive brings its own transitive needs: libgit2 and openssl are
# statically linked into it by the *-sys crates, but the Rust standard library
# still wants pthread/dl/m, and openssl-sys wants zlib. Naming them after the
# archive matters for single-pass linkers, which only resolve symbols from
# libraries mentioned later on the command line.
logos_module(
    NAME ${MODULE_NAME}
    SOURCES
        src/radicle_impl.h
        src/radicle_impl.cpp
        src/seed_client.h
        src/seed_client.cpp
        src/http_client.h
        src/http_client.cpp
        src/local_store.h
        src/local_store.cpp
        src/local_reader.h
        src/local_reader.cpp
        src/local_writer.h
        src/local_writer.cpp
        src/radicle_ffi.h
    FIND_PACKAGES
        Qt6Network
    LINK_LIBRARIES
        Qt6::Network
        ${RADICLE_LOCAL_FFI}
        pthread
        dl
        m
    INCLUDE_DIRS
        src
)
