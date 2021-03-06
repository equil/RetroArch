/*  RetroArch - A frontend for libretro.
 *  Copyright (C) 2010-2014 - Hans-Kristian Arntzen
 *  Copyright (C) 2011-2015 - Daniel De Matteis
 *  Copyright (C) 2012-2015 - Michael Lelli
 *
 *  RetroArch is free software: you can redistribute it and/or modify it under the terms
 *  of the GNU General Public License as published by the Free Software Found-
 *  ation, either version 3 of the License, or (at your option) any later version.
 *
 *  RetroArch is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
 *  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 *  PURPOSE.  See the GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License along with RetroArch.
 *  If not, see <http://www.gnu.org/licenses/>.
 */

#include <boolean.h>
#include "libretro.h"
#include "dynamic.h"
#include "libretro_version_1.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <retro_inline.h>
#include <ctype.h>
#include <errno.h>
#include "general.h"
#include "runloop.h"
#include "retroarch.h"
#include "performance.h"
#include "input/keyboard_line.h"
#include "audio/audio_utils.h"
#include "retroarch_logger.h"
#include "record/record_driver.h"
#include "intl/intl.h"

#ifdef HAVE_NETPLAY
#include "netplay.h"
#endif

static bool video_frame_scale(const void *data,
      unsigned width, unsigned height,
      size_t pitch)
{
   driver_t *driver = driver_get_ptr();
   global_t *global = global_get_ptr();

   RARCH_PERFORMANCE_INIT(video_frame_conv);

   if (!data)
      return false;
   if (global->system.pix_fmt != RETRO_PIXEL_FORMAT_0RGB1555)
      return false;
   if (data == RETRO_HW_FRAME_BUFFER_VALID)
      return false;

   RARCH_PERFORMANCE_START(video_frame_conv);

   driver->scaler.in_width      = width;
   driver->scaler.in_height     = height;
   driver->scaler.out_width     = width;
   driver->scaler.out_height    = height;
   driver->scaler.in_stride     = pitch;
   driver->scaler.out_stride    = width * sizeof(uint16_t);

   scaler_ctx_scale(&driver->scaler, driver->scaler_out, data);

   RARCH_PERFORMANCE_STOP(video_frame_conv);
   
   return true;
}

static bool video_frame_filter(const void *data,
      unsigned width, unsigned height,
      size_t pitch,
      unsigned *output_width, unsigned *output_height,
      unsigned *output_pitch)
{
   settings_t *settings = config_get_ptr();
   global_t   *global   = global_get_ptr();

   RARCH_PERFORMANCE_INIT(softfilter_process);

   if (!global->filter.filter)
      return false;
   if (!data)
      return false;

   rarch_softfilter_get_output_size(global->filter.filter,
         output_width, output_height, width, height);

   *output_pitch = (*output_width) * global->filter.out_bpp;

   RARCH_PERFORMANCE_START(softfilter_process);
   rarch_softfilter_process(global->filter.filter,
         global->filter.buffer, *output_pitch,
         data, width, height, pitch);
   RARCH_PERFORMANCE_STOP(softfilter_process);

   if (settings->video.post_filter_record)
      recording_dump_frame(global->filter.buffer,
            *output_width, *output_height, *output_pitch);

   return true;
}

/**
 * video_frame:
 * @data                 : pointer to data of the video frame.
 * @width                : width of the video frame.
 * @height               : height of the video frame.
 * @pitch                : pitch of the video frame.
 *
 * Video frame render callback function.
 **/
