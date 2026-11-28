import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import '../../domain/classifier/model_bundle.dart';

/// Loads the shipped model assets (labels.json + weights.json) and
/// assembles a validated [ModelBundle]. A missing or corrupt asset —
/// including a model trained for the other hand — yields null, and the
/// app falls back to the C1 threshold rules. The app must work with no
/// model present.
class ModelAssetLoader {
  ModelAssetLoader([AssetBundle? bundle]) : _bundle = bundle ?? rootBundle;

  final AssetBundle _bundle;

  static const String labelsPath = 'assets/models/labels.json';
  static const String weightsPath = 'assets/models/weights.json';

  /// Two-hand model (Both mode recordings, labels hand 'LR'); optional.
  static const String twoLabelsPath = 'assets/models/labels_two.json';
  static const String twoWeightsPath = 'assets/models/weights_two.json';

  Future<ModelBundle?> load(
      [String labelsAsset = labelsPath,
      String weightsAsset = weightsPath]) async {
    try {
      final labels = await _bundle.loadString(labelsAsset);
      final weights = await _bundle.loadString(weightsAsset);
      return ModelBundle.assemble(labels, weights);
    } catch (_) {
      // FlutterError from loadString (asset absent) or an assemble null —
      // both mean "no usable model": threshold rules take over.
      return null;
    }
  }
}
