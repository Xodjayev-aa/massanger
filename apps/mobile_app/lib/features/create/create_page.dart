import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../app/brand.dart';
import '../../app/di.dart';
import '../../app/router.dart';
import '../../core/errors.dart';
import '../../core/mp4.dart';
import '../../data/feed_repository.dart';
import '../../data/social_models.dart';
import '../../data/social_repository.dart';
import '../../data/video_repository.dart';
import '../../data/voice_over.dart';

/// The composer: one screen that publishes either a long-form video or a reel,
/// because the only difference is which cap applies and which RPC runs at the
/// end.
///
/// The upload path is the honest one — validate on-device, ask `video-ticket`
/// for a presigned PUT, push the bytes **straight to B2**, then let the server
/// re-read the object and tell us the real size and duration. Nothing the phone
/// declares ever reaches the database; if the bytes say something else, the
/// bytes win.
class CreatePage extends StatefulWidget {
  const CreatePage({super.key, this.initialKind = 'video', this.replyTo});

  /// `video` (long form) or `short` (a reel, optionally a duet/stitch reply).
  final String initialKind;
  final String? replyTo;

  @override
  State<CreatePage> createState() => _CreatePageState();
}

class _CreatePageState extends State<CreatePage> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _description = TextEditingController();
  final TextEditingController _tags = TextEditingController();
  final TextEditingController _voiceScript = TextEditingController();

  late String _kind = widget.initialKind == 'short' ? 'short' : 'video';
  XFile? _file;
  Uint8List? _bytes;
  Duration? _duration;
  XFile? _poster;
  Uint8List? _posterBytes;

  String _visibility = 'public';
  String? _category;
  List<VideoCategory> _categories = const <VideoCategory>[];
  bool _allowComments = true;
  bool _isMature = false;
  String _replyKind = 'original';

  /// The soundtrack attached to the publish: an existing sound or a voice-over
  /// minted a moment ago. Null means "original audio".
  String? _soundId;
  String? _soundLabel;

  double _progress = 0;
  String _stage = '';
  bool _busy = false;
  bool _b2Configured = true;
  Object? _error;

  /// The app uploads in one in-memory PUT, so this is the honest client cap
  /// even though the server accepts far more for a future chunked path.
  static const int _clientMaxBytes = 250 * 1024 * 1024;
  static const Duration _shortMax = Duration(seconds: 60);
  static const Duration _longMax = Duration(hours: 4);

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _tags.dispose();
    _voiceScript.dispose();
    super.dispose();
  }

  Future<void> _prepare() async {
    final configured = await sl<VideoRepository>().isConfigured();
    List<VideoCategory> categories = const <VideoCategory>[];
    try {
      categories = await sl<FeedRepository>().categories();
    } catch (_) {
      // A category is optional; the picker simply stays empty.
    }
    if (!mounted) return;
    setState(() {
      _b2Configured = configured;
      _categories = categories;
    });
  }

  Future<void> _pickVideo() async {
    try {
      final picked = await ImagePicker().pickVideo(source: ImageSource.gallery);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      final duration = readMp4Duration(bytes);
      if (duration == null || duration <= Duration.zero) {
        throw const AppException('storage', 'That file could not be read as an MP4 video.');
      }
      final cap = _kind == 'short' ? _shortMax : _longMax;
      if (duration > cap) {
        throw AppException(
          'storage',
          _kind == 'short'
              ? 'Reels stay under 60 seconds — switch to a long video to publish this one.'
              : 'Videos stay under 4 hours.',
        );
      }
      if (bytes.length > _clientMaxBytes) {
        throw const AppException('storage', 'The in-app uploader handles files up to 250 MB.');
      }
      if (!mounted) return;
      setState(() {
        _file = picked;
        _bytes = bytes;
        _duration = duration;
        _error = null;
        if (_title.text.isEmpty) {
          final name = picked.name.replaceAll(RegExp(r'\.(mp4|mov|m4v)$', caseSensitive: false), '');
          _title.text = name.replaceAll(RegExp(r'[_-]+'), ' ').trim();
        }
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _pickPoster() async {
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 88);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      if (bytes.length > 8 * 1024 * 1024) {
        throw const AppException('storage', 'Poster frames stay under 8 MB.');
      }
      if (!mounted) return;
      setState(() {
        _poster = picked;
        _posterBytes = bytes;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  /// The soundtrack choice: keep the original audio, reuse a sound somebody
  /// already published, or have the device speak a script you wrote.
  ///
  /// The voice-over is a `sounds` row (`origin = 'tts'`) that carries the script
  /// instead of bytes — that is the whole trick that keeps the feature free:
  /// there is no paid speech service in the loop, and any other device can
  /// re-render the same voice-over from the stored script.
  Future<void> _chooseSound() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.mic_rounded),
              title: const Text('Original audio'),
              subtitle: const Text('Whatever the clip already sounds like.'),
              onTap: () => Navigator.of(sheetContext).pop('original'),
            ),
            ListTile(
              leading: const Icon(Icons.library_music_rounded),
              title: const Text('Use an existing sound'),
              subtitle: const Text('Trending tracks and other people’s voice-overs.'),
              onTap: () => Navigator.of(sheetContext).pop('library'),
            ),
            ListTile(
              leading: const Icon(Icons.graphic_eq_rounded),
              title: const Text('AI voice-over'),
              subtitle: const Text('Type a script; this device speaks it, and the script travels with the post.'),
              onTap: () => Navigator.of(sheetContext).pop('tts'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'original':
        setState(() {
          _soundId = null;
          _soundLabel = null;
        });
      case 'library':
        await _pickExistingSound();
      case 'tts':
        await _designVoiceOver();
    }
  }

  Future<void> _pickExistingSound() async {
    List<SoundSummary> sounds;
    try {
      sounds = await sl<FeedRepository>().sounds(limit: 50);
    } catch (error) {
      if (mounted) setState(() => _error = error);
      return;
    }
    if (!mounted) return;
    final picked = await showModalBottomSheet<SoundSummary>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(sheetContext).size.height * 0.6,
          child: sounds.isEmpty
              ? const EmptyState(title: 'No sounds yet', message: 'Write a voice-over instead — it needs nothing.', icon: Icons.music_off_rounded)
              : ListView.builder(
                  itemCount: sounds.length,
                  itemBuilder: (context, index) {
                    final sound = sounds[index];
                    return ListTile(
                      leading: Icon(sound.isVoiceOver ? Icons.graphic_eq_rounded : Icons.music_note_rounded),
                      title: Text(sound.title),
                      subtitle: Text(
                        '${sound.artist ?? 'Unknown'} · ${compactCount(sound.useCount)} reels'
                        '${sound.isVoiceOver ? ' · AI voice-over' : ''}',
                      ),
                      onTap: () => Navigator.of(sheetContext).pop(sound),
                    );
                  },
                ),
        ),
      ),
    );
    if (picked == null) return;
    setState(() {
      _soundId = picked.id;
      _soundLabel = picked.isVoiceOver ? '${picked.title} (AI voice-over)' : picked.title;
    });
  }

  Future<void> _designVoiceOver() async {
    final created = await showModalBottomSheet<({String soundId, String label})>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => _VoiceOverSheet(initialScript: _voiceScript.text),
    );
    if (created == null || !mounted) return;
    setState(() {
      _soundId = created.soundId;
      _soundLabel = created.label;
    });
  }

  String get _imageMime {
    final name = (_poster?.name ?? '').toLowerCase();
    if (name.endsWith('.png')) return 'image/png';
    return 'image/jpeg';
  }

  Future<void> _publish() async {
    final bytes = _bytes;
    final duration = _duration;
    if (_busy) return;
    if (_kind == 'video' && _title.text.trim().isEmpty) {
      setState(() => _error = const AppException('bad_request', 'A video needs a title.'));
      return;
    }
    if (bytes == null || duration == null) {
      setState(() => _error = const AppException('bad_request', 'Pick a video first.'));
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _progress = 0.05;
      _stage = 'Preparing';
    });

    try {
      final videos = sl<VideoRepository>();
      final scope = _kind == 'short' ? VideoScope.short : VideoScope.video;

      // 1. The poster goes first: if it fails, nothing else has been paid for.
      String? posterKey;
      if (_posterBytes != null && _poster != null) {
        setState(() {
          _stage = 'Uploading cover';
          _progress = 0.12;
        });
        final ticket = await videos.requestUpload(
          scope: scope,
          sizeBytes: _posterBytes!.length,
          mime: _imageMime,
        );
        await VideoRepository.putBytes(url: ticket.url, bytes: _posterBytes!, contentType: ticket.contentType);
        final verified = await videos.confirm(scope: scope, key: ticket.key);
        posterKey = verified.key;
      }

      // 2. The video itself.
      setState(() {
        _stage = 'Uploading video';
        _progress = 0.25;
      });
      final ticket = await videos.requestUpload(
        scope: scope,
        sizeBytes: bytes.length,
        duration: duration,
      );
      await VideoRepository.putBytes(url: ticket.url, bytes: bytes, contentType: ticket.contentType);

      setState(() {
        _stage = 'Verifying';
        _progress = 0.8;
      });
      final verified = await videos.confirm(scope: scope, key: ticket.key);
      if (verified.isImage) {
        throw const AppException('storage', 'The uploaded file was not a video.');
      }

      setState(() {
        _stage = 'Publishing';
        _progress = 0.92;
      });
      final feed = sl<FeedRepository>();
      final tags = _tags.text
          .split(RegExp(r'[,\s#]+'))
          .map((tag) => tag.trim().toLowerCase())
          .where((tag) => tag.isNotEmpty)
          .take(12)
          .toList(growable: false);

      final id = _kind == 'short'
          ? await feed.publishShort(
              objectKey: verified.key,
              duration: verified.duration,
              sizeBytes: verified.sizeBytes,
              caption: _description.text.trim().isEmpty ? null : _description.text.trim(),
              visibility: _visibility,
              kind: _replyKind,
              replyToShort: _replyKind == 'original' ? null : widget.replyTo,
              thumbnailKey: posterKey,
              soundId: _soundId,
              allowComments: _allowComments,
            )
          : await feed.publishVideo(
              objectKey: verified.key,
              title: _title.text.trim(),
              description: _description.text.trim().isEmpty ? null : _description.text.trim(),
              thumbnailKey: posterKey,
              duration: verified.duration,
              sizeBytes: verified.sizeBytes,
              visibility: _visibility,
              category: _category,
              tags: tags,
              soundId: _soundId,
              allowComments: _allowComments,
              isMature: _isMature,
            );

      if (!mounted) return;
      setState(() {
        _progress = 1;
        _stage = 'Done';
      });
      // Straight into the result: publishing and then landing on a feed is how
      // a creator loses track of whether it worked.
      if (_kind == 'short') {
        context.go(Routes.reels);
      } else {
        context.go(Routes.watch(id));
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _busy = false;
        _progress = 0;
        _stage = '';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isShort = _kind == 'short';
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create'),
        actions: <Widget>[
          TextButton(
            onPressed: _busy ? null : _publish,
            child: Text(_busy ? 'Publishing…' : 'Publish'),
          ),
        ],
      ),
      body: !_b2Configured
          ? const EmptyState(
              title: 'Video hosting is not configured',
              message: 'Set the B2 secrets on the deployment (see docs/runbook) and uploads turn on for everyone.',
              icon: Icons.cloud_off_rounded,
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
              children: <Widget>[
                SegmentedButton<String>(
                  segments: const <ButtonSegment<String>>[
                    ButtonSegment<String>(value: 'video', label: Text('Video'), icon: Icon(Icons.smart_display_outlined)),
                    ButtonSegment<String>(value: 'short', label: Text('Reel'), icon: Icon(Icons.phone_iphone_rounded)),
                  ],
                  selected: <String>{_kind},
                  onSelectionChanged: _busy
                      ? null
                      : (selection) => setState(() {
                            _kind = selection.first;
                            final duration = _duration;
                            if (isShort && duration != null && duration > _shortMax) {
                              _error = const AppException('storage', 'That clip is longer than a reel — it stays a long video.');
                            } else {
                              _error = null;
                            }
                          }),
                ),
                const SizedBox(height: 16),
                _PickerCard(
                  title: isShort ? 'Your reel' : 'Your video',
                  subtitle: _file == null
                      ? 'MP4 · ${isShort ? 'up to 60 seconds' : 'up to 4 hours'}'
                      : '${_file!.name} · ${clockDuration(_duration ?? Duration.zero)} · ${(_bytes!.length / 1048576).toStringAsFixed(1)} MB',
                  icon: isShort ? Icons.videocam_rounded : Icons.movie_rounded,
                  onTap: _busy ? null : _pickVideo,
                ),
                const SizedBox(height: 10),
                _PickerCard(
                  title: 'Cover frame',
                  subtitle: _poster == null
                      ? 'Optional — a JPEG or PNG poster shown in the feed'
                      : '${_poster!.name} · ${((_posterBytes?.length ?? 0) / 1024).toStringAsFixed(0)} KB',
                  icon: Icons.image_outlined,
                  onTap: _busy ? null : _pickPoster,
                ),
                const SizedBox(height: 10),
                _PickerCard(
                  title: 'Soundtrack',
                  subtitle: _soundLabel ?? 'Original audio — your own recording',
                  icon: Icons.music_note_rounded,
                  onTap: _busy ? null : _chooseSound,
                ),
                if (!isShort) ...<Widget>[
                  const SizedBox(height: 18),
                  TextField(
                    controller: _title,
                    enabled: !_busy,
                    maxLength: 120,
                    decoration: const InputDecoration(
                      labelText: 'Title',
                      hintText: 'What is this video about?',
                      counterText: '',
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: _description,
                  enabled: !_busy,
                  minLines: isShort ? 2 : 3,
                  maxLines: 6,
                  maxLength: isShort ? 500 : 5000,
                  decoration: InputDecoration(
                    labelText: isShort ? 'Caption' : 'Description',
                    hintText: isShort ? 'Say something about this reel' : 'Chapters, links, credits…',
                    counterText: '',
                  ),
                ),
                if (isShort && widget.replyTo != null) ...<Widget>[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: _replyKind,
                    decoration: const InputDecoration(labelText: 'Reply style'),
                    items: const <DropdownMenuItem<String>>[
                      DropdownMenuItem<String>(value: 'original', child: Text('Original')),
                      DropdownMenuItem<String>(value: 'duet', child: Text('Duet')),
                      DropdownMenuItem<String>(value: 'stitch', child: Text('Stitch')),
                    ],
                    onChanged: _busy ? null : (value) => setState(() => _replyKind = value ?? 'original'),
                  ),
                ],
                if (!isShort && _categories.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: _category,
                    decoration: const InputDecoration(labelText: 'Category'),
                    items: <DropdownMenuItem<String>>[
                      const DropdownMenuItem<String>(value: null, child: Text('No category')),
                      for (final category in _categories)
                        DropdownMenuItem<String>(
                          value: category.slug,
                          child: Text('${category.emoji ?? '🎬'}  ${category.label}'),
                        ),
                    ],
                    onChanged: _busy ? null : (value) => setState(() => _category = value),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _tags,
                    enabled: !_busy,
                    decoration: const InputDecoration(
                      labelText: 'Hashtags',
                      hintText: 'music, tutorial, behind the scenes',
                      helperText: 'Separated by spaces or commas — up to 12',
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Who can watch'),
                  subtitle: Text(
                    switch (_visibility) {
                      'followers' => 'Followers only',
                      'unlisted' => 'Anyone with the link',
                      'private' => 'Only you',
                      _ => 'Everyone',
                    },
                    style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                  ),
                  trailing: DropdownButton<String>(
                    value: _visibility,
                    underline: const SizedBox.shrink(),
                    onChanged: _busy ? null : (value) => setState(() => _visibility = value ?? 'public'),
                    items: const <DropdownMenuItem<String>>[
                      DropdownMenuItem<String>(value: 'public', child: Text('Everyone')),
                      DropdownMenuItem<String>(value: 'followers', child: Text('Followers')),
                      DropdownMenuItem<String>(value: 'unlisted', child: Text('Unlisted')),
                      DropdownMenuItem<String>(value: 'private', child: Text('Only me')),
                    ],
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _allowComments,
                  onChanged: _busy ? null : (value) => setState(() => _allowComments = value),
                  title: const Text('Allow comments'),
                ),
                if (!isShort)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _isMature,
                    onChanged: _busy ? null : (value) => setState(() => _isMature = value),
                    title: const Text('Age-restricted'),
                    subtitle: const Text('Hidden from accounts under 18 and from the For You feed.'),
                  ),
                if (_busy) ...<Widget>[
                  const SizedBox(height: 18),
                  LinearProgressIndicator(value: _progress == 0 ? null : _progress),
                  const SizedBox(height: 8),
                  Text(
                    '$_stage — ${(_progress * 100).round()}%',
                    style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                  ),
                ],
                if (_error != null) ...<Widget>[
                  const SizedBox(height: 16),
                  InlineFailure(error: _error!),
                ],
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _busy ? null : _publish,
                  icon: const Icon(Icons.cloud_upload_rounded),
                  label: Text(isShort ? 'Publish reel' : 'Publish video'),
                ),
                const SizedBox(height: 10),
                Text(
                  'Uploads go straight from this device to object storage with a short-lived signed URL. '
                  'The server re-reads every file before it is published, so the size and duration in the feed are the real ones.',
                  style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant, height: 1.4),
                ),
              ],
            ),
    );
  }
}