static void video_frame(const void *data, unsigned width,
      unsigned height, size_t pitch)
{
   unsigned output_width  = 0, output_height = 0, output_pitch = 0;
   const char *msg      = NULL;
   driver_t  *driver    = driver_get_ptr();
   global_t  *global    = global_get_ptr();
   settings_t *settings = config_get_ptr();

   if (!driver->video_active)
      return;

   global->frame_cache.data   = data;
   global->frame_cache.width  = width;
   global->frame_cache.height = height;
   global->frame_cache.pitch  = pitch;

   if (video_frame_scale(data, width, height, pitch))
   {
      data                        = driver->scaler_out;
      pitch                       = driver->scaler.out_stride;
   }

   /* Slightly messy code,
    * but we really need to do processing before blocking on VSync
    * for best possible scheduling.
    */
   if ((!global->filter.filter
            || !settings->video.post_filter_record || !data
            || global->record.gpu_buffer)
      )
      recording_dump_frame(data, width, height, pitch);

   msg                = rarch_main_msg_queue_pull();
   driver->current_msg = msg;

   if (video_frame_filter(data, width, height, pitch,
            &output_width, &output_height, &output_pitch))
   {
      data   = global->filter.buffer;
      width  = output_width;
      height = output_height;
      pitch  = output_pitch;
   }

   if (!video_driver_frame(data, width, height, pitch, msg))
      driver->video_active = false;
}

/**
 * retro_flush_audio:
 * @data                 : pointer to audio buffer.
 * @right                : amount of samples to write.
 *
 * Writes audio samples to audio driver. Will first
 * perform DSP processing (if enabled) and resampling.
 *
 * Returns: true (1) if audio samples were written to the audio
 * driver, false (0) in case of an error.
 **/
bool retro_flush_audio(const int16_t *data, size_t samples)
{
   const void *output_data        = NULL;
   unsigned output_frames         = 0;
   size_t   output_size           = sizeof(float);
   struct resampler_data src_data = {0};
   struct rarch_dsp_data dsp_data = {0};
   runloop_t *runloop             = rarch_main_get_ptr();
   driver_t  *driver              = driver_get_ptr();
   global_t  *global              = global_get_ptr();
   settings_t *settings           = config_get_ptr();

   if (driver->recording_data)
   {
      struct ffemu_audio_data ffemu_data = {0};
      ffemu_data.data                    = data;
      ffemu_data.frames                  = samples / 2;

      if (driver->recording && driver->recording->push_audio)
         driver->recording->push_audio(driver->recording_data, &ffemu_data);
   }

   if (runloop->is_paused || settings->audio.mute_enable)
      return true;
   if (!driver->audio_active || !global->audio_data.data)
      return false;

   RARCH_PERFORMANCE_INIT(audio_convert_s16);
   RARCH_PERFORMANCE_START(audio_convert_s16);
   audio_convert_s16_to_float(global->audio_data.data, data, samples,
         global->audio_data.volume_gain);
   RARCH_PERFORMANCE_STOP(audio_convert_s16);

   src_data.data_in               = global->audio_data.data;
   src_data.input_frames          = samples >> 1;

   dsp_data.input                 = global->audio_data.data;
   dsp_data.input_frames          = samples >> 1;

   if (global->audio_data.dsp)
   {
      RARCH_PERFORMANCE_INIT(audio_dsp);
      RARCH_PERFORMANCE_START(audio_dsp);
      rarch_dsp_filter_process(global->audio_data.dsp, &dsp_data);
      RARCH_PERFORMANCE_STOP(audio_dsp);

      if (dsp_data.output)
      {
         src_data.data_in      = dsp_data.output;
         src_data.input_frames = dsp_data.output_frames;
      }
   }

   src_data.data_out = global->audio_data.outsamples;

   if (global->audio_data.rate_control)
      audio_driver_readjust_input_rate();

   src_data.ratio = global->audio_data.src_ratio;
   if (runloop->is_slowmotion)
      src_data.ratio *= settings->slowmotion_ratio;

   RARCH_PERFORMANCE_INIT(resampler_proc);
   RARCH_PERFORMANCE_START(resampler_proc);
   rarch_resampler_process(driver->resampler,
         driver->resampler_data, &src_data);
   RARCH_PERFORMANCE_STOP(resampler_proc);

   output_data   = global->audio_data.outsamples;
   output_frames = src_data.output_frames;

   if (!global->audio_data.use_float)
   {
      RARCH_PERFORMANCE_INIT(audio_convert_float);
      RARCH_PERFORMANCE_START(audio_convert_float);
      audio_convert_float_to_s16(global->audio_data.conv_outsamples,
            (const float*)output_data, output_frames * 2);
      RARCH_PERFORMANCE_STOP(audio_convert_float);

      output_data = global->audio_data.conv_outsamples;
      output_size = sizeof(int16_t);
   }

   if (audio_driver_write(output_data, output_frames * output_size * 2) < 0)
   {
      RARCH_ERR(RETRO_LOG_AUDIO_WRITE_FAILED);

      driver->audio_active = false;
      return false;
   }

   return true;
}

