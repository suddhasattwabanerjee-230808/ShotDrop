import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'remove_people.dart';

/// A model Remove People & Objects downloads once: from a fixed revision on Hugging
/// Face, checked against its size and SHA-256.
class ModelFile {
  const ModelFile(this.name, this.url, this.bytes, this.sha256);
  final String name, url, sha256;
  final int bytes;
}

/// The people models, all from OpenCV Zoo (Apache 2.0).
const finderModel = ModelFile(
  'person_finder_yolox_s_int8.onnx',
  'https://huggingface.co/opencv/object_detection_yolox/resolve/78c368f74ce73ee28fc7a1be418a598c71b58b52/object_detection_yolox_2022nov_int8.onnx',
  9079452,
  '01a3b0f400b30bc1e45230e991b2e499ab42622485a330021947333fbaf03935',
);
const outlinerModel = ModelFile(
  'person_outline_pphumanseg.onnx',
  'https://huggingface.co/opencv/human_segmentation_pphumanseg/resolve/e876e63603f6c65c1a22576bfd5fc7c07ecf9eb9/human_segmentation_pphumanseg_2023mar.onnx',
  6163938,
  '552d8a984054e59b5d773d24b9b12022b22046ceb2bbc4c9aaeaceb36a9ddf24',
);
const painterModel = ModelFile(
  'background_painter_lama.onnx',
  'https://huggingface.co/opencv/inpainting_lama/resolve/aee6d22f0a13e5e35af1c9a1c3afd62841fc6f3f/inpainting_lama_2025jan.onnx',
  92591623,
  '7df918ac3921d3daf0aae1d219776cf0dc4e4935f035af81841b40adcf74fdf2',
);

/// D-FINE-S on Objects365 (Apache 2.0), int8, as ONNX by onnx-community.
const thingFinderModel = ModelFile(
  'thing_finder_dfine_s_obj365_int8.onnx',
  'https://huggingface.co/onnx-community/dfine_s_obj365-ONNX/resolve/a61e4cdfe4f9d3188a305d91e37dbf38688ffbb8/onnx/model_int8.onnx',
  11333721,
  '3355fe77be41bca48937cd5bb100de51e1bfd894e67275f6d398cfda35624838',
);

/// MobileSAM (Apache 2.0), as ONNX by Acly (MIT): the encoder looks at the
/// photo once, the decoder outlines each thing from its box.
const thingLookModel = ModelFile(
  'thing_outline_mobilesam_encoder.onnx',
  'https://huggingface.co/Acly/MobileSAM/resolve/0d3b403339b4674a82493d5e97964dd78089ddc8/mobile_sam_image_encoder.onnx',
  28157093,
  '580f5fb648ea1062c0aabc26217aed56921985f03f0cbbd852bba81d760cc749',
);
const thingOutlinerModel = ModelFile(
  'thing_outline_sam_decoder.onnx',
  'https://huggingface.co/Acly/MobileSAM/resolve/0d3b403339b4674a82493d5e97964dd78089ddc8/sam_mask_decoder_single.onnx',
  16501323,
  '93915fc7c993ab9d59ab8c9ccd3bce37f7509c81ab4150a74abd4d2abbd8570d',
);
const peopleModelFiles = [
  finderModel,
  outlinerModel,
  painterModel,
  thingFinderModel,
  thingLookModel,
  thingOutlinerModel,
];

/// Keeps the models in the app's own files (`models/`), which updates keep
/// and storage tidying never touches, so they download once.
class ModelStore {
  ModelStore({this._dir, HttpClient Function()? client, this.files = peopleModelFiles})
    : assert(files.length == 6),
      _client = client ?? HttpClient.new;

  static final instance = ModelStore();

  Directory? _dir;
  final HttpClient Function() _client;

  /// The finder, outliner and painter for people, then the finder, the
  /// look and the outliner for things, in that order.
  final List<ModelFile> files;

  Future<Directory> get dir async => _dir ??= Directory('${(await getApplicationSupportDirectory()).path}/models');

  Future<String> pathOf(ModelFile f) async => '${(await dir).path}/${f.name}';

  /// Whether every model is downloaded (by size; checked fully when fetched).
  Future<bool> ready() async => await missingBytes() == 0;

  /// How much is still to download.
  Future<int> missingBytes() async {
    var missing = 0;
    for (final f in files) {
      final file = File(await pathOf(f));
      if (!await file.exists() || await file.length() != f.bytes) missing += f.bytes;
    }
    return missing;
  }

  /// The models' paths, downloading whatever's missing first. [onProgress]
  /// gets bytes done and the total of what's missing, while downloading. A
  /// dropped download carries on from where it got to next time.
  Future<PeopleModels> ensure({void Function(int done, int total)? onProgress}) async {
    await (await dir).create(recursive: true);
    final total = await missingBytes();
    var before = 0;
    for (final f in files) {
      final path = await pathOf(f);
      final file = File(path);
      if (!await file.exists() || await file.length() != f.bytes) {
        await _fetch(f, path, (n) => onProgress?.call(before + n, total));
        before += f.bytes;
      }
    }
    return PeopleModels(
      finder: await pathOf(files[0]),
      outliner: await pathOf(files[1]),
      painter: await pathOf(files[2]),
      thingFinder: await pathOf(files[3]),
      thingLook: await pathOf(files[4]),
      thingOutliner: await pathOf(files[5]),
    );
  }

  Future<void> _fetch(ModelFile f, String path, void Function(int) onBytes) async {
    final part = File('$path.part');
    var have = await part.exists() ? await part.length() : 0;
    if (have > f.bytes) {
      await part.delete();
      have = 0;
    }
    if (have < f.bytes) {
      final client = _client()..connectionTimeout = const Duration(seconds: 20);
      try {
        final req = await client.getUrl(Uri.parse(f.url));
        if (have > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
        final res = await req.close();
        if (res.statusCode == HttpStatus.ok) {
          have = 0; // the server sent it all: start the file again
        } else if (res.statusCode != HttpStatus.partialContent) {
          throw HttpException('The download failed (${res.statusCode})', uri: Uri.parse(f.url));
        }
        final sink = part.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
        try {
          await for (final chunk in res.timeout(const Duration(seconds: 30))) {
            sink.add(chunk);
            have += chunk.length;
            onBytes(have);
          }
        } finally {
          await sink.close();
        }
      } finally {
        client.close(force: true);
      }
    }
    final digest = await sha256.bind(part.openRead()).first;
    if (await part.length() != f.bytes || digest.toString() != f.sha256) {
      await part.delete();
      throw const FileSystemException('The download was damaged; try again');
    }
    await part.rename(path);
  }
}
