// FFI bridge shared by every platform: the Dart side sends a JSON request and
// gets a JSON response back. Platform differences are limited to the few
// conditional blocks below.
#include "whisper_ggml_plus.h"

#include "whisper/include/whisper.h"
#include "whisper/ggml/include/ggml-backend.h"

#define DR_WAV_IMPLEMENTATION
#include "whisper/examples/dr_wav.h"

#include <atomic>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
#include <codecvt>
#include <locale>
#endif

#ifdef __ANDROID__
#include <android/log.h>
#endif

#if defined(WHISPER_GGML_PLUS_CPU_DISPATCH) && !defined(_WIN32)
#include <dlfcn.h>
#endif

#include "json/json.hpp"

using json = nlohmann::json;

#ifdef WHISPER_GGML_PLUS_NATIVE_VAD
// Implemented in vad_helper.mm, compiled only by the CocoaPods build: the
// Silero model bundled in flutter_assets
extern "C" const char * get_vad_model_path();
#endif

static void log_debug(const char * fmt, ...) {
    va_list args;
    va_start(args, fmt);
#ifdef __ANDROID__
    __android_log_vprint(ANDROID_LOG_DEBUG, "WhisperFlutter", fmt, args);
#else
    std::vfprintf(stderr, fmt, args);
    std::fputc('\n', stderr);
    std::fflush(stderr);
#endif
    va_end(args);
}

enum class whisper_vad_mode {
    auto_mode,
    disabled,
    enabled,
};

struct whisper_params {
    int32_t seed = -1;
    int32_t n_threads = std::min(4, (int32_t) std::thread::hardware_concurrency());

    int32_t n_processors = 1;
    int32_t offset_t_ms = 0;
    int32_t offset_n = 0;
    int32_t duration_ms = 0;
    int32_t max_context = -1;
    int32_t max_len = 0;
    int32_t best_of = 5;
    int32_t beam_size = -1;

    float word_thold = 0.01f;
    float entropy_thold = 2.40f;
    float logprob_thold = -1.00f;

    bool verbose = false;
    bool print_special_tokens = false;
    bool speed_up = false;
    bool translate = false;
    bool diarize = false;
    bool no_fallback = false;
    bool output_txt = false;
    bool output_vtt = false;
    bool output_srt = false;
    bool output_wts = false;
    bool output_csv = false;
    bool print_special = false;
    bool print_colors = false;
    bool print_progress = false;
    bool no_timestamps = false;
    bool split_on_word = false;
    whisper_vad_mode vad_mode = whisper_vad_mode::auto_mode;

    std::string language = "id";
    std::string prompt;
    std::string model = "";
    std::string audio = "";
    std::string vad_model_path = "";
    std::vector<std::string> fname_inp = {};
    std::vector<std::string> fname_outp = {};
};

static whisper_vad_mode parse_vad_mode(const json & json_body) {
    const std::string vad_mode = json_body.value("vad_mode", std::string("auto"));
    if (vad_mode == "disabled") {
        return whisper_vad_mode::disabled;
    }
    if (vad_mode == "enabled") {
        return whisper_vad_mode::enabled;
    }
    return whisper_vad_mode::auto_mode;
}

static std::string default_vad_model_path() {
#ifdef WHISPER_GGML_PLUS_NATIVE_VAD
    const char * vad_path = get_vad_model_path();
    return vad_path == nullptr ? std::string() : std::string(vad_path);
#else
    // Other platforms receive the extracted asset path from the Dart side
    return std::string();
#endif
}

#ifdef WHISPER_GGML_PLUS_CPU_DISPATCH
// Directory holding this library: ggml's CPU variants are bundled next to it.
// On Windows every DLL sits beside the executable, which ggml searches by
// itself, so only Linux needs the explicit directory.
static std::string plugin_directory() {
#ifdef _WIN32
    return std::string();
#else
    Dl_info info;
    if (dladdr(reinterpret_cast<void *>(&request), &info) == 0 || info.dli_fname == nullptr) {
        return std::string();
    }
    std::string path(info.dli_fname);
    const size_t slash = path.find_last_of('/');
    return slash == std::string::npos ? std::string() : path.substr(0, slash);
#endif
}
#endif

// With dynamic backends nothing is registered until loaded: pick the best CPU
// variant for this machine once, before any whisper call. Returns an error
// message when no CPU backend could be loaded.
static std::string load_backends_once() {
#ifdef WHISPER_GGML_PLUS_CPU_DISPATCH
    static std::once_flag once;
    static std::string searched;
    std::call_once(once, [] {
        searched = plugin_directory();
        ggml_backend_load_all_from_path(searched.empty() ? nullptr : searched.c_str());
    });
    if (ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU) == nullptr) {
        return "no ggml CPU backend found in " + (searched.empty() ? std::string("the executable directory") : searched);
    }
#endif
    return std::string();
}

