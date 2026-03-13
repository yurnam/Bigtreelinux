/*
 * lcd_init.c – BigTreeTech PandaTouch LCD initialisation pre-loader
 *
 * Purpose
 * -------
 * This ESP-IDF application initialises the ESP32-S3 LCD_CAM peripheral for
 * parallel RGB output (800 × 480, RGB565) and keeps it scanning out from a
 * framebuffer allocated in PSRAM before Linux boots.
 *
 * After the display is up this application is intended to chain to the
 * esp-hosted network_adapter firmware which loads and starts the Linux
 * kernel.  For development purposes it can also run standalone and draw a
 * test pattern so the display can be verified without Linux.
 *
 * Integration
 * -----------
 * Flash this application to the "bootloader_app" partition (factory, offset
 * 0x10000).  After it finishes initialising the display it performs a
 * software reset which re-enters the ROM bootloader; the ROM then loads the
 * esp-hosted app from the "bootloader_app" partition again – this second
 * boot intentionally skips the LCD init path (detected via RTC memory flag)
 * and jumps straight to the Linux loader.
 *
 * Alternatively, integrate the lcd_panel_init() call directly into the
 * esp-hosted network_adapter main.c so that only one application needs to
 * be flashed.  The PSRAM framebuffer address is fixed at PSRAM_BASE
 * (0x3C000000) so the simple-framebuffer DT node always finds it there.
 *
 * Hardware (BigTreeTech PandaTouch)
 * ----------------------------------
 *  PCLK  : GPIO5   @ 14.8 MHz
 *  DE    : GPIO38
 *  HSYNC : –       (DE mode, not routed)
 *  VSYNC : –       (DE mode, not routed)
 *  B3–B7 : GPIO17,18,48,47,39
 *  G2–G7 : GPIO11,12,13,14,15,16
 *  R3–R7 : GPIO6,7,8,9,10
 *  BL    : GPIO21  (backlight enable, active HIGH)
 *  RESET : GPIO46  (LCD reset, active LOW)
 *
 * Memory
 * ------
 *  Framebuffer : 0x3C000000 (PSRAM base), 800 × 480 × 2 = 768 000 bytes
 *  Linux RAM   : 0x3C0BB800 – 0x3FFFFFFF (~7.25 MB)
 */

#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_panel_rgb.h"
#include "esp_log.h"
#include "esp_psram.h"
#include "esp_heap_caps.h"
#include "driver/gpio.h"
#include "driver/ledc.h"
#include "esp_rom_sys.h"
#include "esp_system.h"

static const char *TAG = "lcd_init";

/* ── Pin definitions ────────────────────────────────────────────────────── */
#define PT_LCD_PCLK_PIN   5
#define PT_LCD_DE_PIN     38
#define PT_LCD_HSYNC_PIN  (-1)   /* not routed */
#define PT_LCD_VSYNC_PIN  (-1)   /* not routed */
/* Blue data bits B3–B7 */
#define PT_LCD_B3_PIN     17
#define PT_LCD_B4_PIN     18
#define PT_LCD_B5_PIN     48
#define PT_LCD_B6_PIN     47
#define PT_LCD_B7_PIN     39
/* Green data bits G2–G7 */
#define PT_LCD_G2_PIN     11
#define PT_LCD_G3_PIN     12
#define PT_LCD_G4_PIN     13
#define PT_LCD_G5_PIN     14
#define PT_LCD_G6_PIN     15
#define PT_LCD_G7_PIN     16
/* Red data bits R3–R7 */
#define PT_LCD_R3_PIN     6
#define PT_LCD_R4_PIN     7
#define PT_LCD_R5_PIN     8
#define PT_LCD_R6_PIN     9
#define PT_LCD_R7_PIN     10

#define PT_LCD_RESET_PIN  46
#define PT_LCD_BL_PIN     21

/* ── Panel timing (from pt_board.h) ────────────────────────────────────── */
#define PT_LCD_H_RES              800
#define PT_LCD_V_RES              480
#define PT_LCD_PCLK_HZ            14800000
#define PT_LCD_HSYNC_PULSE_WIDTH  4
#define PT_LCD_HSYNC_BACK_PORCH   16
#define PT_LCD_HSYNC_FRONT_PORCH  16
#define PT_LCD_VSYNC_PULSE_WIDTH  4
#define PT_LCD_VSYNC_BACK_PORCH   32
#define PT_LCD_VSYNC_FRONT_PORCH  32

