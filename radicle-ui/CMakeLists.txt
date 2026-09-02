cmake_minimum_required(VERSION 3.14)
project(RadicleUiPlugin LANGUAGES CXX)

if(DEFINED ENV{LOGOS_MODULE_BUILDER_ROOT})
    include($ENV{LOGOS_MODULE_BUILDER_ROOT}/cmake/LogosModule.cmake)
else()
    message(FATAL_ERROR "LogosModule.cmake not found. Set LOGOS_MODULE_BUILDER_ROOT.")
endif()

# Derive the module name from metadata.json — single source of truth.
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/metadata.json" METADATA_JSON)
string(JSON MODULE_NAME GET ${METADATA_JSON} name)

# A thin view over the `radicle` core module. No Qt6Network here on purpose:
# this plugin never touches the network, it only forwards to the core module.
logos_module(
    NAME ${MODULE_NAME}
    REP_FILE src/radicle_ui.rep
    SOURCES
        src/radicle_ui_backend.h
        src/radicle_ui_backend.cpp
    INCLUDE_DIRS
        src
)
