#include "sd_audio.h"

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "driver/i2s_std.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "hal/gpio_types.h"

#define MINIMP3_IMPLEMENTATION
#define MINIMP3_ONLY_MP3
#include "minimp3.h"

static const char *TAG = "sd_audio";

#define I2S_DOUT_PIN GPIO_NUM_2
#define I2S_BCLK_PIN GPIO_NUM_3
#define I2S_WS_PIN   GPIO_NUM_4
#define I2S_PORT     I2S_NUM_0

#define SD_AUDIO_MAX_FILES  64
#define SD_AUDIO_PATH_LEN   160
#define READ_CHUNK          4096
#define MP3_BUF_SIZE        (READ_CHUNK + 2048)

static TaskHandle_t s_audio_task;
static volatile bool s_stop_request;
static char s_folder_copy[16];
static SemaphoreHandle_t s_start_mutex;

static i2s_chan_handle_t s_tx_chan;
static int s_cur_sample_hz;
static bool s_tx_enabled;
static int16_t s_mono_stereo_tmp[MINIMP3_MAX_SAMPLES_PER_FRAME * 2];

static bool ends_with_mp3(const char *name)
{
    const size_t n = strlen(name);
    if (n < 4) {
        return false;
    }
    return strcasecmp(name + n - 4, ".mp3") == 0;
}

static int cmp_path(const void *a, const void *b)
{
    return strcmp((const char *)a, (const char *)b);
}

static esp_err_t i2s_tx_create_and_init(int sample_rate_hz)
{
    i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(I2S_PORT, I2S_ROLE_MASTER);
    esp_err_t err = i2s_new_channel(&chan_cfg, &s_tx_chan, NULL);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "i2s_new_channel: %s", esp_err_to_name(err));
        return err;
    }

    i2s_std_config_t std_cfg = {
        .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(sample_rate_hz),
        .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO),
        .gpio_cfg = {
            .mclk = I2S_GPIO_UNUSED,
            .bclk = I2S_BCLK_PIN,
            .ws = I2S_WS_PIN,
            .dout = I2S_DOUT_PIN,
            .din = I2S_GPIO_UNUSED,
            .invert_flags = {
                .mclk_inv = false,
                .bclk_inv = false,
                .ws_inv = false,
            },
        },
    };

    err = i2s_channel_init_std_mode(s_tx_chan, &std_cfg);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "i2s_channel_init_std_mode: %s", esp_err_to_name(err));
        (void)i2s_del_channel(s_tx_chan);
        s_tx_chan = NULL;
        return err;
    }

    err = i2s_channel_enable(s_tx_chan);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "i2s_channel_enable: %s", esp_err_to_name(err));
        (void)i2s_del_channel(s_tx_chan);
        s_tx_chan = NULL;
        return err;
    }

    s_cur_sample_hz = sample_rate_hz;
    s_tx_enabled = true;
    return ESP_OK;
}

static esp_err_t i2s_install_if_needed(int sample_rate_hz)
{
    if (s_tx_chan == NULL) {
        return i2s_tx_create_and_init(sample_rate_hz);
    }

    if (!s_tx_enabled) {
        esp_err_t err = i2s_channel_enable(s_tx_chan);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "i2s_channel_enable: %s", esp_err_to_name(err));
            return err;
        }
        s_tx_enabled = true;
    }

    if (s_cur_sample_hz == sample_rate_hz) {
        return ESP_OK;
    }

    esp_err_t err = i2s_channel_disable(s_tx_chan);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "i2s_channel_disable: %s", esp_err_to_name(err));
        return err;
    }
    s_tx_enabled = false;

    i2s_std_clk_config_t clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(sample_rate_hz);
    err = i2s_channel_reconfig_std_clock(s_tx_chan, &clk_cfg);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "i2s_channel_reconfig_std_clock: %s", esp_err_to_name(err));
        return err;
    }

    err = i2s_channel_enable(s_tx_chan);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "i2s_channel_enable: %s", esp_err_to_name(err));
        return err;
    }
    s_tx_enabled = true;
    s_cur_sample_hz = sample_rate_hz;
    return ESP_OK;
}

