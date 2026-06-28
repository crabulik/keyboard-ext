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
 * Multi-host: the keyboard stays connected to every paired host at once; the
 * Easy-Switch layer (BT_SEL) only changes which host receives HID, not the BLE
 * links. So several hosts' companion apps may be writing at the same time. To
 * keep the LEDs showing the host you're actually typing on, each host's last
 * byte is remembered per peer address, but only the *active* BLE profile's value
 * is shown — and on a profile switch we re-apply the newly-active host's value
 * (or turn the LEDs off if that host has no companion yet).
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
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>

#include <zmk/ble.h>
#include <zmk/event_manager.h>
#include <zmk/events/ble_active_profile_changed.h>

LOG_MODULE_REGISTER(layout_indicators, CONFIG_ZMK_LOG_LEVEL);

#if !defined(CONFIG_BT_MAX_PAIRED)
#define CONFIG_BT_MAX_PAIRED 5
#endif

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

/* Remember the last layout byte each paired host wrote, keyed by peer address,
 * so we can re-show the active host's value when the profile switches. The table
 * is touched from both the GATT write callback and the profile-changed listener,
 * so guard it with a mutex. */
struct host_layout {
    bt_addr_le_t addr;
    uint8_t val;
    bool used;
};
static struct host_layout hosts[CONFIG_BT_MAX_PAIRED];
static struct k_mutex hosts_lock;

/* Find the slot for addr; with create=true, claim a free slot if none exists.
 * Caller holds hosts_lock. */
static struct host_layout *host_slot(const bt_addr_le_t *addr, bool create) {
    struct host_layout *free_slot = NULL;
    for (size_t i = 0; i < ARRAY_SIZE(hosts); i++) {
        if (hosts[i].used && bt_addr_le_cmp(&hosts[i].addr, addr) == 0) {
            return &hosts[i];
        }
        if (!hosts[i].used && free_slot == NULL) {
            free_slot = &hosts[i];
        }
    }
    if (create && free_slot != NULL) {
        bt_addr_le_copy(&free_slot->addr, addr);
        free_slot->val = LAYOUT_OFF;
        free_slot->used = true;
        return free_slot;
    }
    return NULL;
}

static bool addr_is_active(const bt_addr_le_t *addr) {
    bt_addr_le_t *active = zmk_ble_active_profile_addr();
    return active != NULL && addr != NULL && bt_addr_le_cmp(active, addr) == 0;
}

/* 6b1a0001-7a3c-4b9e-9c2d-1f5e8a0b1c2d / ...0002 */
#define LAYOUT_SVC_UUID BT_UUID_128_ENCODE(0x6b1a0001, 0x7a3c, 0x4b9e, 0x9c2d, 0x1f5e8a0b1c2d)
#define LAYOUT_CHR_UUID BT_UUID_128_ENCODE(0x6b1a0002, 0x7a3c, 0x4b9e, 0x9c2d, 0x1f5e8a0b1c2d)

static struct bt_uuid_128 layout_svc_uuid = BT_UUID_INIT_128(LAYOUT_SVC_UUID);
static struct bt_uuid_128 layout_chr_uuid = BT_UUID_INIT_128(LAYOUT_CHR_UUID);

static ssize_t write_layout(struct bt_conn *conn, const struct bt_gatt_attr *attr,
                            const void *buf, uint16_t len, uint16_t offset, uint8_t flags) {
    ARG_UNUSED(attr);
    ARG_UNUSED(flags);

    if (offset != 0) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_OFFSET);
    }
    if (len < 1) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    }

    uint8_t val = ((const uint8_t *)buf)[0];
    const bt_addr_le_t *dst = bt_conn_get_dst(conn);

    /* Remember this host's value; only light the LEDs if it's the active host,
     * so a background host (e.g. the Mac after you switch to Windows) can't
     * drive the indicators for the host you're actually typing on. */
    k_mutex_lock(&hosts_lock, K_FOREVER);
    struct host_layout *h = host_slot(dst, true);
    if (h != NULL) {
        h->val = val;
    }
    bool active = addr_is_active(dst);
    if (active) {
        apply_layout(val);
    }
    k_mutex_unlock(&hosts_lock);

    LOG_INF("Layout write %u from %s host", val, active ? "active" : "background");
    return len;
}

/* When the Easy-Switch layer changes the active BLE profile, re-show that host's
 * remembered layout (or turn the LEDs off if it has no companion yet), instead
 * of leaving the previous host's value on the LEDs. */
static int on_active_profile_changed(const zmk_event_t *eh) {
    ARG_UNUSED(eh);
    uint8_t val = LAYOUT_OFF;
    k_mutex_lock(&hosts_lock, K_FOREVER);
    bt_addr_le_t *active = zmk_ble_active_profile_addr();
    if (active != NULL) {
        struct host_layout *h = host_slot(active, false);
        if (h != NULL) {
            val = h->val;
        }
    }
    apply_layout(val);
    k_mutex_unlock(&hosts_lock);
    LOG_INF("Active profile changed -> layout %u", val);
    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(layout_indicators, on_active_profile_changed);
ZMK_SUBSCRIPTION(layout_indicators, zmk_ble_active_profile_changed);

/* Compiling a static BT_GATT_SERVICE_DEFINE auto-registers the service into the
 * GATT database alongside ZMK's HID service; it persists across reconnects. */
BT_GATT_SERVICE_DEFINE(layout_svc,
    BT_GATT_PRIMARY_SERVICE(&layout_svc_uuid),
    BT_GATT_CHARACTERISTIC(&layout_chr_uuid.uuid,
                           BT_GATT_CHRC_WRITE | BT_GATT_CHRC_WRITE_WITHOUT_RESP,
                           BT_GATT_PERM_WRITE_ENCRYPT, /* only a bonded host may write */
                           NULL, write_layout, NULL));

static int layout_indicators_init(void) {
    k_mutex_init(&hosts_lock);
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
