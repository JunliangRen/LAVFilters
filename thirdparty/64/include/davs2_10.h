/* Dual-depth davs2 extension built by thirdparty/build_avs.sh. */
#ifndef LAV_DAVS2_10_H
#define LAV_DAVS2_10_H

#include <davs2.h>

#define DAVS2_HAS_10BIT 1

#ifdef __cplusplus
extern "C" {
#endif

void *lav_davs2_10_decoder_open(davs2_param_t *param);
int lav_davs2_10_decoder_send_packet(void *decoder, davs2_packet_t *packet);
int lav_davs2_10_decoder_recv_frame(void *decoder, davs2_seq_info_t *headerset,
                                  davs2_picture_t *out_frame);
int lav_davs2_10_decoder_flush(void *decoder, davs2_seq_info_t *headerset,
                             davs2_picture_t *out_frame);
void lav_davs2_10_decoder_frame_unref(void *decoder, davs2_picture_t *out_frame);
void lav_davs2_10_decoder_close(void *decoder);

#ifdef __cplusplus
}
#endif

#endif
