/* Strata prototype: the sound device of the emulator (the model and its host
 * side). Header-only; included after display.h.
 *
 * The device (DEV_SOUND, common/platform.h) plays a queue of mono signed
 * 16-bit samples at RATE samples per second of timer time:
 *   PCM     write: a transfer's bytes are samples, low byte first, appended
 *           to the queue (SND_QLEN samples); what does not fit is dropped
 *   RATE    read / write: samples per second (SND_MIN_RATE..SND_MAX_RATE)
 *   STATUS  read: u32 samples queued and not yet played, u32 samples dropped
 * An empty queue plays silence. Software paces itself with STATUS: it keeps
 * a fraction of a second queued and never fills the queue.
 *
 * A machine has the device only when it is asked for (strata-emu -a or -A
 * FILE; the play page), and says so in its platform table (PT_SOUND); the
 * RTL has none. Where the samples go on the host:
 *   SDL (unless -g none or -DNO_SDL): queued on an audio device opened at RATE
 *   -A FILE: a WAV file of everything played from the first sample on,
 *            silences included (deterministic with -T virtual: the tests)
 *   the browser build: a ring the worker drains (web_audio) for WebAudio */
#ifndef STRATA_SOUND_H
#define STRATA_SOUND_H

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

static bool snd_present;              /* the machine has the device */
static uint32_t snd_rate = SND_DEF_RATE;
static uint64_t snd_queue;            /* samples queued, not yet played */
static uint64_t snd_dropped;          /* samples that found the queue full */
static uint64_t snd_t, snd_rem;       /* timer time of the last look; the fraction of a sample left then */
static uint64_t snd_gap;              /* samples of silence played since the last one written */
static bool snd_started;              /* a sample has been written */
static uint64_t snd_wbuf;             /* RATE being written */
static uint64_t snd_lat;              /* a register latched at its byte 0 */
static uint8_t snd_lo;                /* the low byte of the sample being written */
static const char *snd_wav_path;      /* -A */
static FILE *snd_wav;
static uint64_t snd_wav_n;            /* samples in it */
static int16_t snd_out[2048];         /* samples of the transfer in progress, for the host */
static unsigned snd_out_n;

/* The queue as of timer time `now`: what was played since the last look leaves it. */
static inline void snd_advance(uint64_t now) {
  if (now <= snd_t) return;
  uint64_t n = (now - snd_t) * snd_rate + snd_rem;
  snd_t = now;
  snd_rem = n % TMR_HZ;
  n /= TMR_HZ;
  if (n > snd_queue) { snd_gap += n - snd_queue; snd_queue = 0; }
  else snd_queue -= n;
}

static inline void snd_wav_put16(int v) { fputc(v & 255, snd_wav); fputc(v >> 8 & 255, snd_wav); }
static inline void snd_wav_put32(uint32_t v) { snd_wav_put16((int)(v & 0xffff)); snd_wav_put16((int)(v >> 16)); }
static inline void snd_wav_header(void) {
  uint32_t bytes = (uint32_t)(snd_wav_n * 2);
  rewind(snd_wav);
  fputs("RIFF", snd_wav); snd_wav_put32(36 + bytes); fputs("WAVEfmt ", snd_wav);
  snd_wav_put32(16); snd_wav_put16(1); snd_wav_put16(1); snd_wav_put32(snd_rate); snd_wav_put32(snd_rate * 2);
  snd_wav_put16(2); snd_wav_put16(16); fputs("data", snd_wav); snd_wav_put32(bytes);
}

#ifdef __EMSCRIPTEN__
static int16_t snd_ring[32768];       /* what the page has not taken yet */
static unsigned snd_ring_head, snd_ring_n;
#elif !defined(NO_SDL)
static SDL_AudioDeviceID snd_sdl;
static uint32_t snd_sdl_rate;
#endif

