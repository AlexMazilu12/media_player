import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:path/path.dart' as path;
import 'dart:io';

late AudioPlayerHandler audioHandler;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  try {
    audioHandler = await AudioService.init(
      builder: () => AudioPlayerHandler(),
      config: AudioServiceConfig(
        androidNotificationChannelId: 'com.example.media_player.audio',
        androidNotificationChannelName: 'Audio Playback',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
        androidNotificationChannelDescription: 'Media playback controls',
        androidShowNotificationBadge: true,
        notificationColor: Colors.purple,
        androidNotificationIcon: 'drawable/ic_notification',
      ),
    );
    
    await audioHandler.setupMediaSession();
    
    audioHandler.mediaItem.add(MediaItem(
      id: 'none',
      title: 'No Track Selected',
      artist: 'Select a track to play',
      album: 'Music Player',
      playable: false,
      duration: Duration.zero,
    ));
    
    audioHandler.playbackState.add(audioHandler.playbackState.value.copyWith(
      controls: [MediaControl.play],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      processingState: AudioProcessingState.idle,
      playing: false,
    ));
  } catch (e) {
    audioHandler = AudioPlayerHandler();
    await audioHandler.setupMediaSession();
  }

  runApp(const AudioPlayerApp());
}

class AudioPlayerApp extends StatelessWidget {
  const AudioPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: AudioPlayerScreen(),
    );
  }
}

class AudioPlayerHandler extends BaseAudioHandler with SeekHandler {
  final _player = AudioPlayer();
  final _playlist = ConcatenatingAudioSource(children: []);
  
  AudioPlayerHandler() {
    _loadEmptyPlaylist();
    _notifyAudioHandlerAboutPlaybackEvents();
    _listenForDurationChanges();
    _listenForCurrentSongIndexChanges();
    _listenForSequenceStateChanges();

    playbackState.add(playbackState.value.copyWith(
      controls: [MediaControl.play, MediaControl.pause],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      processingState: AudioProcessingState.idle,
      playing: false,
    ));
  }

  Future<void> setupMediaSession() async {
    final session = await AudioSession.instance;
    await session.configure(AudioSessionConfiguration.music());
  }

  Future<void> _loadEmptyPlaylist() async {
    try {
      await _player.setAudioSource(_playlist);
    } catch (e) {}
  }

  void _notifyAudioHandlerAboutPlaybackEvents() {
    _player.playbackEventStream.listen((PlaybackEvent event) {
      final playing = _player.playing;
      
      playbackState.add(playbackState.value.copyWith(
        controls: [
          if (playing) MediaControl.pause else MediaControl.play,
        ],
        processingState: {
          ProcessingState.idle: AudioProcessingState.idle,
          ProcessingState.loading: AudioProcessingState.loading,
          ProcessingState.buffering: AudioProcessingState.buffering,
          ProcessingState.ready: AudioProcessingState.ready,
          ProcessingState.completed: AudioProcessingState.completed,
        }[_player.processingState]!,
        playing: playing,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
        queueIndex: event.currentIndex,
      ));

      if (_player.currentIndex != null && queue.value.isNotEmpty) {
        mediaItem.add(queue.value[_player.currentIndex!]);
      }
    });
  }

  void _listenForDurationChanges() {
    _player.durationStream.listen((duration) {
      var index = _player.currentIndex;
      final newQueue = queue.value;
      if (index == null || newQueue.isEmpty) return;
      if (_player.duration == null) return;
      final oldMediaItem = newQueue[index];
      final newMediaItem = oldMediaItem.copyWith(duration: duration);
      newQueue[index] = newMediaItem;
      queue.add(newQueue);
      mediaItem.add(newMediaItem);
    });
  }

  void _listenForCurrentSongIndexChanges() {
    _player.currentIndexStream.listen((index) {
      final playlist = queue.value;
      if (index == null || playlist.isEmpty) return;
      mediaItem.add(playlist[index]);
    });
  }

