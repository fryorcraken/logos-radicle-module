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

# All Radicle business logic lives in this module: HTTP to seed nodes, JSON
# parsing, SHA resolution and local-profile detection. UI modules are thin
# views over the API in src/radicle_impl.h.
#
# Qt6Network supplies the HTTP client. Qt Core and RemoteObjects are linked by
# logos_module() already; Network is the one extra component we need.
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
    FIND_PACKAGES
        Qt6Network
    LINK_LIBRARIES
        Qt6::Network
    INCLUDE_DIRS
        src
)
