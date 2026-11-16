# Eiwa freestanding component: links the eiwac-emitted object plus the
# portable vendored C runtime (exception state, string helpers). The object
# is generated, not checked in:
#   ./bin/eiwac build --target esp32 -o samples/esp32-hello/main/eiwa_prog.o samples/esp32_hello.ei
idf_component_register(
    SRCS "eiwa_compat.c"
         "${CMAKE_CURRENT_SOURCE_DIR}/../../../src/runtime/third_party/eiwa_exc/exc_state.c"
         "${CMAKE_CURRENT_SOURCE_DIR}/../../../src/runtime/third_party/eiwa_string/string_helpers.c"
    INCLUDE_DIRS "."
                 "${CMAKE_CURRENT_SOURCE_DIR}/../../../src/runtime/third_party"
    PRIV_REQUIRES freertos)

# The whole object links (entry is app_main); --gc-sections (IDF default)
# dead-strips every unreachable section.
target_link_libraries(${COMPONENT_LIB} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/eiwa_prog.o")
# The prebuilt object sits on the final link line after this archive, so
# plain archive pulling would drop the C members. Whole-archive forces
# every member in regardless of order (libmain here is only 3 small files).
target_link_libraries(${COMPONENT_LIB} INTERFACE
    "-Wl,--whole-archive,$<TARGET_FILE:${COMPONENT_LIB}>,--no-whole-archive")
