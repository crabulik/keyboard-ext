if(CONFIG_ZMK_LAYOUT_INDICATORS)
  zephyr_library()
  zephyr_library_sources(src/layout_indicators.c)
  # zmk/ble.h, zmk/event_manager.h, etc. live in the ZMK app's include dir,
  # which the app exposes only as PRIVATE. Add it so this external module can
  # use ZMK internals like zmk_ble_active_profile_addr().
  zephyr_library_include_directories(${APPLICATION_SOURCE_DIR}/include)
endif()
