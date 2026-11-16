#pragma once
#include <stdbool.h>
#include <stdint.h>

typedef struct LocalScribeGigaAM LocalScribeGigaAM;

bool localscribe_gigaam_available(void);
LocalScribeGigaAM *localscribe_gigaam_create(const char *encoder, const char *decoder,
    const char *joiner, const char *tokens);
const char *localscribe_gigaam_recognize(LocalScribeGigaAM *engine, const float *samples, int32_t count);
void localscribe_gigaam_free_result(const char *result);
void localscribe_gigaam_destroy(LocalScribeGigaAM *engine);
