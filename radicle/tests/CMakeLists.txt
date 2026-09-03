cmake_minimum_required(VERSION 3.14)
project(RadicleModuleTests LANGUAGES CXX)

include(LogosTest)

# AUTOMOC needs metadata.json alongside the sources it moc's.
configure_file(${CMAKE_CURRENT_SOURCE_DIR}/../metadata.json
               ${CMAKE_CURRENT_BINARY_DIR}/metadata.json COPYONLY)

# Unit tests for the pure logic — URL building, ref resolution, pagination,
# error shapes and local-profile detection. These do not hit the network:
# anything that would is exercised through the seam in test_seed_client.cpp.
logos_test(
    NAME radicle_module_tests
    MODULE_SOURCES
        ../src/seed_client.cpp
        ../src/local_store.cpp
        # Linked even though the tests inject their own transport: SeedClient
        # still references httpGet as its default.
        ../src/http_client.cpp
    TEST_SOURCES
        main.cpp
        test_seed_client.cpp
        test_local_store.cpp
    EXTRA_INCLUDES
        ../src
)