/**
 * audio_sample:
 * @left                 : value of the left audio channel.
 * @right                : value of the right audio channel.
 *
 * Audio sample render callback function.
 **/
static void audio_sample(int16_t left, int16_t right)
{
   global_t *global = global_get_ptr();

   global->audio_data.conv_outsamples[global->audio_data.data_ptr++] = left;
   global->audio_data.conv_outsamples[global->audio_data.data_ptr++] = right;

   if (global->audio_data.data_ptr < global->audio_data.chunk_size)
      return;

   retro_flush_audio(global->audio_data.conv_outsamples, global->audio_data.data_ptr);

   global->audio_data.data_ptr = 0;
}

/**
 * audio_sample_batch:
 * @data                 : pointer to audio buffer.
 * @frames               : amount of audio frames to push.
 *
 * Batched audio sample render callback function.
 *
 * Returns: amount of frames sampled. Will be equal to @frames
 * unless @frames exceeds (AUDIO_CHUNK_SIZE_NONBLOCKING / 2).
 **/
static size_t audio_sample_batch(const int16_t *data, size_t frames)
{
   if (frames > (AUDIO_CHUNK_SIZE_NONBLOCKING >> 1))
      frames = AUDIO_CHUNK_SIZE_NONBLOCKING >> 1;

   retro_flush_audio(data, frames << 1);

   return frames;
}

/**
 * audio_sample_rewind:
 * @left                 : value of the left audio channel.
 * @right                : value of the right audio channel.
 *
 * Audio sample render callback function (rewind version). This callback
 * function will be used instead of audio_sample when rewinding is activated.
 **/
static void audio_sample_rewind(int16_t left, int16_t right)
{
   global_t *global = global_get_ptr();

   global->audio_data.rewind_buf[--global->audio_data.rewind_ptr] = right;
   global->audio_data.rewind_buf[--global->audio_data.rewind_ptr] = left;
}

/**
 * audio_sample_batch_rewind:
 * @data                 : pointer to audio buffer.
 * @frames               : amount of audio frames to push.
 *
 * Batched audio sample render callback function (rewind version). This callback
 * function will be used instead of audio_sample_batch when rewinding is activated.
 *
 * Returns: amount of frames sampled. Will be equal to @frames
 * unless @frames exceeds (AUDIO_CHUNK_SIZE_NONBLOCKING / 2).
 **/
static size_t audio_sample_batch_rewind(const int16_t *data, size_t frames)
{
   size_t i;
   size_t samples   = frames << 1;
   global_t *global = global_get_ptr();

   for (i = 0; i < samples; i++)
      global->audio_data.rewind_buf[--global->audio_data.rewind_ptr] = data[i];

   return frames;
}

/**
 * input_apply_turbo:
 * @port                 : user number
 * @id                   : identifier of the key
 * @res                  : boolean return value. FIXME/TODO: to be refactored.
 *
 * Apply turbo button if activated.
 *
 * If turbo button is held, all buttons pressed except
 * for D-pad will go into a turbo mode. Until the button is
 * released again, the input state will be modulated by a 
 * periodic pulse defined by the configured duty cycle. 
 *
 * Returns: 1 (true) if turbo button is enabled for this
 * key ID, otherwise the value of @res will be returned.
 *
 **/
static bool input_apply_turbo(unsigned port, unsigned id, bool res)
{
   settings_t *settings           = config_get_ptr();
   global_t *global               = global_get_ptr();

   if (res && global->turbo_frame_enable[port])
      global->turbo_enable[port] |= (1 << id);
   else if (!res)
      global->turbo_enable[port] &= ~(1 << id);

   if (global->turbo_enable[port] & (1 << id))
      return res && ((global->turbo_count % settings->input.turbo_period)
            < settings->input.turbo_duty_cycle);
   return res;
}

