'use strict'

import React from 'react'
import { NativeModules, NativeEventEmitter, Platform } from 'react-native'

const { AudioRecorderManager } = NativeModules
const AudioRecorderManagerEmitter = new NativeEventEmitter(AudioRecorderManager)

var AudioRecorder = {
  prepareRecordingAtPath: function (path, options) {
    if (this.progressSubscription) this.progressSubscription.remove()
    this.progressSubscription = AudioRecorderManagerEmitter.addListener(
      'recordingProgress',
      data => {
        if (this.onProgress) {
          this.onProgress(data)
        }
      },
    )

    if (this.finishedSubscription) this.finishedSubscription.remove()
    this.finishedSubscription = AudioRecorderManagerEmitter.addListener(
      'recordingFinished',
      data => {
        if (this.onFinished) {
          this.onFinished(data)
        }
      },
    )

    var defaultOptions = {
      SampleRate: 44100.0,
      Channels: 2,
      AudioQuality: 'High',
      AudioEncoding: 'ima4',
      OutputFormat: 'mpeg_4',
      MeteringEnabled: false,
      MeasurementMode: false,
      AudioEncodingBitRate: 32000,
      IncludeBase64: false,
    }

    var recordingOptions = { ...defaultOptions, ...options }

    if (Platform.OS === 'ios') {
      AudioRecorderManager.prepareRecordingAtPath(
        path,
        recordingOptions.SampleRate,
        recordingOptions.Channels,
        recordingOptions.AudioQuality,
        recordingOptions.AudioEncoding,
        recordingOptions.MeteringEnabled,
        recordingOptions.MeasurementMode,
        recordingOptions.IncludeBase64,
      )
    } else {
      return AudioRecorderManager.prepareRecordingAtPath(path, recordingOptions)
    }
  },
  startRecording: function (startTime) {
    return AudioRecorderManager.startRecording(startTime)
  },
  stopRecording: function () {
    return AudioRecorderManager.stopRecording()
  },
  checkAuthorizationStatus: AudioRecorderManager.checkAuthorizationStatus,
  requestAuthorization: AudioRecorderManager.requestAuthorization,
  removeListeners: function () {
    if (this.progressSubscription) this.progressSubscription.remove()
    if (this.finishedSubscription) this.finishedSubscription.remove()
  },
  generateWaveform: function(path) {
    return AudioRecorderManager.generateWaveform(path)
  },
  getAudioData: function(path) {
    return AudioRecorderManager.getAudioData(path)
  },
}

let AudioUtils = {}

if (Platform.OS === 'ios') {
  AudioUtils = {
    MainBundlePath: AudioRecorderManager.MainBundlePath,
    CachesDirectoryPath: AudioRecorderManager.NSCachesDirectoryPath,
    DocumentDirectoryPath: AudioRecorderManager.NSDocumentDirectoryPath,
    LibraryDirectoryPath: AudioRecorderManager.NSLibraryDirectoryPath,
  }
} else if (Platform.OS === 'android') {
  AudioUtils = {
    MainBundlePath: AudioRecorderManager.MainBundlePath,
    CachesDirectoryPath: AudioRecorderManager.CachesDirectoryPath,
    DocumentDirectoryPath: AudioRecorderManager.DocumentDirectoryPath,
    LibraryDirectoryPath: AudioRecorderManager.LibraryDirectoryPath,
    PicturesDirectoryPath: AudioRecorderManager.PicturesDirectoryPath,
    MusicDirectoryPath: AudioRecorderManager.MusicDirectoryPath,
    DownloadsDirectoryPath: AudioRecorderManager.DownloadsDirectoryPath,
  }
}

module.exports = { AudioRecorder, AudioUtils }
