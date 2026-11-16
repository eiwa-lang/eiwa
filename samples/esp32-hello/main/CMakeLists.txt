# Eiwa freestanding component: links the eiwac-emitted object plus the
# portable vendored C runtime (exception state, string helpers). The object
# is generated, not checked in:
#   ./bin/eiwac build --target esp32 -o samples/esp32-hello/main/eiwa_prog.o samples/esp32_hello.ei
idf_component_register(
    SRCS "eiwa_compat.c"
         "${CMAKE_CURRENT_SOURCE_DIR}/../../../src/runtime/third_party/eiwa_exc/exc_state.c"
         "${CMAKE_CURRENT_SOURCE_DIR}/../../../src/runtime/third_party/eiwa_string/string_helpers.c"
         "${CMAKE_CURRENT_SOURCE_DIR}/../../../src/runtime/third_party/eiwa_net/net_helpers.c"
         "${CMAKE_CURRENT_SOURCE_DIR}/../../../src/runtime/third_party/eiwa_wifi/wifi_helpers.c"
    INCLUDE_DIRS "."
                 "${CMAKE_CURRENT_SOURCE_DIR}/../../../src/runtime/third_party"
    PRIV_REQUIRES freertos lwip esp_wifi esp_event nvs_flash esp_driver_gpio)

# Whole object links (entry is app_main); --gc-sections strips the dead
# sections. idf::lwip must follow: archives resolve only against LATER
# archives, and nothing follows our object otherwise.
target_link_libraries(${COMPONENT_LIB} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/eiwa_prog.o" idf::lwip)
# Ordering-proof: this archive sits at the END of the final link line.
# Re-list liblwip.a explicitly so one left-to-right pass resolves it.
target_link_libraries(${COMPONENT_LIB} INTERFACE
    "-Wl,--whole-archive,$<TARGET_FILE:${COMPONENT_LIB}>,--no-whole-archive"
    "$<TARGET_FILE:idf::lwip>")
