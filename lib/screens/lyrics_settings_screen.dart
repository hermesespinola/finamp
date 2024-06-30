import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:hive/hive.dart';

import '../components/LayoutSettingsScreen/player_screen_minimum_cover_padding_editor.dart';
import '../models/finamp_models.dart';
import '../services/finamp_settings_helper.dart';

class LyricsSettingsScreen extends StatelessWidget {
  const LyricsSettingsScreen({super.key});

  static const routeName = "/settings/lyrics";

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context)!.lyricsScreen),
      ),
      body: ListView(
        children: const [
          ShowLyricsTimestampsToggle(),
          LyricsAlignmentSelector(),
          KeepScreenAwakeToggle(),
        ],
      ),
    );
  }
}

class ShowLyricsTimestampsToggle extends StatelessWidget {
  const ShowLyricsTimestampsToggle({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Box<FinampSettings>>(
      valueListenable: FinampSettingsHelper.finampSettingsListener,
      builder: (context, box, child) {
        bool? showLyricsTimestamps =
            box.get("FinampSettings")?.showLyricsTimestamps;

        return SwitchListTile.adaptive(
          title: Text(AppLocalizations.of(context)!.showLyricsTimestampsTitle),
          subtitle:
              Text(AppLocalizations.of(context)!.showLyricsTimestampsSubtitle),
          value: showLyricsTimestamps ?? false,
          onChanged: showLyricsTimestamps == null
              ? null
              : (value) {
                  FinampSettings finampSettingsTemp =
                      box.get("FinampSettings")!;
                  finampSettingsTemp.showLyricsTimestamps = value;
                  box.put("FinampSettings", finampSettingsTemp);
                },
        );
      },
    );
  }
}

class LyricsAlignmentSelector extends StatelessWidget {
  const LyricsAlignmentSelector({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Box<FinampSettings>>(
      valueListenable: FinampSettingsHelper.finampSettingsListener,
      builder: (_, box, __) {
        final finampSettings = box.get("FinampSettings")!;
        return ListTile(
          title: Text(AppLocalizations.of(context)!.lyricsAlignmentTitle),
          subtitle: Text(AppLocalizations.of(context)!.lyricsAlignmentSubtitle),
          trailing: DropdownButton<LyricsAlignment>(
            value: finampSettings.lyricsAlignment,
            items: LyricsAlignment.values
                .map((e) => DropdownMenuItem<LyricsAlignment>(
                      value: e,
                      child: Text(e.toLocalisedString(context)),
                    ))
                .toList(),
            onChanged: (value) {
              if (value != null) {
                FinampSettings finampSettingsTemp = finampSettings;
                finampSettingsTemp.lyricsAlignment = value;
                Hive.box<FinampSettings>("FinampSettings")
                    .put("FinampSettings", finampSettingsTemp);
              }
            },
          ),
        );
      },
    );
  }
}

class KeepScreenAwakeToggle extends StatelessWidget {
  const KeepScreenAwakeToggle({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Box<FinampSettings>>(
      valueListenable: FinampSettingsHelper.finampSettingsListener,
      builder: (context, box, child) {
        bool? showLyricsTimestamps =
            box.get("FinampSettings")?.keepScreenAwakeInLyrics;

        return SwitchListTile.adaptive(
          title: Text(AppLocalizations.of(context)!.keepScreenAwakeInLyricsScreenTitile),
          subtitle:
              Text(AppLocalizations.of(context)!.keepScreenAwakeInLyricsScreenSubtitle),
          value: keepScreenAwakeInLyrics ?? false,
          onChanged: keepScreenAwakeInLyrics == null
              ? null
              : (value) {
                  FinampSettings finampSettingsTemp =
                      box.get("FinampSettings")!;
                  finampSettingsTemp.keepScreenAwakeInLyrics = value;
                  box.put("FinampSettings", finampSettingsTemp);
                },
        );
      },
    );
  }
}
