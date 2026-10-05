#ifndef RUNNER_AUDIO_DUCKING_H_
#define RUNNER_AUDIO_DUCKING_H_

#include <flutter/binary_messenger.h>

// Windows lowers ("ducks") all other sounds when an app uses the communications audio
// device, like during a phone call. WebRTC (voice channels) uses that device, so by
// default music and games would get 80% quieter whenever you join voice. These functions
// opt this app out of that, as Microsoft documents for communication apps:
// https://learn.microsoft.com/windows/win32/coreaudio/disabling-the-ducking-experience

// Opts this app's audio sessions on the default devices out of ducking. Returns how many
// sessions were updated. COM must be initialized on the calling thread.
int OptOutOfDucking();

// Channel "vianden/audio" for Dart:
//   "disableDucking"      calls OptOutOfDucking again (e.g. after the device changed).
//   "defaultAudioDevices" returns {"input": id, "output": id}: Windows' default devices,
//                         as the IDs WebRTC uses (its own list has no "default" entry).
void RegisterAudioChannel(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_AUDIO_DUCKING_H_
