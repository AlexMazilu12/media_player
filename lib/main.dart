import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';

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
        androidStopForegroundOnPause: false,  // Change to false
        androidNotificationChannelDescription: 'Media playback controls',
        notificationColor: Colors.purple,
      ),
    );
    
    // Only set up the media session once, here
    await audioHandler.setupMediaSession();
    
    // Initialize media item and playback state here
    audioHandler.mediaItem.add(MediaItem(
      id: 'none',
      title: 'No Track Selected',
      artist: 'Select a track to play',
      album: 'Music Player',
      playable: false,
    ));
    
    audioHandler.playbackState.add(audioHandler.playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        MediaControl.play,
        MediaControl.skipToNext,
      ],
      processingState: AudioProcessingState.idle,
      playing: false,
    ));
  } catch (e) {
    print("Error initializing audio service: $e");
    // Initialize with a fallback handler if needed
    audioHandler = AudioPlayerHandler();
    
    // Set up media session for fallback handler
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
    controls: [
      MediaControl.skipToPrevious,
      MediaControl.play,
      MediaControl.pause,
      MediaControl.skipToNext,
    ],
    androidCompactActionIndices: const [0, 1, 3],
    systemActions: {MediaAction.seek},
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
    } catch (e) {
      print("Error occured: $e");
    }
  }

void _notifyAudioHandlerAboutPlaybackEvents() {
  _player.playbackEventStream.listen((PlaybackEvent event) {
    final playing = _player.playing;
    
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      androidCompactActionIndices: const [0, 1, 2],
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
  Future<void> skipToNext() => _player.seekToNext();

  @override
  Future<void> skipToPrevious() => _player.seekToPrevious();

  @override
  Future<void> stop() => _player.stop();

Future<void> setFilePath(String filePath, {String? title, String? artist}) async {
  final newMediaItem = MediaItem(
    id: filePath,
    title: title ?? 'Unknown Title',
    artist: artist ?? 'Unknown Artist',
    album: 'Music Player',
    playable: true,
    displayTitle: title ?? 'Unknown Title',
    displaySubtitle: artist ?? 'Unknown Artist',
    artUri: Uri.parse('asset:///assets/album_art.png'),
    duration: await _getDuration(filePath),
  );

  // Update the current media item
  mediaItem.add(newMediaItem);

  await _playlist.clear();
  await _playlist.add(
    AudioSource.uri(
      Uri.parse('file://$filePath'),
      tag: newMediaItem,
    ),
  );

  queue.add([newMediaItem]);
  
  // Make sure we update the playback state before playing
  playbackState.add(playbackState.value.copyWith(
    controls: [
      MediaControl.skipToPrevious,
      MediaControl.pause,
      MediaControl.skipToNext,
    ],
    androidCompactActionIndices: const [0, 1, 2],
    processingState: AudioProcessingState.ready,
    playing: false,
  ));

  // Now play the media
  play();
}


  Future<Duration?> _getDuration(String filePath) async {
    try {
      final tempPlayer = AudioPlayer();
      final duration = await tempPlayer.setFilePath(filePath).then((_) => tempPlayer.duration);
      await tempPlayer.dispose();
      return duration;
    } catch (e) {
      print("Error getting duration: $e");
      return null;
    }
  }

  // Make sure you properly implement these override methods
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
  void dispose() {
    super.dispose();
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
                      IconButton(
                        icon: Image.asset('assets/previous.png', width: 40, height: 40, color: Colors.white),
                        onPressed: () => audioHandler.skipToPrevious(),
                      ),
                      SizedBox(width: 50),
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
                      SizedBox(width: 50),
                      IconButton(
                        icon: Image.asset('assets/fast-forward.png', width: 40, height: 40, color: Colors.white),
                        onPressed: () => audioHandler.skipToNext(),
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