  void _listenForSequenceStateChanges() {
    _player.sequenceStateStream.listen((SequenceState? sequenceState) {
      final sequence = sequenceState?.effectiveSequence;
      if (sequence == null || sequence.isEmpty) return;
      final items = sequence.map((source) => source.tag as MediaItem);
      queue.add(items.toList());
    });
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> stop() => _player.stop();

Future<Duration> _getDuration(String filePath) async {
    try {
      // Create a temporary player to get the duration
      final tempPlayer = AudioPlayer();
      await tempPlayer.setFilePath(filePath);
      
      // Wait for duration to be available
      Duration? duration;
      try {
        duration = await tempPlayer.durationFuture;
      } catch (e) {
        // If durationFuture throws an error, try getting it directly
        duration = tempPlayer.duration;
      }
      
      await tempPlayer.dispose();
      return duration ?? Duration.zero;
    } catch (e) {
      print('Error getting duration: $e');
      return Duration.zero;
    }
  }
  
  Future<void> setFilePath(String filePath, {String? title, String? artist}) async {
    try {
      playbackState.add(playbackState.value.copyWith(
        processingState: AudioProcessingState.loading,
        playing: false,
      ));
      
      final duration = await _getDuration(filePath);
      
      // Extract metadata from the file
      final metadata = await _extractMetadata(filePath);
      
      // If album art is available, save it to a temporary file
      Uri? artUri;
      if (metadata['albumArt'] != null) {
        try {
          final tempDir = Directory.systemTemp;
          final tempFile = File('${tempDir.path}/album_art_${DateTime.now().millisecondsSinceEpoch}.jpg');
          await tempFile.writeAsBytes(metadata['albumArt']);
          artUri = Uri.file(tempFile.path);
        } catch (e) {
          print('Error saving album art: $e');
          artUri = Uri.parse('asset:///assets/album_art.png');
        }
      } else {
        artUri = Uri.parse('asset:///assets/album_art.png');
      }
      
      final newMediaItem = MediaItem(
        id: filePath,
        title: metadata['title'] ?? title ?? _getFileNameWithoutExtension(filePath),
        artist: metadata['artist'] ?? artist ?? 'Unknown Artist',
        album: metadata['album'] ?? 'Music Player',
        artUri: artUri,
        playable: true,
        displayTitle: metadata['title'] ?? title ?? _getFileNameWithoutExtension(filePath),
        displaySubtitle: metadata['artist'] ?? artist ?? 'Unknown Artist',
        duration: duration,
      );

      mediaItem.add(newMediaItem);

      await _playlist.clear();
      await _playlist.add(
        AudioSource.uri(
          Uri.parse('file://$filePath'),
          tag: newMediaItem,
        ),
      );
      
      queue.add([newMediaItem]);
      
      playbackState.add(playbackState.value.copyWith(
        controls: [MediaControl.pause],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        processingState: AudioProcessingState.ready,
        playing: false,
      ));
      
      await Future.delayed(Duration(milliseconds: 200));
      await _player.play();
    } catch (e) {
      print('Error setting file path: $e');
    }
  }

  String _getFileNameWithoutExtension(String filePath) {
    final fileName = path.basename(filePath);
    return path.basenameWithoutExtension(fileName);
  }

  Future<Map<String, dynamic>> _extractMetadata(String filePath) async {
    try {
      // Create a temporary player to get basic metadata
      final tempPlayer = AudioPlayer();
      await tempPlayer.setFilePath(filePath);
      
      // Try to parse the filename for additional info
      final fileName = path.basename(filePath);
      final fileNameWithoutExt = path.basenameWithoutExtension(filePath);
      
      // Set defaults using filename
      String title = fileNameWithoutExt;
      String artist = 'Unknown Artist';
      
      // Try to parse artist - title pattern from filename
      if (fileNameWithoutExt.contains(' - ')) {
        final parts = fileNameWithoutExt.split(' - ');
        if (parts.length >= 2) {
          artist = parts[0].trim();
          title = parts.sublist(1).join(' - ').trim();
        }
      }
      
      // Use any available icyMetadata from the audio source
      if (tempPlayer.icyMetadata?.info?.title != null) {
        // ICY title often contains both artist and title in format "Artist - Title"
        final icyTitle = tempPlayer.icyMetadata!.info!.title!;
        
        if (icyTitle.contains(' - ')) {
          final parts = icyTitle.split(' - ');
          if (parts.length >= 2) {
            artist = parts[0].trim();
            title = parts.sublist(1).join(' - ').trim();
          } else {
            title = icyTitle;
          }
        } else {
          title = icyTitle;
        }
      }
      
      final result = {
        'title': title,
        'artist': artist,
        'album': 'Music Player',
        // We won't have album art this way
      };
      
      await tempPlayer.dispose();
      return result;
    } catch (e) {
      print('Error extracting basic metadata: $e');
      // Return filename-based metadata as fallback
      final fileNameWithoutExt = path.basenameWithoutExtension(filePath);
      return {
        'title': fileNameWithoutExt,
        'artist': 'Unknown Artist',
        'album': 'Music Player',
      };
    }
  }

  @override
  Future<void> addQueueItem(MediaItem mediaItem) async {
    final audioSource = AudioSource.uri(
      Uri.parse(mediaItem.id),
      tag: mediaItem,
    );
    await _playlist.add(audioSource);
    final newQueue = List<MediaItem>.from(queue.value)..add(mediaItem);
    queue.add(newQueue);
  }

  @override
  Future<void> removeQueueItemAt(int index) async {
    await _playlist.removeAt(index);
    final newQueue = List<MediaItem>.from(queue.value)..removeAt(index);
    queue.add(newQueue);
  }
}

class AudioPlayerScreen extends StatefulWidget {
  const AudioPlayerScreen({super.key});

