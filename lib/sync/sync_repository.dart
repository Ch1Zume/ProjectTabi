import '../data/sample_pilgrimage_repository.dart';

/// Replace records atomically, retaining logical IDs and device-local settings.
abstract interface class SyncRepository {
  Future<void> replaceSyncSnapshot(SamplePilgrimageRepositorySnapshot snapshot);
}
