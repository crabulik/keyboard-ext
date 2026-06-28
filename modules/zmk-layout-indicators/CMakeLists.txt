if(CONFIG_ZMK_LAYOUT_INDICATORS)
  zephyr_library()
  zephyr_library_sources(src/layout_indicators.c)
endif()
