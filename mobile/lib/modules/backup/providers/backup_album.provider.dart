import 'package:immich_mobile/extensions/album_extensions.dart';
import 'package:immich_mobile/modules/album/models/album.model.dart';
import 'package:immich_mobile/modules/backup/models/backup_album.model.dart';
import 'package:immich_mobile/modules/backup/models/backup_album_state.model.dart';
import 'package:immich_mobile/modules/backup/providers/device_assets.provider.dart';
import 'package:immich_mobile/shared/models/asset.dart';
import 'package:immich_mobile/shared/models/device_asset.dart';
import 'package:immich_mobile/shared/providers/db.provider.dart';
import 'package:isar/isar.dart';
import 'package:logging/logging.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'backup_album.provider.g.dart';

@riverpod
class BackupAlbums extends _$BackupAlbums {
  final Logger _logger = Logger("BackupAlbumsProvider");

  @override
  Future<BackupAlbumState> build() async {
    final db = ref.read(dbProvider);
    return BackupAlbumState(
      selectedBackupAlbums: await db.backupAlbums
          .filter()
          .selectionEqualTo(BackupSelection.select)
          .findAll(),
      excludedBackupAlbums: await db.backupAlbums
          .filter()
          .selectionEqualTo(BackupSelection.exclude)
          .findAll(),
    );
  }

  Future<void> addBackupAlbum(
    LocalAlbum album,
    BackupSelection selection,
  ) async {
    final db = ref.read(dbProvider);
    final albumInDB =
        await db.backupAlbums.filter().idEqualTo(album.id).findFirst();

    final backupAlbum = albumInDB ??
        BackupAlbum(
          id: album.id,
          lastBackup: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
          selection: selection,
        );

    backupAlbum.selection = selection;
    backupAlbum.album.value = album;

    final assets = await _updateDeviceAssetsToSelection(album, selection);

    await db.writeTxn(() async {
      await db.backupAlbums.store(backupAlbum);
      await db.deviceAssets.putAll(assets);
    });

    ref.invalidateSelf();
  }

  Future<void> syncWithLocalAlbum(LocalAlbum album) async {
    final db = ref.read(dbProvider);
    final albumInDB =
        await db.backupAlbums.filter().idEqualTo(album.id).findFirst();
    if (albumInDB == null) {
      _logger.fine("No backup album for local album - ${album.name}");
      return;
    }
    albumInDB.album.value = album;

    final assets =
        await _updateDeviceAssetsToSelection(album, albumInDB.selection);

    await db.writeTxn(() async {
      await db.backupAlbums.store(albumInDB);
      await db.deviceAssets.putAll(assets);
    });

    ref.invalidateSelf();
  }

  Future<void> _updateAlbumSelection(
    LocalAlbum localAlbum,
    BackupSelection selection,
  ) async {
    await localAlbum.backup.load();
    final backupAlbum = localAlbum.backup.value;

    if (backupAlbum == null) {
      return addBackupAlbum(localAlbum, selection);
    }

    final db = ref.read(dbProvider);
    backupAlbum.selection = selection;

    final assets = await _updateDeviceAssetsToSelection(localAlbum, selection);

    await db.writeTxn(() async {
      await db.backupAlbums.store(backupAlbum);
      await db.deviceAssets.putAll(assets);
    });

    ref.invalidateSelf();
  }

  Future<void> selectAlbumForBackup(LocalAlbum album) =>
      _updateAlbumSelection(album, BackupSelection.select);

  Future<void> excludeAlbumFromBackup(LocalAlbum album) =>
      _updateAlbumSelection(album, BackupSelection.exclude);

  Future<void> deSelectAlbum(LocalAlbum album) =>
      _updateAlbumSelection(album, BackupSelection.none);

  Future<List<LocalAlbum>> _getAllLocalAlbumWithAsset(Asset asset) async {
    return await ref
        .read(dbProvider)
        .localAlbums
        .filter()
        .assets((q) => q.idEqualTo(asset.id))
        .findAll();
  }

  Future<List<DeviceAsset>> _updateDeviceAssetsToSelection(
    LocalAlbum album,
    BackupSelection selection,
  ) async {
    await album.assets.load();
    final assets = album.assets.toList();
    final updatedAssets = <DeviceAsset>[];

    for (final asset in assets) {
      if (!asset.isLocal) {
        _logger.warning("Local id not available for asset ID - ${asset.id}");
        continue;
      }
      final deviceAsset = await ref
          .read(dbProvider)
          .deviceAssets
          .where()
          .idEqualTo(asset.localId!)
          .findFirst();
      if (deviceAsset == null) {
        _logger.warning(
          "Device asset not available for local asset ID - ${asset.id}",
        );
        continue;
      }

      // Exclude takes priority
      if (selection == BackupSelection.exclude) {
        deviceAsset.backupSelection = selection;
      } else if (selection == BackupSelection.select) {
        bool shouldExclude = false;
        final localAlbums = await _getAllLocalAlbumWithAsset(asset);
        for (final a in localAlbums) {
          await a.backup.load();
          // Check if there is any other excluded albums in which the asset is present
          if (a.backup.value?.selection == BackupSelection.exclude &&
              a.id != album.id) {
            shouldExclude = true;
            break;
          }
        }

        // Force exclude ignoring selection if asset is part of another excluded album
        deviceAsset.backupSelection =
            shouldExclude ? BackupSelection.exclude : BackupSelection.select;
      } else if (selection == BackupSelection.none) {
        bool setToNone = true;
        BackupSelection? oldSelection;
        final localAlbums = await _getAllLocalAlbumWithAsset(asset);
        for (final a in localAlbums) {
          await a.backup.load();
          // Check if there is any other albums in which the asset is present
          if (a.backup.value?.selection != BackupSelection.none &&
              a.id != album.id) {
            setToNone = false;
            oldSelection = a.backup.value?.selection;
            break;
          }
        }

        // Only set to none when the asset is not part of any other selected or excluded albums
        if (setToNone) {
          deviceAsset.backupSelection = BackupSelection.none;
        } else if (oldSelection != null) {
          deviceAsset.backupSelection = oldSelection;
        }
      }

      updatedAssets.add(deviceAsset);
    }

    if (updatedAssets.isNotEmpty) {
      ref.invalidate(deviceAssetsProvider);
    }

    return updatedAssets;
  }
}
