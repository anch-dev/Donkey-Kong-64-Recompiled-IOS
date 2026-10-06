#include <cstdio>
#include <cassert>
#include <unordered_map>
#include <vector>
#include <array>
#include <filesystem>
#include <numeric>
#include <stdexcept>
#include <cinttypes>
#include <chrono>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#if !defined(DK64_IOS)
#include "nfd.h"
#else
#include "ios_platform.h"
#include "ios_touch_controls.h"
#include "ios_log.h"
#endif

#include "ultramodern/ultra64.h"
#include "ultramodern/ultramodern.hpp"
#include "ultramodern/config.hpp"
#if !defined(DK64_IOS)
#define SDL_MAIN_HANDLED
#endif
#ifdef _WIN32
#include "SDL.h"
#else
#include "SDL2/SDL.h"
#include "SDL2/SDL_syswm.h"
#if defined(__APPLE__)
#include "SDL2/SDL_metal.h"
#endif
// Undefine x11 macros that get included by SDL_syswm.h.
#undef None
#undef Status
#undef LockMask
#undef ControlMask
#undef Success
#undef Always
#endif

#include "recompui/recompui.h"
#include "recompui/program_config.h"
#include "recompui/renderer.h"
#include "recompui/config.h"
#include "util/file.h"
#include "recompinput/input_events.h"
#include "recompinput/recompinput.h"
#include "recompinput/profiles.h"
#include "donk_config.h"
#include "donk_sound.h"
#include "donk_draw.h"
#include "donk_support.h"
#include "donk_game.h"
#include "donk_launcher.h"
#include "recomp_data.h"
#include "ovl_patches.hpp"
#include "theme.h"
#include "librecomp/game.hpp"
#include "librecomp/mods.hpp"
#include "librecomp/helpers.hpp"

#include "../../patches/graphics.h"
#include "../../patches/input.h"
#include "../../patches/sound.h"
#include "../../patches/options.h"
#include "../../patches/ui.h"
#include "../../patches/misc_funcs.h"

namespace {

class PacingRendererContext final : public ultramodern::renderer::RendererContext {
public:
    explicit PacingRendererContext(std::unique_ptr<ultramodern::renderer::RendererContext> inner_context)
        : inner(std::move(inner_context)) {
        setup_result = inner->get_setup_result();
        chosen_api = inner->get_chosen_api();
    }

    bool valid() override {
        return inner->valid();
    }

    bool update_config(const ultramodern::renderer::GraphicsConfig& old_config, const ultramodern::renderer::GraphicsConfig& new_config) override {
        return inner->update_config(old_config, new_config);
    }

    void enable_instant_present() override {
        inner->enable_instant_present();
    }

    void send_dl(const OSTask* task) override {
        inner->send_dl(task);
    }

    void send_dummy_workload(uint32_t fb_address) override {
        inner->send_dummy_workload(fb_address);
    }

    void update_screen() override {
        inner->update_screen();
    }

    void shutdown() override {
        inner->shutdown();
    }

    uint32_t get_display_framerate() const override {
        return inner->get_display_framerate();
    }

    float get_resolution_scale() const override {
        return inner->get_resolution_scale();
    }

private:
    std::unique_ptr<ultramodern::renderer::RendererContext> inner;
};

std::unique_ptr<ultramodern::renderer::RendererContext> create_pacing_render_context(uint8_t* rdram, ultramodern::renderer::WindowHandle window_handle, bool developer_mode) {
    auto presentation_mode = ultramodern::renderer::PresentationMode::PresentEarly;
    auto render_context = recompui::renderer::create_render_context(rdram, window_handle, presentation_mode, developer_mode);
    return std::make_unique<PacingRendererContext>(std::move(render_context));
}
}

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <Windows.h>
#include <timeapi.h>
#include "SDL_syswm.h"
#define APP_ICON_B 1
#define APP_ICON_K 2
#endif

#include "../../lib/rt64/src/contrib/stb/stb_image.h"

const std::string version_string = "1.0.3";

template<typename... Ts>
void exit_error(const char* str, Ts ...args) {
    // TODO pop up an error
    ((void)fprintf(stderr, str, args), ...);
    assert(false);
        
    ultramodern::error_handling::quick_exit(__FILE__, __LINE__, __FUNCTION__);
}

ultramodern::gfx_callbacks_t::gfx_data_t create_gfx() {
    SDL_SetHint(SDL_HINT_WINDOWS_DPI_AWARENESS, "permonitorv2");
    SDL_SetHint(SDL_HINT_GAMECONTROLLER_USE_BUTTON_LABELS, "0");
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI_PS4_RUMBLE, "1");
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI_PS5_RUMBLE, "1");
    SDL_SetHint(SDL_HINT_MOUSE_FOCUS_CLICKTHROUGH, "1");
#if defined(DK64_IOS)
    // RmlUi launcher/config menus consume SDL mouse events. On iOS, explicitly
    // ask SDL to synthesize those mouse events from UIKit touch input.
    SDL_SetHint(SDL_HINT_TOUCH_MOUSE_EVENTS, "1");
#endif
    SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");

    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_GAMECONTROLLER | SDL_INIT_JOYSTICK | SDL_INIT_HAPTIC) > 0) {
        exit_error("Failed to initialize SDL2: %s\n", SDL_GetError());
    }

    fprintf(stdout, "SDL Video Driver: %s\n", SDL_GetCurrentVideoDriver());

    return {};
}

