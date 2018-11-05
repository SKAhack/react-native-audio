//
//  AudioRecorderManager.m
//  AudioRecorderManager
//
//  Created by Joshua Sierles on 15/04/15.
//  Copyright (c) 2015 Joshua Sierles. All rights reserved.
//

#import "AudioRecorderManager.h"
#import <React/RCTConvert.h>
#import <React/RCTBridge.h>
#import <React/RCTUtils.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <React/RCTLog.h>

#define absX(x) (x<0?0-x:x)
#define minMaxX(x,mn,mx) (x<=mn?mn:(x>=mx?mx:x))
#define noiseFloor (-160.0)
#define decibel(amplitude) (20.0 * log10(absX(amplitude)/32767.0))

NSString *const AudioRecorderEventProgress = @"recordingProgress";
NSString *const AudioRecorderEventFinished = @"recordingFinished";

@implementation AudioRecorderManager {
  AVAudioRecorder *_audioRecorder;
  NSTimeInterval _currentTime;
  NSTimeInterval _recordingStartTime;
  id _progressUpdateTimer;
  int _progressUpdateInterval;
  NSDate *_prevProgressUpdateTime;
  NSURL *_audioFileURL;
  NSURL *_tmp1AudioFileURL;
  NSURL *_tmp2AudioFileURL;
  NSNumber *_audioQuality;
  NSNumber *_audioEncoding;
  NSNumber *_audioChannels;
  NSNumber *_audioSampleRate;
  NSDictionary *_recordSettings;
  AVAudioSession *_recordSession;
  BOOL _meteringEnabled;
  BOOL _measurementMode;
  BOOL _includeBase64;
}

+ (BOOL)requiresMainQueueSetup {
  return YES;
}

RCT_EXPORT_MODULE();

- (NSArray<NSString *> *)supportedEvents {
  return @[
    AudioRecorderEventProgress,
    AudioRecorderEventFinished
  ];
}

- (void)sendProgressUpdate {
  if (_audioRecorder && _audioRecorder.isRecording) {
    _currentTime = _audioRecorder.currentTime;
  } else {
    return;
  }

  if (_prevProgressUpdateTime == nil ||
   (([_prevProgressUpdateTime timeIntervalSinceNow] * -1000.0) >= _progressUpdateInterval)) {
      NSMutableDictionary *body = [[NSMutableDictionary alloc] init];
      [body setObject:[NSNumber numberWithFloat:_currentTime] forKey:@"currentTime"];
      if (_meteringEnabled) {
          [_audioRecorder updateMeters];
          float _currentMetering = [_audioRecorder averagePowerForChannel: 0];
          [body setObject:[NSNumber numberWithFloat:_currentMetering] forKey:@"currentMetering"];

          float _currentPeakMetering = [_audioRecorder peakPowerForChannel:0];
          [body setObject:[NSNumber numberWithFloat:_currentPeakMetering] forKey:@"currentPeakMetering"];
      }
      [self sendEventWithName:AudioRecorderEventProgress body:body];

    _prevProgressUpdateTime = [NSDate date];
  }
}

- (void)stopProgressTimer {
  [_progressUpdateTimer invalidate];
}