static void write_i2s_pcm(const int16_t *pcm, int samples_per_ch, int channels)
{
    if (s_tx_chan == NULL || !s_tx_enabled) {
        return;
    }

    size_t written = 0;
    if (channels == 2) {
        const size_t bytes = (size_t)samples_per_ch * 2u * sizeof(int16_t);
        (void)i2s_channel_write(s_tx_chan, pcm, bytes, &written, portMAX_DELAY);
        return;
    }
    /* mono -> duplicate L/R */
    for (int i = 0; i < samples_per_ch; i++) {
        const int16_t s = pcm[i];
        s_mono_stereo_tmp[i * 2] = s;
        s_mono_stereo_tmp[i * 2 + 1] = s;
    }
    const size_t bytes = (size_t)samples_per_ch * 2u * sizeof(int16_t);
    (void)i2s_channel_write(s_tx_chan, s_mono_stereo_tmp, bytes, &written, portMAX_DELAY);
}

static void flush_i2s_silence(void)
{
    if (s_tx_chan == NULL || !s_tx_enabled) {
        return;
    }
    static int16_t zero[512 * 2];
    memset(zero, 0, sizeof(zero));
    for (int i = 0; i < 6; i++) {
        size_t w = 0;
        (void)i2s_channel_write(s_tx_chan, zero, sizeof(zero), &w, pdMS_TO_TICKS(200));
    }
}

/** @return true if user requested stop */
static bool decode_play_file(const char *path, int *out_hz)
{
    FILE *f = fopen(path, "rb");
    if (f == NULL) {
        ESP_LOGW(TAG, "fopen failed: %s", path);
        return false;
    }

    static mp3dec_t dec;
    mp3dec_init(&dec);

    uint8_t *buf = (uint8_t *)malloc(MP3_BUF_SIZE);
    if (buf == NULL) {
        fclose(f);
        ESP_LOGE(TAG, "malloc mp3 buf failed");
        return false;
    }

    int16_t *pcm = (int16_t *)malloc(MINIMP3_MAX_SAMPLES_PER_FRAME * 2 * sizeof(int16_t));
    if (pcm == NULL) {
        free(buf);
        fclose(f);
        ESP_LOGE(TAG, "malloc pcm buf failed");
        return false;
    }
    size_t buf_fill = 0;
    size_t offset = 0;

    while (!s_stop_request) {
        if (buf_fill < READ_CHUNK && !feof(f)) {
            if (offset > 0) {
                memmove(buf, buf + offset, buf_fill - offset);
                buf_fill -= offset;
                offset = 0;
            }
            const size_t space = MP3_BUF_SIZE - buf_fill - 1;
            const size_t n = fread(buf + buf_fill, 1, space, f);
            buf_fill += n;
        }

        if (buf_fill <= offset) {
            if (feof(f)) {
                break;
            }
            vTaskDelay(pdMS_TO_TICKS(1));
            continue;
        }

        mp3dec_frame_info_t info = {0};
        const int samples = mp3dec_decode_frame(&dec, buf + offset, (int)(buf_fill - offset), pcm, &info);
        const int consumed = info.frame_bytes;
        if (consumed > 0) {
            offset += (size_t)consumed;
        } else if (buf_fill > offset && feof(f)) {
            /* trailing garbage */
            break;
        } else if (samples == 0 && consumed == 0 && feof(f)) {
            break;
        }

        if (offset > READ_CHUNK) {
            memmove(buf, buf + offset, buf_fill - offset);
            buf_fill -= offset;
            offset = 0;
        }

        if (samples > 0 && info.channels >= 1 && info.channels <= 2 && info.hz > 0) {
            if (*out_hz != info.hz) {
                *out_hz = info.hz;
                if (i2s_install_if_needed(info.hz) != ESP_OK) {
                    break;
                }
            }
            write_i2s_pcm(pcm, samples, info.channels);
        }
    }

    free(pcm);
    free(buf);
    fclose(f);
    return s_stop_request;
}