/**
 * input_state:
 * @port                 : user number.
 * @device               : device identifier of user.
 * @idx                  : index value of user.
 * @id                   : identifier of key pressed by user.
 *
 * Input state callback function.
 *
 * Returns: Non-zero if the given key (identified by @id) was pressed by the user
 * (assigned to @port).
 **/
static int16_t input_state(unsigned port, unsigned device,
      unsigned idx, unsigned id)
{
   int16_t res                    = 0;
   settings_t *settings           = config_get_ptr();
   driver_t *driver               = driver_get_ptr();
   global_t *global               = global_get_ptr();
   const struct retro_keybind *libretro_input_binds[MAX_USERS] = {
      settings->input.binds[0],
      settings->input.binds[1],
      settings->input.binds[2],
      settings->input.binds[3],
      settings->input.binds[4],
      settings->input.binds[5],
      settings->input.binds[6],
      settings->input.binds[7],
      settings->input.binds[8],
      settings->input.binds[9],
      settings->input.binds[10],
      settings->input.binds[11],
      settings->input.binds[12],
      settings->input.binds[13],
      settings->input.binds[14],
      settings->input.binds[15],
   };

   device &= RETRO_DEVICE_MASK;

   if (global->bsv.movie && global->bsv.movie_playback)
   {
      int16_t ret;
      if (bsv_movie_get_input(global->bsv.movie, &ret))
         return ret;

      global->bsv.movie_end = true;
   }

   if (settings->input.remap_binds_enable)
   {
      if (id < RARCH_FIRST_CUSTOM_BIND)
         id = settings->input.remap_ids[port][id];
   }

   if (!driver->block_libretro_input)
   {
      if (((id < RARCH_FIRST_META_KEY) || (device == RETRO_DEVICE_KEYBOARD)))
         res = input_driver_state(libretro_input_binds, port, device, idx, id);

#ifdef HAVE_OVERLAY
      if (port == 0)
      {
         switch (device)
         {
            case RETRO_DEVICE_JOYPAD:
               if (driver->overlay_state.buttons & (UINT64_C(1) << id))
                  res |= 1;
               break;
            case RETRO_DEVICE_KEYBOARD:
               if (id < RETROK_LAST)
               {
                  if (OVERLAY_GET_KEY(&driver->overlay_state, id))
                     res |= 1;
               }
               break;
            case RETRO_DEVICE_ANALOG:
               {
                  unsigned base = 0;
                  
                  if (idx == RETRO_DEVICE_INDEX_ANALOG_RIGHT)
                     base = 2;
                  if (id == RETRO_DEVICE_ID_ANALOG_Y)
                     base += 1;
                  if (driver->overlay_state.analog[base])
                     res = driver->overlay_state.analog[base];
               }
               break;
         }
      }
#endif
   }

   /* flushing_input will be cleared in rarch_main_iterate. */
   if (driver->flushing_input)
      res = 0;

   /* Don't allow turbo for D-pad. */
   if (device == RETRO_DEVICE_JOYPAD && (id < RETRO_DEVICE_ID_JOYPAD_UP ||
            id > RETRO_DEVICE_ID_JOYPAD_RIGHT))
      res = input_apply_turbo(port, id, res);

   if (global->bsv.movie && !global->bsv.movie_playback)
      bsv_movie_set_input(global->bsv.movie, res);

   return res;
}


#ifdef HAVE_OVERLAY
/*
 * input_poll_overlay:
 * @overlay_device : pointer to overlay 
 *
 * Poll pressed buttons/keys on currently active overlay.
 **/