- (void)startProgressTimer {
  _progressUpdateInterval = 250;
  //_prevProgressUpdateTime = nil;

  [self stopProgressTimer];

  _progressUpdateTimer = [CADisplayLink
                          displayLinkWithTarget:self
                          selector:@selector(sendProgressUpdate)];
  [_progressUpdateTimer addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)prepareToRecord {
  NSError *error = nil;
  _audioRecorder = [[AVAudioRecorder alloc]
                initWithURL:_tmp1AudioFileURL
                settings:_recordSettings
                error:&error];

  _audioRecorder.meteringEnabled = _meteringEnabled;
  _audioRecorder.delegate = self;

  if (error) {
    // TODO: dispatch error over the bridge
  } else {
    [_audioRecorder prepareToRecord];
  }
}

- (AVComposition *)mergeAudioWithTargetURL:(NSURL *)targetURL sourceURL:(NSURL *)sourceURL atTime:(CMTime)startTime {
  AVMutableComposition *composition = [AVMutableComposition composition];
  AVMutableCompositionTrack *track = [composition
                                      addMutableTrackWithMediaType:AVMediaTypeAudio
                                      preferredTrackID:kCMPersistentTrackID_Invalid];

  AVURLAsset *targetAsset = [AVURLAsset URLAssetWithURL:targetURL options:nil];
  AVURLAsset *sourceAsset = [AVURLAsset URLAssetWithURL:sourceURL options:nil];

  if (CMTimeCompare(startTime, kCMTimeZero) != 0) {
    if (![self insertTrackWithAsset:targetAsset track:track atTime:kCMTimeZero startTime:kCMTimeZero endTime:startTime]) {
      return nil;
    }
  }
  if (![self insertTrackWithAsset:sourceAsset track:track atTime:startTime startTime:kCMTimeZero endTime:sourceAsset.duration]) {
    return nil;
  }
  if (CMTimeCompare(CMTimeSubtract(targetAsset.duration, startTime), sourceAsset.duration) == 1) {
    if (![self insertTrackWithAsset:targetAsset
      track:track
      atTime:CMTimeAdd(startTime, sourceAsset.duration)
      startTime:CMTimeAdd(startTime, sourceAsset.duration)
      endTime:targetAsset.duration])
    {
      return nil;
    }
  }
  return [composition copy];
}

- (BOOL)insertTrackWithAsset:(AVURLAsset *)asset
  track:(AVMutableCompositionTrack *)track
  atTime:(CMTime)atTime
  startTime:(CMTime)startTime
  endTime:(CMTime)endTime
{
  NSError *error;
  NSArray *assetTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
  if ([assetTracks count] == 0) {
    return NO;
  }
  AVAssetTrack *assetTrack = [assetTracks objectAtIndex:0];
  CMTimeRange timeRange = CMTimeRangeMake(startTime, endTime);

  error = nil;
  [track insertTimeRange:timeRange ofTrack:assetTrack atTime:atTime error:&error];
  if (error) {
    return NO;
  }
  return YES;
}

- (BOOL)exportAudioAsset:(AVAsset *)asset complete:(void (^)(void))handler {
  AVAssetExportSession *exportSession = [AVAssetExportSession
                                          exportSessionWithAsset:asset
                                          presetName:AVAssetExportPresetAppleM4A];
  if (exportSession == nil) {
    return NO;
  }
  exportSession.outputURL = _tmp2AudioFileURL;
  exportSession.outputFileType = AVFileTypeAppleM4A;

  [exportSession exportAsynchronouslyWithCompletionHandler:^{
    switch (exportSession.status) {
      case AVAssetExportSessionStatusCompleted:
        handler();
        break;
      case AVAssetExportSessionStatusFailed:
        RCTLogInfo(@"audioRecorderDidFinishRecording: failed %@", exportSession.error);
        break;
      default:
        RCTLogInfo(@"audioRecorderDidFinishRecording: default");
        break;
    }
  }];
  return YES;
}

- (void)audioRecorderDidFinishRecording:(AVAudioRecorder *)recorder successfully:(BOOL)flag {
  NSError *error;
  NSFileManager *manager = [[NSFileManager alloc] init];
  if ([manager fileExistsAtPath: [_audioFileURL path]]) {
    AVComposition *composition = [self mergeAudioWithTargetURL:_audioFileURL
                                  sourceURL:recorder.url
                                  atTime:CMTimeMakeWithSeconds(_recordingStartTime, 1000000)];
    if (composition == nil) {
      return;
    }

    [self exportAudioAsset:composition complete:^{
      NSError *error = nil;
      [manager removeItemAtURL:_audioFileURL error:&error];
      [manager removeItemAtURL:_tmp1AudioFileURL error:&error];
      [manager moveItemAtURL:_tmp2AudioFileURL toURL:_audioFileURL error:&error];
      [self finishRecording];
    }];
  } else {
    error = nil;
    [manager moveItemAtURL:recorder.url toURL:_audioFileURL error:&error];
    [self finishRecording];
  }
}

- (void)finishRecording {
  NSString *base64 = @"";
  if (_includeBase64) {
    NSData *data = [NSData dataWithContentsOfFile:_audioFileURL];
    base64 = [data base64EncodedStringWithOptions:0];
  }

  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:_audioFileURL options:nil];
  [self sendEventWithName:AudioRecorderEventFinished body:@{
    @"base64":base64,
    @"duration":@(CMTimeGetSeconds(asset.duration)),
    @"status":@"OK",
    @"audioFileURL":[_audioFileURL absoluteString]
  }];
}