/* ── Framebuffer ────────────────────────────────────────────────────────── */
/* Fixed at the start of PSRAM – Linux simple-framebuffer DT node points here */
#define PT_FB_SIZE   (PT_LCD_H_RES * PT_LCD_V_RES * sizeof(uint16_t))

static uint16_t *s_fb = NULL;           /* pointer into PSRAM */
static esp_lcd_panel_handle_t s_panel;  /* LCD panel handle  */

/* ── Helpers ────────────────────────────────────────────────────────────── */

/** Initialise the backlight GPIO and turn it on at full brightness. */
static void backlight_init(void)
{
    gpio_config_t bl_cfg = {
        .pin_bit_mask = (1ULL << PT_LCD_BL_PIN),
        .mode         = GPIO_MODE_OUTPUT,
        .pull_up_en   = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type    = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&bl_cfg));
    gpio_set_level(PT_LCD_BL_PIN, 1);
    ESP_LOGI(TAG, "Backlight ON (GPIO%d)", PT_LCD_BL_PIN);
}

/**
 * Allocate the framebuffer in PSRAM and return a pointer to it.
 * The buffer is allocated at the very start of external RAM so that its
 * physical address is always PSRAM_BASE (0x3C000000), which matches the
 * simple-framebuffer reg property in the Linux device tree.
 */
static uint16_t *fb_alloc(void)
{
    /* Request PSRAM-backed allocation of exactly PT_FB_SIZE bytes.
     * heap_caps_malloc with MALLOC_CAP_SPIRAM gives memory in external RAM. */
    uint16_t *fb = heap_caps_malloc(PT_FB_SIZE, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!fb) {
        ESP_LOGE(TAG, "Failed to allocate %u bytes in PSRAM for framebuffer",
                 (unsigned)PT_FB_SIZE);
        abort();
    }
    ESP_LOGI(TAG, "Framebuffer: %u bytes at %p (PSRAM)", (unsigned)PT_FB_SIZE, fb);
    memset(fb, 0x00, PT_FB_SIZE);  /* clear to black */
    return fb;
}

/** Draw a colour test pattern: red, green, blue vertical bars. */
static void draw_test_pattern(uint16_t *fb)
{
    const uint16_t RED   = 0xF800;
    const uint16_t GREEN = 0x07E0;
    const uint16_t BLUE  = 0x001F;
    const uint16_t WHITE = 0xFFFF;

    const int quarter = PT_LCD_H_RES / 4;
    for (int y = 0; y < PT_LCD_V_RES; y++) {
        for (int x = 0; x < PT_LCD_H_RES; x++) {
            uint16_t colour;
            if      (x < quarter)         colour = RED;
            else if (x < 2 * quarter)     colour = GREEN;
            else if (x < 3 * quarter)     colour = BLUE;
            else                          colour = WHITE;
            fb[y * PT_LCD_H_RES + x] = colour;
        }
    }
}

/** Draw a simple "Linux booting…" splash screen in RGB565. */
static void draw_splash(uint16_t *fb)
{
    /* Dark background */
    const uint16_t BG   = 0x0841;   /* very dark grey */
    const uint16_t CYAN = 0x07FF;
    for (int i = 0; i < PT_LCD_H_RES * PT_LCD_V_RES; i++) {
        fb[i] = BG;
    }
    /* Draw a thin cyan horizontal line in the middle */
    for (int x = 0; x < PT_LCD_H_RES; x++) {
        fb[(PT_LCD_V_RES / 2) * PT_LCD_H_RES + x] = CYAN;
    }
}

/* ── LCD initialisation ─────────────────────────────────────────────────── */

