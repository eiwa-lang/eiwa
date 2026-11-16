# Eiwa freestanding component: links the eiwac-emitted object plus the
# portable vendored C runtime (exception state, string helpers). The object
# is generated, not checked in:
#   ./bin/eiwac build --target esp32 -o samples/esp32-hello/main/eiwa_prog.o samples/esp32_hello.ei
idf_component_register(
    SRCS "eiwa_compat.c"
         "${CMAKE_CURRENT_SOURCE_DIR}/../../../src/runtime/third_party/eiwa_exc/exc_state.c"
         "${CMAKE_CURRENT_SOURCE_DIR}/../../../src/runtime/third_party/eiwa_string/string_helpers.c"
         "${CMAKE_CURRENT_SOURCE_DIR}/../../../src/runtime/third_party/eiwa_net/net_helpers.c"
    INCLUDE_DIRS "."
                 "${CMAKE_CURRENT_SOURCE_DIR}/../../../src/runtime/third_party"
    PRIV_REQUIRES freertos lwip)

# The whole object links (entry is app_main); --gc-sections (IDF default)
# dead-strips every unreachable section. idf::lwip must follow our objects
# on the final link line: archive members resolve only against LATER
# archives, and nothing follows the prebuilt object otherwise.
target_link_libraries(${COMPONENT_LIB} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/eiwa_prog.o" idf::lwip)
# Ordering-proof: the prebuilt object and this archive sit at the END of the
# final link line, after the last liblwip.a. Archives resolve only against
# LATER archives, so re-list liblwip.a explicitly after ourselves via its
# target file (single left-to-right pass then finds lwip_socket & friends).
target_link_libraries(${COMPONENT_LIB} INTERFACE
    "-Wl,--whole-archive,$<TARGET_FILE:${COMPONENT_LIB}>,--no-whole-archive"
    "$<TARGET_FILE:idf::lwip>")
