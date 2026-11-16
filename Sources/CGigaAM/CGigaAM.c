#include "CGigaAM.h"
#include <stddef.h>

#if defined(LOCALSCRIBE_GIGAAM_STATIC)

#include "upstream/sherpa-onnx-c-api.h"

bool localscribe_gigaam_available(void) {
    return true;
}

LocalScribeGigaAM *localscribe_gigaam_create(const char *encoder, const char *decoder,
    const char *joiner, const char *tokens) {
    SherpaOnnxOfflineRecognizerConfig config = {0};
    config.feat_config.sample_rate = 16000;
    config.feat_config.feature_dim = 80;
    config.model_config.transducer.encoder = encoder;
    config.model_config.transducer.decoder = decoder;
    config.model_config.transducer.joiner = joiner;
    config.model_config.tokens = tokens;
    config.model_config.model_type = "nemo_transducer";
    config.model_config.num_threads = 2;
    config.model_config.provider = "cpu";
    config.decoding_method = "greedy_search";
    return (LocalScribeGigaAM *)SherpaOnnxCreateOfflineRecognizer(&config);
}

const char *localscribe_gigaam_recognize(LocalScribeGigaAM *engine, const float *samples, int32_t count) {
    const SherpaOnnxOfflineRecognizer *recognizer = (const SherpaOnnxOfflineRecognizer *)engine;
    const SherpaOnnxOfflineStream *stream = SherpaOnnxCreateOfflineStream(recognizer);
    if (!stream) return NULL;
    SherpaOnnxAcceptWaveformOffline(stream, 16000, samples, count);
    SherpaOnnxDecodeOfflineStream(recognizer, stream);
    const char *result = SherpaOnnxGetOfflineStreamResultAsJson(stream);
    SherpaOnnxDestroyOfflineStream(stream);
    return result;
}

void localscribe_gigaam_free_result(const char *result) {
    SherpaOnnxDestroyOfflineStreamResultJson(result);
}

void localscribe_gigaam_destroy(LocalScribeGigaAM *engine) {
    SherpaOnnxDestroyOfflineRecognizer((const SherpaOnnxOfflineRecognizer *)engine);
}

#else

// Plain SwiftPM builds can run contract tests without fetching the runtime.
bool localscribe_gigaam_available(void) { return false; }
LocalScribeGigaAM *localscribe_gigaam_create(const char *encoder, const char *decoder,
    const char *joiner, const char *tokens) { return NULL; }
const char *localscribe_gigaam_recognize(LocalScribeGigaAM *engine, const float *samples, int32_t count) { return NULL; }
void localscribe_gigaam_free_result(const char *result) {}
void localscribe_gigaam_destroy(LocalScribeGigaAM *engine) {}

#endif
