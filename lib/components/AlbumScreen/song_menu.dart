import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:finamp/components/AlbumScreen/speed_menu.dart';
import 'package:finamp/components/PlayerScreen/queue_list.dart';
import 'package:finamp/components/PlayerScreen/sleep_timer_cancel_dialog.dart';
import 'package:finamp/components/PlayerScreen/sleep_timer_dialog.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/screens/artist_screen.dart';
import 'package:finamp/screens/blurred_player_screen_background.dart';
import 'package:finamp/services/album_image_provider.dart';
import 'package:finamp/services/current_album_image_provider.dart';
import 'package:finamp/services/current_track_metadata_provider.dart';
import 'package:finamp/services/feedback_helper.dart';
import 'package:finamp/services/metadata_provider.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/theme_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_blurhash/flutter_blurhash.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:flutter_vibrate/flutter_vibrate.dart';
import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';

import '../../models/jellyfin_models.dart';
import '../../screens/add_to_playlist_screen.dart';
import '../../screens/album_screen.dart';
import '../../services/audio_service_helper.dart';
import '../../services/downloads_service.dart';
import '../../services/finamp_settings_helper.dart';
import '../../services/jellyfin_api_helper.dart';
import '../PlayerScreen/album_chip.dart';
import '../PlayerScreen/artist_chip.dart';
import '../PlayerScreen/queue_source_helper.dart';
import '../album_image.dart';
import '../global_snackbar.dart';
import 'download_dialog.dart';

const Duration songMenuDefaultAnimationDuration = Duration(milliseconds: 750);
const Curve songMenuDefaultInCurve = Curves.easeOutCubic;
const Curve songMenuDefaultOutCurve = Curves.easeInCubic;

Future<void> showModalSongMenu({
  required BuildContext context,
  required BaseItemDto item,
  bool showPlaybackControls = false,
  bool usePlayerTheme = false,
  bool isInPlaylist = false,
  BaseItemDto? parentItem,
  Function? onRemoveFromList,
  bool confirmPlaylistRemoval = true,
  ImageProvider? cachedImage,
  ThemeProvider? themeProvider,
}) async {
  final isOffline = FinampSettingsHelper.finampSettings.isOffline;
  final canGoToAlbum = item.parentId != null;
  final canGoToArtist = (item.artistItems?.isNotEmpty ?? false);
  final canGoToGenre = (item.genreItems?.isNotEmpty ?? false);

  FeedbackHelper.feedback(FeedbackType.impact);

  if (themeProvider == null && !usePlayerTheme) {
    if (cachedImage != null) {
      // If calling widget failed to precalculate theme and we have a cached image,
      // calculate in foreground.  This causes a lag spike but is far quicker.
      themeProvider = ThemeProvider(cachedImage, Theme.of(context).brightness,
          useIsolate: false);
    } else if (item.blurHash != null) {
      themeProvider = ThemeProvider(
          BlurHashImage(item.blurHash!), Theme.of(context).brightness,
          useIsolate: false);
    }
  }

  await showModalBottomSheet(
      context: context,
      constraints: BoxConstraints(
          maxWidth: (Platform.isIOS || Platform.isAndroid)
              ? 500
              : min(500, MediaQuery.sizeOf(context).width * 0.9)),
      isDismissible: true,
      enableDrag: true,
      useSafeArea: true,
      isScrollControlled: true,
      routeSettings: const RouteSettings(name: SongMenu.routeName),
      clipBehavior: Clip.hardEdge,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
      ),
      backgroundColor: (Theme.of(context).brightness == Brightness.light
              ? Colors.white
              : Colors.black)
          .withOpacity(0.9),
      builder: (BuildContext context) {
        return SongMenu(
          key: ValueKey(item.id),
          item: item,
          parentItem: parentItem,
          usePlayerTheme: usePlayerTheme,
          isOffline: isOffline,
          showPlaybackControls: showPlaybackControls,
          isInPlaylist: isInPlaylist,
          canGoToAlbum: canGoToAlbum,
          canGoToArtist: canGoToArtist,
          canGoToGenre: canGoToGenre,
          onRemoveFromList: onRemoveFromList,
          cachedImage: cachedImage,
          themeProvider: themeProvider,
          brightness: Theme.of(context).brightness,
          confirmPlaylistRemoval: confirmPlaylistRemoval,
        );
      });
}

