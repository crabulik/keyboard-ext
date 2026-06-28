/*
 * Layout indicator LEDs, driven by a paired host over BLE.
 *
 * Registers a custom GATT service with a single writable, encryption-required
 * characteristic. The companion app (running on the paired host) detects the
 * active OS keyboard layout and writes ONE byte to that characteristic:
 *
 *     0 = US  -> led_us on,  led_ua off
 *     1 = UA  -> led_ua on,  led_us off
 *     2 = off / unknown -> both off   (any other value behaves the same)
 *
 * Because the keyboard cannot read the host's active layout on its own, this is
 * how the host pushes true layout state onto the device's indicator LEDs.
 *
 * UUIDs (also used by the companion app):
 *     Service:        6b1a0001-7a3c-4b9e-9c2d-1f5e8a0b1c2d
 *     Characteristic: 6b1a0002-7a3c-4b9e-9c2d-1f5e8a0b1c2d
 */

#include <zephyr/init.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>

LOG_MODULE_REGISTER(layout_indicators, CONFIG_ZMK_LOG_LEVEL);

enum layout_state {
    LAYOUT_US = 0,
    LAYOUT_UA = 1,
    LAYOUT_OFF = 2,
};

static const struct gpio_dt_spec led_us = GPIO_DT_SPEC_GET(DT_NODELABEL(led_us), gpios);
static const struct gpio_dt_spec led_ua = GPIO_DT_SPEC_GET(DT_NODELABEL(led_ua), gpios);

static void apply_layout(uint8_t val) {
    switch (val) {
    case LAYOUT_US:
        gpio_pin_set_dt(&led_us, 1);
        gpio_pin_set_dt(&led_ua, 0);
        break;
    case LAYOUT_UA:
        gpio_pin_set_dt(&led_us, 0);
        gpio_pin_set_dt(&led_ua, 1);
        break;
    default: /* LAYOUT_OFF / unknown */
        gpio_pin_set_dt(&led_us, 0);
        gpio_pin_set_dt(&led_ua, 0);
        break;
    }
}

/* 6b1a0001-7a3c-4b9e-9c2d-1f5e8a0b1c2d / ...0002 */
#define LAYOUT_SVC_UUID BT_UUID_128_ENCODE(0x6b1a0001, 0x7a3c, 0x4b9e, 0x9c2d, 0x1f5e8a0b1c2d)
#define LAYOUT_CHR_UUID BT_UUID_128_ENCODE(0x6b1a0002, 0x7a3c, 0x4b9e, 0x9c2d, 0x1f5e8a0b1c2d)

static struct bt_uuid_128 layout_svc_uuid = BT_UUID_INIT_128(LAYOUT_SVC_UUID);
static struct bt_uuid_128 layout_chr_uuid = BT_UUID_INIT_128(LAYOUT_CHR_UUID);

static ssize_t write_layout(struct bt_conn *conn, const struct bt_gatt_attr *attr,
                            const void *buf, uint16_t len, uint16_t offset, uint8_t flags) {
    ARG_UNUSED(conn);
    ARG_UNUSED(attr);
    ARG_UNUSED(flags);

    if (offset != 0) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_OFFSET);
    }
    if (len < 1) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    }

    uint8_t val = ((const uint8_t *)buf)[0];
    LOG_INF("Layout indicator set to %u", val);
    apply_layout(val);
    return len;
}

/* Compiling a static BT_GATT_SERVICE_DEFINE auto-registers the service into the
 * GATT database alongside ZMK's HID service; it persists across reconnects. */
BT_GATT_SERVICE_DEFINE(layout_svc,
    BT_GATT_PRIMARY_SERVICE(&layout_svc_uuid),
    BT_GATT_CHARACTERISTIC(&layout_chr_uuid.uuid,
                           BT_GATT_CHRC_WRITE | BT_GATT_CHRC_WRITE_WITHOUT_RESP,
                           BT_GATT_PERM_WRITE_ENCRYPT, /* only a bonded host may write */
                           NULL, write_layout, NULL));

static int layout_indicators_init(void) {
    if (!gpio_is_ready_dt(&led_us) || !gpio_is_ready_dt(&led_ua)) {
        LOG_ERR("Layout indicator LED GPIOs not ready");
        return -ENODEV;
    }
    gpio_pin_configure_dt(&led_us, GPIO_OUTPUT_INACTIVE);
    gpio_pin_configure_dt(&led_ua, GPIO_OUTPUT_INACTIVE);
    LOG_INF("Layout indicators ready");
    return 0;
}

SYS_INIT(layout_indicators_init, APPLICATION, CONFIG_APPLICATION_INIT_PRIORITY);