static std::string cpu_backend_description() {
    ggml_backend_dev_t cpu = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
    return cpu == nullptr ? std::string("none") : std::string(ggml_backend_dev_description(cpu));
}

static struct whisper_context * g_ctx = nullptr;
static std::string g_model_path = "";
static std::mutex g_mutex;
static std::atomic<bool> g_should_abort(false);

static void dispose_context_locked() {
    if (g_ctx != nullptr) {
        whisper_free(g_ctx);
        g_ctx = nullptr;
    }
    g_model_path.clear();
}

static bool abort_callback(void * user_data) {
    (void) user_data;
    return g_should_abort.load();
}

#ifdef _WIN32
static std::wstring utf8_to_wstring(const std::string & path) {
    std::wstring_convert<std::codecvt_utf8<wchar_t>> converter;
    return converter.from_bytes(path);
}
#endif

static char * json_to_char(const json & json_data) {
    try {
        // Escape non-ASCII and replace malformed UTF-8 so the string survives the FFI boundary
        std::string result = json_data.dump(-1, ' ', true, nlohmann::json::error_handler_t::replace);
        char * ch = new char[result.size() + 1];
        std::strcpy(ch, result.c_str());
        return ch;
    } catch (const std::exception &) {
        std::string error_json = "{\"@type\":\"error\",\"message\":\"JSON serialization failed\"}";
        char * ch = new char[error_json.size() + 1];
        std::strcpy(ch, error_json.c_str());
        return ch;
    }
}