- (NSString *) applicationDocumentsDirectory
{
  NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
  NSString *basePath = ([paths count] > 0) ? [paths objectAtIndex:0] : nil;
  return basePath;
}

RCT_EXPORT_METHOD(prepareRecordingAtPath:(NSString *)path sampleRate:(float)sampleRate channels:(nonnull NSNumber *)channels quality:(NSString *)quality encoding:(NSString *)encoding meteringEnabled:(BOOL)meteringEnabled measurementMode:(BOOL)measurementMode includeBase64:(BOOL)includeBase64)
{
  _prevProgressUpdateTime = nil;
  [self stopProgressTimer];

  _audioFileURL = [NSURL fileURLWithPath:path];

  NSString *pathWithoutLastPath = [[_audioFileURL URLByDeletingLastPathComponent] absoluteString];
  NSString *lastPathComponent = [_audioFileURL lastPathComponent];
  _tmp1AudioFileURL = [NSURL URLWithString:
    [NSString stringWithFormat:@"%@%@_%@", pathWithoutLastPath, @"tmp1", lastPathComponent]];
  _tmp2AudioFileURL = [NSURL URLWithString:
    [NSString stringWithFormat:@"%@%@_%@", pathWithoutLastPath, @"tmp2", lastPathComponent]];

  // Default options
  _audioQuality = [NSNumber numberWithInt:AVAudioQualityHigh];
  _audioEncoding = [NSNumber numberWithInt:kAudioFormatAppleIMA4];
  _audioChannels = [NSNumber numberWithInt:2];
  _audioSampleRate = [NSNumber numberWithFloat:44100.0];
  _meteringEnabled = NO;
  _includeBase64 = NO;

  // Set audio quality from options
  if (quality != nil) {
    if ([quality  isEqual: @"Low"]) {
      _audioQuality =[NSNumber numberWithInt:AVAudioQualityLow];
    } else if ([quality  isEqual: @"Medium"]) {
      _audioQuality =[NSNumber numberWithInt:AVAudioQualityMedium];
    } else if ([quality  isEqual: @"High"]) {
      _audioQuality =[NSNumber numberWithInt:AVAudioQualityHigh];
    }
  }

  // Set channels from options
  if (channels != nil) {
    _audioChannels = channels;
  }

  // Set audio encoding from options
  if (encoding != nil) {
    if ([encoding  isEqual: @"lpcm"]) {
      _audioEncoding =[NSNumber numberWithInt:kAudioFormatLinearPCM];
    } else if ([encoding  isEqual: @"ima4"]) {
      _audioEncoding =[NSNumber numberWithInt:kAudioFormatAppleIMA4];
    } else if ([encoding  isEqual: @"aac"]) {
      _audioEncoding =[NSNumber numberWithInt:kAudioFormatMPEG4AAC];
    } else if ([encoding  isEqual: @"MAC3"]) {
      _audioEncoding =[NSNumber numberWithInt:kAudioFormatMACE3];
    } else if ([encoding  isEqual: @"MAC6"]) {
      _audioEncoding =[NSNumber numberWithInt:kAudioFormatMACE6];
    } else if ([encoding  isEqual: @"ulaw"]) {
      _audioEncoding =[NSNumber numberWithInt:kAudioFormatULaw];
    } else if ([encoding  isEqual: @"alaw"]) {
      _audioEncoding =[NSNumber numberWithInt:kAudioFormatALaw];
    } else if ([encoding  isEqual: @"mp1"]) {
      _audioEncoding =[NSNumber numberWithInt:kAudioFormatMPEGLayer1];
    } else if ([encoding  isEqual: @"mp2"]) {
      _audioEncoding =[NSNumber numberWithInt:kAudioFormatMPEGLayer2];
    } else if ([encoding  isEqual: @"alac"]) {
      _audioEncoding =[NSNumber numberWithInt:kAudioFormatAppleLossless];
    } else if ([encoding  isEqual: @"amr"]) {
      _audioEncoding =[NSNumber numberWithInt:kAudioFormatAMR];
    }
  }

  // Set sample rate from options
  _audioSampleRate = [NSNumber numberWithFloat:sampleRate];

  _recordSettings = [NSDictionary dictionaryWithObjectsAndKeys:
          _audioQuality, AVEncoderAudioQualityKey,
          _audioEncoding, AVFormatIDKey,
          _audioChannels, AVNumberOfChannelsKey,
          _audioSampleRate, AVSampleRateKey,
          nil];

  // Enable metering from options
  if (meteringEnabled != NO) {
    _meteringEnabled = meteringEnabled;
  }

  // Measurement mode to disable mic auto gain and high pass filters
  if (measurementMode != NO) {
    _measurementMode = measurementMode;
  }

  if (includeBase64) {
    _includeBase64 = includeBase64;
  }

  _recordSession = [AVAudioSession sharedInstance];

  if (_measurementMode) {
      [_recordSession setCategory:AVAudioSessionCategoryRecord error:nil];
      [_recordSession setMode:AVAudioSessionModeMeasurement error:nil];
  }else{
      [_recordSession setCategory:AVAudioSessionCategoryMultiRoute error:nil];
  }
}