  @override
  _AudioPlayerScreenState createState() => _AudioPlayerScreenState();
}

class _AudioPlayerScreenState extends State<AudioPlayerScreen> {
  String? _filePath;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String _title = 'Melody Title';
  String _artist = 'Artist';

  @override
  void initState() {
    super.initState();
    _setupAudioHandlerListeners();
  }

  void _setupAudioHandlerListeners() {
    audioHandler.playbackState.listen((state) {
      setState(() {
        _isPlaying = state.playing;
        _position = state.position;
      });
    });
    
    audioHandler.mediaItem.listen((item) {
      if (item != null) {
        setState(() {
          _title = item.title;
          _artist = item.artist ?? 'Unknown Artist';
          _duration = item.duration ?? Duration.zero;
        });
      }
    });
  }

  Future<void> _pickFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
    );

    if (result != null) {
      _filePath = result.files.single.path;
      await audioHandler.setFilePath(_filePath!);
    }
  }

  Future<void> _togglePlayPause() async {
    if (_isPlaying) {
      await audioHandler.pause();
    } else {
      await audioHandler.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF53027C),
              Color(0xFF021250),
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 310,
                      height: 310,
                      decoration: BoxDecoration(
                        color: Color(0xFF743AC0),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Center(
                        child: IconButton(
                          icon: Image.asset('assets/upload.png', width: 60, height: 60, color: Colors.white),
                          onPressed: _pickFile,
                        ),
                      ),
                    ),
                    SizedBox(height: 20),
                    Text(
                      _title,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      _artist,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                      ),
                    ),
                    SizedBox(height: 40),
                    SizedBox(
                      width: 300,
                      child: LinearProgressIndicator(
                        value: _duration.inMilliseconds > 0 
                          ? _position.inMilliseconds / _duration.inMilliseconds
                          : 0.0,
                        backgroundColor: Colors.white24,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  ],
                ),
              ),
              Container(
                child: Transform.translate(
                  offset: Offset(0, -80),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 65,
                        height: 65,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                        child: IconButton(
                          icon: Center(
                            child: Image.asset(
                              _isPlaying ? 'assets/pause.png' : 'assets/play-button-arrowhead.png',
                              width: 30,
                              height: 30,
                              color: Colors.black,
                            ),
                          ),
                          onPressed: _togglePlayPause,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}