static INLINE void input_poll_overlay(input_overlay_t *overlay_device, float opacity)
{
   input_overlay_state_t old_key_state;
   unsigned i, j, device;
   uint16_t key_mod               = 0;
   bool polled                    = false;
   driver_t *driver               = driver_get_ptr();
   settings_t *settings           = config_get_ptr();

   if (overlay_device->state != OVERLAY_STATUS_ALIVE)
      return;

   memcpy(old_key_state.keys, driver->overlay_state.keys,
         sizeof(driver->overlay_state.keys));
   memset(&driver->overlay_state, 0, sizeof(driver->overlay_state));

   device = input_overlay_full_screen(overlay_device) ?
      RARCH_DEVICE_POINTER_SCREEN : RETRO_DEVICE_POINTER;

   for (i = 0;
         input_driver_state(NULL, 0, device, i, RETRO_DEVICE_ID_POINTER_PRESSED);
         i++)
   {
      input_overlay_state_t polled_data;
      int16_t x = input_driver_state(NULL, 0,
            device, i, RETRO_DEVICE_ID_POINTER_X);
      int16_t y = input_driver_state(NULL, 0,
            device, i, RETRO_DEVICE_ID_POINTER_Y);

      input_overlay_poll(overlay_device, &polled_data, x, y);

      driver->overlay_state.buttons |= polled_data.buttons;

      for (j = 0; j < ARRAY_SIZE(driver->overlay_state.keys); j++)
         driver->overlay_state.keys[j] |= polled_data.keys[j];

      /* Fingers pressed later take prio and matched up
       * with overlay poll priorities. */
      for (j = 0; j < 4; j++)
         if (polled_data.analog[j])
            driver->overlay_state.analog[j] = polled_data.analog[j];

      polled = true;
   }

   if (OVERLAY_GET_KEY(&driver->overlay_state, RETROK_LSHIFT) ||
         OVERLAY_GET_KEY(&driver->overlay_state, RETROK_RSHIFT))
      key_mod |= RETROKMOD_SHIFT;

   if (OVERLAY_GET_KEY(&driver->overlay_state, RETROK_LCTRL) ||
    OVERLAY_GET_KEY(&driver->overlay_state, RETROK_RCTRL))
      key_mod |= RETROKMOD_CTRL;

   if (OVERLAY_GET_KEY(&driver->overlay_state, RETROK_LALT) ||
         OVERLAY_GET_KEY(&driver->overlay_state, RETROK_RALT))
      key_mod |= RETROKMOD_ALT;

   if (OVERLAY_GET_KEY(&driver->overlay_state, RETROK_LMETA) ||
         OVERLAY_GET_KEY(&driver->overlay_state, RETROK_RMETA))
      key_mod |= RETROKMOD_META;

   /* CAPSLOCK SCROLLOCK NUMLOCK */
   for (i = 0; i < ARRAY_SIZE(driver->overlay_state.keys); i++)
   {
      if (driver->overlay_state.keys[i] != old_key_state.keys[i])
      {
         uint32_t orig_bits = old_key_state.keys[i];
         uint32_t new_bits  = driver->overlay_state.keys[i];

         for (j = 0; j < 32; j++)
            if ((orig_bits & (1 << j)) != (new_bits & (1 << j)))
               input_keyboard_event(new_bits & (1 << j),
                     i * 32 + j, 0, key_mod, RETRO_DEVICE_POINTER);
      }
   }

   /* Map "analog" buttons to analog axes like regular input drivers do. */
   for (j = 0; j < 4; j++)
   {
      unsigned bind_plus  = RARCH_ANALOG_LEFT_X_PLUS + 2 * j;
      unsigned bind_minus = bind_plus + 1;

      if (driver->overlay_state.analog[j])
         continue;

      if (driver->overlay_state.buttons & (1ULL << bind_plus))
         driver->overlay_state.analog[j] += 0x7fff;
      if (driver->overlay_state.buttons & (1ULL << bind_minus))
         driver->overlay_state.analog[j] -= 0x7fff;
   }

   /* Check for analog_dpad_mode.
    * Map analogs to d-pad buttons when configured. */
   switch (settings->input.analog_dpad_mode[0])
   {
      case ANALOG_DPAD_LSTICK:
      case ANALOG_DPAD_RSTICK:
      {
         float analog_x, analog_y;
         unsigned analog_base = 2;

         if (settings->input.analog_dpad_mode[0] == ANALOG_DPAD_LSTICK)
            analog_base = 0;

         analog_x = (float)driver->overlay_state.analog[analog_base + 0] / 0x7fff;
         analog_y = (float)driver->overlay_state.analog[analog_base + 1] / 0x7fff;

         if (analog_x <= -settings->input.axis_threshold)
            driver->overlay_state.buttons |= (1ULL << RETRO_DEVICE_ID_JOYPAD_LEFT);
         if (analog_x >=  settings->input.axis_threshold)
            driver->overlay_state.buttons |= (1ULL << RETRO_DEVICE_ID_JOYPAD_RIGHT);
         if (analog_y <= -settings->input.axis_threshold)
            driver->overlay_state.buttons |= (1ULL << RETRO_DEVICE_ID_JOYPAD_UP);
         if (analog_y >=  settings->input.axis_threshold)
            driver->overlay_state.buttons |= (1ULL << RETRO_DEVICE_ID_JOYPAD_DOWN);
         break;
      }

      default:
         break;
   }

   if (polled)
      input_overlay_post_poll(overlay_device, opacity);
   else
      input_overlay_poll_clear(overlay_device, opacity);
}
#endif