ultramodern::input::connected_device_info_t get_connected_device_info(int controller_num) {
    if (recompinput::players::is_single_player_mode() || recompinput::players::get_player_is_assigned(controller_num)) {
        return ultramodern::input::connected_device_info_t{
            .connected_device = ultramodern::input::Device::Controller,
            .connected_pak = ultramodern::input::Pak::RumblePak,
        };
    }

    return ultramodern::input::connected_device_info_t{
        .connected_device = ultramodern::input::Device::None,
        .connected_pak = ultramodern::input::Pak::None,
    };
}

#include "icon_bytes.h"

#if defined(__gnu_linux__)
bool SetImageAsIcon(const char* filename, SDL_Window* window)
{
    // Read data
    int width, height, bytesPerPixel;
    void* data = stbi_load_from_memory(reinterpret_cast<const uint8_t*>(icon_bytes), sizeof(icon_bytes), &width, &height, &bytesPerPixel, 4);

    // Calculate pitch
    int pitch;
    pitch = width * 4;
    pitch = (pitch + 3) & ~3;

    // Setup relevance bitmask
    int Rmask, Gmask, Bmask, Amask;

#if SDL_BYTEORDER == SDL_LIL_ENDIAN
    Rmask = 0x000000FF;
    Gmask = 0x0000FF00;
    Bmask = 0x00FF0000;
    Amask = 0xFF000000;
#else
    Rmask = 0xFF000000;
    Gmask = 0x00FF0000;
    Bmask = 0x0000FF00;
    Amask = 0x000000FF;
#endif

    SDL_Surface* surface = nullptr;
    if (data != nullptr) {
        surface = SDL_CreateRGBSurfaceFrom(data, width, height, 32, pitch, Rmask, Gmask,
                            Bmask, Amask);
    }

    if (surface == nullptr) {   
        if (data != nullptr) {
            stbi_image_free(data);
        }
        return false;
	} else {
        SDL_SetWindowIcon(window,surface);
        SDL_FreeSurface(surface);
        stbi_image_free(data);
        return true;
    }
}
#endif

SDL_Window* window;

ultramodern::renderer::WindowHandle create_window(ultramodern::gfx_callbacks_t::gfx_data_t) {
    uint32_t flags = SDL_WINDOW_RESIZABLE;

#if defined(DK64_IOS)
    // iOS uses point-based window coordinates; request the native Retina drawable.
    flags |= SDL_WINDOW_ALLOW_HIGHDPI;
#endif

#if defined(__APPLE__)
    flags |= SDL_WINDOW_METAL;
#elif defined(RT64_SDL_WINDOW_VULKAN)
    flags |= SDL_WINDOW_VULKAN;
#endif

    window = SDL_CreateWindow("DK64: Recompiled", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, 1600, 900,  flags);

    if (window == nullptr) {
        exit_error("Failed to create window: %s\n", SDL_GetError());
    }

    SDL_SysWMinfo wmInfo;
    SDL_VERSION(&wmInfo.version);
    SDL_GetWindowWMInfo(window, &wmInfo);

#if defined(_WIN32)
    bool choose_kazooie_icon = (rand() % 2 == 0);
    HICON new_icon = LoadIcon(GetModuleHandle(NULL), choose_kazooie_icon ? MAKEINTRESOURCE(APP_ICON_K) : MAKEINTRESOURCE(APP_ICON_B));
    SendMessage(wmInfo.info.win.window, WM_SETICON, ICON_SMALL2, (LPARAM)(new_icon));
#elif defined(__linux__)
    SetImageAsIcon("icons/app.png", window);
#endif

#if defined(_WIN32)
    return ultramodern::renderer::WindowHandle{ wmInfo.info.win.window, GetCurrentThreadId() };
#elif defined(__linux__) || defined(__ANDROID__)
    return ultramodern::renderer::WindowHandle{ window };
#elif defined(__APPLE__)
    SDL_MetalView view = SDL_Metal_CreateView(window);
#if defined(DK64_IOS)
    void* ui_window = reinterpret_cast<void*>(wmInfo.info.uikit.window);
    void* metal_layer = reinterpret_cast<void*>(SDL_Metal_GetLayer(view));
    dk64_ios_fix_metal_layer_scale(ui_window, metal_layer);

    // Install the touch overlay (own UIWindow above the SDL window) once the Metal view exists.
    dk64_ios_log_window_info(window);
    dk64_ios_log_install_event_watch();
    dk64_ios_touch_controls_init(window);
    dk64_ios_touch_controls_set_visible(1);

    return ultramodern::renderer::WindowHandle{ ui_window, metal_layer };
#else
    return ultramodern::renderer::WindowHandle{ wmInfo.info.cocoa.window, SDL_Metal_GetLayer(view) };
#endif
#else
    static_assert(false && "Unimplemented");
#endif
}

void update_gfx(void*) {
#if defined(DK64_IOS)
    // The touch overlay lives in its own transparent UIWindow above the SDL window and is shown only during gameplay
    // (it owns every touch then). In menus it is hidden and SDL's touch->mouse translation drives the UI.
    dk64_ios_log_frame_tick();
    {
        static int last_started = -1, last_capturing = -1;
        const int started = ultramodern::is_game_started() ? 1 : 0;
        const int capturing = recompui::is_context_capturing_input() ? 1 : 0;
        if (started != last_started || capturing != last_capturing) {
            DK64_LOG("STATE game_started=%d ui_capturing_input=%d", started, capturing);
            last_started = started;
            last_capturing = capturing;
        }
    }
    dk64_ios_touch_controls_set_gameplay(ultramodern::is_game_started() && !recompui::is_context_capturing_input() ? 1 : 0);
    dk64_ios_touch_controls_tick();
#endif
    recompinput::handle_events();
}

static SDL_AudioCVT audio_convert;
static SDL_AudioDeviceID audio_device = 0;