/* The samples of a finished transfer go to the host. */
static inline void snd_flush(void) {
  if (!snd_out_n) return;
  if (snd_wav) {
    for (; snd_gap; snd_gap--, snd_wav_n++) snd_wav_put16(0); /* the silence before them */
    for (unsigned i = 0; i < snd_out_n; i++) snd_wav_put16(snd_out[i]);
    snd_wav_n += snd_out_n;
  }
  snd_gap = 0;
#ifdef __EMSCRIPTEN__
  for (unsigned i = 0; i < snd_out_n && snd_ring_n < 32768; i++, snd_ring_n++)
    snd_ring[(snd_ring_head + snd_ring_n) & 32767] = snd_out[i];
#elif !defined(NO_SDL)
  if (host_gfx) {
    if (snd_sdl_rate != snd_rate) { /* (opened once per rate; snd_sdl stays 0 if there is no audio) */
      if (snd_sdl) SDL_CloseAudioDevice(snd_sdl);
      snd_sdl = 0;
      SDL_AudioSpec want = {0}, have;
      want.freq = (int)snd_rate;
      want.format = AUDIO_S16SYS;
      want.channels = 1;
      want.samples = 512;
      if (SDL_InitSubSystem(SDL_INIT_AUDIO) == 0) snd_sdl = SDL_OpenAudioDevice(NULL, 0, &want, &have, 0);
      if (snd_sdl) SDL_PauseAudioDevice(snd_sdl, 0);
      snd_sdl_rate = snd_rate;
    }
    /* (the host's queue is kept under half a second: the machine may run ahead of the host's clock) */
    if (snd_sdl && SDL_GetQueuedAudioSize(snd_sdl) < snd_rate) SDL_QueueAudio(snd_sdl, snd_out, snd_out_n * 2);
  }
#endif
  snd_out_n = 0;
}

/* Byte `i` of a transfer written to PCM. */
static inline void snd_pcm_byte(uint64_t i, uint8_t b, uint64_t now) {
  if (!(i & 1)) { snd_lo = b; return; }
  snd_advance(now);
  if (!snd_started) { snd_started = true; snd_gap = 0; } /* (the WAV starts with the first sample) */
  if (snd_queue >= SND_QLEN) { snd_dropped++; return; }
  snd_queue++;
  if (snd_out_n == sizeof snd_out / sizeof *snd_out) snd_flush();
  snd_out[snd_out_n++] = (int16_t)(snd_lo | b << 8);
}

/* Byte `j` of RATE written (it takes effect with its last byte). */
static inline void snd_rate_byte(unsigned j, uint8_t b, uint64_t now) {
  snd_wbuf = (snd_wbuf & ~(0xffull << (8 * j))) | (uint64_t)b << (8 * j);
  if (j != 7) return;
  snd_advance(now);
  snd_rate = snd_wbuf < SND_MIN_RATE ? SND_MIN_RATE : snd_wbuf > SND_MAX_RATE ? SND_MAX_RATE : (uint32_t)snd_wbuf;
}

/* Byte `j` of the register at `reg` (SND_RATE or SND_STATUS) read. */
static inline uint8_t snd_read(unsigned reg, unsigned j, uint64_t now) {
  if (j == 0) {
    snd_advance(now);
    snd_lat = reg == SND_RATE ? snd_rate : snd_queue | (snd_dropped & 0xffffffffull) << 32;
  }
  return (uint8_t)(snd_lat >> (8 * j));
}

static void snd_finish(void) {
  snd_flush();
  if (snd_wav) { snd_wav_header(); fclose(snd_wav); snd_wav = NULL; }
}

/* The machine has the device; `wav` (or NULL): record what it plays there. False if the file cannot be made. */
static inline bool snd_host_init(const char *wav) {
  snd_present = true;
  snd_wav_path = wav;
  if (wav) {
    if (!(snd_wav = fopen(wav, "wb"))) return false;
    snd_wav_header();
  }
  atexit(snd_finish);
  return true;
}

#endif