/**
 * input_poll:
 *
 * Input polling callback function.
 **/
static void input_poll(void)
{
   driver_t *driver               = driver_get_ptr();
   settings_t *settings           = config_get_ptr();

   input_driver_poll();

#ifdef HAVE_OVERLAY
   if (driver->overlay)
      input_poll_overlay(driver->overlay,
            settings->input.overlay_opacity);
#endif

#ifdef HAVE_COMMAND
   if (driver->command)
      rarch_cmd_poll(driver->command);
#endif
}

/**
 * retro_set_default_callbacks:
 * @data           : pointer to retro_callbacks object
 *
 * Binds the libretro callbacks to default callback functions.
 **/
void retro_set_default_callbacks(void *data)
{
   struct retro_callbacks *cbs = (struct retro_callbacks*)data;

   if (!cbs)
      return;

   cbs->frame_cb        = video_frame;
   cbs->sample_cb       = audio_sample;
   cbs->sample_batch_cb = audio_sample_batch;
   cbs->state_cb        = input_state;
   cbs->poll_cb         = input_poll;
}

/**
 * retro_init_libretro_cbs:
 * @data           : pointer to retro_callbacks object
 *
 * Initializes libretro callbacks, and binds the libretro callbacks 
 * to default callback functions.
 **/
void retro_init_libretro_cbs(void *data)
{
   struct retro_callbacks *cbs = (struct retro_callbacks*)data;
   driver_t *driver = driver_get_ptr();
   global_t *global = global_get_ptr();

   if (!cbs)
      return;

   (void)driver;
   (void)global;

   pretro_set_video_refresh(video_frame);
   pretro_set_audio_sample(audio_sample);
   pretro_set_audio_sample_batch(audio_sample_batch);
   pretro_set_input_state(input_state);
   pretro_set_input_poll(input_poll);

   retro_set_default_callbacks(cbs);

#ifdef HAVE_NETPLAY
   if (!driver->netplay_data)
      return;

   if (global->netplay_is_spectate)
   {
      pretro_set_input_state(
            (global->netplay_is_client ?
             input_state_spectate_client : input_state_spectate)
            );
   }
   else
   {
      pretro_set_video_refresh(video_frame_net);
      pretro_set_audio_sample(audio_sample_net);
      pretro_set_audio_sample_batch(audio_sample_batch_net);
      pretro_set_input_state(input_state_net);
   }
#endif
}

/**
 * retro_set_rewind_callbacks:
 *
 * Sets the audio sampling callbacks based on whether or not
 * rewinding is currently activated.
 **/
void retro_set_rewind_callbacks(void)
{
   global_t *global = global_get_ptr();

   if (global->rewind.frame_is_reverse)
   {
      pretro_set_audio_sample(audio_sample_rewind);
      pretro_set_audio_sample_batch(audio_sample_batch_rewind);
   }
   else
   {
      pretro_set_audio_sample(audio_sample);
      pretro_set_audio_sample_batch(audio_sample_batch);
   }
}