// Samples per channel per second.
static uint32_t sample_rate = 48000;
static uint32_t output_sample_rate = 48000;
// Channel count.
constexpr uint32_t input_channels = 2;
static uint32_t output_channels = 2;

// Terminology: a frame is a collection of samples for each channel. e.g. 2 input samples is one input frame. This is unrelated to graphical frames.

// Number of frames to duplicate for fixing interpolation at the start and end of a chunk.
constexpr uint32_t duplicated_input_frames = 4;
// The number of output frames to skip for playback (to avoid playing duplicate inputs twice).
static uint32_t discarded_output_frames;

constexpr uint32_t bytes_per_frame = input_channels * sizeof(float);

void queue_samples(int16_t* audio_data, size_t sample_count) {
    // Buffer for holding the output of swapping the audio channels. This is reused across
    // calls to reduce runtime allocations.
    static std::vector<float> swap_buffer;
    static std::array<float, duplicated_input_frames * input_channels> duplicated_sample_buffer;

    // Make sure the swap buffer is large enough to hold the audio data, including any extra space needed for resampling.
    size_t resampled_sample_count = sample_count + duplicated_input_frames * input_channels;
    size_t max_sample_count = std::max(resampled_sample_count, resampled_sample_count * audio_convert.len_mult);
    if (max_sample_count > swap_buffer.size()) {
        swap_buffer.resize(max_sample_count);
    }
    
    // Copy the duplicated frames from last chunk into this chunk
    for (size_t i = 0; i < duplicated_input_frames * input_channels; i++) {
        swap_buffer[i] = duplicated_sample_buffer[i];
    }

    // Convert the audio from 16-bit values to floats and swap the audio channels into the
    // swap buffer to correct for the address xor caused by endianness handling.
    float cur_main_volume = static_cast<float>(recompui::config::sound::get_main_volume()) / 100.0f; // Get the current main volume, normalized to 0.0-1.0.
#if defined(DK64_IOS)
    {
        static float last_logged_volume = -1.0f;
        if (cur_main_volume != last_logged_volume) {
            DK64_LOG("AUDIO main volume = %.2f", cur_main_volume);
            last_logged_volume = cur_main_volume;
        }
    }
#endif
    for (size_t i = 0; i < sample_count; i += input_channels) {
        swap_buffer[i + 0 + duplicated_input_frames * input_channels] = audio_data[i + 1] * (0.5f / 32768.0f) * cur_main_volume;
        swap_buffer[i + 1 + duplicated_input_frames * input_channels] = audio_data[i + 0] * (0.5f / 32768.0f) * cur_main_volume;
    }
    
    // TODO handle cases where a chunk is smaller than the duplicated frame count.
    assert(sample_count > duplicated_input_frames * input_channels);

    // Copy the last converted samples into the duplicated sample buffer to reuse in resampling the next queued chunk.
    for (size_t i = 0; i < duplicated_input_frames * input_channels; i++) {
        duplicated_sample_buffer[i] = swap_buffer[i + sample_count];
    }
    
    audio_convert.buf = reinterpret_cast<Uint8*>(swap_buffer.data());
    audio_convert.len = (sample_count + duplicated_input_frames * input_channels) * sizeof(swap_buffer[0]);

    int ret = SDL_ConvertAudio(&audio_convert);

    if (ret < 0) {
        printf("Error using SDL audio converter: %s\n", SDL_GetError());
        throw std::runtime_error("Error using SDL audio converter");
    }

    uint64_t cur_queued_microseconds = uint64_t(SDL_GetQueuedAudioSize(audio_device)) / bytes_per_frame * 1000000 / sample_rate;
    uint32_t num_bytes_to_queue = audio_convert.len_cvt - output_channels * discarded_output_frames * sizeof(swap_buffer[0]);
    float* samples_to_queue = swap_buffer.data() + output_channels * discarded_output_frames / 2;

    // Prevent audio latency from building up by skipping samples in incoming audio when too many samples are already queued.
    // Skip samples based on how many microseconds of samples are queued already.
    uint32_t skip_factor = cur_queued_microseconds / 100000;
#if defined(DK64_IOS)
    {
        // Audio diagnostics (written to DK64Logs/dk64.log). The queue is measured in OUTPUT-rate frames, so also log the
        // true queued time; the game's own figure above divides by the input sample rate.
        static Uint64 window_start = 0, last_call = 0, last_event_log = 0;
        static uint32_t calls = 0, skips = 0, starved = 0;
        static uint64_t q_min = UINT64_MAX, q_max = 0, q_sum = 0, max_gap_us = 0;
        const Uint64 freq = SDL_GetPerformanceFrequency();
        const Uint64 now = SDL_GetPerformanceCounter();
        const uint64_t true_queued_us = uint64_t(SDL_GetQueuedAudioSize(audio_device)) / bytes_per_frame * 1000000 / output_sample_rate;
        if (window_start == 0) { window_start = now; last_call = now; }
        const uint64_t gap_us = (now - last_call) * 1000000 / freq;
        last_call = now;
        calls++;
        q_min = std::min(q_min, true_queued_us);
        q_max = std::max(q_max, true_queued_us);
        q_sum += true_queued_us;
        max_gap_us = std::max(max_gap_us, gap_us);
        const bool ran_dry = true_queued_us < 2000;  // device had (almost) nothing left: an underrun/gap is likely
        if (ran_dry) starved++;
        if (skip_factor != 0) skips++;
        if ((skip_factor != 0 || ran_dry) && (now - last_event_log) * 1000 / freq > 250) {
            last_event_log = now;
            DK64_LOG("AUDIO %s: queued(true)=%.1fms queued(game calc)=%.1fms skip_factor=%u gap_since_last_call=%.1fms incoming=%zu samples in_rate=%u out_rate=%u",
                     skip_factor != 0 ? "SKIPPING SAMPLES (latency limiter)" : "QUEUE RAN DRY (likely underrun)",
                     true_queued_us / 1000.0, cur_queued_microseconds / 1000.0, skip_factor, gap_us / 1000.0, sample_count, sample_rate, output_sample_rate);
        }
        if ((now - window_start) / freq >= 5) {
            DK64_LOG("AUDIO 5s summary: calls=%u queued ms min/avg/max=%.1f/%.1f/%.1f max_gap=%.1fms skips=%u ran_dry=%u in_rate=%u out_rate=%u",
                     calls, q_min / 1000.0, (q_sum / (double)std::max(calls, 1u)) / 1000.0, q_max / 1000.0, max_gap_us / 1000.0, skips, starved,
                     sample_rate, output_sample_rate);
            window_start = now; calls = skips = starved = 0; q_min = UINT64_MAX; q_max = q_sum = max_gap_us = 0;
        }
    }
#endif
    if (skip_factor != 0) {
        uint32_t skip_ratio = 1 << skip_factor;
        num_bytes_to_queue /= skip_ratio;
        for (size_t i = 0; i < num_bytes_to_queue / (output_channels * sizeof(swap_buffer[0])); i++) {
            samples_to_queue[2 * i + 0] = samples_to_queue[2 * skip_ratio * i + 0];
            samples_to_queue[2 * i + 1] = samples_to_queue[2 * skip_ratio * i + 1];
        }
    }

    // Queue the swapped audio data.
    // Offset the data start by only half the discarded frame count as the other half of the discarded frames are at the end of the buffer.
    SDL_QueueAudio(audio_device, samples_to_queue, num_bytes_to_queue);
}

