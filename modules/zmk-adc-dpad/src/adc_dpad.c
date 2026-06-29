/*
 * Resistor-ladder 5-way d-pad on a single ADC channel.
 *
 * A passive 5-way control (center + up/down/left/right), like a CaddxFPV OSD
 * menu board, ties each direction through a different resistor to one signal
 * wire. With an external pull-up to 3.3V the idle line sits high and each press
 * divides it down to a distinct voltage. This driver samples that voltage on a
 * timer, maps it to a direction band, and sends the mapped key directly into
 * ZMK's HID pipeline (so it needs no kscan/keymap entry and works on any layer).
 *
 * Wiring, the overlay snippet (which provides the `dpad_chan` ADC channel), and
 * the calibration procedure are in modules/zmk-adc-dpad/README.md.
 */

#include <zephyr/kernel.h>
#include <zephyr/init.h>
#include <zephyr/device.h>
#include <zephyr/drivers/adc.h>
#include <zephyr/logging/log.h>

#include <dt-bindings/zmk/keys.h>
#include <zmk/events/keycode_state_changed.h>

LOG_MODULE_REGISTER(adc_dpad, CONFIG_ZMK_LOG_LEVEL);

#define DPAD_CHAN_NODE DT_NODELABEL(dpad_chan)

#if DT_NODE_HAS_STATUS(DPAD_CHAN_NODE, okay)

/* ===== CALIBRATE ME (see README "Calibration") ============================ *
 * thresholds_mv: ascending upper bound (mV) of each direction's band.
 * keycodes:      the key each band sends, same order/length as thresholds_mv.
 * A reading below thresholds_mv[i] (and >= the previous bound) selects band i;
 * a reading >= DPAD_KEYUP_MV means "nothing pressed" (idle pull-up).
 * Enable CONFIG_CRABULIK_ADC_DPAD_LOG_MV, press each direction, read the mV,
 * then set the bounds to the midpoints between neighbouring readings and order
 * the keycodes to match which direction landed in which band.                 */
static const uint16_t thresholds_mv[] = {  400, 1000, 1700, 2400, 2900 };
static const uint32_t keycodes[]      = { LEFT, DOWN,   UP, RIGHT,  RET };
#define DPAD_KEYUP_MV  3000  /* readings >= this = idle (no press)             */
#define DPAD_POLL_MS     30  /* sampling interval                             */
#define DPAD_RESOLUTION  12  /* SAADC resolution (bits)                       */
/* ========================================================================== */

BUILD_ASSERT(ARRAY_SIZE(thresholds_mv) == ARRAY_SIZE(keycodes),
             "thresholds_mv and keycodes must be the same length");
#define DPAD_NUM_KEYS ARRAY_SIZE(thresholds_mv)

static const struct device *const adc_dev = DEVICE_DT_GET(DT_PARENT(DPAD_CHAN_NODE));
static const struct adc_channel_cfg dpad_ch = ADC_CHANNEL_CFG_DT(DPAD_CHAN_NODE);

static int16_t sample_buf;
static struct adc_sequence sequence = {
    .buffer = &sample_buf,
    .buffer_size = sizeof(sample_buf),
    .resolution = DPAD_RESOLUTION,
};
static struct k_work_delayable poll_work;
static int current_band = -1; /* -1 = nothing pressed */

static int classify(int32_t mv) {
    if (mv >= DPAD_KEYUP_MV) {
        return -1;
    }
    for (int i = 0; i < DPAD_NUM_KEYS; i++) {
        if (mv < (int32_t)thresholds_mv[i]) {
            return i;
        }
    }
    return -1;
}

static void poll_fn(struct k_work *work) {
    ARG_UNUSED(work);

    int err = adc_read(adc_dev, &sequence);
    if (err) {
        LOG_WRN("adc_read failed (%d)", err);
        goto reschedule;
    }

    int32_t mv = sample_buf;
    adc_raw_to_millivolts(adc_ref_internal(adc_dev), dpad_ch.gain, DPAD_RESOLUTION, &mv);

    int band = classify(mv);
    if (band != current_band) {
        int64_t ts = k_uptime_get();
        if (current_band >= 0) {
            raise_zmk_keycode_state_changed_from_encoded(keycodes[current_band], false, ts);
        }
        if (band >= 0) {
            raise_zmk_keycode_state_changed_from_encoded(keycodes[band], true, ts);
        }
        current_band = band;
    }

#if IS_ENABLED(CONFIG_CRABULIK_ADC_DPAD_LOG_MV)
    LOG_INF("dpad mv=%d -> band=%d", mv, band);
#endif

reschedule:
    k_work_reschedule(&poll_work, K_MSEC(DPAD_POLL_MS));
}

static int adc_dpad_init(void) {
    if (!device_is_ready(adc_dev)) {
        LOG_ERR("ADC controller not ready");
        return -ENODEV;
    }

    int err = adc_channel_setup(adc_dev, &dpad_ch);
    if (err) {
        LOG_ERR("ADC channel setup failed (%d)", err);
        return err;
    }
    sequence.channels = BIT(dpad_ch.channel_id);

    k_work_init_delayable(&poll_work, poll_fn);
    k_work_reschedule(&poll_work, K_MSEC(DPAD_POLL_MS));
    LOG_INF("ADC d-pad ready (%d keys on channel %d)", DPAD_NUM_KEYS, dpad_ch.channel_id);
    return 0;
}

SYS_INIT(adc_dpad_init, APPLICATION, CONFIG_APPLICATION_INIT_PRIORITY);

#else
#warning "CRABULIK_ADC_DPAD is enabled but the overlay has no `dpad_chan` ADC channel node. See modules/zmk-adc-dpad/README.md."
#endif /* DPAD_CHAN_NODE okay */
