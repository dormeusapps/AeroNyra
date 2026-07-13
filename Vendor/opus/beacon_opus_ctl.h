/* beacon_opus_ctl.h — non-variadic shims over opus_encoder_ctl / opus_decoder_ctl.
 *
 * NOT from the upstream tarball (like config.h). Opus's CTL entry points are C
 * variadic functions, which Swift cannot call directly, and the OPUS_SET_ and
 * OPUS_GET_ request macros expand to a (request, value) pair that also isn't
 * expressible from Swift. These `static inline` wrappers keep the CTL calls on
 * the C side (where the macros work) and expose a plain, Swift-callable
 * surface. Thin, auditable, no behavior of its own.
 */
#ifndef BEACON_OPUS_CTL_H
#define BEACON_OPUS_CTL_H

#include "opus.h"

static inline int beacon_opus_encoder_set_bitrate(OpusEncoder *e, opus_int32 v) {
    return opus_encoder_ctl(e, OPUS_SET_BITRATE(v));
}
static inline int beacon_opus_encoder_set_complexity(OpusEncoder *e, opus_int32 v) {
    return opus_encoder_ctl(e, OPUS_SET_COMPLEXITY(v));
}
static inline int beacon_opus_encoder_set_inband_fec(OpusEncoder *e, opus_int32 on) {
    return opus_encoder_ctl(e, OPUS_SET_INBAND_FEC(on));
}
static inline int beacon_opus_encoder_set_packet_loss_perc(OpusEncoder *e, opus_int32 pct) {
    return opus_encoder_ctl(e, OPUS_SET_PACKET_LOSS_PERC(pct));
}
static inline int beacon_opus_encoder_set_signal_voice(OpusEncoder *e) {
    return opus_encoder_ctl(e, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
}
static inline int beacon_opus_encoder_get_bitrate(OpusEncoder *e, opus_int32 *out) {
    return opus_encoder_ctl(e, OPUS_GET_BITRATE(out));
}

#endif /* BEACON_OPUS_CTL_H */