size_t get_frames_remaining() {
    constexpr float buffer_offset_frames = 1.0f;
    // Get the number of remaining buffered audio bytes.
    uint64_t buffered_byte_count = SDL_GetQueuedAudioSize(audio_device);

    // Scale the byte count based on the ratio of sample rates and channel counts.
    buffered_byte_count = buffered_byte_count * 2 * sample_rate / output_sample_rate / output_channels;

    // Adjust the reported count to be some number of refreshes in the future, which helps ensure that
    // there are enough samples even if the audio thread experiences a small amount of lag. This prevents
    // audio popping on games that use the buffered audio byte count to determine how many samples
    // to generate.
    uint32_t frames_per_vi = (sample_rate / 60);
    if (buffered_byte_count > (buffer_offset_frames * bytes_per_frame * frames_per_vi)) {
        buffered_byte_count -= (buffer_offset_frames * bytes_per_frame * frames_per_vi);
    }
    else {
        buffered_byte_count = 0;
    }
    // Convert from byte count to sample count.
    return static_cast<uint32_t>(buffered_byte_count / bytes_per_frame);
}

void update_audio_converter() {
    int ret = SDL_BuildAudioCVT(&audio_convert, AUDIO_F32, input_channels, sample_rate, AUDIO_F32, output_channels, output_sample_rate);

    if (ret < 0) {
        printf("Error creating SDL audio converter: %s\n", SDL_GetError());
        throw std::runtime_error("Error creating SDL audio converter");
    }

    // Calculate the number of samples to discard based on the sample rate ratio and the duplicate frame count.
    discarded_output_frames = duplicated_input_frames * output_sample_rate / sample_rate;
}

void set_frequency(uint32_t freq) {
#if defined(DK64_IOS)
    DK64_LOG("AUDIO game sample rate changed: %u -> %u Hz", sample_rate, freq);
#endif
    sample_rate = freq;
    
    update_audio_converter();
}

bool reset_audio(uint32_t output_freq) {
    SDL_AudioSpec spec_desired{
        .freq = (int)output_freq,
        .format = AUDIO_F32,
        .channels = (Uint8)output_channels,
        .silence = 0, // calculated
        .samples = 0x100, // Fairly small sample count to reduce the latency of internal buffering
        .padding = 0, // unused
        .size = 0, // calculated
        .callback = nullptr,
        .userdata = nullptr
    };

#if defined(DK64_IOS)
    SDL_AudioSpec obtained{};
    audio_device = SDL_OpenAudioDevice(nullptr, false, &spec_desired, &obtained, 0);
    DK64_LOG("AUDIO device opened: id=%u driver=%s asked freq=%d samples=%u -> got freq=%d format=0x%x channels=%u samples=%u size=%u bytes",
             (unsigned)audio_device, SDL_GetCurrentAudioDriver() ? SDL_GetCurrentAudioDriver() : "?", spec_desired.freq, (unsigned)spec_desired.samples,
             obtained.freq, (unsigned)obtained.format, (unsigned)obtained.channels, (unsigned)obtained.samples, (unsigned)obtained.size);
#else
    audio_device = SDL_OpenAudioDevice(nullptr, false, &spec_desired, nullptr, 0);
#endif
    if (audio_device == 0) {
        std::string audio_error = std::string("No audio device could be found. Please make sure an audio device is available.\nError opening audio device: ") + std::string(SDL_GetError());
        recompui::message_box(audio_error.c_str());
        return false;
    }

    SDL_PauseAudioDevice(audio_device, 0);

    output_sample_rate = output_freq;
    update_audio_converter();

    return true;
}

extern RspUcodeFunc n_aspMain;

