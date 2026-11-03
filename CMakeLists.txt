cmake_minimum_required(VERSION 3.22)
project(translator64 CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(DYN ${CMAKE_SOURCE_DIR}/third_party/dynarmic)
set(DYNBUILD ${CMAKE_SOURCE_DIR}/build/dynarmic)

set(WST_COMMON
    src/memory.cpp
    src/cpu.cpp
    src/thunks.cpp
    src/gl_fwd.cpp
    src/elf.cpp
    src/jni.cpp
    src/jni_real.cpp
    src/jni_invoke.cpp
    src/sys.cpp
    src/signals.cpp
    src/hooks.cpp
    src/gfx.cpp
    src/driver.cpp
)

set(WST_INCLUDES
    ${DYN}/src
    ${DYN}/include
    ${CMAKE_SOURCE_DIR}/third_party/boost
    ${DYN}/externals/mcl/include
    ${DYNBUILD}/externals/mcl/include           # generated mcl config headers
    ${DYN}/externals/fmt/include
)

set(WST_LIBS
    ${DYNBUILD}/src/dynarmic/libdynarmic.a
    ${DYNBUILD}/externals/mcl/src/libmcl.a
    ${DYNBUILD}/externals/fmt/libfmt.a
    log android EGL GLESv2
)

# CLI driver (standalone executable)
add_executable(wst64 src/main.cpp ${WST_COMMON})
target_include_directories(wst64 PRIVATE ${WST_INCLUDES})
target_link_libraries(wst64 ${WST_LIBS})

# Android host-app library (loaded by com.windstock.translator64's Activity)
add_library(wst64so SHARED src/android_main.cpp ${WST_COMMON})
set_target_properties(wst64so PROPERTIES OUTPUT_NAME wst64)
target_include_directories(wst64so PRIVATE ${WST_INCLUDES})
target_link_libraries(wst64so ${WST_LIBS})
