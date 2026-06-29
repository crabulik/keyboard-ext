if(CONFIG_CRABULIK_ADC_DPAD)
  zephyr_library()
  zephyr_library_sources(src/adc_dpad.c)
endif()
