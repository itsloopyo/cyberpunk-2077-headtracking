cmake_minimum_required(VERSION 3.20)
project(HeadTrackingAim VERSION 0.0.0 LANGUAGES CXX)

# C++20 required for RED4ext.SDK
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Output to predictable location
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)

# RED4ext.SDK as submodule
add_subdirectory(deps/RED4ext.SDK)

set(CAMERAUNLOCK_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../cameraunlock-core/cpp")
if(NOT EXISTS "${CAMERAUNLOCK_DIR}/CMakeLists.txt")
    message(FATAL_ERROR
        "cameraunlock-core not found at ${CAMERAUNLOCK_DIR}. "
        "Run: git submodule update --init --recursive")
endif()
set(CAMERAUNLOCK_BUILD_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory(${CAMERAUNLOCK_DIR} ${CMAKE_BINARY_DIR}/_deps/cameraunlock EXCLUDE_FROM_ALL)
if(MSVC)
    set_property(TARGET cameraunlock PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL")
endif()

# Our plugin
add_library(HeadTrackingAim SHARED
    src/main.cpp
    src/SharedState.cpp
    src/AimCompensation.cpp
    src/NativeRunningHook.cpp
    src/CamPropagatorHook.cpp
    src/HitscanHook.cpp
    src/ShotSnapHook.cpp
    src/ShotEntryProbe.cpp
    src/FreezeFrameHook.cpp
    src/AimProviderHook.cpp
    src/AimGetterHook.cpp
    src/UdpReceiver.cpp
    src/TcpServer.cpp
)

target_include_directories(HeadTrackingAim PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

target_link_libraries(HeadTrackingAim PRIVATE
    RED4ext.SDK
    cameraunlock
    psapi    # HitscanHook: GetModuleInformation for RVA resolution
    d3d12    # FreezeFrameHook: swapchain Present hook + backbuffer copy
    dxgi     # FreezeFrameHook: swapchain creation for vtable steal
)

# Windows-specific settings
if(WIN32)
    target_compile_definitions(HeadTrackingAim PRIVATE
        WIN32_LEAN_AND_MEAN
        NOMINMAX
    )
endif()

# Set output name
set_target_properties(HeadTrackingAim PROPERTIES
    OUTPUT_NAME "HeadTrackingAim"
    PREFIX ""
)
