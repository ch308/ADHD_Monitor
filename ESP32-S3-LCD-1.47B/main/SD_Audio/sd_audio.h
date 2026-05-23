#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/** Start looping MP3 playback from `/sdcard/audio/<folder>/` (folder: "432Hz" or "528Hz"). */
void sd_audio_start(const char *folder);

/** Stop playback and release the audio task. Safe to call from any task. */
void sd_audio_stop(void);

#ifdef __cplusplus
}
#endif