RCT_EXPORT_METHOD(startRecording:(double)startTime)
{
  _recordingStartTime = startTime;

  [_recordSession setCategory:AVAudioSessionCategoryRecord error:nil];
  [self prepareToRecord];
  [self startProgressTimer];
  [_recordSession setActive:YES error:nil];
  [_audioRecorder record];
}

RCT_EXPORT_METHOD(stopRecording)
{
  [_audioRecorder stop];
  [self stopProgressTimer];
  [_recordSession setCategory:AVAudioSessionCategoryPlayback error:nil];
  _prevProgressUpdateTime = nil;
}

RCT_EXPORT_METHOD(checkAuthorizationStatus:(RCTPromiseResolveBlock)resolve reject:(__unused RCTPromiseRejectBlock)reject)
{
  AVAudioSessionRecordPermission permissionStatus = [[AVAudioSession sharedInstance] recordPermission];
  switch (permissionStatus) {
    case AVAudioSessionRecordPermissionUndetermined:
      resolve(@("undetermined"));
    break;
    case AVAudioSessionRecordPermissionDenied:
      resolve(@("denied"));
      break;
    case AVAudioSessionRecordPermissionGranted:
      resolve(@("granted"));
      break;
    default:
      reject(RCTErrorUnspecified, nil, RCTErrorWithMessage(@("Error checking device authorization status.")));
      break;
  }
}

RCT_EXPORT_METHOD(requestAuthorization:(RCTPromiseResolveBlock)resolve
                  rejecter:(__unused RCTPromiseRejectBlock)reject)
{
  [[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL granted) {
    if(granted) {
      resolve(@YES);
    } else {
      resolve(@NO);
    }
  }];
}