static void scan_mp3_sorted(const char *dir_path, char paths[][SD_AUDIO_PATH_LEN], int *out_count)
{
    *out_count = 0;
    DIR *d = opendir(dir_path);
    if (d == NULL) {
        ESP_LOGW(TAG, "opendir failed: %s", dir_path);
        return;
    }
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL && *out_count < SD_AUDIO_MAX_FILES) {
        if (ent->d_name[0] == '.') {
            continue;
        }
        if (!ends_with_mp3(ent->d_name)) {
            continue;
        }
        int written = snprintf(paths[*out_count], SD_AUDIO_PATH_LEN, "%s/%s", dir_path, ent->d_name);
        if (written <= 0 || written >= SD_AUDIO_PATH_LEN) {
            ESP_LOGW(TAG, "path too long under %s", dir_path);
            continue;
        }
        (*out_count)++;
    }
    closedir(d);
    if (*out_count > 1) {
        qsort(paths, (size_t)*out_count, SD_AUDIO_PATH_LEN, cmp_path);
    }
}

static void audio_task(void *arg)
{
    (void)arg;
    char dir_path[96];
    snprintf(dir_path, sizeof(dir_path), "/sdcard/audio/%s", s_folder_copy);

    char (*paths)[SD_AUDIO_PATH_LEN] = calloc(SD_AUDIO_MAX_FILES, SD_AUDIO_PATH_LEN);
    if (paths == NULL) {
        ESP_LOGE(TAG, "malloc path list failed");
        goto done;
    }

    int nfiles = 0;
    scan_mp3_sorted(dir_path, paths, &nfiles);
    if (nfiles == 0) {
        ESP_LOGW(TAG, "no mp3 under %s", dir_path);
        goto done;
    }

    ESP_LOGI(TAG, "playing %d file(s) from %s (loop)", nfiles, dir_path);

    int out_hz = 0;
    while (!s_stop_request) {
        for (int i = 0; i < nfiles && !s_stop_request; i++) {
            if (decode_play_file(paths[i], &out_hz)) {
                goto done;
            }
        }
    }

done:
    free(paths);
    flush_i2s_silence();
    if (s_tx_chan != NULL && s_tx_enabled) {
        (void)i2s_channel_disable(s_tx_chan);
        s_tx_enabled = false;
    }
    s_audio_task = NULL;
    vTaskDelete(NULL);
}

void sd_audio_stop(void)
{
    s_stop_request = true;
    for (int i = 0; i < 80 && s_audio_task != NULL; i++) {
        vTaskDelay(pdMS_TO_TICKS(50));
    }
    if (s_audio_task != NULL) {
        ESP_LOGW(TAG, "audio task did not exit cleanly");
    }
}

void sd_audio_start(const char *folder)
{
    if (folder == NULL || (strcmp(folder, "432Hz") != 0 && strcmp(folder, "528Hz") != 0)) {
        ESP_LOGW(TAG, "invalid folder: %s", folder ? folder : "(null)");
        return;
    }

    if (s_start_mutex == NULL) {
        s_start_mutex = xSemaphoreCreateMutex();
    }
    if (xSemaphoreTake(s_start_mutex, pdMS_TO_TICKS(2000)) != pdTRUE) {
        return;
    }

    sd_audio_stop();
    s_stop_request = false;
    strncpy(s_folder_copy, folder, sizeof(s_folder_copy) - 1);
    s_folder_copy[sizeof(s_folder_copy) - 1] = '\0';

    BaseType_t ok = xTaskCreatePinnedToCore(
        audio_task,
        "sd_audio",
        12288,
        NULL,
        5,
        &s_audio_task,
        1);
    if (ok != pdPASS) {
        ESP_LOGE(TAG, "xTaskCreatePinnedToCore failed");
        s_audio_task = NULL;
    }

    xSemaphoreGive(s_start_mutex);
}