class SongMenu extends ConsumerStatefulWidget {
  static const routeName = "/song-menu";

  const SongMenu({
    super.key,
    required this.item,
    required this.isOffline,
    required this.showPlaybackControls,
    required this.usePlayerTheme,
    required this.isInPlaylist,
    required this.canGoToAlbum,
    required this.canGoToArtist,
    required this.canGoToGenre,
    required this.onRemoveFromList,
    required this.confirmPlaylistRemoval,
    this.parentItem,
    this.cachedImage,
    this.themeProvider,
    required this.brightness,
  });

  final BaseItemDto item;
  final BaseItemDto? parentItem;
  final bool isOffline;
  final bool showPlaybackControls;
  final bool usePlayerTheme;
  final bool isInPlaylist;
  final bool canGoToAlbum;
  final bool canGoToArtist;
  final bool canGoToGenre;
  final Function? onRemoveFromList;
  final ImageProvider? cachedImage;
  final ThemeProvider? themeProvider;
  final Brightness brightness;
  final bool confirmPlaylistRemoval;

  @override
  ConsumerState<SongMenu> createState() => _SongMenuState();
}

bool isBaseItemInQueueItem(BaseItemDto baseItem, FinampQueueItem? queueItem) {
  if (queueItem != null) {
    final baseItem = BaseItemDto.fromJson(queueItem.item.extras!["itemJson"]);
    return baseItem.id == queueItem.id;
  }
  return false;
}

class _SongMenuState extends ConsumerState<SongMenu> {
  final _jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();
  final _audioServiceHelper = GetIt.instance<AudioServiceHelper>();
  final _audioHandler = GetIt.instance<MusicPlayerBackgroundTask>();
  final _queueService = GetIt.instance<QueueService>();

  final ScrollController _controller = ScrollController();

  ColorScheme? _imageTheme;
  ImageProvider? _imageProvider;
  // Makes sure that widget doesn't just disappear after press while menu is visible
  bool speedWidgetWasVisible = false;
  bool showSpeedMenu = false;
  final dragController = DraggableScrollableController();
  double initialSheetExtent = 0.0;
  double inputStep = 0.9;
  double oldExtent = 0.0;

  @override
  void initState() {
    if (widget.usePlayerTheme) {
      // We do not want to update theme/image on track changes.
      _imageTheme = ref.read(playerScreenThemeProvider(widget.brightness));
      _imageProvider = ref.read(currentAlbumImageProvider);
    } else {
      _imageTheme = widget.themeProvider?.colorScheme;
      if (_imageTheme == null) {
        _imageTheme = getGreyTheme(widget.brightness);
        // Rebuild widget if/when theme calculation completes
        widget.themeProvider?.colorSchemeFuture.then((value) => setState(() {
              _imageTheme = value;
            }));
      }
      _imageProvider = widget.cachedImage ??
          ref.read(albumImageProvider(AlbumImageRequest(
            item: widget.item,
            maxWidth: 100,
            maxHeight: 100,
          )));
    }
    super.initState();
    initialSheetExtent = widget.showPlaybackControls ? 0.6 : 0.45;
    oldExtent = initialSheetExtent;
  }

  /// Sets the item's favourite on the Jellyfin server.
  Future<void> toggleFavorite() async {
    try {
      final isOffline = FinampSettingsHelper.finampSettings.isOffline;

      if (isOffline) {
        FeedbackHelper.feedback(FeedbackType.error);
        GlobalSnackbar.message((context) =>
            AppLocalizations.of(context)!.notAvailableInOfflineMode);
        return;
      }

      final currentTrack = _queueService.getCurrentTrack();
      if (isBaseItemInQueueItem(widget.item, currentTrack)) {
        await setFavourite(currentTrack!, context);
        FeedbackHelper.feedback(FeedbackType.success);
        return;
      }

      // We switch the widget state before actually doing the request to
      // make the app feel faster (without, there is a delay from the
      // user adding the favourite and the icon showing)
      setState(() {
        widget.item.userData!.isFavorite = !widget.item.userData!.isFavorite;
      });
      FeedbackHelper.feedback(FeedbackType.success);

      // Since we flipped the favourite state already, we can use the flipped
      // state to decide which API call to make
      final newUserData = widget.item.userData!.isFavorite
          ? await _jellyfinApiHelper.addFavourite(widget.item.id)
          : await _jellyfinApiHelper.removeFavourite(widget.item.id);

      if (!mounted) return;

      setState(() {
        widget.item.userData = newUserData;
      });
    } catch (e) {
      setState(() {
        widget.item.userData!.isFavorite = !widget.item.userData!.isFavorite;
      });
      FeedbackHelper.feedback(FeedbackType.error);
      GlobalSnackbar.error(e);
    }
  }