class _PickerCard extends StatelessWidget {
  const _PickerCard({required this.title, required this.subtitle, required this.icon, this.onTap});

  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: scheme.outlineVariant.withOpacity(0.7)),
        ),
        child: Row(
          children: <Widget>[
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(color: scheme.primary.withOpacity(0.1), borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, color: scheme.primary),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded),
          ],
        ),
      ),
    );
  }
}

/// One failure line, shared by every screen that can fail without a list.
class InlineFailure extends StatelessWidget {
  const InlineFailure({super.key, required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final message = error is AppException ? (error as AppException).message : 'Something went wrong.';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.error_outline_rounded, color: scheme.onErrorContainer, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: TextStyle(fontSize: 13, color: scheme.onErrorContainer)),
          ),
        ],
      ),
    );
  }
}

/// The voice-over studio, in a sheet.
///
/// Three things happen here and nothing else: pick a device voice, listen to the
/// script, then store it as a sound.
///
/// The sound always carries the **script**, which is what makes the feature
/// free and portable: any device can re-render the same words with its own
/// speech engine, and no paid TTS service is anywhere in the loop. When the
/// device can also write an audio file (Android and iOS can; the web build
/// cannot), the rendered bytes are uploaded through the `sound` scope of
/// `video-ticket` so the reel has real audio too — every player can then play
/// it without a speech engine. When it cannot, the row keeps the script and the
/// UI says so instead of pretending.
class _VoiceOverSheet extends StatefulWidget {
  const _VoiceOverSheet({required this.initialScript});