RspUcodeFunc* get_rsp_microcode(const OSTask* task) {
    switch (task->t.type) {
    case M_AUDTASK:
        return n_aspMain;

    default:
        fprintf(stderr, "Unknown task: %" PRIu32 "\n", task->t.type);
        return nullptr;
    }
}

extern "C" void recomp_entrypoint(uint8_t * rdram, recomp_context * ctx);
gpr get_entrypoint_address();

// array of supported GameEntry objects
std::vector<recomp::GameEntry> supported_games = {
    {
        .rom_hash = 0x4d876060f09b3fc5ULL,
        .internal_name = "DONKEY KONG 64",
        .display_name = "Donkey Kong 64",
        .game_id = u8"DK64",
        .mod_game_id = "dk64",
        .discovery_url = "https://dk64recomp.com/mods.json",
        // Eep16k instead of Eep4k to have room for extra save file data.
        .save_type = recomp::SaveType::Eep16k,
        .thumbnail_bytes = std::span<const char>(icon_bytes),
        .is_enabled = false,
        .decompression_routine = dk64::decompress_dk,
        .has_compressed_code = true,
        .entrypoint_address = get_entrypoint_address(),
        .entrypoint = recomp_entrypoint,
        .on_init_callback = dk64::dk_on_init,
    },
};

// TODO: move somewhere else
namespace dk64 {
    std::string get_game_thread_name(const OSThread* t) {
        std::string name = "[Game] ";

        switch (t->id) {
            case 0:
                switch (t->priority) {
                    case 150:
                        name += "PIMGR";
                        break;

                    case 254:
                        name += "VIMGR";
                        break;

                    default:
                        name += std::to_string(t->id);
                        break;
                }
                break;
            case 1:
                name += "INIT";
                break;
            case 2:
                name += "NO_EXP_PAK";
                break;
            case 3:
                name += "MAIN";
                break;
            case 4:
                name += "AUDIO";
                break;
            case 5:
                name += "GFX_DEBUG";
                break;
            case 8:
                name += "CPU_DEBUG";
                break;
            case 9:
                name += "EEPROM";
                break;
            case 11:
                name += "IDLE";
                break;
            default:
                name += std::to_string(t->id);
                break;
        }

        return name;
    }
}

#ifdef _WIN32

struct PreloadContext {
    HANDLE handle;
    HANDLE mapping_handle;
    SIZE_T size;
    PVOID view;
};

