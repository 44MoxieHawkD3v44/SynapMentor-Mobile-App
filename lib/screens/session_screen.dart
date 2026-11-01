import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show Helper;
import 'package:livekit_client/livekit_client.dart' hide ChatMessage;
import 'package:wakelock_plus/wakelock_plus.dart';

import '../api/api_client.dart';
import '../core/theme.dart';
import '../core/time_format.dart';
import '../services/auth_service.dart';
import '../services/explore_service.dart';
import '../services/screen_protection.dart';
import '../services/session_service.dart';
import '../widgets/auth_scaffold.dart';
import '../widgets/animated_logo.dart';
import '../widgets/chat_extras.dart';
import '../widgets/glass.dart';
import '../widgets/glass_controls.dart';
import '../widgets/true_colors.dart';
import 'booking_sheet.dart';
import 'bookings_tab.dart';
import 'top_up_prompt.dart';

enum _Stage { verify, consent, lobby, room, ended }

/// One screen for the whole session: a one-time face check, the lobby
/// countdown, then the meeting room (Meet) or chat interface (Chat). Leaving
/// and rejoining is always allowed; the session runs until its end time.
class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key, required this.user, required this.booking});

  final AppUser user;
  final Booking booking;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  final _sessions = SessionService.instance;
  bool _verifying = false;

  // Your microphone, camera and screen share. Before the meeting connects
  // these are what you've chosen (applied on connecting); once connected
  // they're read back from the call after every change, so the buttons always
  // show what's really on.
  bool _micOn = true;
  bool _videoOn = true;
  bool _sharing = false;

  /// A mic, camera or share change being applied, so taps don't overlap.
  bool _mediaBusy = false;

  /// Why the last mic, camera or share change didn't work, briefly.
  String? _mediaError;

  // Live sessions: the pre-session face scan and the LiveKit meeting.
  CameraController? _faceCamera;
  String? _faceError;
  Room? _room;
  EventsListener<RoomEvent>? _roomEvents;
  bool _connecting = false;
  String? _meetError;

  bool get _live => _sessions.isRemote(_b);

  @override
  void initState() {
    super.initState();
    _sessions.enter(_b);
    // The admin's session settings, such as when extensions open.
    ExploreService.instance.loadBookingConfig();
    // The other person's profile picture, for when their camera is off.
    _sessions.loadPeerPhoto(_b);
    if (_live && _needsFace) _openFaceCamera();
    // The phone stays awake for the whole session.
    WakelockPlus.enable().catchError((Object _) {});
    _lifecycle = AppLifecycleListener(onResume: _refreshMeetingService);
    // The session clock ticks in the background too.
    _sessions.addListener(_endWhenTimeIsUp);
  }

  /// Follows the app going to the background and coming back.
  AppLifecycleListener? _lifecycle;

  /// The call was closed because the session's time is up.
  bool _ended = false;

  /// When the session's time is up the meeting ends at once, also with the
  /// app in the background: the call is closed, the background service and
  /// any screen share stop, and the phone may sleep again. The review form
  /// comes next.
  void _endWhenTimeIsUp() {
    if (_ended || _sessions.phaseOf(_b) != SessionPhase.completed) return;
    _ended = true;
    // A deliberate end, not a dropped connection to rejoin.
    _leaving = true;
    WakelockPlus.disable().catchError((Object _) {});
    _stopMeetingService();
    _closeShareView();
    final podcastRoute = _podcastRoute;
    if (podcastRoute != null && podcastRoute.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (podcastRoute.isActive) podcastRoute.navigator?.removeRoute(podcastRoute);
      });
    }
    final room = _room;
    _detachRoom();
    _room = null;
    room?.disconnect();
    _faceCamera?.dispose();
    _faceCamera = null;
    ScreenProtection.instance.allowCapture(false);
    if (mounted) setState(() => _sharing = false);
  }

  @override
  void dispose() {
    _sessions.removeListener(_endWhenTimeIsUp);
    WakelockPlus.disable().catchError((Object _) {});
    _lifecycle?.dispose();
    _shareWait?.cancel();
    _leaving = true;
    _stopMeetingService();
    ScreenProtection.instance.allowCapture(false);
    _closeShareView();
    _detachRoom();
    _room?.disconnect();
    _faceCamera?.dispose();
    _sessions.leave(_b);
    super.dispose();
  }

  bool get _needsFace =>
      _sessions.faceRequired(_b, asSolver: _asSolver) && !_sessions.faceDone(_b, asSolver: _asSolver);

  Future<void> _openFaceCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return;
      final front = cameras.where((c) => c.lensDirection == CameraLensDirection.front).firstOrNull ?? cameras.first;
      final camera = CameraController(
        front,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await camera.initialize();
      if (!mounted) return await camera.dispose();
      setState(() => _faceCamera = camera);
    } on CameraException {
      if (mounted) {
        setState(() => _faceError = 'Camera access is needed to verify your face. Allow it in your phone\'s settings.');
      }
    }
  }

  /// Set once the user leaves, so a closing connection isn't reopened.
  bool _leaving = false;

  /// A dropped connection (e.g. the network changed while the app was in the
  /// background) is joined again, unless the meeting was left, ended, or
  /// taken over by another device.
  void _onDisconnected(Room room, DisconnectReason? reason) {
    if (_leaving || !mounted || !identical(room, _room)) return;
    const ended = {
      DisconnectReason.clientInitiated,
      DisconnectReason.duplicateIdentity,
      DisconnectReason.participantRemoved,
      DisconnectReason.roomDeleted,
    };
    _detachRoom();
    _sharing = false;
    ScreenProtection.instance.allowCapture(false);
    setState(() => _room = null);
    if (ended.contains(reason)) {
      _stopMeetingService();
      setState(() => _meetError = 'You left the meeting from another device or it was closed.');
      return;
    }
    // Straight away, even while another app is open (the screen isn't
    // redrawn then, so it can't wait for the meeting view).
    _connectMeeting();
  }

  /// Joins the LiveKit room and turns on the camera and microphone.
  Future<void> _connectMeeting() async {
    if (_connecting || _room != null) return;
    setState(() {
      _connecting = true;
      _meetError = null;
    });
    try {
      final m = await _sessions.joinMeeting(_b);
      final room = Room(
        roomOptions: const RoomOptions(
          adaptiveStream: true,
          dynacast: true,
          // iOS shares the screen through the ScreenShare broadcast extension
          // (ignored on Android).
          defaultScreenShareCaptureOptions: ScreenShareCaptureOptions(useiOSBroadcastExtension: true),
        ),
      );
      _roomEvents = room.createListener()
        ..on<DataReceivedEvent>((e) => _sessions.receiveBoardData(_b, e.data, e.topic))
        ..on<RoomDisconnectedEvent>((e) => _onDisconnected(room, e.reason))
        ..on<TrackSubscribedEvent>((e) => _keepVideoFlowing(e.publication))
        ..on<TrackStreamStateUpdatedEvent>((e) {
          if (e.streamState == StreamState.active) _flowing.add(e.publication.sid);
        })
        ..on<TrackPublishedEvent>((e) => _ensureSubscribed(e.publication))
        ..on<TrackSubscriptionExceptionEvent>((e) {
          final pub = e.participant?.trackPublications[e.sid];
          if (pub != null) _ensureSubscribed(pub);
        })
        ..listen((_) => _onRoomEvent());
      await room.connect('${m['livekit_url']}', '${m['token']}');
      _room = room;
      _sessions.attachRoom(_b, room);
      // A new connection never starts out sharing the screen.
      _sharing = false;
      final me = room.localParticipant;
      await me?.setCameraEnabled(_videoOn).catchError((Object _) => null);
      await me?.setMicrophoneEnabled(_micOn).catchError((Object _) => null);
      _syncLocalMedia();
      // Keeps the call going if another app is opened. Started after the
      // microphone and camera, so their permissions are in place for it.
      _refreshMeetingService();
    } on AuthException catch (e) {
      _meetError = e.message;
    } catch (_) {
      _meetError = 'Couldn\'t connect to the meeting. Check your connection and try again.';
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  /// People in the room besides you. Recording, transcription and other bots
  /// are left out.
  List<RemoteParticipant> get _people => [
    for (final p in _room?.remoteParticipants.values ?? const <RemoteParticipant>[])
      if (p.kind == ParticipantKind.STANDARD) p,
  ];

  /// Videos the server has reported as arriving, by publication sid.
  final _flowing = <String>{};

  /// A camera or screen being shown. One that's turned off isn't, so its
  /// last frame doesn't stay frozen on screen: a camera counts as off when
  /// it's muted, or when it was arriving and the server reports it stopped
  /// (paused), e.g. the other app paused its camera without signalling it.
  /// A video that's still starting up is shown.
  VideoTrack? _videoOf(RemoteParticipant p, {required bool screen}) => p.videoTrackPublications
      .where(
        (t) =>
            t.subscribed &&
            t.track != null &&
            !t.muted &&
            t.isScreenShare == screen &&
            (screen || !(_flowing.contains(t.sid) && t.streamState == StreamState.paused)),
      )
      .firstOrNull
      ?.track;

  /// The other person: the one with their camera on, else whoever is here
  /// (a second connection of theirs, e.g. another browser tab, may be too).
  RemoteParticipant? get _peer {
    final people = _people;
    return people.where((p) => _videoOf(p, screen: false) != null).firstOrNull ?? people.firstOrNull;
  }

  /// The other person's camera (not a screen they share).
  VideoTrack? get _remoteVideo {
    final peer = _peer;
    return peer == null ? null : _videoOf(peer, screen: false);
  }

  /// The screen being shared, from whichever of the other person's
  /// connections shares it (the web shares from the same one).
  VideoTrack? get _remoteScreen => _people.map((p) => _videoOf(p, screen: true)).nonNulls.firstOrNull;

  /// The full-screen view of a shared screen, while it's open.
  Route<void>? _shareRoute;

  /// The shared screen that last opened full screen by itself, so closing it
  /// doesn't reopen it.
  VideoTrack? _autoOpened;

  Future<void> _openShare(VideoTrack screen) async {
    if (_shareRoute != null) return;
    final route = MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _ScreenShareView(track: screen, name: _otherName),
    );
    _shareRoute = route;
    await Navigator.of(context).push(route);
    _shareRoute = null;
  }

  /// Opens a newly shared screen full screen, and closes the view when the
  /// sharing stops.
  void _followShare(VideoTrack? screen) {
    if (screen == null) {
      _autoOpened = null;
      _closeShareView();
      return;
    }
    if (identical(screen, _autoOpened)) return;
    _autoOpened = screen;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _openShare(screen);
    });
  }

  /// Stops listening to the meeting room (when leaving, or when its
  /// connection dropped).
  void _detachRoom() {
    _flowing.clear();
    _sessions.attachRoom(_b, null);
    _roomEvents?.dispose();
    _roomEvents = null;
  }

  /// Closes the full-screen view of a shared screen, if it's open.
  void _closeShareView() {
    final route = _shareRoute;
    if (route == null || !route.isActive) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (route.isActive) route.navigator?.removeRoute(route);
    });
  }

  /// Something changed in the call: someone joined, left, or turned their
  /// mic, camera or screen share on or off.
  void _onRoomEvent() {
    if (!mounted) return;
    final wasSharing = _sharing;
    // Your own media can change outside the app too, e.g. sharing stopped
    // from Android's notification.
    if (!_connecting && !_mediaBusy) _syncLocalMedia();
    if (wasSharing && !_sharing) {
      _refreshMeetingService();
      ScreenProtection.instance.allowCapture(false);
    }
    setState(() {});
  }

  /// With adaptive streaming the server pauses a video until a view of it
  /// is on screen, and that check runs the moment the video arrives, before
  /// the meeting can show it. A screen shared (or camera turned on) mid-call
  /// could then stay paused until rejoining. Asking for it explicitly keeps
  /// it coming; the picture size still follows the view.
  void _keepVideoFlowing(RemoteTrackPublication pub) {
    if (pub.kind == TrackType.VIDEO) pub.enable();
  }

  /// A video published mid-call is asked for again if it hasn't arrived
  /// after a few seconds (e.g. the connection was busy), up to three times.
  void _ensureSubscribed(RemoteTrackPublication pub, {int attempt = 0}) {
    if (pub.kind != TrackType.VIDEO || attempt >= 3) return;
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (!mounted || _room == null || pub.subscribed) return;
      // Still published by someone in the call?
      if (!_people.any((p) => p.trackPublications.containsKey(pub.sid))) return;
      pub.subscribe();
      _ensureSubscribed(pub, attempt: attempt + 1);
    });
  }

  /// A screen the other person started sharing whose picture hasn't
  /// arrived yet.
  bool get _screenComing =>
      _people.any((p) => p.videoTrackPublications.any((t) => t.isScreenShare && !t.muted && t.track == null));

  /// Reads back what's really on in the call.
  void _syncLocalMedia() {
    final me = _room?.localParticipant;
    if (me == null) return;
    _micOn = me.isMicrophoneEnabled();
    _videoOn = me.isCameraEnabled();
    _sharing = me.isScreenShareEnabled();
  }

  /// Your camera (not your shared screen), while it's on.
  VideoTrack? get _localVideo =>
      _room?.localParticipant?.videoTrackPublications.where((t) => !t.isScreenShare && !t.muted).firstOrNull?.track;

  Future<void> _toggleMic() => _changeMedia(
    'microphone',
    apply: (me, on) => me.setMicrophoneEnabled(on),
    on: !_micOn,
    choose: (on) => _micOn = on,
  );

  Future<void> _toggleVideo() =>
      _changeMedia('camera', apply: (me, on) => me.setCameraEnabled(on), on: !_videoOn, choose: (on) => _videoOn = on);

  /// Turns your [device] on or off. Before connecting it's just remembered;
  /// in the call it's applied, then the buttons show the result.
  Future<void> _changeMedia(
    String device, {
    required Future<Object?> Function(LocalParticipant me, bool on) apply,
    required bool on,
    required void Function(bool on) choose,
  }) async {
    if (_mediaBusy) return;
    final me = _room?.localParticipant;
    setState(() {
      choose(on);
      _mediaBusy = me != null;
      _mediaError = null;
    });
    if (me == null) return;
    try {
      await apply(me, on);
    } catch (_) {
      _mediaError = 'Couldn\'t turn ${on ? 'on' : 'off'} the $device. Check the app\'s permissions and try again.';
    } finally {
      _mediaBusy = false;
      _syncLocalMedia();
      // Turning it on may have just granted its permission: cover it.
      if (on) _refreshMeetingService();
      if (mounted) setState(() {});
    }
  }

  /// The Android foreground service that keeps the meeting running in the
  /// background (microphone and camera, and screen capture while sharing).
  /// Without it the call goes quiet, then drops, when another app is opened.
  static const _meetingService = MethodChannel('synapmentor/meeting');

  Future<void> _startMeetingService({bool screen = false}) async {
    if (Platform.isAndroid) await _meetingService.invokeMethod<bool>('start', {'screen': screen});
  }

  /// Starts the service, or updates it for what's on now (e.g. a permission
  /// just granted, or screen sharing stopped). Android only allows this while
  /// the app is on screen; otherwise it's done on coming back.
  void _refreshMeetingService() {
    if (_room == null || WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) return;
    _startMeetingService(screen: _sharing).catchError((Object _) => null);
  }

  Future<void> _stopMeetingService() async {
    if (!Platform.isAndroid) return;
    try {
      await _meetingService.invokeMethod<bool>('stop');
    } catch (_) {
      // Already stopped.
    }
  }

  /// Starts or stops sharing your screen. Only once you're in the call.
  Future<void> _toggleShare() async {
    final me = _room?.localParticipant;
    if (me == null || _mediaBusy) {
      if (me == null) setState(() => _mediaError = 'Screen sharing starts once you\'re connected to the meeting.');
      return;
    }
    final on = !_sharing;
    setState(() {
      _mediaBusy = true;
      _mediaError = null;
    });
    try {
      if (on && Platform.isAndroid) {
        // Permission first, then the service, then the capture.
        if (!await Helper.requestCapturePermission()) return;
        await _startMeetingService(screen: true);
      }
      // The app is kept out of screenshots and recordings; let your share
      // through first, so the other person sees it from the start.
      if (on) await ScreenProtection.instance.allowCapture(true);
      await me.setScreenShareEnabled(on, captureScreenAudio: false);
    } catch (_) {
      _mediaError = on
          ? 'Screen sharing couldn\'t start. Please try again.'
          : 'Screen sharing couldn\'t stop. Please try again.';
    } finally {
      _mediaBusy = false;
      _syncLocalMedia();
      if (on && Platform.isIOS && !_sharing && _mediaError == null) {
        // iOS: sharing starts once you confirm in the system's broadcast sheet.
        _awaitIosShare();
      } else {
        // Protected again unless the share is running.
        ScreenProtection.instance.allowCapture(_sharing);
      }
      // Back to just the camera and microphone when not sharing.
      if (!_sharing) _refreshMeetingService();
      if (mounted) setState(() {});
    }
  }

  /// iOS: waits for a share started from the system's broadcast sheet.
  Timer? _shareWait;

  /// Your share is let through while the sheet is open, so its first frames
  /// aren't covered; if it hasn't started after a while (the sheet was
  /// dismissed), the app is protected again. Once it starts it shows in the
  /// call like any share, and stopping it there, or from the phone's status
  /// bar, ends it the same way.
  void _awaitIosShare() {
    _shareWait?.cancel();
    _shareWait = Timer(const Duration(seconds: 30), () {
      if (!_sharing) ScreenProtection.instance.allowCapture(false);
    });
  }

  Booking get _b => widget.booking;

  /// The solver sees the same flow from their side.
  bool get _asSolver => widget.user.role == UserRole.solver;

  /// The other person's profile picture, when known.
  String? get _otherPhoto => _sessions.peerPhoto(_b);

  String get _otherName => _asSolver ? _b.seekerLabel : _b.solver.name;
  String get _otherInitials => _asSolver ? _b.seekerInitials : _b.solver.initials;

  _Stage get _stage {
    if (_sessions.phaseOf(_b) == SessionPhase.completed) return _Stage.ended;
    if (_needsFace) return _Stage.verify;
    if (_needsRecordingConsent) return _Stage.consent;
    if (!_sessions.hasStarted(_b)) return _Stage.lobby;
    return _Stage.room;
  }

  Future<void> _verify() async {
    setState(() {
      _verifying = true;
      _faceError = null;
    });
    try {
      List<String>? frames;
      final camera = _faceCamera;
      if (_live) {
        if (camera == null) throw const AuthException('The camera isn\'t ready yet.');
        // A few frames a moment apart for the server to match.
        frames = [];
        for (var i = 0; i < 5; i++) {
          frames.add((await camera.takePicture()).path);
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
      await _sessions.verifyFace(_b, asSolver: _asSolver, framePaths: frames);
      await _faceCamera?.dispose();
      _faceCamera = null;
    } on AuthException catch (e) {
      _faceError = e.message;
    } on CameraException {
      _faceError = 'Couldn\'t use the camera. Try again.';
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  Future<T?> _sheet<T>(Widget sheet) => showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (_) => sheet,
  );

  /// Leaving on purpose (the Leave buttons), also from a meeting.
  void _leave() {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
  }

  /// In a meeting the back button doesn't leave it: the app goes to the
  /// background, like the home button, and the call keeps running.
  bool get _inMeeting => _stage == _Stage.room && _b.mode != SessionMode.chat;

  void _toBackground() {
    if (Platform.isAndroid) _meetingService.invokeMethod<bool>('background').catchError((Object _) => null);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _sessions,
      builder: (context, child) => PopScope(
        canPop: !_inMeeting,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _toBackground();
        },
        child: child!,
      ),
      child: _buildScreen(),
    );
  }

  Widget _buildScreen() {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _sessions,
          builder: (context, _) {
            final stage = _stage;
            if (stage == _Stage.room) _sessions.markJoined(_b, asSolver: _asSolver);
            return StepSwitcher(
              child: KeyedSubtree(
                key: ValueKey(stage),
                child: switch (stage) {
                  _Stage.verify => _buildVerify(),
                  _Stage.consent => _buildConsent(),
                  _Stage.lobby => _buildLobby(),
                  _Stage.room => _b.mode == SessionMode.chat ? _buildChatRoom() : _buildMeetRoom(),
                  _Stage.ended => _buildEnded(),
                },
              ),
            );
          },
        ),
      ),
    );
  }

  // ---- Face verification -------------------------------------------------------

  Widget _buildVerify() {
    return _Page(
      onBack: _leave,
      title: 'Face Verification',
      subtitle: 'Verify your identity to join the session.',
      children: [
        Center(
          child: SizedBox.square(
            dimension: 210,
            child: CustomPaint(
              foregroundPainter: const _FrameCornersPainter(),
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: GlassWell(
                  radius: 90,
                  child: _faceCamera?.value.isInitialized == true
                      ? ClipOval(
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              FittedBox(
                                fit: BoxFit.cover,
                                child: SizedBox(
                                  width: _faceCamera!.value.previewSize?.height ?? 1,
                                  height: _faceCamera!.value.previewSize?.width ?? 1,
                                  child: TrueColors(child: CameraPreview(_faceCamera!)),
                                ),
                              ),
                              if (_verifying)
                                const Center(
                                  child: SizedBox.square(
                                    dimension: 48,
                                    child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
                                  ),
                                ),
                            ],
                          ),
                        )
                      : Center(
                          child: _verifying
                              ? const SizedBox.square(
                                  dimension: 48,
                                  child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
                                )
                              : Icon(Icons.face_retouching_natural_outlined, size: 84, color: AppColors.white(0.7)),
                        ),
                ),
              ),
            ),
          ),
        ),
        gap24,
        GlassWell(
          radius: 18,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            children: [
              for (final line in const [
                'Position your face in the frame',
                'Make sure you\'re in good lighting',
                'Look directly at the camera',
              ])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle_outline_rounded, size: 18, color: Colors.white),
                      const SizedBox(width: 10),
                      Expanded(child: Text(line, style: AppText.label.copyWith(fontSize: 13.5))),
                    ],
                  ),
                ),
            ],
          ),
        ),
        gap24,
        if (_faceError != null) ...[
          Text(
            _faceError!,
            style: AppText.caption.copyWith(color: Colors.white),
            textAlign: TextAlign.center,
          ),
          gap14,
        ],
        PrimaryPillButton(label: 'Start Verification', loading: _verifying, onPressed: _verify),
        gap14,
        Text(
          'Needed only when you first join this session, not each time you rejoin.',
          style: AppText.caption,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  // ---- Lobby ---------------------------------------------------------------------

  // ---- Recording consent (podcast solver) ---------------------------------------

  /// The solver agrees to a podcast's recording after the face check, before
  /// entering.
  bool get _needsRecordingConsent =>
      _asSolver && _b.type == BookingType.podcast && !_sessions.stateOf(_b).recordingConsented;

  bool _consentTicked = false;

  Widget _buildConsent() {
    return _Page(
      title: 'Recording consent',
      subtitle: 'This podcast session is recorded.',
      onBack: _leave,
      children: [
        const Center(child: GlassIconBadge(icon: Icons.fiber_manual_record_outlined, size: 72)),
        gap24,
        GlassWell(
          radius: 18,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'The whole session, video and audio, is recorded. Afterwards the recording is saved to your Content '
                'drafts, where you can publish or delete it.',
                style: AppText.body,
              ),
              gap14,
              GlassConsentRow(
                value: _consentTicked,
                onChanged: (v) => setState(() => _consentTicked = v),
                text: 'I understand and agree that this session will be recorded.',
              ),
            ],
          ),
        ),
        gap24,
        PrimaryPillButton(
          label: 'Continue',
          onPressed: _consentTicked ? () => setState(() => _sessions.stateOf(_b).recordingConsented = true) : null,
        ),
        gap14,
        GlassPillButton(label: 'Leave', onPressed: _leave),
      ],
    );
  }

  // ---- Podcast grid ----------------------------------------------------------------

  /// The full-screen view of the podcast grid, while it's open.
  Route<void>? _podcastRoute;

  Future<void> _openPodcastFullScreen() async {
    if (_podcastRoute != null) return;
    final route = MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _PodcastFullScreen(grid: () => _podcastGrid(fullScreen: true)),
    );
    _podcastRoute = route;
    await Navigator.of(context).push(route);
    _podcastRoute = null;
  }

  /// A podcast's two people side by side: the seeker on the left and the
  /// solver on the right, on both phones.
  Widget _podcastGrid({bool fullScreen = false}) {
    final remote = _remoteVideo;
    final otherHere = _people.isNotEmpty;
    final local = _videoOn ? _localVideo : null;
    final anonymousYou = !_asSolver && _b.type == BookingType.anonymous;
    final mine = _VideoTile(
      label: '${anonymousYou ? 'You (Anonymous)' : 'You'} · ${_asSolver ? 'Solver' : 'Seeker'}',
      initials: anonymousYou ? '?' : initialsOf(widget.user.name),
      videoOff: !_videoOn,
      muted: !_micOn,
      video: local == null
          ? null
          : VideoTrackRenderer(local, fit: VideoViewFit.cover, mirrorMode: VideoViewMirrorMode.mirror),
    );
    final Widget theirs = !otherHere
        ? GlassPanel(
            radius: 18,
            padding: const EdgeInsets.all(12),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.hourglass_empty_rounded, size: 30, color: Colors.white),
                  gap8,
                  Text(
                    'Waiting for the ${_asSolver ? 'seeker' : 'solver'} to join',
                    textAlign: TextAlign.center,
                    style: AppText.caption.copyWith(color: Colors.white),
                  ),
                ],
              ),
            ),
          )
        : _VideoTile(
            label: '$_otherName · ${_asSolver ? 'Seeker' : 'Solver'}',
            initials: _otherInitials,
            photoUrl: _otherPhoto,
            speaking: _peer?.isSpeaking ?? false,
            muted: !(_peer?.isMicrophoneEnabled() ?? true),
            videoOff: remote == null,
            video: remote == null ? null : VideoTrackRenderer(remote, fit: VideoViewFit.cover),
          );
    final seeker = _asSolver ? theirs : mine;
    final solver = _asSolver ? mine : theirs;
    return OrientationBuilder(
      builder: (context, orientation) {
        // Upright tiles on a phone held upright; wider ones sideways.
        final ratio = orientation == Orientation.landscape ? 4 / 3 : 3 / 4;
        return Row(
          children: [
            Expanded(
              child: AspectRatio(aspectRatio: ratio, child: seeker),
            ),
            SizedBox(width: fullScreen ? 12 : 10),
            Expanded(
              child: AspectRatio(aspectRatio: ratio, child: solver),
            ),
          ],
        );
      },
    );
  }

  Widget _buildLobby() {
    final now = DateTime.now().toUtc();
    final left = _b.start.difference(now);
    final progress = 1 - (left.inSeconds / SessionService.liveLead.inSeconds).clamp(0.0, 1.0);
    final zone = ExploreService.userZone(widget.user);
    final wall = zone.wall(_b.start);
    return _Page(
      title: 'Waiting for session to start',
      subtitle: 'You\'re in the lobby. The session starts automatically.',
      children: [
        Center(
          child: SizedBox.square(
            dimension: 200,
            child: CustomPaint(
              foregroundPainter: _RingPainter(progress),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: const GlassWell(radius: 90, child: Center(child: AnimatedLogo(size: 150))),
              ),
            ),
          ),
        ),
        gap14,
        Text(
          'Starts in ${_mmss(left)}',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white),
        ),
        gap24,
        GlassWell(
          radius: 18,
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  GlassAvatar(initials: _otherInitials, size: 40, photoUrl: _otherPhoto),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _b.title,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
                        ),
                        Text('with $_otherName', style: AppText.caption),
                      ],
                    ),
                  ),
                ],
              ),
              gap8,
              Text('${formatDay(wall)} · ${formatClock(wall)} · ${_b.minutes} min', style: AppText.caption),
              Text(sessionTypeLabel(_b), style: AppText.caption),
            ],
          ),
        ),
        gap14,
        const InlineNotice(
          message: 'You can leave and rejoin anytime. The session starts automatically at the scheduled time.',
        ),
        GlassPillButton(label: 'Leave Lobby', onPressed: _leave),
      ],
    );
  }

  // ---- Meeting room --------------------------------------------------------------

  Widget _buildMeetRoom() {
    if (_live && _room == null && !_connecting && _meetError == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _connectMeeting();
      });
    }
    final remote = _remoteVideo;
    final screen = _remoteScreen;
    _followShare(screen);
    final local = _videoOn ? _localVideo : null;
    final anonymousYou = !_asSolver && _b.type == BookingType.anonymous;
    final you = anonymousYou ? 'You (Anonymous)' : 'You';
    // The other person shows only once they've joined the meeting.
    final otherHere = _people.isNotEmpty;
    final waiting = otherHere ? null : 'Waiting for the ${_asSolver ? 'seeker' : 'solver'} to join';
    final speaking = otherHere && (_peer?.isSpeaking ?? false);
    // What the other person has turned off, shown beside their name.
    final otherMicOff = otherHere && !(_peer?.isMicrophoneEnabled() ?? true);
    final otherCameraOff = otherHere && remote == null;
    final otherCamera = remote == null || !otherHere ? null : VideoTrackRenderer(remote, fit: VideoViewFit.cover);
    final podcast = _b.type == BookingType.podcast;
    return Stack(
      children: [
        // The stage: a podcast's grid; else a shared screen, else the other
        // person, full view.
        Positioned.fill(
          child: podcast
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        GlassIconButton(
                          icon: Icons.fullscreen_rounded,
                          tooltip: 'Full screen',
                          onPressed: _openPodcastFullScreen,
                        ),
                        gap8,
                        _podcastGrid(),
                      ],
                    ),
                  ),
                )
              : screen != null
              ? GestureDetector(
                  onTap: () => _openShare(screen),
                  child: TrueColors(child: VideoTrackRenderer(screen, fit: VideoViewFit.contain)),
                )
              : _screenComing
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 2.6, color: Colors.white),
                      ),
                      gap14,
                      Text('Loading $_otherName\'s screen…', style: AppText.caption.copyWith(color: Colors.white)),
                    ],
                  ),
                )
              : otherCamera != null
              ? TrueColors(child: otherCamera)
              : Center(
                  child: waiting != null
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.hourglass_empty_rounded, size: 40, color: Colors.white),
                            gap14,
                            Text(waiting, style: AppText.caption.copyWith(color: Colors.white)),
                          ],
                        )
                      : GlassAvatar(initials: _otherInitials, size: 120, photoUrl: _otherPhoto),
                ),
        ),
        // Header and notices float over the top of the stage.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GlassPanel(
                  radius: 24,
                  padding: EdgeInsets.zero,
                  child: _RoomHeader(
                    booking: _b,
                    otherName: _otherName,
                    otherInitials: _otherInitials,
                    otherPhoto: _otherPhoto,
                    onLeave: _leave,
                    waiting: waiting,
                  ),
                ),
                gap8,
                if (_sessions.stateOf(_b).recordingActive) ...[
                  _RecordingBanner(podcast: _b.type == BookingType.podcast),
                  gap8,
                ],
                _ExtensionBanner(user: widget.user, booking: _b, asSolver: _asSolver, onRequest: _openExtension),
                FlashError(_mediaError, onHidden: () => setState(() => _mediaError = null)),
                if (_live && (_connecting || _meetError != null))
                  GlassWell(
                    radius: 16,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    child: _connecting
                        ? Text('Connecting to the meeting…', style: AppText.caption, textAlign: TextAlign.center)
                        : GestureDetector(
                            onTap: () => setState(() => _meetError = null),
                            child: Text(
                              '$_meetError Tap to retry.',
                              style: AppText.caption.copyWith(color: Colors.white),
                              textAlign: TextAlign.center,
                            ),
                          ),
                  ),
              ],
            ),
          ),
        ),
        // Along the bottom: who's on stage and the small views, then the
        // controls, which rise as the panel is pulled up.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // A podcast shows both people in its grid instead.
              if (!podcast)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: waiting != null
                            ? const SizedBox.shrink()
                            : Align(
                                alignment: Alignment.centerLeft,
                                child: GlassWell(
                                  radius: 12,
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (screen != null) ...[
                                        const Icon(Icons.screen_share_outlined, size: 14, color: Colors.white),
                                        const SizedBox(width: 6),
                                      ] else ...[
                                        if (otherMicOff) ...[
                                          const Icon(Icons.mic_off_rounded, size: 14, color: Colors.white),
                                          const SizedBox(width: 6),
                                        ],
                                        if (otherCameraOff) ...[
                                          const Icon(Icons.videocam_off_outlined, size: 14, color: Colors.white),
                                          const SizedBox(width: 6),
                                        ],
                                      ],
                                      Flexible(
                                        child: Text(
                                          screen != null ? '$_otherName\'s screen · Tap for full screen' : _otherName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 12.5, color: Colors.white),
                                        ),
                                      ),
                                      if (speaking) ...[
                                        const SizedBox(width: 6),
                                        const Icon(Icons.graphic_eq_rounded, size: 16, color: Colors.white),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                      ),
                      const SizedBox(width: 12),
                      // The other person's camera while their screen is on
                      // stage, and you.
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (screen != null && otherCamera != null) ...[
                            SizedBox(
                              width: 104,
                              height: 140,
                              child: _VideoTile(
                                label: _otherName,
                                initials: _otherInitials,
                                photoUrl: _otherPhoto,
                                speaking: speaking,
                                muted: otherMicOff,
                                video: otherCamera,
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],
                          SizedBox(
                            width: 104,
                            height: 140,
                            child: _VideoTile(
                              label: you,
                              initials: anonymousYou ? '?' : initialsOf(widget.user.name),
                              videoOff: !_videoOn,
                              muted: !_micOn,
                              sharing: _sharing,
                              video: local == null || _sharing
                                  ? null
                                  : VideoTrackRenderer(
                                      local,
                                      fit: VideoViewFit.cover,
                                      mirrorMode: VideoViewMirrorMode.mirror,
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: _DropUpPanel(
                  controls: Row(
                    children: [
                      _Control(
                        icon: _micOn ? Icons.mic_none_rounded : Icons.mic_off_rounded,
                        label: 'Mic',
                        active: _micOn,
                        onTap: _toggleMic,
                      ),
                      _Control(
                        icon: _videoOn ? Icons.videocam_outlined : Icons.videocam_off_outlined,
                        label: 'Video',
                        active: _videoOn,
                        onTap: _toggleVideo,
                      ),
                      // Podcasts are recorded without screen sharing.
                      if (_b.type != BookingType.podcast)
                        _Control(
                          icon: _sharing ? Icons.stop_screen_share_outlined : Icons.screen_share_outlined,
                          label: _sharing ? 'Stop' : 'Share',
                          active: !_sharing,
                          onTap: _toggleShare,
                        ),
                      _Control(
                        icon: Icons.chat_bubble_outline_rounded,
                        label: 'Chat',
                        onTap: () => _sheet<void>(_ChatSheet(booking: _b, asSolver: _asSolver, otherName: _otherName)),
                      ),
                      _Control(icon: Icons.more_horiz_rounded, label: 'More', onTap: _openMore),
                    ],
                  ),
                  tools: Row(
                    children: [
                      Expanded(
                        child: _Tool(
                          icon: Icons.draw_outlined,
                          label: 'Whiteboard',
                          onTap: () => _sheet<void>(_WhiteboardSheet(booking: _b)),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _Tool(
                          icon: Icons.folder_open_outlined,
                          label: 'Files',
                          onTap: () =>
                              _sheet<void>(_FilesSheet(booking: _b, asSolver: _asSolver, otherName: _otherName)),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _Tool(
                          icon: Icons.group_outlined,
                          label: 'Participants',
                          onTap: () => _sheet<void>(_ParticipantsSheet(user: widget.user, booking: _b)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---- Chat session --------------------------------------------------------------

  Widget _buildChatRoom() {
    return Column(
      children: [
        _RoomHeader(
          booking: _b,
          otherName: _otherName,
          otherInitials: _otherInitials,
          otherPhoto: _otherPhoto,
          onLeave: _leave,
          onMore: _openMore,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _ExtensionBanner(user: widget.user, booking: _b, asSolver: _asSolver, onRequest: _openExtension),
        ),
        Expanded(
          child: _ChatPanel(booking: _b, user: widget.user, asSolver: _asSolver, otherName: _otherName),
        ),
      ],
    );
  }

  // ---- More / extension ----------------------------------------------------------

  Future<void> _openMore() async {
    final choice = await _sheet<String>(_MoreSheet(user: widget.user, booking: _b, asSolver: _asSolver));
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'extend':
        _openExtension();
      case 'leave':
        _leave();
    }
  }

  /// A seeker low on minutes is offered a top-up before asking for more time.
  Future<void> _openExtension() async {
    final cost = ExploreService.walletCost(_b.solver, _b.type, SessionService.minExtension);
    if (!await ensureWalletBalance(context, widget.user, needed: cost) || !mounted) return;
    await _sheet<void>(_ExtensionSheet(user: widget.user, booking: _b));
  }

  // ---- Ended ---------------------------------------------------------------------

  /// The solver's choice for a podcast's recording: null until made.
  bool? _keepRecording;
  bool _discarding = false;
  String? _recordingError;

  /// Deleting needs a confirmation; keeping needs no call (the recording
  /// becomes a draft by itself).
  Future<void> _deleteRecording() async {
    final confirmed = await _sheet<bool>(
      FlowSheetFrame(
        title: 'Delete the recording?',
        body: Text(
          'The recording and its draft are deleted for good. Published content isn\'t affected.',
          style: AppText.body,
        ),
        footer: Builder(
          builder: (context) => Row(
            children: [
              Expanded(
                child: GlassPillButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop(false)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: PrimaryPillButton(label: 'Delete', onPressed: () => Navigator.of(context).pop(true)),
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _discarding = true;
      _recordingError = null;
    });
    try {
      await _sessions.discardPodcastRecording(_b);
      if (mounted) setState(() => _keepRecording = false);
    } on AuthException catch (e) {
      if (mounted) setState(() => _recordingError = e.message);
    } finally {
      if (mounted) setState(() => _discarding = false);
    }
  }

  Widget _buildEnded() {
    final podcastHost = _asSolver && _live && _b.type == BookingType.podcast;
    return _Page(
      onBack: _leave,
      title: 'Session Complete',
      subtitle: _asSolver
          ? 'Thanks for the session. Share a quick review to receive your minutes.'
          : 'Thanks for joining. Please share a quick review to continue.',
      children: [
        const Center(child: GlassIconBadge(icon: Icons.check_rounded, size: 80)),
        if (podcastHost) ...[
          gap24,
          GlassWell(
            radius: 18,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Podcast recording',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
                ),
                gap8,
                Text(switch (_keepRecording) {
                  null =>
                    'The recording is saved to your Content drafts, where you can edit and publish it. '
                        'Unpublished recordings are deleted after a while.',
                  true => 'Kept. You\'ll find it in Content → Podcasts once it\'s processed.',
                  false => 'The recording was deleted.',
                }, style: AppText.caption),
                InlineNotice(message: _recordingError, tone: NoticeTone.error),
                if (_keepRecording == null) ...[
                  gap14,
                  Row(
                    children: [
                      Expanded(
                        child: GlassPillButton(label: 'Delete', onPressed: _discarding ? null : _deleteRecording),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: PrimaryPillButton(
                          label: 'Keep',
                          loading: _discarding,
                          onPressed: () => setState(() => _keepRecording = true),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
        gap24,
        PrimaryPillButton(label: 'Continue', onPressed: _leave),
      ],
    );
  }
}

String _mmss(Duration d) {
  final s = d.inSeconds.clamp(0, 359999);
  return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
}

// ---- Layout pieces ---------------------------------------------------------------------

class _Page extends StatelessWidget {
  const _Page({required this.title, required this.subtitle, required this.children, this.onBack});

  final String title;
  final String subtitle;
  final List<Widget> children;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: SizedBox(
            height: 44,
            child: Row(
              children: [
                if (onBack != null)
                  GlassIconButton(icon: Icons.arrow_back_rounded, tooltip: 'Back', onPressed: onBack!),
              ],
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        title.toUpperCase(),
                        style: AppText.heading.copyWith(fontSize: 21),
                        textAlign: TextAlign.center,
                      ),
                      gap8,
                      Text(subtitle, style: AppText.body, textAlign: TextAlign.center),
                      gap24,
                      ...children,
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RoomHeader extends StatelessWidget {
  const _RoomHeader({
    required this.booking,
    required this.otherName,
    required this.otherInitials,
    required this.onLeave,
    this.onMore,
    this.waiting,
    this.otherPhoto,
  });

  /// The other person's profile picture, when known.
  final String? otherPhoto;

  final Booking booking;
  final String otherName;
  final String otherInitials;
  final VoidCallback onLeave;
  final VoidCallback? onMore;

  /// Shown instead of the other person until they've joined the meeting.
  final String? waiting;

  @override
  Widget build(BuildContext context) {
    final left = SessionService.instance.endOf(booking).difference(DateTime.now().toUtc());
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          waiting == null
              ? GlassAvatar(initials: otherInitials, size: 40, photoUrl: otherPhoto)
              : const SizedBox.square(
                  dimension: 40,
                  child: Icon(Icons.hourglass_empty_rounded, size: 22, color: Colors.white),
                ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  booking.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
                ),
                Text(
                  '${_mmss(left)} left · ${waiting ?? 'with $otherName'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(fontSize: 12),
                ),
              ],
            ),
          ),
          if (onMore != null) ...[
            GlassIconButton(icon: Icons.more_horiz_rounded, tooltip: 'More', onPressed: onMore!),
            const SizedBox(width: 8),
          ],
          SmallPillButton(label: 'Leave', onPressed: onLeave),
        ],
      ),
    );
  }
}

/// Shown while the server says the meeting is being recorded.
class _RecordingBanner extends StatelessWidget {
  const _RecordingBanner({this.podcast = false});

  final bool podcast;

  @override
  Widget build(BuildContext context) {
    return GlassWell(
      radius: 16,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.fiber_manual_record_rounded, size: 14, color: AppColors.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Recording… This ${podcast ? 'podcast ' : ''}session is being recorded.',
              style: AppText.caption.copyWith(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

/// Appears in [SessionService.extensionWindow]: offers an extension, then shows the
/// solver's answer.
class _ExtensionBanner extends StatelessWidget {
  const _ExtensionBanner({required this.user, required this.booking, required this.onRequest, this.asSolver = false});

  final AppUser user;
  final Booking booking;
  final VoidCallback onRequest;

  /// The solver answers requests instead of sending them.
  final bool asSolver;

  @override
  Widget build(BuildContext context) {
    final sessions = SessionService.instance;
    final end = sessions.endOf(booking);
    var request = sessions.stateOf(booking).extension;
    // An answer from before this last stretch (an earlier extension) no
    // longer applies: the seeker can ask again.
    if (request != null &&
        request.status != ExtensionStatus.pending &&
        request.sentAt.toUtc().isBefore(end.subtract(SessionService.extensionWindow))) {
      request = null;
    }
    final inWindow = sessions.inExtensionWindow(booking);
    // Podcasts run for their booked time and can't be extended.
    if (booking.type == BookingType.podcast || (!inWindow && request == null)) return const SizedBox.shrink();
    final left = end.difference(DateTime.now().toUtc());
    if (asSolver) return _buildForSolver(context, sessions, request, left);
    final extend = sessions.canRequestExtension(booking)
        ? SmallPillButton(label: 'Extend', onPressed: onRequest)
        : null;
    final (text, action) = switch (request?.status) {
      null => ('Session ends in ${_mmss(left)}. Need more time?', extend),
      ExtensionStatus.pending => (
        'Extension of ${request!.minutes} min sent. Waiting for ${booking.solver.name}…${_answerLeft(request)}',
        null,
      ),
      ExtensionStatus.approved => ('${booking.solver.name} approved +${request!.minutes} min.', extend),
      ExtensionStatus.rejected => (
        request!.expired
            ? '${booking.solver.name} didn\'t answer in time. Your minutes were returned.'
            : '${booking.solver.name} declined the extension. Your minutes were returned.',
        extend,
      ),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: GlassWell(
        radius: 16,
        active: request?.status == null,
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.more_time_rounded, size: 18, color: Colors.white),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(text, style: AppText.caption.copyWith(color: Colors.white)),
                ),
                ?action,
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Time left to answer a pending request, from the server's window.
  static String _answerLeft(ExtensionRequest request) {
    final left = request.timeLeft;
    return left == null || left == Duration.zero ? '' : ' (${_mmss(left)} left to answer)';
  }

  /// The seeker's request arrives here: approve adds the time (and the
  /// minutes you earn), decline keeps the original end time.
  Widget _buildForSolver(BuildContext context, SessionService sessions, ExtensionRequest? request, Duration left) {
    final seeker = booking.seekerLabel;
    final text = switch (request?.status) {
      null => 'Session ends in ${_mmss(left)}.',
      ExtensionStatus.pending =>
        '$seeker asks for ${request!.minutes} more minutes'
            '${request.note.isEmpty ? '.' : ': "${request.note}"'}${_answerLeft(request)}',
      ExtensionStatus.approved => 'You approved +${request!.minutes} min. You\'ll earn these minutes too.',
      ExtensionStatus.rejected =>
        request!.autoDeclined
            ? 'The extension was declined automatically: it would run into your next booking or past your '
                  'available hours.'
            : request.expired
            ? 'The extension request expired without an answer.'
            : 'You declined the extension.',
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: GlassWell(
        radius: 16,
        active: request?.status == ExtensionStatus.pending,
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.more_time_rounded, size: 18, color: Colors.white),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(text, style: AppText.caption.copyWith(color: Colors.white)),
                ),
              ],
            ),
            if (request?.status == ExtensionStatus.pending) ...[
              gap8,
              Row(
                children: [
                  SmallPillButton(
                    label: 'Approve',
                    primary: true,
                    onPressed: () => sessions.resolveExtension(null, booking, approve: true),
                  ),
                  const SizedBox(width: 8),
                  SmallPillButton(
                    label: 'Decline',
                    onPressed: () => sessions.resolveExtension(null, booking, approve: false),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A small corner view of someone in the meeting: their video, or their
/// initials, with their name.
class _VideoTile extends StatelessWidget {
  const _VideoTile({
    required this.label,
    required this.initials,
    this.speaking = false,
    this.videoOff = false,
    this.muted = false,
    this.sharing = false,
    this.video,
    this.photoUrl,
  });

  final String label;
  final String initials;

  /// Shown instead of the initials when the camera is off.
  final String? photoUrl;
  final bool speaking;
  final bool videoOff;
  final bool muted;
  final bool sharing;

  /// The live video feed, when the camera is on in a live meeting.
  final Widget? video;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      radius: 18,
      padding: const EdgeInsets.all(5),
      child: Stack(
        children: [
          if (video != null)
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(13),
                child: TrueColors(child: video!),
              ),
            )
          else
            Center(
              child: sharing
                  ? const Icon(Icons.screen_share_outlined, size: 26, color: Colors.white)
                  : GlassAvatar(initials: initials, size: 44, photoUrl: photoUrl),
            ),
          Positioned(
            left: 3,
            bottom: 3,
            right: 3,
            child: Align(
              alignment: Alignment.centerLeft,
              child: GlassWell(
                radius: 8,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (muted) ...[
                      const Icon(Icons.mic_off_rounded, size: 11, color: Colors.white),
                      const SizedBox(width: 4),
                    ],
                    if (videoOff) ...[
                      const Icon(Icons.videocam_off_outlined, size: 11, color: Colors.white),
                      const SizedBox(width: 4),
                    ],
                    if (speaking) ...[
                      const Icon(Icons.graphic_eq_rounded, size: 12, color: Colors.white),
                      const SizedBox(width: 4),
                    ],
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10.5, color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The meeting's controls along the bottom. Swiping up (or tapping the
/// handle) opens the [tools] below the [controls]; swiping down closes them.
/// It's as tall as its content, so nothing is cut off at any text size.
class _DropUpPanel extends StatefulWidget {
  const _DropUpPanel({required this.controls, required this.tools});

  final Widget controls;
  final Widget tools;

  @override
  State<_DropUpPanel> createState() => _DropUpPanelState();
}

class _DropUpPanelState extends State<_DropUpPanel> {
  bool _open = false;

  void _onDragEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    if (v.abs() < 100) return;
    setState(() => _open = v < 0);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onVerticalDragEnd: _onDragEnd,
      child: GlassPanel(
        radius: 28,
        padding: const EdgeInsets.fromLTRB(6, 0, 6, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              button: true,
              label: _open ? 'Hide meeting tools' : 'Show meeting tools',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _open = !_open),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(color: AppColors.white(0.45), borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                ),
              ),
            ),
            widget.controls,
            AnimatedSize(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _open
                  ? Padding(padding: const EdgeInsets.fromLTRB(6, 14, 6, 0), child: widget.tools)
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}

class _Control extends StatelessWidget {
  const _Control({required this.icon, required this.label, required this.onTap, this.active = true});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: [
                SizedBox.square(
                  dimension: 44,
                  child: GlassWell(
                    radius: 22,
                    active: !active,
                    fillTop: active ? 0 : 0.10,
                    fillBottom: active ? 0 : 0.06,
                    child: Icon(icon, size: 21, color: active ? Colors.white : AppColors.error),
                  ),
                ),
                const SizedBox(height: 4),
                Text(label, style: AppText.caption.copyWith(fontSize: 11.5, color: Colors.white)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Tool extends StatelessWidget {
  const _Tool({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GlassOption(
      height: 76,
      radius: 18,
      selected: false,
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 22, color: Colors.white),
          const SizedBox(height: 6),
          Text(label, style: AppText.caption.copyWith(fontSize: 12, color: Colors.white)),
        ],
      ),
    );
  }
}

class _FrameCornersPainter extends CustomPainter {
  const _FrameCornersPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    const l = 28.0;
    final w = size.width, h = size.height;
    for (final (o, dx, dy) in [
      (Offset.zero, 1.0, 1.0),
      (Offset(w, 0), -1.0, 1.0),
      (Offset(0, h), 1.0, -1.0),
      (Offset(w, h), -1.0, -1.0),
    ]) {
      canvas.drawLine(o, o + Offset(l * dx, 0), paint);
      canvas.drawLine(o, o + Offset(0, l * dy), paint);
    }
  }

  @override
  bool shouldRepaint(_FrameCornersPainter old) => false;
}

class _RingPainter extends CustomPainter {
  const _RingPainter(this.value);

  final double value;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(3);
    canvas.drawArc(
      rect,
      0,
      2 * math.pi,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = AppColors.white(0.16),
    );
    canvas.drawArc(
      rect,
      -math.pi / 2,
      2 * math.pi * value,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.value != value;
}

// ---- Chat --------------------------------------------------------------------------------

/// Messages plus an input with file attach. Used as the whole room for chat
/// sessions and inside the Chat sheet during meetings.
class _ChatPanel extends StatefulWidget {
  const _ChatPanel({
    required this.booking,
    required this.otherName,
    this.user,
    this.compact = false,
    this.asSolver = false,
  });

  final Booking booking;
  final AppUser? user;
  final bool compact;
  final bool asSolver;

  /// The other person in the session.
  final String otherName;

  @override
  State<_ChatPanel> createState() => _ChatPanelState();
}

enum _ChatTab { chat, files, participants }

class _ChatPanelState extends State<_ChatPanel> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  _ChatTab _tab = _ChatTab.chat;
  String? _error;

  /// The message being replied to, shown above the composer.
  ChatMessage? _replyTo;

  /// Reading older messages (not at the bottom), and how many messages there
  /// were when the reader was last at the bottom.
  bool _away = false;
  int _seen = 0;

  Booking get _b => widget.booking;

  @override
  void initState() {
    super.initState();
    _seen = SessionService.instance.stateOf(_b).messages.length;
    _scroll.addListener(_onScroll);
    SessionService.instance.addListener(_onMessages);
    _toBottom();
  }

  @override
  void dispose() {
    SessionService.instance.removeListener(_onMessages);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    final away = _scroll.position.extentAfter > 80;
    if (away == _away) return;
    setState(() {
      _away = away;
      if (!away) _seen = SessionService.instance.stateOf(_b).messages.length;
    });
  }

  /// New messages: followed when at the bottom; otherwise counted for the
  /// "new messages" button.
  void _onMessages() {
    final count = SessionService.instance.stateOf(_b).messages.length;
    if (count == _seen) return;
    if (_away) return setState(() {});
    _seen = count;
    _toBottom();
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    SessionService.instance.send(_b, text, fromSeeker: !widget.asSolver, replyTo: _replyTo);
    _input.clear();
    setState(() => _replyTo = null);
    _toBottom();
  }

  Future<void> _attach() async {
    final file = await FilePicker.pickFile();
    if (file == null || !mounted) return;
    final bytes = await file.length();
    if (!mounted) return;
    if (bytes == null || bytes > 25 * 1024 * 1024) {
      setState(() => _error = 'Files can be up to 25 MB.');
      return;
    }
    setState(() => _error = null);
    SessionService.instance.send(
      _b,
      'Shared a file',
      fileName: file.name,
      filePath: file.path,
      fromSeeker: !widget.asSolver,
    );
    _toBottom();
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) {
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SessionService.instance,
      builder: (context, _) {
        final state = SessionService.instance.stateOf(_b);
        return Column(
          children: [
            if (!widget.compact)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                child: Row(
                  children: [
                    for (final tab in _ChatTab.values) ...[
                      if (tab != _ChatTab.chat) const SizedBox(width: 8),
                      GlassChip(
                        label: switch (tab) {
                          _ChatTab.chat => 'Chat',
                          _ChatTab.files => 'Files',
                          _ChatTab.participants => 'Participants',
                        },
                        selected: _tab == tab,
                        onTap: () => setState(() => _tab = tab),
                      ),
                    ],
                  ],
                ),
              ),
            Expanded(
              child: switch (_tab) {
                _ChatTab.chat => Stack(
                  children: [
                    ListView(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      children: [
                        if (state.messages.isEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 40),
                            child: Text(
                              'Say hello to ${widget.otherName}.',
                              style: AppText.body,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        for (final m in state.messages)
                          if (m.system)
                            ChatBubble(message: m, otherName: widget.otherName, seekerView: !widget.asSolver)
                          else
                            SwipeToReply(
                              onReply: () => setState(() => _replyTo = m),
                              child: ChatBubble(
                                message: m,
                                otherName: widget.otherName,
                                seekerView: !widget.asSolver,
                                replyTo: m.replyToId == null
                                    ? null
                                    : state.messages.where((x) => x.id == m.replyToId).firstOrNull,
                              ),
                            ),
                      ],
                    ),
                    if (_away && state.messages.length > _seen)
                      Positioned(
                        right: 16,
                        bottom: 10,
                        child: _NewMessagesButton(count: state.messages.length - _seen, onTap: _toBottom),
                      ),
                  ],
                ),
                _ChatTab.files => _FilesList(booking: _b, asSolver: widget.asSolver, otherName: widget.otherName),
                _ChatTab.participants => _ParticipantsList(user: widget.user, booking: _b),
              },
            ),
            if (_tab == _ChatTab.chat)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FlashError(
                      _error ?? SessionService.instance.sendError,
                      onHidden: () => setState(() {
                        _error = null;
                        SessionService.instance.sendError = null;
                      }),
                    ),
                    if (_replyTo case final r?)
                      ReplyComposerBar(
                        author: r.fromSeeker == !widget.asSolver ? 'yourself' : widget.otherName,
                        text: r.fileName ?? r.text,
                        onCancel: () => setState(() => _replyTo = null),
                      ),
                    Row(
                      children: [
                        GlassIconButton(icon: Icons.attach_file_rounded, tooltip: 'Share a file', onPressed: _attach),
                        const SizedBox(width: 8),
                        Expanded(
                          child: GlassTextField(
                            controller: _input,
                            hint: 'Type a message',
                            textCapitalization: TextCapitalization.sentences,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _send(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        GlassIconButton(icon: Icons.send_rounded, tooltip: 'Send', onPressed: _send),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Shown while reading older messages when new ones arrive; jumps to them.
class _NewMessagesButton extends StatelessWidget {
  const _NewMessagesButton({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '$count new message${count == 1 ? '' : 's'}. Jump to the latest.',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            const SizedBox.square(
              dimension: 44,
              child: GlassWell(
                floating: true,
                fillTop: 0.1,
                fillBottom: 0.05,
                child: Center(child: Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white)),
              ),
            ),
            Positioned(
              right: -4,
              top: -4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(9)),
                child: Text(
                  count > 99 ? '99+' : '$count',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.primary),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilesList extends StatelessWidget {
  const _FilesList({required this.booking, required this.otherName, this.asSolver = false});

  final Booking booking;
  final String otherName;
  final bool asSolver;

  @override
  Widget build(BuildContext context) {
    final files = SessionService.instance.stateOf(booking).messages.where((m) => m.fileName != null).toList();
    if (files.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text('Files shared in the chat appear here.', style: AppText.body, textAlign: TextAlign.center),
      );
    }
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        for (final f in files)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GlassWell(
              radius: 14,
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(f.fromSeeker != asSolver ? 'You' : otherName, style: AppText.caption.copyWith(fontSize: 11.5)),
                  const SizedBox(height: 6),
                  SecureAttachment(
                    name: f.fileName!,
                    url: f.fileUrl,
                    localPath: f.localPath,
                    download: ApiClient.instance.download,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _ParticipantsList extends StatelessWidget {
  const _ParticipantsList({required this.user, required this.booking});

  final AppUser? user;
  final Booking booking;

  @override
  Widget build(BuildContext context) {
    // In a meeting, the other person is listed once they've joined it.
    return ListenableBuilder(listenable: SessionService.instance, builder: (context, _) => _build());
  }

  Widget _build() {
    final asSolver = user?.role == UserRole.solver;
    final anonymous = booking.type == BookingType.anonymous;
    final otherHere = SessionService.instance.otherInMeeting(booking) ?? true;
    final photo = SessionService.instance.peerPhoto(booking);
    if (asSolver) {
      return _participants([
        (initialsOf(user!.name), 'You · ${user!.name}', 'Solver', null),
        if (otherHere) (booking.seekerInitials, booking.seekerLabel, 'Seeker', photo),
      ], waiting: otherHere ? null : 'The seeker hasn\'t joined yet.');
    }
    final you = anonymous ? 'You (Anonymous)' : 'You${user == null ? '' : ' · ${user!.name}'}';
    return _participants([
      if (otherHere) (booking.solver.initials, booking.solver.name, 'Solver', photo),
      (
        anonymous
            ? '?'
            : (user?.name.isNotEmpty ?? false)
            ? user!.name[0].toUpperCase()
            : 'Y',
        you,
        'Seeker',
        null,
      ),
    ], waiting: otherHere ? null : 'The solver hasn\'t joined yet.');
  }

  Widget _participants(List<(String, String, String, String?)> people, {String? waiting}) {
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        if (waiting != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(waiting, style: AppText.caption),
          ),
        for (final (initials, name, role, photo) in people)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GlassWell(
              radius: 14,
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  GlassAvatar(initials: initials, size: 36, photoUrl: photo),
                  const SizedBox(width: 10),
                  Expanded(child: Text(name, style: AppText.label.copyWith(fontSize: 14))),
                  BookingBadge(role),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// ---- Sheets --------------------------------------------------------------------------------

class _ChatSheet extends StatelessWidget {
  const _ChatSheet({required this.booking, required this.otherName, this.asSolver = false});

  final Booking booking;
  final String otherName;
  final bool asSolver;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(
          height: media.size.height * 0.75,
          child: GlassPanel(
            radius: 30,
            squareBottom: true,
            blur: 5,
            padding: EdgeInsets.only(top: 14, bottom: media.padding.bottom),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Chat',
                          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: Colors.white),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded, color: Colors.white),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _ChatPanel(booking: booking, otherName: otherName, asSolver: asSolver, compact: true),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FilesSheet extends StatelessWidget {
  const _FilesSheet({required this.booking, required this.otherName, this.asSolver = false});

  final Booking booking;
  final String otherName;
  final bool asSolver;

  @override
  Widget build(BuildContext context) {
    return FlowSheetFrame(
      title: 'Files',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Share files from the chat. They appear here for everyone in the session.', style: AppText.caption),
          gap14,
          _FilesList(booking: booking, asSolver: asSolver, otherName: otherName),
        ],
      ),
      footer: GlassPillButton(label: 'Close', onPressed: () => Navigator.of(context).pop()),
    );
  }
}

class _ParticipantsSheet extends StatelessWidget {
  const _ParticipantsSheet({required this.user, required this.booking});

  final AppUser user;
  final Booking booking;

  @override
  Widget build(BuildContext context) {
    return FlowSheetFrame(
      title: 'Participants',
      body: _ParticipantsList(user: user, booking: booking),
      footer: GlassPillButton(label: 'Close', onPressed: () => Navigator.of(context).pop()),
    );
  }
}

class _WhiteboardSheet extends StatefulWidget {
  const _WhiteboardSheet({required this.booking});

  final Booking booking;

  @override
  State<_WhiteboardSheet> createState() => _WhiteboardSheetState();
}

class _WhiteboardSheetState extends State<_WhiteboardSheet> {
  List<Offset>? _current;

  @override
  void initState() {
    super.initState();
    SessionService.instance.openBoard(widget.booking);
  }

  @override
  void dispose() {
    SessionService.instance.closeBoard(widget.booking);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sessions = SessionService.instance;
    return FlowSheetFrame(
      title: 'Whiteboard',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Draw to explain ideas. Everyone in the session sees the board.', style: AppText.caption),
          gap14,
          SizedBox(
            height: 340,
            child: GlassWell(
              radius: 18,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: LayoutBuilder(
                  builder: (context, box) {
                    // Strokes are kept in board coordinates so both screens
                    // show the same drawing whatever their size.
                    final scale = box.maxWidth / SessionService.boardWidth;
                    Offset toBoard(Offset p) => p / scale;
                    return GestureDetector(
                      onPanStart: (d) => setState(() => _current = [toBoard(d.localPosition)]),
                      onPanUpdate: (d) => setState(() => _current?.add(toBoard(d.localPosition))),
                      onPanEnd: (_) {
                        final stroke = _current;
                        if (stroke != null && stroke.length > 1) sessions.addStroke(widget.booking, stroke);
                        setState(() => _current = null);
                      },
                      child: ListenableBuilder(
                        listenable: sessions,
                        builder: (context, _) => CustomPaint(
                          painter: _StrokesPainter([...sessions.stateOf(widget.booking).strokes, ?_current], scale),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
      footer: Row(
        children: [
          Expanded(
            child: GlassPillButton(label: 'Clear', onPressed: () => sessions.clearWhiteboard(widget.booking)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: PrimaryPillButton(label: 'Done', onPressed: () => Navigator.of(context).pop()),
          ),
        ],
      ),
    );
  }
}

class _StrokesPainter extends CustomPainter {
  const _StrokesPainter(this.strokes, this.scale);

  final List<List<Offset>> strokes;

  /// Screen pixels per board unit.
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    for (final stroke in strokes) {
      if (stroke.length < 2) continue;
      final path = Path()..moveTo(stroke.first.dx * scale, stroke.first.dy * scale);
      for (final p in stroke.skip(1)) {
        path.lineTo(p.dx * scale, p.dy * scale);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_StrokesPainter old) => true;
}

class _MoreSheet extends StatelessWidget {
  const _MoreSheet({required this.user, required this.booking, this.asSolver = false});

  final AppUser user;
  final Booking booking;
  final bool asSolver;

  @override
  Widget build(BuildContext context) {
    final sessions = SessionService.instance;
    final canExtend = sessions.canRequestExtension(booking);
    Widget option(IconData icon, String label, String? note, String? value) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassOption(
        height: 60,
        radius: 16,
        selected: false,
        onTap: value == null ? null : () => Navigator.of(context).pop(value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Icon(icon, color: Colors.white),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: AppText.label.copyWith(fontSize: 14)),
                    if (note != null) Text(note, style: AppText.caption.copyWith(fontSize: 11.5)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return FlowSheetFrame(
      title: 'More',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Podcasts can't be extended.
          if (!asSolver && booking.type != BookingType.podcast)
            option(
              Icons.more_time_rounded,
              'Extend Session',
              canExtend
                  ? 'Request extra time from the solver'
                  : 'Available in the last ${SessionService.extensionWindowLabel}',
              canExtend ? 'extend' : null,
            ),
          option(Icons.logout_rounded, 'Leave Session', 'You can rejoin until the session ends', 'leave'),
        ],
      ),
    );
  }
}

class _ExtensionSheet extends StatefulWidget {
  const _ExtensionSheet({required this.user, required this.booking});

  final AppUser user;
  final Booking booking;

  @override
  State<_ExtensionSheet> createState() => _ExtensionSheetState();
}

class _ExtensionSheetState extends State<_ExtensionSheet> {
  final _custom = TextEditingController();
  final _note = TextEditingController();
  int? _minutes = 10;
  bool _customMode = false;
  String? _error;

  /// The most minutes that fit before the solver's next commitment, once
  /// checked.
  int? _room;

  @override
  void initState() {
    super.initState();
    SessionService.instance.extensionRoom(widget.user, widget.booking).then((room) {
      if (!mounted) return;
      setState(() {
        _room = room;
        if ((_minutes ?? 0) > room) _minutes = null;
      });
    });
  }

  int get _max => _room ?? SessionService.maxExtension;

  @override
  void dispose() {
    _custom.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final minutes = _customMode ? int.tryParse(_custom.text.trim()) : _minutes;
    if (minutes == null || minutes < SessionService.minExtension) {
      setState(() => _error = 'Enter at least ${SessionService.minExtension} minutes.');
      return;
    }
    if (minutes > _max) {
      setState(() => _error = 'Choose $_max minutes or less.');
      return;
    }
    final cost = ExploreService.walletCost(widget.booking.solver, widget.booking.type, minutes);
    if (!await ensureWalletBalance(context, widget.user, needed: cost)) return;
    try {
      await SessionService.instance.requestExtension(widget.user, widget.booking, minutes, _note.text);
      if (mounted) Navigator.of(context).pop();
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.booking;
    final minutes = _customMode ? int.tryParse(_custom.text.trim()) : _minutes;
    final room = _room;
    final blocked = room != null && room < SessionService.minExtension;
    return FlowSheetFrame(
      title: 'Request Session Extension',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InlineNotice(
            message: 'You can request an extension in the last ${SessionService.extensionWindowLabel} of your session.',
          ),
          if (blocked)
            InlineNotice(
              message:
                  '${b.solver.name} isn\'t free right after this session (another booking or the end of their '
                  'available hours), so it can\'t be extended.',
              tone: NoticeTone.error,
              persistent: true,
            )
          else if (room != null && room < SessionService.maxExtension)
            InlineNotice(message: '${b.solver.name} is free for up to $room more minutes after this session.'),
          InlineNotice(message: _error, tone: NoticeTone.error),
          const Text('Additional Duration', style: _label),
          gap8,
          OptionGrid(
            columns: 4,
            spacing: 8,
            children: [
              for (final m in const [10, 20, 30])
                GlassOption(
                  height: 44,
                  selected: !_customMode && _minutes == m,
                  // Lengths that don't fit before the solver's next commitment can't be picked.
                  onTap: m > _max
                      ? null
                      : () => setState(() {
                          _customMode = false;
                          _minutes = m;
                          _error = null;
                        }),
                  child: Text('$m min', style: AppText.label.copyWith(fontSize: 13.5)),
                ),
              GlassOption(
                height: 44,
                selected: _customMode,
                onTap: blocked ? null : () => setState(() => _customMode = true),
                child: Text('Custom', style: AppText.label.copyWith(fontSize: 13.5)),
              ),
            ],
          ),
          if (_customMode) ...[
            gap14,
            GlassTextField(
              controller: _custom,
              hint: 'Minutes (${SessionService.minExtension}–$_max)',
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() => _error = null),
            ),
          ],
          gap14,
          const Text('Note (optional)', style: _label),
          gap8,
          GlassTextField(controller: _note, hint: 'Add a note for the solver', maxLines: 3),
          if (minutes != null && minutes >= SessionService.minExtension) ...[
            gap14,
            Text(
              'If approved, ${ExploreService.walletCost(b.solver, b.type, minutes)} minutes will be charged from your wallet.',
              style: AppText.caption,
            ),
          ],
        ],
      ),
      footer: Row(
        children: [
          Expanded(
            child: GlassPillButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: PrimaryPillButton(label: 'Send Request', onPressed: blocked ? null : _send),
          ),
        ],
      ),
    );
  }

  static const _label = TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white);
}

/// The other person's shared screen, full screen; pinch to zoom.
class _ScreenShareView extends StatefulWidget {
  const _ScreenShareView({required this.track, required this.name});

  final VideoTrack track;
  final String name;

  @override
  State<_ScreenShareView> createState() => _ScreenShareViewState();
}

class _ScreenShareViewState extends State<_ScreenShareView> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              maxScale: 4,
              child: TrueColors(child: VideoTrackRenderer(widget.track, fit: VideoViewFit.contain)),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0x99000000),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          "${widget.name}'s screen",
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Material(
                      color: const Color(0x99000000),
                      shape: const CircleBorder(),
                      child: IconButton(
                        tooltip: 'Exit full screen',
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.fullscreen_exit_rounded, color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The podcast grid filling the screen; turn the phone for bigger tiles.
/// It follows the call as people join, leave or turn their camera off.
class _PodcastFullScreen extends StatefulWidget {
  const _PodcastFullScreen({required this.grid});

  /// Builds the grid as the call is now.
  final Widget Function() grid;

  @override
  State<_PodcastFullScreen> createState() => _PodcastFullScreenState();
}

class _PodcastFullScreenState extends State<_PodcastFullScreen> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: ListenableBuilder(listenable: SessionService.instance, builder: (_, _) => widget.grid()),
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: GlassIconButton(
                icon: Icons.fullscreen_exit_rounded,
                tooltip: 'Exit full screen',
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
