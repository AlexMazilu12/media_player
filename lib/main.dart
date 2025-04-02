import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:path/path.dart' as path;
import 'dart:async';

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
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
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
      
      final metadata = await _extractMetadata(filePath);
      
      final newMediaItem = MediaItem(
        id: filePath,
        title: metadata['title'] ?? title ?? _getFileNameWithoutExtension(filePath),
        artist: metadata['artist'] ?? artist ?? 'Unknown Artist',
        album: metadata['album'] ?? 'Music Player',
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
        controls: [
          MediaControl.skipToPrevious,
          MediaControl.pause,
          MediaControl.skipToNext,
        ],
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

  Future<void> addMultipleFiles(List<String> filePaths) async {
    try {
      playbackState.add(playbackState.value.copyWith(
        processingState: AudioProcessingState.loading,
        playing: false,
      ));
      
      await _playlist.clear();
      final newQueue = <MediaItem>[];
      
      for (final filePath in filePaths) {
        final duration = await _getDuration(filePath);
        final metadata = await _extractMetadata(filePath);
        
        final newMediaItem = MediaItem(
          id: filePath,
          title: metadata['title'] ?? _getFileNameWithoutExtension(filePath),
          artist: metadata['artist'] ?? 'Unknown Artist',
          album: metadata['album'] ?? 'Music Player',
          playable: true,
          displayTitle: metadata['title'] ?? _getFileNameWithoutExtension(filePath),
          displaySubtitle: metadata['artist'] ?? 'Unknown Artist',
          duration: duration,
        );
        
        newQueue.add(newMediaItem);
        
        await _playlist.add(
          AudioSource.uri(
            Uri.parse('file://$filePath'),
            tag: newMediaItem,
          ),
        );
      }
      
      queue.add(newQueue);
      
      if (newQueue.isNotEmpty) {
        mediaItem.add(newQueue[0]);
      }
      
      playbackState.add(playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        processingState: AudioProcessingState.ready,
        playing: false,
      ));
    } catch (e) {
      print('Error adding multiple files: $e');
    }
  }

  @override
  Future<void> skipToNext() async {
    if (_player.hasNext) {
      await _player.seekToNext();
    }
  }
  
  @override
  Future<void> skipToPrevious() async {
    if (_player.hasPrevious) {
      await _player.seekToPrevious();
    }
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= _playlist.length) return;
    await _player.seek(Duration.zero, index: index);
  }

  String _getFileNameWithoutExtension(String filePath) {
    final fileName = path.basename(filePath);
    return path.basenameWithoutExtension(fileName);
  }

  Future<Map<String, dynamic>> _extractMetadata(String filePath) async {
    try {
      final tempPlayer = AudioPlayer();
      await tempPlayer.setFilePath(filePath);
      
      final fileName = path.basename(filePath);
      final fileNameWithoutExt = path.basenameWithoutExtension(filePath);
      
      String title = fileNameWithoutExt;
      String artist = 'Unknown Artist';
      
      if (fileNameWithoutExt.contains(' - ')) {
        final parts = fileNameWithoutExt.split(' - ');
        if (parts.length >= 2) {
          artist = parts[0].trim();
          title = parts.sublist(1).join(' - ').trim();
        }
      }
      
      if (tempPlayer.icyMetadata?.info?.title != null) {
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
      };
      
      await tempPlayer.dispose();
      return result;
    } catch (e) {
      print('Error extracting basic metadata: $e');
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
  Timer? _positionTimer;
  List<MediaItem> _playlist = [];
  bool _showPlaylist = false;

  AudioPlayer get _player => audioHandler._player;

  @override
  void initState() {
    super.initState();
    _setupAudioHandlerListeners();
    _startPositionTimer();
  }

  @override
  void dispose() {
    _positionTimer?.cancel();
    super.dispose();
  }

  void _startPositionTimer() {
  _positionTimer?.cancel();
  
  _positionTimer = Timer.periodic(Duration(milliseconds: 50), (timer) {
    if (_isPlaying) {
      var position = audioHandler._player.position;
      
      if (_duration > Duration.zero && position > _duration) {
        position = _duration;
      }
      
      if (position != _position) {
        setState(() {
          _position = position;
          });
        }
      }
    });
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
    
    audioHandler.queue.listen((items) {
      setState(() {
        _playlist = items;
      });
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

  Future<void> _pickMultipleFiles() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      allowMultiple: true,
    );

    if (result != null && result.files.isNotEmpty) {
      List<String> filePaths = result.files
          .where((file) => file.path != null)
          .map((file) => file.path!)
          .toList();
          
      if (filePaths.isNotEmpty) {
        await audioHandler.addMultipleFiles(filePaths);
      }
    }
  }

  Future<void> _togglePlayPause() async {
    if (_isPlaying) {
      await audioHandler.pause();
    } else {
      await audioHandler.play();
    }
  }
  
  void _skipToNext() async {
    await audioHandler.skipToNext();
  }
  
  void _skipToPrevious() async {
    await audioHandler.skipToPrevious();
  }
  
  void _togglePlaylistView() {
    setState(() {
      _showPlaylist = !_showPlaylist;
    });
  }
  
  void _playTrack(int index) async {
    await audioHandler.skipToQueueItem(index);
    await audioHandler.play();
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  Widget _buildPlayerView() {
    return Column(
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
            child: _playlist.isEmpty 
                ? IconButton(
                    icon: Image.asset('assets/upload.png', width: 60, height: 60, color: Colors.white),
                    onPressed: _pickMultipleFiles,
                  )
                : Icon(Icons.music_note, size: 100, color: Colors.white.withOpacity(0.7)),
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatDuration(_position),
                style: TextStyle(color: Colors.white),
              ),
              Text(
                _formatDuration(_duration),
                style: TextStyle(color: Colors.white),
              ),
            ],
          ),
        ),
        SizedBox(height: 8),
        SizedBox(
          width: 300,
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 4,
              thumbShape: RoundSliderThumbShape(enabledThumbRadius: 8),
              overlayShape: RoundSliderOverlayShape(overlayRadius: 16),
            ),
            child: Slider(
              value: _duration.inMilliseconds > 0 
                ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
                : 0.0,
              onChanged: (value) {
                final newPosition = Duration(
                  milliseconds: (value * _duration.inMilliseconds).round(),
                );
                audioHandler.seek(newPosition);
              },
              activeColor: Colors.white,
              inactiveColor: Colors.white24,
            ),
          ),
        ),
      ],
    );
  }
  
  Widget _buildPlaylistView() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text(
            'Playlist (${_playlist.length} songs)',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        Expanded(
          child: _playlist.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.playlist_add, color: Colors.white.withOpacity(0.7), size: 80),
                      SizedBox(height: 16),
                      Text(
                        'Your playlist is empty',
                        style: TextStyle(color: Colors.white, fontSize: 16),
                      ),
                      SizedBox(height: 20),
                      ElevatedButton.icon(
                        icon: Icon(Icons.add),
                        label: Text('Add Songs'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Color(0xFF743AC0),
                          foregroundColor: Colors.white,
                          padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        ),
                        onPressed: _pickMultipleFiles,
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: _playlist.length,
                  itemBuilder: (context, index) {
                    final item = _playlist[index];
                    final isCurrentTrack = index == _player.currentIndex;
                    
                    return ListTile(
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: isCurrentTrack ? Color(0xFF743AC0) : Colors.white.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Center(
                          child: Icon(
                            isCurrentTrack && _isPlaying ? Icons.pause : Icons.music_note,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      title: Text(
                        item.title,
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: isCurrentTrack ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                      subtitle: Text(
                        item.artist ?? 'Unknown Artist',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.7),
                        ),
                      ),
                      trailing: Text(
                        _formatDuration(item.duration ?? Duration.zero),
                        style: TextStyle(color: Colors.white.withOpacity(0.7)),
                      ),
                      onTap: () => _playTrack(index),
                    );
                  },
                ),
        ),
      ],
    );
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
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      icon: Icon(Icons.playlist_play, color: Colors.white, size: 32),
                      onPressed: _togglePlaylistView,
                    ),
                  ],
                ),
              ),

              Expanded(
                child: _showPlaylist
                    ? _buildPlaylistView()
                    : _buildPlayerView(),
              ),
              

              Container(
                child: Transform.translate(
                  offset: Offset(0, -80),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        icon: Image.asset(
                          'assets/previous.png',
                          width: 35,
                          height: 35,
                          color: Colors.white,
                        ),
                        onPressed: _skipToPrevious,
                      ),
                      SizedBox(width: 40),
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
                      SizedBox(width: 40),
                      IconButton(
                        icon: Image.asset(
                          'assets/fast-forward.png',
                          width: 35,
                          height: 35,
                          color: Colors.white,
                        ),
                        onPressed: _skipToNext,
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