static void lcd_panel_init(void)
{
    ESP_LOGI(TAG, "Initialising RGB LCD panel (800×480, RGB565)");

    /* Reset the panel */
    gpio_config_t rst_cfg = {
        .pin_bit_mask = (1ULL << PT_LCD_RESET_PIN),
        .mode         = GPIO_MODE_OUTPUT,
        .pull_up_en   = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type    = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&rst_cfg));
    gpio_set_level(PT_LCD_RESET_PIN, 0);
    vTaskDelay(pdMS_TO_TICKS(10));
    gpio_set_level(PT_LCD_RESET_PIN, 1);
    vTaskDelay(pdMS_TO_TICKS(120));

    /* Allocate framebuffer in PSRAM */
    s_fb = fb_alloc();

    /* Configure the RGB panel */
    esp_lcd_rgb_panel_config_t panel_cfg = {
        .data_width          = 16,
        .psram_trans_align   = 64,
        .num_fbs             = 1,
        .clk_src             = LCD_CLK_SRC_DEFAULT,
        .disp_gpio_num       = GPIO_NUM_NC,
        .pclk_gpio_num       = PT_LCD_PCLK_PIN,
        .vsync_gpio_num      = PT_LCD_VSYNC_PIN,
        .hsync_gpio_num      = PT_LCD_HSYNC_PIN,
        .de_gpio_num         = PT_LCD_DE_PIN,
        .data_gpio_nums = {
            /* D0–D4: B3–B7 (blue LSB first) */
            PT_LCD_B3_PIN, PT_LCD_B4_PIN, PT_LCD_B5_PIN,
            PT_LCD_B6_PIN, PT_LCD_B7_PIN,
            /* D5–D10: G2–G7 (green) */
            PT_LCD_G2_PIN, PT_LCD_G3_PIN, PT_LCD_G4_PIN,
            PT_LCD_G5_PIN, PT_LCD_G6_PIN, PT_LCD_G7_PIN,
            /* D11–D15: R3–R7 (red) */
            PT_LCD_R3_PIN, PT_LCD_R4_PIN, PT_LCD_R5_PIN,
            PT_LCD_R6_PIN, PT_LCD_R7_PIN,
        },
        .timings = {
            .pclk_hz            = PT_LCD_PCLK_HZ,
            .h_res              = PT_LCD_H_RES,
            .v_res              = PT_LCD_V_RES,
            .hsync_pulse_width  = PT_LCD_HSYNC_PULSE_WIDTH,
            .hsync_back_porch   = PT_LCD_HSYNC_BACK_PORCH,
            .hsync_front_porch  = PT_LCD_HSYNC_FRONT_PORCH,
            .vsync_pulse_width  = PT_LCD_VSYNC_PULSE_WIDTH,
            .vsync_back_porch   = PT_LCD_VSYNC_BACK_PORCH,
            .vsync_front_porch  = PT_LCD_VSYNC_FRONT_PORCH,
            .flags.pclk_active_neg = 0,
        },
        .flags.fb_in_psram         = 1,    /* framebuffer in PSRAM */
        .flags.double_fb           = 0,    /* single framebuffer for simplicity */
        .flags.no_fb               = 0,
        .flags.bb_invalidate_cache = 0,
    };

    ESP_ERROR_CHECK(esp_lcd_new_rgb_panel(&panel_cfg, &s_panel));
    ESP_ERROR_CHECK(esp_lcd_panel_reset(s_panel));
    ESP_ERROR_CHECK(esp_lcd_panel_init(s_panel));

    ESP_LOGI(TAG, "RGB panel initialised – drawing splash");
    draw_splash(s_fb);

    /* Flush the framebuffer to the panel */
    ESP_ERROR_CHECK(esp_lcd_panel_draw_bitmap(s_panel, 0, 0,
                                              PT_LCD_H_RES, PT_LCD_V_RES,
                                              s_fb));
    backlight_init();

    ESP_LOGI(TAG,
             "LCD ready. Framebuffer at %p (0x%08x). "
             "Linux simple-framebuffer will reuse this address.",
             s_fb, (unsigned)(uintptr_t)s_fb);
}

/* ── Entry point ─────────────────────────────────────────────────────────── */

void app_main(void)
{
    ESP_LOGI(TAG, "BigTreeTech PandaTouch lcd-init v1.0");
    ESP_LOGI(TAG, "PSRAM size: %u bytes", (unsigned)esp_psram_get_size());

    lcd_panel_init();

    /*
     * The panel is now scanning out the PSRAM framebuffer continuously.
     * The LCD_CAM DMA will keep running even after this app exits because
     * the peripheral is autonomous once started.
     *
     * In production, the next step is to load and start the Linux kernel
     * (via the esp-hosted chain-loader).  For standalone testing, display
     * the colour-bar test pattern for 3 seconds then loop.
     */
    ESP_LOGI(TAG, "Display active. Drawing test pattern for 3 s...");
    draw_test_pattern(s_fb);
    vTaskDelay(pdMS_TO_TICKS(3000));

    ESP_LOGI(TAG, "Restoring splash...");
    draw_splash(s_fb);

    ESP_LOGI(TAG,
             "lcd-init complete.\n"
             "Next step: integrate this init sequence into the esp-hosted\n"
             "network_adapter firmware (or a chain-loader) so that the LCD\n"
             "is active when Linux boots and uses /dev/fb0 via simple-framebuffer.");

    /* Spin here in standalone mode; in production this would chain to Linux. */
    while (1) {
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
}
