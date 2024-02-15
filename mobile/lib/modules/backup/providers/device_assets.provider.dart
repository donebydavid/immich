import 'package:immich_mobile/modules/backup/models/backup_album.model.dart';
import 'package:immich_mobile/modules/backup/models/device_album_state.model.dart';
import 'package:immich_mobile/shared/models/device_asset.dart';
import 'package:immich_mobile/shared/providers/db.provider.dart';
import 'package:isar/isar.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'device_assets.provider.g.dart';

@riverpod
class DeviceAssets extends _$DeviceAssets {
  @override
  Future<DeviceAssetState> build() async {
    final db = ref.read(dbProvider);
    return DeviceAssetState(
      assetIdsForBackup: await db.deviceAssets
          .filter()
          .backupSelectionEqualTo(BackupSelection.select)
          .idProperty()
          .findAll(),
    );
  }
}