static json transcribe(const json & json_body) {
    std::lock_guard<std::mutex> lock(g_mutex);

    g_should_abort.store(false);

    json json_result;
    json_result["@type"] = "transcribe";

    const std::string backend_error = load_backends_once();
    if (!backend_error.empty()) {
        json_result["@type"] = "error";
        json_result["message"] = backend_error;
        return json_result;
    }

    whisper_params params;
    params.n_threads = json_body["threads"];
    params.verbose = json_body["is_verbose"];
    params.translate = json_body["is_translate"];
    params.language = json_body["language"];
    params.print_special_tokens = json_body["is_special_tokens"];
    params.no_timestamps = json_body["is_no_timestamps"];
    params.model = json_body["model"];
    params.audio = json_body["audio"];
    params.split_on_word = json_body["split_on_word"];
    params.diarize = json_body["diarize"];
    params.speed_up = json_body["speed_up"];
    params.vad_mode = parse_vad_mode(json_body);
    params.vad_model_path = json_body.value("vad_model_path", std::string(""));
    if (json_body.contains("prompt") && json_body["prompt"].is_string()) {
        params.prompt = json_body["prompt"].get<std::string>();
    }

    if (g_ctx == nullptr || g_model_path != params.model) {
        dispose_context_locked();

        whisper_context_params cparams = whisper_context_default_params();
        // Flash attention pays off on the Metal GPU path; on CPU-only builds
        // its block-wise kernel does far more fp16 conversions, which are
        // software routines on CPUs without F16C
#ifdef GGML_USE_METAL
        cparams.use_gpu = true;
        cparams.flash_attn = true;
#else
        cparams.use_gpu = false;
        cparams.flash_attn = false;
#endif

        g_ctx = whisper_init_from_file_with_params(params.model.c_str(), cparams);
        if (g_ctx != nullptr) {
            g_model_path = params.model;
        }
    }

    if (g_ctx == nullptr) {
        json_result["@type"] = "error";
        json_result["message"] = "failed to initialize whisper context (possibly OOM)";
        return json_result;
    }

    std::vector<float> pcmf32;
    {
        drwav wav;
#ifdef _WIN32
        const std::wstring audio_path = utf8_to_wstring(params.audio);
        if (!drwav_init_file_w(&wav, audio_path.c_str(), nullptr)) {
#else
        if (!drwav_init_file(&wav, params.audio.c_str(), nullptr)) {
#endif
            json_result["@type"] = "error";
            json_result["message"] = " failed to open WAV file ";
            return json_result;
        }

        int n = wav.totalPCMFrameCount;
        std::vector<int16_t> pcm16(n * wav.channels);
        drwav_read_pcm_frames_s16(&wav, n, pcm16.data());
        drwav_uninit(&wav);

        pcmf32.resize(n);
        if (wav.channels == 1) {
            for (int i = 0; i < n; ++i) {
                pcmf32[i] = float(pcm16[i]) / 32768.0f;
            }
        } else {
            for (int i = 0; i < n; ++i) {
                pcmf32[i] = float(pcm16[2 * i] + pcm16[2 * i + 1]) / 65536.0f;
            }
        }
    }

    const int model_n_text_layer = whisper_model_n_text_layer(g_ctx);
    const int model_n_vocab = whisper_model_n_vocab(g_ctx);
    const bool is_turbo = model_n_text_layer == 4 && model_n_vocab == 51866;

    log_debug("[DEBUG] Model info - n_text_layer: %d, n_vocab: %d, is_turbo: %d",
              model_n_text_layer, model_n_vocab, is_turbo);

    whisper_sampling_strategy strategy = is_turbo ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY;
    whisper_full_params wparams = whisper_full_default_params(strategy);

    wparams.print_realtime = false;
    wparams.print_progress = false;
    wparams.print_timestamps = !params.no_timestamps;
    wparams.translate = params.translate;
    wparams.language = params.language.c_str();
    wparams.n_threads = params.n_threads;
    wparams.split_on_word = params.split_on_word;
    if (!params.prompt.empty()) {
        wparams.initial_prompt = params.prompt.c_str();
    }
    wparams.audio_ctx = params.speed_up ? 768 : 0;
    wparams.single_segment = false;

    if (params.split_on_word) {
        log_debug("[DEBUG] Disabling VAD because split_on_word requires stable timestamps");
        wparams.vad = false;
    } else if (params.vad_mode == whisper_vad_mode::disabled) {
        wparams.vad = false;
    } else {
        if (params.vad_model_path.empty()) {
            params.vad_model_path = default_vad_model_path();
        }
        if (!params.vad_model_path.empty()) {
            wparams.vad = true;
            wparams.vad_model_path = params.vad_model_path.c_str();
        } else if (params.vad_mode == whisper_vad_mode::enabled) {
            json_result["@type"] = "error";
            json_result["message"] =
                "VAD was explicitly enabled but no vad_model_path was available";
            return json_result;
        } else {
            wparams.vad = false;
        }
    }

    if (is_turbo) {
        wparams.beam_search.beam_size = 3;
        log_debug("[DEBUG] Turbo model detected - using beam search (beam_size=3)");
    }

    if (params.split_on_word) {
        wparams.max_len = 1;
        wparams.token_timestamps = true;
    }

    wparams.abort_callback = abort_callback;
    wparams.abort_callback_user_data = nullptr;

    log_debug("[DEBUG] Transcription params - threads: %d, speed_up: %d, no_timestamps: %d, single_segment: %d, split_on_word: %d, max_len: %d",
              wparams.n_threads,
              params.speed_up,
              wparams.no_timestamps,
              wparams.single_segment,
              wparams.split_on_word,
              wparams.max_len);

    auto start_time = std::chrono::high_resolution_clock::now();

    if (whisper_full(g_ctx, wparams, pcmf32.data(), pcmf32.size()) != 0) {
        if (g_should_abort.load()) {
            json_result["@type"] = "aborted";
            json_result["message"] = "transcription aborted by user";
            g_should_abort.store(false);
            return json_result;
        }
        json_result["@type"] = "error";
        json_result["message"] = "failed to process audio";
        return json_result;
    }

    auto end_time = std::chrono::high_resolution_clock::now();
    auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(end_time - start_time).count();

    log_debug("[DEBUG] Transcription completed in %lldms", (long long) duration);

    const int n_segments = whisper_full_n_segments(g_ctx);
    std::vector<json> segments_json = {};
    std::string text_result = "";

    for (int i = 0; i < n_segments; ++i) {
        const char * text = whisper_full_get_segment_text(g_ctx, i);
        text_result += std::string(text);

        if (!params.no_timestamps) {
            json json_segment;
            json_segment["from_ts"] = whisper_full_get_segment_t0(g_ctx, i);
            json_segment["to_ts"] = whisper_full_get_segment_t1(g_ctx, i);
            json_segment["text"] = text;
            segments_json.push_back(json_segment);
        }
    }

    if (!params.no_timestamps) {
        json_result["segments"] = segments_json;
    }

    json_result["text"] = text_result;
    return json_result;
}

extern "C" {

FUNCTION_ATTRIBUTE char *request(char *body) {
    try {
        json json_body = json::parse(body);
        if (json_body["@type"] == "abort") {
            g_should_abort.store(true);
            return json_to_char({{"@type", "abort"}, {"message", "abort signal sent"}});
        }
        if (json_body["@type"] == "dispose") {
            std::lock_guard<std::mutex> lock(g_mutex);
            dispose_context_locked();
            return json_to_char({{"@type", "dispose"}, {"message", "whisper context disposed"}});
        }
        if (json_body["@type"] == "getTextFromWavFile") {
            return json_to_char(transcribe(json_body));
        }
        if (json_body["@type"] == "getVersion") {
            const std::string backend_error = load_backends_once();
            if (!backend_error.empty()) {
                return json_to_char({{"@type", "error"}, {"message", backend_error}});
            }
            return json_to_char({{"@type", "version"},
                                 {"message", "lib v1.8.3-accel (cpu: " + cpu_backend_description() + ")"}});
        }
        return json_to_char({{"@type", "error"}, {"message", "method not found"}});
    } catch (const std::exception & e) {
        return json_to_char({{"@type", "error"}, {"message", e.what()}});
    }
}

FUNCTION_ATTRIBUTE void free_string(char *ptr) {
    delete[] ptr;
}

}