  void toggleSpeedMenu() {
    setState(() {
      showSpeedMenu = !showSpeedMenu;
    });
    if (dragController.isAttached) {
      scrollToExtent(dragController, showSpeedMenu ? inputStep : null);
    }
    FeedbackHelper.feedback(FeedbackType.selection);
  }

  bool shouldShowSpeedControls(
      double currentSpeed, MetadataProvider? metadata) {
    if (currentSpeed != 1.0 ||
        FinampSettingsHelper.finampSettings.playbackSpeedVisibility ==
            PlaybackSpeedVisibility.visible) {
      return true;
    }

    if (FinampSettingsHelper.finampSettings.playbackSpeedVisibility ==
        PlaybackSpeedVisibility.automatic) {
      return metadata?.qualifiesForPlaybackSpeedControl ?? false;
    }

    return false;
  }

  void scrollToExtent(
      DraggableScrollableController scrollController, double? percentage) {
    var currentSize = scrollController.size;
    if ((percentage != null && currentSize < percentage) ||
        scrollController.size == inputStep) {
      scrollController.animateTo(
        percentage ?? oldExtent,
        duration: songMenuDefaultAnimationDuration,
        curve: songMenuDefaultInCurve,
      );
    }
    oldExtent = currentSize;
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData(colorScheme: _imageTheme),
      child: LayoutBuilder(builder: (context, constraints) {
        final menuEntries = _menuEntries(context);
        var stackHeight = widget.showPlaybackControls ? 255 : 155;
        stackHeight += menuEntries
                .where((element) =>
                    switch (element) { Visibility e => e.visible, _ => true })
                .length *
            56;
        var size = (stackHeight / constraints.maxHeight).clamp(0.4, 1.0);
        initialSheetExtent = size;

        if (Platform.isIOS || Platform.isAndroid) {
          return DraggableScrollableSheet(
            controller: dragController,
            snap: true,
            initialChildSize: size,
            minChildSize: size * 0.75,
            expand: false,
            builder: (context, scrollController) =>
                menu(context, scrollController, menuEntries),
          );
        } else {
          return SizedBox(
            // This is an overestimate of stack height on desktop, but this widget
            // needs some bottom padding on large displays anyway.
            height: stackHeight.toDouble(),
            child: menu(context, _controller, menuEntries),
          );
        }
      }),
    );
  }

  List<Widget> _menuEntries(BuildContext context) {
    final downloadsService = GetIt.instance<DownloadsService>();
    final downloadStatus = downloadsService.getStatus(
        DownloadStub.fromItem(type: DownloadItemType.song, item: widget.item),
        null);
    var iconColor = Theme.of(context).colorScheme.primary;

    String? parentTooltip;
    if (downloadStatus.isIncidental) {
      var parent = downloadsService.getFirstRequiringItem(DownloadStub.fromItem(
          type: DownloadItemType.song, item: widget.item));
      if (parent != null) {
        var parentName = AppLocalizations.of(context)!
            .itemTypeSubtitle(parent.baseItemType.name, parent.name);
        parentTooltip =
            AppLocalizations.of(context)!.incidentalDownloadTooltip(parentName);
      }
    }

    return [
      Visibility(
        visible: !widget.isOffline,
        child: ListTile(
          leading: Icon(
            Icons.playlist_add,
            color: iconColor,
          ),
          title: Text(AppLocalizations.of(context)!.addToPlaylistTitle),
          enabled: !widget.isOffline,
          onTap: () {
            Navigator.pop(context); // close menu
            Navigator.of(context).pushNamed(AddToPlaylistScreen.routeName,
                arguments: widget.item.id);
          },
        ),
      ),
      Visibility(
        visible: _queueService.getQueue().nextUp.isNotEmpty,
        child: ListTile(
          leading: Icon(
            TablerIcons.corner_right_down,
            color: iconColor,
          ),
          title: Text(AppLocalizations.of(context)!.playNext),
          onTap: () async {
            await _queueService.addNext(
                items: [widget.item],
                source: QueueItemSource(
                    type: QueueItemSourceType.nextUp,
                    name: const QueueItemSourceName(
                        type: QueueItemSourceNameType.nextUp),
                    id: widget.item.id));

            if (!context.mounted) return;

            GlobalSnackbar.message(
                (context) =>
                    AppLocalizations.of(context)!.confirmPlayNext("track"),
                isConfirmation: true);
            Navigator.pop(context);
          },
        ),
      ),
      ListTile(
        leading: Icon(
          TablerIcons.corner_right_down_double,
          color: iconColor,
        ),
        title: Text(AppLocalizations.of(context)!.addToNextUp),
        onTap: () async {
          await _queueService.addToNextUp(
              items: [widget.item],
              source: QueueItemSource(
                  type: QueueItemSourceType.nextUp,
                  name: const QueueItemSourceName(
                      type: QueueItemSourceNameType.nextUp),
                  id: widget.item.id));

          if (!context.mounted) return;

          GlobalSnackbar.message(
              (context) =>
                  AppLocalizations.of(context)!.confirmAddToNextUp("track"),
              isConfirmation: true);
          Navigator.pop(context);
        },
      ),
      ListTile(
        leading: Icon(
          TablerIcons.playlist,
          color: iconColor,
        ),
        title: Text(AppLocalizations.of(context)!.addToQueue),
        onTap: () async {
          await _queueService.addToQueue(
              items: [widget.item],
              source: QueueItemSource(
                  type: QueueItemSourceType.queue,
                  name: QueueItemSourceName(
                      type: QueueItemSourceNameType.preTranslated,
                      pretranslatedName: AppLocalizations.of(context)!.queue),
                  id: widget.item.id));

          if (!context.mounted) return;

          GlobalSnackbar.message(
              (context) => AppLocalizations.of(context)!.addedToQueue,
              isConfirmation: true);
          Navigator.pop(context);
        },
      ),
      Visibility(
        visible: widget.isInPlaylist &&
            widget.parentItem != null &&
            !widget.isOffline,
        child: ListTile(
          leading: Icon(
            Icons.playlist_remove,
            color: iconColor,
          ),
          title: Text(AppLocalizations.of(context)!.removeFromPlaylistTitle),
          enabled: widget.isInPlaylist &&
              widget.parentItem != null &&
              !widget.isOffline,
          onTap: () async {
            var removed = await removeFromPlaylist(
                context, widget.item, widget.parentItem!,
                confirm: widget.confirmPlaylistRemoval);
            if (removed) {
              if (widget.onRemoveFromList != null) {
                widget.onRemoveFromList!();
              }
              if (context.mounted) {
                Navigator.pop(context);
              }
            }
          },
        ),
      ),
      Visibility(
        visible: !widget.isOffline,
        child: ListTile(
          leading: Icon(
            Icons.explore,
            color: iconColor,
          ),
          title: Text(AppLocalizations.of(context)!.instantMix),
          enabled: !widget.isOffline,
          onTap: () async {
            await _audioServiceHelper.startInstantMixForItem(widget.item);

            if (!context.mounted) return;

            GlobalSnackbar.message(
                (context) => AppLocalizations.of(context)!.startingInstantMix,
                isConfirmation: true);
            Navigator.pop(context);
          },
        ),
      ),
      Visibility(
        visible: downloadStatus.isRequired,
        child: ListTile(
          leading: Icon(
            Icons.delete_outlined,
            color: iconColor,
          ),
          title: Text(AppLocalizations.of(context)!.deleteItem),
          enabled: downloadStatus.isRequired,
          onTap: () async {
            var item = DownloadStub.fromItem(
                type: DownloadItemType.song, item: widget.item);
            unawaited(downloadsService.deleteDownload(stub: item));
            if (mounted) {
              Navigator.pop(context);
            }
          },
        ),
      ),
      Visibility(
        visible: downloadStatus == DownloadItemStatus.notNeeded,
        child: ListTile(
          leading: Icon(
            Icons.file_download_outlined,
            color: iconColor,
          ),
          title: Text(AppLocalizations.of(context)!.downloadItem),
          enabled: !widget.isOffline &&
              downloadStatus == DownloadItemStatus.notNeeded,
          onTap: () async {
            var item = DownloadStub.fromItem(
                type: DownloadItemType.song, item: widget.item);
            await DownloadDialog.show(context, item, null);
            if (context.mounted) {
              Navigator.pop(context);
            }
          },
        ),
      ),
      Visibility(
        visible: downloadStatus.isIncidental,
        child: Tooltip(
          message: parentTooltip ?? "Widget shouldn't be visible",
          child: ListTile(
            leading: Icon(
              Icons.lock_outlined,
              color: widget.isOffline ? iconColor.withOpacity(0.3) : iconColor,
            ),
            title: Text(AppLocalizations.of(context)!.lockDownload),
            enabled: !widget.isOffline && downloadStatus.isIncidental,
            onTap: () async {
              var item = DownloadStub.fromItem(
                  type: DownloadItemType.song, item: widget.item);
              await DownloadDialog.show(context, item, null);
              if (context.mounted) {
                Navigator.pop(context);
              }
            },
          ),
        ),
      ),
      ListTile(
        enabled: !widget.isOffline,
        leading: widget.item.userData!.isFavorite
            ? Icon(
                Icons.favorite,
                color:
                    widget.isOffline ? iconColor.withOpacity(0.3) : iconColor,
              )
            : Icon(
                Icons.favorite_border,
                color:
                    widget.isOffline ? iconColor.withOpacity(0.3) : iconColor,
              ),
        title: Text(widget.item.userData!.isFavorite
            ? AppLocalizations.of(context)!.removeFavourite
            : AppLocalizations.of(context)!.addFavourite),
        onTap: () async {
          await toggleFavorite();
          if (context.mounted) Navigator.pop(context);
        },
      ),
      Visibility(
        visible: widget.canGoToAlbum,
        child: ListTile(
          leading: Icon(
            Icons.album,
            color: iconColor,
          ),
          title: Text(AppLocalizations.of(context)!.goToAlbum),
          enabled: widget.canGoToAlbum,
          onTap: () async {
            late BaseItemDto album;
            try {
              if (FinampSettingsHelper.finampSettings.isOffline) {
                final downloadsService = GetIt.instance<DownloadsService>();
                album = (await downloadsService.getCollectionInfo(
                        id: widget.item.albumId!))!
                    .baseItem!;
              } else {
                album =
                    await _jellyfinApiHelper.getItemById(widget.item.albumId!);
              }
            } catch (e) {
              GlobalSnackbar.error(e);
              return;
            }
            if (context.mounted) {
              Navigator.pop(context);
              await Navigator.of(context)
                  .pushNamed(AlbumScreen.routeName, arguments: album);
            }
          },
        ),
      ),
      Visibility(
        visible: widget.canGoToArtist,
        child: ListTile(
          leading: Icon(
            Icons.person,
            color: iconColor,
          ),
          title: Text(AppLocalizations.of(context)!.goToArtist),
          enabled: widget.canGoToArtist,
          onTap: () async {
            late BaseItemDto artist;
            try {
              if (FinampSettingsHelper.finampSettings.isOffline) {
                final downloadsService = GetIt.instance<DownloadsService>();
                artist = (await downloadsService.getCollectionInfo(
                        id: widget.item.artistItems!.first.id))!
                    .baseItem!;
              } else {
                artist = await _jellyfinApiHelper
                    .getItemById(widget.item.artistItems!.first.id);
              }
            } catch (e) {
              GlobalSnackbar.error(e);
              return;
            }
            if (context.mounted) {
              Navigator.pop(context);
              await Navigator.of(context)
                  .pushNamed(ArtistScreen.routeName, arguments: artist);
            }
          },
        ),
      ),
      Visibility(
        visible: widget.canGoToGenre,
        child: ListTile(
          leading: Icon(
            Icons.category_outlined,
            color: iconColor,
          ),
          title: Text(AppLocalizations.of(context)!.goToGenre),
          enabled: widget.canGoToGenre,
          onTap: () async {
            late BaseItemDto genre;
            try {
              if (FinampSettingsHelper.finampSettings.isOffline) {
                final downloadsService = GetIt.instance<DownloadsService>();
                genre = (await downloadsService.getCollectionInfo(
                        id: widget.item.genreItems!.first.id))!
                    .baseItem!;
              } else {
                genre = await _jellyfinApiHelper
                    .getItemById(widget.item.genreItems!.first.id);
              }
            } catch (e) {
              GlobalSnackbar.error(e);
              return;
            }
            if (context.mounted) {
              Navigator.pop(context);
              await Navigator.of(context)
                  .pushNamed(ArtistScreen.routeName, arguments: genre);
            }
          },
        ),
      ),
    ];
  }

  Widget menu(BuildContext context, ScrollController scrollController,
      List<Widget> menuEntries) {
    var iconColor = Theme.of(context).colorScheme.primary;
    return Consumer(builder: (context, ref, child) {
      final metadata = ref.watch(currentTrackMetadataProvider).unwrapPrevious();

      return Stack(
        children: [
          if (FinampSettingsHelper.finampSettings.useCoverAsBackground)
            BlurredPlayerScreenBackground(
                customImageProvider: _imageProvider,
                blurHash: widget.item.blurHash,
                opacityFactor: Theme.of(context).brightness == Brightness.dark
                    ? 1.0
                    : 1.0),
          CustomScrollView(
            controller: scrollController,
            slivers: [
              SliverPersistentHeader(
                delegate: SongMenuSliverAppBar(
                  item: widget.item,
                  headerImage: widget.usePlayerTheme ? _imageProvider : null,
                ),
                pinned: true,
              ),
              if (widget.showPlaybackControls)
                SongMenuMask(
                    child: StreamBuilder<PlaybackBehaviorInfo>(
                  stream: Rx.combineLatest3(
                      _queueService.getPlaybackOrderStream(),
                      _queueService.getLoopModeStream(),
                      _queueService.getPlaybackSpeedStream(),
                      (a, b, c) => PlaybackBehaviorInfo(a, b, c)),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const SliverToBoxAdapter();
                    }

                    final playbackBehavior = snapshot.data!;
                    const playbackOrderIcons = {
                      FinampPlaybackOrder.linear: TablerIcons.arrows_right,
                      FinampPlaybackOrder.shuffled: TablerIcons.arrows_shuffle,
                    };
                    final playbackOrderTooltips = {
                      FinampPlaybackOrder.linear: AppLocalizations.of(context)
                              ?.playbackOrderLinearButtonLabel ??
                          "Playing in order",
                      FinampPlaybackOrder.shuffled: AppLocalizations.of(context)
                              ?.playbackOrderShuffledButtonLabel ??
                          "Shuffling",
                    };
                    const loopModeIcons = {
                      FinampLoopMode.none: TablerIcons.repeat,
                      FinampLoopMode.one: TablerIcons.repeat_once,
                      FinampLoopMode.all: TablerIcons.repeat,
                    };
                    final loopModeTooltips = {
                      FinampLoopMode.none: AppLocalizations.of(context)
                              ?.loopModeNoneButtonLabel ??
                          "Looping off",
                      FinampLoopMode.one: AppLocalizations.of(context)
                              ?.loopModeOneButtonLabel ??
                          "Looping this song",
                      FinampLoopMode.all: AppLocalizations.of(context)
                              ?.loopModeAllButtonLabel ??
                          "Looping all",
                    };

                    var sliverArray = [
                      PlaybackAction(
                        icon: playbackOrderIcons[playbackBehavior.order]!,
                        onPressed: () async {
                          _queueService.togglePlaybackOrder();
                        },
                        tooltip: playbackOrderTooltips[playbackBehavior.order]!,
                        iconColor: playbackBehavior.order ==
                                FinampPlaybackOrder.shuffled
                            ? iconColor
                            : Theme.of(context).textTheme.bodyMedium?.color ??
                                Colors.white,
                      ),
                      ValueListenableBuilder<Timer?>(
                        valueListenable: _audioHandler.sleepTimer,
                        builder: (context, timerValue, child) {
                          final remainingMinutes =
                              (_audioHandler.sleepTimerRemaining.inSeconds /
                                      60.0)
                                  .ceil();
                          return PlaybackAction(
                            icon: timerValue != null
                                ? TablerIcons.hourglass_high
                                : TablerIcons.hourglass_empty,
                            onPressed: () async {
                              if (timerValue != null) {
                                await showDialog(
                                  context: context,
                                  builder: (context) =>
                                      const SleepTimerCancelDialog(),
                                );
                              } else {
                                await showDialog(
                                  context: context,
                                  builder: (context) =>
                                      const SleepTimerDialog(),
                                );
                              }
                            },
                            tooltip: timerValue != null
                                ? AppLocalizations.of(context)
                                        ?.sleepTimerRemainingTime(
                                            remainingMinutes) ??
                                    "Sleeping in $remainingMinutes minutes"
                                : AppLocalizations.of(context)!
                                    .sleepTimerTooltip,
                            iconColor: timerValue != null
                                ? iconColor
                                : Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.color ??
                                    Colors.white,
                          );
                        },
                      ),
                      // [Playback speed widget will be added here if conditions are met]
                      PlaybackAction(
                        icon: loopModeIcons[playbackBehavior.loop]!,
                        onPressed: () async {
                          _queueService.toggleLoopMode();
                        },
                        tooltip: loopModeTooltips[playbackBehavior.loop]!,
                        iconColor: playbackBehavior.loop == FinampLoopMode.none
                            ? Theme.of(context).textTheme.bodyMedium?.color ??
                                Colors.white
                            : iconColor,
                      ),
                    ];

                    final speedWidget = PlaybackAction(
                      icon: TablerIcons.brand_speedtest,
                      onPressed: () {
                        toggleSpeedMenu();
                      },
                      tooltip: AppLocalizations.of(context)!
                          .playbackSpeedButtonLabel(playbackBehavior.speed),
                      iconColor: playbackBehavior.speed == 1.0
                          ? Theme.of(context).textTheme.bodyMedium?.color ??
                              Colors.white
                          : iconColor,
                    );

                    if (speedWidgetWasVisible ||
                        shouldShowSpeedControls(
                            playbackBehavior.speed, metadata.value)) {
                      speedWidgetWasVisible = true;
                      sliverArray.insertAll(2, [speedWidget]);
                    }

                    return SliverCrossAxisGroup(
                      slivers: sliverArray,
                    );
                  },
                )),
              SliverToBoxAdapter(
                child: AnimatedSwitcher(
                  duration: songMenuDefaultAnimationDuration,
                  switchInCurve: songMenuDefaultInCurve,
                  switchOutCurve: songMenuDefaultOutCurve,
                  transitionBuilder: (child, animation) {
                    return SizeTransition(sizeFactor: animation, child: child);
                  },
                  child: showSpeedMenu ? SpeedMenu(iconColor: iconColor) : null,
                ),
              ),
              SongMenuMask(
                child: SliverPadding(
                  padding: const EdgeInsets.only(left: 8.0),
                  sliver: SliverList(
                    delegate: SliverChildListDelegate(menuEntries),
                  ),
                ),
              )
            ],
          ),
        ],
      );
    });
  }

  @override
  void dispose() {
    widget.themeProvider?.dispose();
    super.dispose();
  }
}