RCT_EXPORT_METHOD(getAudioData:(NSString *)path resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
{
  NSURL *url = [NSURL fileURLWithPath:path];
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
  resolve(@{
    @"duration": @(CMTimeGetSeconds(asset.duration))
  });
}

RCT_EXPORT_METHOD(generateWaveform:(NSString *)path resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
{
  // ref: https://stackoverflow.com/questions/8298610/waveform-on-ios
  NSError *error;
  NSURL *url = [NSURL fileURLWithPath:path];
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
  AVAssetTrack *assetTrack = [asset.tracks firstObject];

  error = nil;
  AVAssetReader *assetReader = [AVAssetReader assetReaderWithAsset:asset error:&error];

  NSMutableArray<NSNumber *> *audioData = [[NSMutableArray alloc] init];
  if (!assetTrack) {
    resolve(audioData);
    return;
  }

  NSDictionary *outputSettingsDict = [NSDictionary dictionaryWithObjectsAndKeys:
    [NSNumber numberWithInt:kAudioFormatLinearPCM], AVFormatIDKey,
    [NSNumber numberWithInt:16], AVLinearPCMBitDepthKey,
    [NSNumber numberWithBool:NO], AVLinearPCMIsBigEndianKey,
    [NSNumber numberWithBool:NO], AVLinearPCMIsFloatKey,
    [NSNumber numberWithBool:NO], AVLinearPCMIsNonInterleaved,
    nil];
  AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput
    assetReaderTrackOutputWithTrack:assetTrack
    outputSettings:outputSettingsDict];
  [assetReader addOutput:output];

  UInt32 sampleRate, channelCount;
  for (unsigned int i = 0; i < assetTrack.formatDescriptions.count; i++) {
    CMFormatDescriptionRef item = (__bridge CMFormatDescriptionRef)assetTrack.formatDescriptions[i];
    const AudioStreamBasicDescription* fmtDesc = CMAudioFormatDescriptionGetStreamBasicDescription(item);
    if (fmtDesc) {
      sampleRate = fmtDesc->mSampleRate;
      channelCount = fmtDesc->mChannelsPerFrame;
    }
  }

  [assetReader startReading];

  UInt32 bytesPerSample = 2 * channelCount;
  Float32 normalizeMax = noiseFloor;
  Float32 totalLeft = 0;
  Float32 totalRight = 0;
  NSInteger sampleTally = 0;
  // 0.25secごとにデータを取得する 1sec / 4 = 0.25
  NSInteger samplesPerPixel = sampleRate / 4;

  while ([assetReader status] == AVAssetReaderStatusReading) {
    AVAssetReaderTrackOutput *trackOutput = (AVAssetReaderTrackOutput *)[assetReader.outputs firstObject];
    CMSampleBufferRef sampleBuffer = [trackOutput copyNextSampleBuffer];
    if (!sampleBuffer) {
      continue;
    }

    CMBlockBufferRef blockBufferRef = CMSampleBufferGetDataBuffer(sampleBuffer);
    size_t length = CMBlockBufferGetDataLength(blockBufferRef);
    NSMutableData *data = [NSMutableData dataWithLength:length];
    CMBlockBufferCopyDataBytes(blockBufferRef, 0, length, data.mutableBytes);

    SInt16 *samples = (SInt16 *)data.mutableBytes;
    unsigned long sampleCount = length / bytesPerSample;
    for (int i = 0; i < sampleCount; i++) {
      Float32 left = (Float32)*samples++;
      left = decibel(left);
      left = minMaxX(left,noiseFloor,0);
      totalLeft += left;

      Float32 right = 0.0;
      if (channelCount == 2) {
        right = (Float32)*samples++;
        right = decibel(right);
        right = minMaxX(right,noiseFloor,0);
        totalRight += right;
      }

      Float32 vol = 0.0;
      sampleTally++;
      if (samplesPerPixel < sampleTally) {
        left = totalLeft / sampleTally;
        if (normalizeMax < left) {
          normalizeMax = left;
        }
        vol = left;

        if (channelCount == 2) {
          right = totalRight / sampleTally;
          if (normalizeMax < right) {
            normalizeMax = right;
          }
          vol = (vol + right) / 2.0;
        }
        // 収録時の大きさと結構違うので合わせる
        vol = vol * 0.35;

        [audioData addObject:[NSNumber numberWithFloat:vol]];
        totalLeft = 0;
        totalRight = 0;
        sampleTally = 0;
      }
    }

    CMSampleBufferInvalidate(sampleBuffer);
    CFRelease(sampleBuffer);
  }

  resolve(audioData);
}

- (NSString *)getPathForDirectory:(int)directory
{
  NSArray *paths = NSSearchPathForDirectoriesInDomains(directory, NSUserDomainMask, YES);
  return [paths firstObject];
}

- (NSDictionary *)constantsToExport
{
  return @{
    @"MainBundlePath": [[NSBundle mainBundle] bundlePath],
    @"NSCachesDirectoryPath": [self getPathForDirectory:NSCachesDirectory],
    @"NSDocumentDirectoryPath": [self getPathForDirectory:NSDocumentDirectory],
    @"NSLibraryDirectoryPath": [self getPathForDirectory:NSLibraryDirectory]
  };
}

@end
