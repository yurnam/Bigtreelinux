idf_component_register(
    SRCS "lcd_init.c"
    INCLUDE_DIRS "."
    REQUIRES
        esp_lcd
        esp_timer
        driver
        log
        esp_psram
)