class SongMenuSliverAppBar extends SliverPersistentHeaderDelegate {
  BaseItemDto item;
  ImageProvider? headerImage;

  SongMenuSliverAppBar({
    required this.item,
    this.headerImage,
  });

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return _SongInfo(
      item: item,
      headerImage: headerImage,
    );
  }

  @override
  double get maxExtent => 150;

  @override
  double get minExtent => 150;

  @override
  bool shouldRebuild(covariant SliverPersistentHeaderDelegate oldDelegate) =>
      true;
}

class _SongInfo extends ConsumerStatefulWidget {
  const _SongInfo({
    required this.item,
    this.headerImage,
  });

  final BaseItemDto item;
  final ImageProvider? headerImage;

  @override
  ConsumerState<_SongInfo> createState() => _SongInfoState();
}

class _SongInfoState extends ConsumerState<_SongInfo> {
  // Wrap a static imageProvider to give to AlbumImage  Do not watch player image
  // provider because the song menu does not update on track changes.
  static final _imageProvider = Provider.autoDispose
      .family<ImageProvider, ImageProvider>((ref, value) => value);

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.transparent,
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 12.0),
          height: 120,
          clipBehavior: Clip.antiAlias,
          decoration: ShapeDecoration(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.black.withOpacity(0.25)
                : Colors.white.withOpacity(0.15),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 120,
                height: 120,
                child: AlbumImage(
                  // Only supply one of item or imageListenable
                  item: widget.headerImage == null ? widget.item : null,
                  imageListenable: widget.headerImage == null
                      ? null
                      : _imageProvider(widget.headerImage!),
                  borderRadius: BorderRadius.zero,
                ),
              ),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.item.name ??
                            AppLocalizations.of(context)!.unknownName,
                        textAlign: TextAlign.start,
                        style: TextStyle(
                          fontSize: 18,
                          height: 1.2,
                          color:
                              Theme.of(context).textTheme.bodyMedium?.color ??
                                  Colors.white,
                        ),
                        overflow: TextOverflow.ellipsis,
                        softWrap: true,
                        maxLines: 2,
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2.0),
                        child: ArtistChips(
                          baseItem: widget.item,
                          backgroundColor: IconTheme.of(context)
                                  .color
                                  ?.withOpacity(0.1) ??
                              Theme.of(context).textTheme.bodyMedium?.color ??
                              Colors.white,
                          color:
                              Theme.of(context).textTheme.bodyMedium?.color ??
                                  Colors.white,
                        ),
                      ),
                      AlbumChip(
                        item: widget.item,
                        color: Theme.of(context).textTheme.bodyMedium?.color ??
                            Colors.white,
                        backgroundColor:
                            IconTheme.of(context).color?.withOpacity(0.1) ??
                                Theme.of(context).textTheme.bodyMedium?.color ??
                                Colors.white,
                        key: widget.item.album == null
                            ? null
                            : ValueKey("${widget.item.album}-album"),
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

class PlaybackAction extends StatelessWidget {
  const PlaybackAction({
    super.key,
    required this.icon,
    this.value,
    required this.onPressed,
    required this.tooltip,
    required this.iconColor,
  });

  final IconData icon;
  final String? value;
  final Function() onPressed;
  final String tooltip;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: IconButton(
        icon: Column(
          children: [
            Icon(
              icon,
              color: iconColor,
              size: 35,
              weight: 1.0,
            ),
            const SizedBox(height: 9),
            SizedBox(
              height: 2 * 12 * 1.4 + 2,
              child: Align(
                alignment: Alignment.topCenter,
                child: Text(
                  tooltip,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.fade,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    fontWeight: FontWeight.w300,
                  ),
                ),
              ),
            ),
          ],
        ),
        onPressed: () {
          FeedbackHelper.feedback(FeedbackType.success);
          onPressed();
        },
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.only(
            top: 12.0, left: 12.0, right: 12.0, bottom: 16.0),
        tooltip: tooltip,
      ),
    );
  }
}

class SongMenuMask extends SingleChildRenderObjectWidget {
  const SongMenuMask({
    super.key,
    super.child,
  });

  @override
  RenderSongMenuMask createRenderObject(BuildContext context) {
    return RenderSongMenuMask();
  }
}

class RenderSongMenuMask extends RenderProxySliver {
  @override
  ShaderMaskLayer? get layer => super.layer as ShaderMaskLayer?;

  @override
  bool get alwaysNeedsCompositing => child != null;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child != null) {
      layer ??= ShaderMaskLayer(
          shader: const LinearGradient(colors: [
            Color.fromARGB(0, 255, 255, 255),
            Color.fromARGB(255, 255, 255, 255)
          ], begin: Alignment.topCenter, end: Alignment.bottomCenter)
              .createShader(const Rect.fromLTWH(0, 135, 0, 10)),
          blendMode: BlendMode.modulate,
          maskRect: const Rect.fromLTWH(0, 0, 99999, 150));

      context.pushLayer(layer!, super.paint, offset);
    } else {
      layer = null;
    }
  }
}