  final String initialScript;

  @override
  State<_VoiceOverSheet> createState() => _VoiceOverSheetState();
}

class _VoiceOverSheetState extends State<_VoiceOverSheet> {
  late final TextEditingController _script = TextEditingController(text: widget.initialScript);
  final TextEditingController _title = TextEditingController();

  List<VoiceOption> _voices = const <VoiceOption>[];
  VoiceOption? _voice;
  bool _loadingVoices = true;
  bool _speaking = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadVoices());
  }

  @override
  void dispose() {
    _script.dispose();
    _title.dispose();
    unawaited(sl<VoiceOverService>().stop());
    super.dispose();
  }

  Future<void> _loadVoices() async {
    final voices = await sl<VoiceOverService>().voices();
    if (!mounted) return;
    setState(() {
      _voices = voices;
      _voice = voices.isEmpty ? null : voices.first;
      _loadingVoices = false;
    });
  }

  Future<void> _preview() async {
    final script = _script.text.trim();
    if (script.isEmpty) {
      setState(() => _error = 'Write what the voice should say first.');
      return;
    }
    setState(() {
      _speaking = true;
      _error = null;
    });
    try {
      final voice = _voice;
      if (voice != null) await sl<VoiceOverService>().select(voice);
      await sl<VoiceOverService>().speak(script);
    } catch (error) {
      if (mounted) setState(() => _error = error is AppException ? error.message : 'The preview failed on this device.');
    } finally {
      if (mounted) setState(() => _speaking = false);
    }
  }

  Future<void> _save() async {
    final script = _script.text.trim();
    if (script.isEmpty) {
      setState(() => _error = 'A voice-over needs a script.');
      return;
    }
    final uid = sl<SocialRepository>().currentUserId;
    if (uid == null) {
      setState(() => _error = 'Sign in again — your account could not be read.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    // The stored duration is an estimate of the spoken length, because the
    // server has no audio to measure: ~2.6 words a second, which is ordinary
    // narration pace. It is a hint for the UI, never a claim about bytes.
    final words = script.split(RegExp(r'\s+')).where((word) => word.isNotEmpty).length;
    final seconds = (words / 2.6).clamp(3, 600).toDouble();
    final duration = Duration(milliseconds: (seconds * 1000).round());
    final title = _title.text.trim().isEmpty ? 'AI voice-over' : _title.text.trim();

    try {
      // 1. Render the audio on this device, when it can. A failure here is not
      //    a failure of the feature: the script is the portable half.
      var objectKey = 'sounds/$uid/tts/${const Uuid().v4()}.mp3';
      var sizeBytes = (seconds * 16000).round().clamp(4096, 50 * 1024 * 1024);
      var mime = 'audio/mpeg';
      if (sl<VoiceOverService>().canSynthesize) {
        final uploaded = await _renderToSound(
          script: script,
          duration: duration,
          fallbackBytes: sizeBytes,
        );
        if (uploaded != null) {
          objectKey = uploaded.key;
          sizeBytes = uploaded.sizeBytes;
          mime = uploaded.mime;
        }
      }

      final soundId = await sl<FeedRepository>().createSound(
        title: title,
        duration: duration,
        sizeBytes: sizeBytes,
        objectKey: objectKey,
        mime: mime,
        origin: 'tts',
        voiceScript: script,
        voiceName: _voice?.name,
        voiceLocale: _voice?.locale,
      );
      if (!mounted) return;
      Navigator.of(context).pop((soundId: soundId, label: '$title (AI voice-over)'));
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error is AppException ? error.message : 'The voice-over could not be saved.';
        });
      }
    }
  }

  /// Speaks the script into a file and uploads it as a sound.
  ///
  /// Returns null — never an exception — when this device cannot produce a
  /// container the sounds table accepts, because that is a normal outcome (the
  /// web build, and iOS writing `.caf`): the caller keeps the script-only row.
  Future<({String key, int sizeBytes, String mime})?> _renderToSound({
    required String script,
    required Duration duration,
    required int fallbackBytes,
  }) async {
    try {
      final voice = _voice;
      if (voice != null) await sl<VoiceOverService>().select(voice);
      final path = await sl<VoiceOverService>().synthesizeToFile(script, name: 'voice-over');
      if (path == null) return null;
      final mime = _audioMimeFor(path);
      if (mime == null) return null;

      // XFile reads a path on every platform the app ships on, and it keeps
      // `dart:io` out of this file so the web build still compiles.
      final bytes = await XFile(path).readAsBytes();
      if (bytes.isEmpty) return null;

      final tickets = sl<VideoRepository>();
      final ticket = await tickets.requestUpload(
        scope: VideoScope.sound,
        sizeBytes: bytes.length,
        duration: duration,
        mime: mime,
      );
      await VideoRepository.putBytes(url: ticket.url, bytes: bytes, contentType: ticket.contentType);
      final verified = await tickets.confirm(scope: VideoScope.sound, key: ticket.key);
      return (
        key: verified.key,
        sizeBytes: verified.sizeBytes > 0 ? verified.sizeBytes : fallbackBytes,
        mime: mime,
      );
    } catch (_) {
      // The row still works: it carries the script.
      return null;
    }
  }

  /// The three containers `video-ticket` and `public.sounds` both accept.
  /// Anything else (notably iOS's `.caf`) means "keep the script, skip the
  /// bytes" rather than an upload that would be rejected server-side.
  static String? _audioMimeFor(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.wav')) return 'audio/wav';
    if (lower.endsWith('.ogg') || lower.endsWith('.opus')) return 'audio/ogg';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('AI voice-over', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'This device speaks the script — no paid service, no upload of your voice. The script is stored with the post '
            'so anybody can re-render the same voice-over, and your clip keeps its own audio as a fallback.',
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant, height: 1.4),
          ),
          const SizedBox(height: 6),
          Text(
            sl<VoiceOverService>().canSynthesize
                ? 'This device also renders the audio itself, so the reel plays with a real voice track everywhere.'
                : 'This device cannot write an audio file, so the reel carries the script and every phone re-renders it.',
            style: TextStyle(
              fontSize: 12,
              color: scheme.primary,
              height: 1.4,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _script,
            minLines: 3,
            maxLines: 6,
            maxLength: 600,
            decoration: const InputDecoration(
              labelText: 'Script',
              hintText: 'Three things nobody tells you about…',
              counterText: '',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          if (_loadingVoices)
            const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator()))
          else if (_voices.isEmpty)
            Text(
              'This device did not offer any voices, so the preview is unavailable here — the script still saves and '
              'plays on a phone that has an engine.',
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant, height: 1.4),
            )
          else
            DropdownButtonFormField<VoiceOption>(
              value: _voice,
              decoration: const InputDecoration(labelText: 'Voice'),
              items: <DropdownMenuItem<VoiceOption>>[
                for (final voice in _voices.take(40))
                  DropdownMenuItem<VoiceOption>(value: voice, child: Text(voice.display, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: _saving ? null : (value) => setState(() => _voice = value),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _title,
            maxLength: 60,
            decoration: const InputDecoration(labelText: 'Sound title', hintText: 'AI voice-over', counterText: ''),
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 12),
            InlineFailure(error: AppException('tts', _error!)),
          ],
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _speaking || _saving ? null : _preview,
                  icon: Icon(_speaking ? Icons.volume_up_rounded : Icons.play_arrow_rounded, size: 18),
                  label: Text(_speaking ? 'Speaking…' : 'Preview'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? 'Saving…' : 'Use this voice-over'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