bool preload_executable(PreloadContext& context) {
    wchar_t module_name[MAX_PATH];
    GetModuleFileNameW(NULL, module_name, MAX_PATH);

    context.handle = CreateFileW(module_name, GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (context.handle == INVALID_HANDLE_VALUE) {
        fprintf(stderr, "Failed to load executable into memory!");
        context = {};
        return false;
    }

    LARGE_INTEGER module_size;
    if (!GetFileSizeEx(context.handle, &module_size)) {
        fprintf(stderr, "Failed to get size of executable!");
        CloseHandle(context.handle);
        context = {};
        return false;
    }

    context.size = module_size.QuadPart;

    context.mapping_handle = CreateFileMappingW(context.handle, nullptr, PAGE_READONLY, 0, 0, nullptr);
    if (context.mapping_handle == nullptr) {
        fprintf(stderr, "Failed to create file mapping of executable!");
        CloseHandle(context.handle);
        context = {};
        return EXIT_FAILURE;
    }

    context.view = MapViewOfFile(context.mapping_handle, FILE_MAP_READ, 0, 0, 0);
    if (context.view == nullptr) {
        fprintf(stderr, "Failed to map view of of executable!");
        CloseHandle(context.mapping_handle);
        CloseHandle(context.handle);
        context = {};
        return false;
    }

    DWORD pid = GetCurrentProcessId();
    HANDLE process_handle = OpenProcess(PROCESS_SET_QUOTA | PROCESS_QUERY_INFORMATION, FALSE, pid);
    if (process_handle == nullptr) {
        fprintf(stderr, "Failed to open own process!");
        CloseHandle(context.mapping_handle);
        CloseHandle(context.handle);
        context = {};
        return false;
    }

    SIZE_T minimum_set_size, maximum_set_size;
    if (!GetProcessWorkingSetSize(process_handle, &minimum_set_size, &maximum_set_size)) {
        fprintf(stderr, "Failed to get working set size!");
        CloseHandle(context.mapping_handle);
        CloseHandle(context.handle);
        context = {};
        return false;
    }

    if (!SetProcessWorkingSetSize(process_handle, minimum_set_size + context.size, maximum_set_size + context.size)) {
        fprintf(stderr, "Failed to set working set size!");
        CloseHandle(context.mapping_handle);
        CloseHandle(context.handle);
        context = {};
        return false;
    }

    if (VirtualLock(context.view, context.size) == 0) {
        fprintf(stderr, "Failed to lock view of executable! (Error: %08lx)\n", GetLastError());
        CloseHandle(context.mapping_handle);
        CloseHandle(context.handle);
        context = {};
        return false;
    }
    
    return true;
}

void release_preload(PreloadContext& context) {
    VirtualUnlock(context.view, context.size);
    CloseHandle(context.mapping_handle);
    CloseHandle(context.handle);
    context = {};
}

#elif defined(__linux__) || defined(__APPLE__)

struct PreloadContext {

};

bool preload_executable(PreloadContext& context) {
    // Preloading isn't implemented on Linux and MacOS, but it's also unnecessary there, as the OS already preloads the executable.
    // Therefore, we can just consider the executable to be preloaded.
    return true;
}

void release_preload(PreloadContext& context) {
}

#else

struct PreloadContext {};

bool preload_executable(PreloadContext& context) {
    return false;
}

void release_preload(PreloadContext& context) {
}

#endif

void enable_texture_pack(recomp::mods::ModContext& context, const recomp::mods::ModHandle& mod) {
    recompui::renderer::enable_texture_pack(context, mod);
}

void disable_texture_pack(recomp::mods::ModContext&, const recomp::mods::ModHandle& mod) {
    recompui::renderer::disable_texture_pack(mod);
}

void reorder_texture_pack(recomp::mods::ModContext&) {
    recompui::renderer::trigger_texture_pack_update();
}

#if defined(DK64_IOS)
// ---- iOS launcher: centred button column, explicit ROM state, "Replace ROM" ----------------------------------------
namespace {
struct IosRomMenuState {
    recompui::GameOption* start_option = nullptr;
    std::u8string game_id;
};
IosRomMenuState g_ios_rom_menu;

void ios_set_start_option_title(const std::string& title) {
    if (g_ios_rom_menu.start_option == nullptr) return;
    recompui::ContextId ui_context = recompui::get_launcher_context_id();
    bool opened = ui_context.open_if_not_already();
    g_ios_rom_menu.start_option->set_title(title);
    if (opened) ui_context.close();
}

void ios_replace_rom_done(void*, int success, const char* path) {
    if (!success) return;  // cancelled or failed (the importer already showed why)
    recomp::RomValidationError error = recomp::select_rom(std::filesystem::path{path}, g_ios_rom_menu.game_id);
    switch (error) {
        case recomp::RomValidationError::Good:
            DK64_LOG("ROM replaced successfully");
            ios_set_start_option_title("Start Game");
            recompui::message_box("ROM updated. Donkey Kong 64 ROM ready.");
            return;
        case recomp::RomValidationError::FailedToOpen: recompui::message_box("Failed to open ROM file."); break;
        case recomp::RomValidationError::NotARom: recompui::message_box("Invalid ROM: this is not a valid N64 ROM file."); break;
        case recomp::RomValidationError::IncorrectRom: recompui::message_box("Wrong game: this ROM is not Donkey Kong 64."); break;
        case recomp::RomValidationError::NotYet: recompui::message_box("This game isn't supported yet."); break;
        case recomp::RomValidationError::IncorrectVersion:
            recompui::message_box("Wrong Donkey Kong 64 revision.\nThis project requires the NTSC-U N64 version."); break;
        case recomp::RomValidationError::OtherError: recompui::message_box("An unknown error has occurred."); break;
    }
    DK64_LOG("ROM replace rejected (error %d); the previous ROM is kept", (int)error);
}
}  // namespace

void on_launcher_init(recompui::LauncherMenu *menu) {
    auto game_options_menu = menu->init_game_options_menu(
        supported_games[0].game_id,
        supported_games[0].mod_game_id,
        supported_games[0].display_name,
        supported_games[0].thumbnail_bytes,
        recompui::GameOptionsMenuLayout::Center
    );

    // ROM state, from librecomp's startup hash check (is_rom_valid) plus whether a stored file existed before that check.
    const bool rom_ready = recomp::is_rom_valid(supported_games[0].game_id);
    const bool rom_was_stored = dk64_ios_rom_stored_at_boot() != 0;
    const char* state = rom_ready ? "READY" : (rom_was_stored ? "INVALID" : "NOT FOUND");
    DK64_LOG("ROM state at launcher init: %s", state);

    g_ios_rom_menu.game_id = supported_games[0].game_id;
    g_ios_rom_menu.start_option = game_options_menu->add_start_game_or_load_rom_option(
        rom_was_stored ? "Select ROM (invalid ROM)" : "Select ROM (ROM not found)", "Start Game");
    game_options_menu->add_setup_controls_option();
    game_options_menu->add_settings_option();
    game_options_menu->add_mods_option();
    if (rom_ready) {
        game_options_menu->add_option("Replace ROM", []() { dk64_ios_pick_rom_async(&ios_replace_rom_done, nullptr); });
    }
    game_options_menu->add_exit_option();

    const recompui::Color text_color{ 0xFF, 0xE0, 0x66, 0xFF };
    const recompui::Color gold{ 0xFF, 0xC8, 0x1E, 0xFF };
    for (auto option : game_options_menu->get_options()) {
        // Real, touch-sized buttons: >= 44 pt on a phone (the launcher UI is 1080 dp tall).
        option->set_justify_content(recompui::JustifyContent::Center);
        option->set_height(112.0f);
        option->set_border_radius(28.0f);
        option->set_border_width(4.0f);
        option->set_border_color(gold);
        option->set_background_color(recompui::Color{ 0x3A, 0x1E, 0x08, 0xD8 });
        option->set_color(text_color);

        // Focused/hovered = lit; pressed (added in the GameOption patch) = recessed. They are distinct states.
        for (auto style : std::vector<recompui::Style *>{ &option->hover_style, &option->focus_style }) {
            style->set_background_color(recompui::Color{ 0xFF, 0xB8, 0x1E, 0xE8 });
            style->set_color(recompui::Color{ 0x2A, 0x12, 0x02, 0xFF });
        }
    }

    recompui::Element *menu_container = menu->get_menu_container();
    menu_container->set_width(1440);
    menu_container->unset_left();
    menu_container->set_top(dk64::launcher_options_top_offset);
    menu_container->set_bottom(-dk64::launcher_options_top_offset);
    menu_container->set_right(50, recompui::Unit::Percent);
    menu_container->set_translate_2D(50.0f, 0.0f, recompui::Unit::Percent);

    // Centre the button column in the middle of the screen (the desktop layout anchors it to the right edge).
    game_options_menu->unset_right();
    game_options_menu->set_width(620.0f);
    game_options_menu->set_left(50.0f, recompui::Unit::Percent);
    game_options_menu->set_bottom(50.0f, recompui::Unit::Percent);
    game_options_menu->set_translate_2D(-50.0f, 50.0f, recompui::Unit::Percent);

    menu->remove_default_title();

    dk64::launcher_animation_setup(menu);
}
#else
void on_launcher_init(recompui::LauncherMenu *menu) {
    auto game_options_menu = menu->init_game_options_menu(
        supported_games[0].game_id,
        supported_games[0].mod_game_id,
        supported_games[0].display_name,
        supported_games[0].thumbnail_bytes,
        recompui::GameOptionsMenuLayout::Center
    );

    game_options_menu->add_default_options();
    game_options_menu->set_width(30, recompui::Unit::Percent);

    for (auto option : game_options_menu->get_options()) {
        option->set_justify_content(recompui::JustifyContent::FlexEnd);
        option->set_border_radius(0);

        std::vector<recompui::Style *> hover_focus = {&option->hover_style, &option->focus_style};
        for (auto style : hover_focus) {
            style->set_background_color(recompui::theme::color::Transparent);
        }
    }

    recompui::Element *menu_container = menu->get_menu_container();
    menu_container->set_width(1440);
    menu_container->unset_left();
    menu_container->set_top(dk64::launcher_options_top_offset);
    menu_container->set_bottom(-dk64::launcher_options_top_offset);
    menu_container->set_right(50, recompui::Unit::Percent);
    menu_container->set_translate_2D(50.0f, 0.0f, recompui::Unit::Percent);

    game_options_menu->unset_left();
    game_options_menu->set_bottom(50.0f, recompui::Unit::Percent);
    game_options_menu->set_translate_2D(0.0f, 50.0f, recompui::Unit::Percent);
    game_options_menu->set_right(dk64::launcher_options_right_position_start);

    menu->remove_default_title();

    dk64::launcher_animation_setup(menu);
}
#endif

#define REGISTER_FUNC(name) recomp::overlays::register_base_export(#name, name)

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;
#if defined(DK64_IOS)
    dk64_ios_log_init();
    DK64_LOG("main() entered");
    // SDL exposes the phone's accelerometer as a joystick ("controller 0"). The game then treated it as a real
    // pad (log: "Couldn't find mapping for device (0)"). Only the on-screen / physical pads should count.
    SDL_SetHint(SDL_HINT_ACCELEROMETER_AS_JOYSTICK, "0");
#endif
    recomp::Version project_version{};
    if (!recomp::Version::from_string(version_string, project_version)) {
        ultramodern::error_handling::message_box(("Invalid version string: " + version_string).c_str());
        return EXIT_FAILURE;
    }

    // Map this executable into memory and lock it, which should keep it in physical memory. This ensures
    // that there are no stutters from the OS having to load new pages of the executable whenever a new code page is run.
    PreloadContext preload_context;
    bool preloaded = preload_executable(preload_context);

    if (!preloaded) {
        fprintf(stderr, "Failed to preload executable!\n");
    }

    // Initialize random seed for icon easter egg.
    std::srand(std::time(nullptr));

#ifdef _WIN32
    // Set up high resolution timing period.
    timeBeginPeriod(1);

    // Process arguments.
    for (int i = 1; i < argc; i++)
    {
        if (strcmp(argv[i], "--show-console") == 0)
        {
            if (GetConsoleWindow() == nullptr)
            {
                AllocConsole();
                freopen("CONIN$", "r", stdin);
                freopen("CONOUT$", "w", stderr);
                freopen("CONOUT$", "w", stdout);
            }

            break;
        }
    }

    // Set up console output to accept UTF-8 on windows
    SetConsoleOutputCP(CP_UTF8);

    // Change to a font that supports Japanese characters
    CONSOLE_FONT_INFOEX cfi;
    cfi.cbSize = sizeof cfi;
    cfi.nFont = 0;
    cfi.dwFontSize.X = 0;
    cfi.dwFontSize.Y = 16;
    cfi.FontFamily = FF_DONTCARE;
    cfi.FontWeight = FW_NORMAL;
    wcscpy_s(cfi.FaceName, L"NSimSun");
    SetCurrentConsoleFontEx(GetStdHandle(STD_OUTPUT_HANDLE), FALSE, &cfi);
#endif

#ifdef _WIN32
    // Force wasapi on Windows, as there seems to be some issue with sample queueing with directsound currently.
    SDL_setenv("SDL_AUDIODRIVER", "wasapi", true);
#endif

#if defined(__linux__) && defined(RECOMP_FLATPAK)
    // When using Flatpak, applications tend to launch from the home directory by default.
    // Mods might use the current working directory to store the data, so we switch it to a directory
    // with persistent data storage and write permissions under Flatpak to ensure it works.
    std::error_code ec;
    std::filesystem::current_path("/var/data", ec);
#endif

#if !defined(DK64_IOS)
    // Initialize native file dialogs.
    NFD_Init();
#endif

    // Initialize program settings.
    recompui::programconfig::set_program_name(dk64::program_name);
    recompui::programconfig::set_program_id(dk64::program_id);
    
    // Initialize SDL audio and set the output frequency.
#if defined(DK64_IOS)
    dk64_ios_prepare_filesystem();
    dk64_ios_import_rom_from_documents();
    dk64_ios_prepare_audio();
#endif
    SDL_InitSubSystem(SDL_INIT_AUDIO);
    if (!reset_audio(48000)) {
        // It is not possible to initialize without an audio device.
        return EXIT_FAILURE;
    }

    // Source controller mappings file
    std::u8string controller_db_path = (recompui::file::get_program_path() / "recompcontrollerdb.txt").u8string();
#if !defined(DK64_IOS)
    if (SDL_GameControllerAddMappingsFromFile(reinterpret_cast<const char *>(controller_db_path.c_str())) < 0) {
        fprintf(stderr, "Failed to load controller mappings: %s\n", SDL_GetError());
    }
#endif

    // Register fonts.
    recompui::register_primary_font("InterVariable.ttf", "Inter Variable");
    recompui::register_extra_font("Suplexmentary Comic NC.ttf");

    // Register configuration path.
    recomp::register_config_path(recompui::file::get_app_folder_path());

    // Register supported games and patches
    for (const auto& game : supported_games) {
        recomp::register_game(game);
    }

    REGISTER_FUNC(recomp_get_window_resolution);
    REGISTER_FUNC(recomp_get_target_aspect_ratio);
    REGISTER_FUNC(recomp_get_target_framerate);
    REGISTER_FUNC(recomp_get_right_analog_inputs);
    REGISTER_FUNC(recomp_get_bgm_volume);
    REGISTER_FUNC(recomp_get_sfx_volume);
    REGISTER_FUNC(recomp_get_draw_distance);
    REGISTER_FUNC(recomp_get_story_skip);
    REGISTER_FUNC(recomp_get_camera_type);
    REGISTER_FUNC(recomp_get_lightning_frequency);
    REGISTER_FUNC(recomp_get_cutscene_bordering);
    REGISTER_FUNC(recomp_get_mp_enabled);
    REGISTER_FUNC(recomp_get_ui_bounds);
    REGISTER_FUNC(recomp_get_ui_pillar);
    REGISTER_FUNC(recomp_get_gyro_deltas);
    REGISTER_FUNC(recomp_get_mouse_deltas);
    REGISTER_FUNC(recomp_get_inverted_axes);
    REGISTER_FUNC(recomp_get_analog_inverted_axes);
    REGISTER_FUNC(recomp_get_swimming_inverted_axes);
    REGISTER_FUNC(recomp_get_first_person_inverted_axes);
    REGISTER_FUNC(recomp_get_gyro_inverted_axes);
    REGISTER_FUNC(recomp_get_mouse_inverted_axes);
    recompui::register_ui_exports();
    recomputil::register_data_api_exports();
    recomptheme::set_custom_theme();

    dk64::register_bk_overlays();
    dk64::register_bk_patches();

    // Register extensions for two types: Props and ActorMarkers.
    recomputil::init_extended_object_data(2);

    recompinput::players::set_single_player_mode(true);

    dk64::init_config();

    recompui::register_launcher_init_callback(on_launcher_init);
    recompui::register_launcher_update_callback(dk64::launcher_animation_update);

    recomp::rsp::callbacks_t rsp_callbacks{
        .get_rsp_microcode = get_rsp_microcode,
    };

    ultramodern::renderer::callbacks_t renderer_callbacks{
        .create_render_context = create_pacing_render_context,
    };

    ultramodern::gfx_callbacks_t gfx_callbacks{
        .create_gfx = create_gfx,
        .create_window = create_window,
        .update_gfx = update_gfx,
    };

    ultramodern::audio_callbacks_t audio_callbacks{
        .queue_samples = queue_samples,
        .get_frames_remaining = get_frames_remaining,
        .set_frequency = set_frequency,
    };

    ultramodern::input::callbacks_t input_callbacks{
        .poll_input = recompinput::poll_inputs,
        .get_input = recompinput::profiles::get_n64_input,
        .set_rumble = recompinput::set_rumble,
        .get_connected_device_info = get_connected_device_info,
    };

    ultramodern::events::callbacks_t thread_callbacks{
        .vi_callback = recompinput::update_rumble,
        .gfx_init_callback = nullptr,
    };

    ultramodern::error_handling::callbacks_t error_handling_callbacks{
        .message_box = recompui::message_box,
    };

    ultramodern::threads::callbacks_t threads_callbacks{
        .get_game_thread_name = dk64::get_game_thread_name,
    };

    // Register the texture pack content type with rt64.json as its content file.
    recomp::mods::ModContentType texture_pack_content_type{
        .content_filename = "rt64.json",
        .allow_runtime_toggle = true,
        .on_enabled = enable_texture_pack,
        .on_disabled = disable_texture_pack,
        .on_reordered = reorder_texture_pack,
    };
    auto texture_pack_content_type_id = recomp::mods::register_mod_content_type(texture_pack_content_type);

    // Register the .rtz texture pack file format with the previous content type as its only allowed content type.
    recomp::mods::register_mod_container_type("rtz", std::vector{ texture_pack_content_type_id }, false);

    recomp::Configuration cfg {
        .argc = argc,
        .argv = argv,
        .project_version = project_version,
        .window_handle = {},
        .rsp_callbacks = rsp_callbacks,
        .renderer_callbacks = renderer_callbacks,
        .audio_callbacks = audio_callbacks,
        .input_callbacks = input_callbacks,
        .gfx_callbacks = gfx_callbacks,
        .events_callbacks = thread_callbacks,
        .error_handling_callbacks = error_handling_callbacks,
        .threads_callbacks = threads_callbacks,
        .message_queue_control = {
            .requeue_timer = false
        },
    };

    recomp::start(cfg);

#if !defined(DK64_IOS)
    NFD_Quit();
#endif

    if (preloaded) {
        release_preload(preload_context);
    }

#ifdef _WIN32
    // End high resolution timing period.
    timeEndPeriod(1);
#endif

    return EXIT_SUCCESS;
}
