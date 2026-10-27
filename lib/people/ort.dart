import 'dart:typed_data';

import 'package:flutter/services.dart';

/// One named input or output of a model: float32 or uint8, any shape.
class Tensor {
  Tensor(this.name, this.shape, this.data, {this.float = true});

  Tensor.f32(String name, List<int> shape, Float32List values)
    : this(name, shape, values.buffer.asUint8List(values.offsetInBytes, values.lengthInBytes));

  final String name;
  final List<int> shape;
  final Uint8List data; // the values' bytes, native (little-endian) order
  final bool float; // false: uint8

  /// The values as floats (copied if the bytes aren't 4-aligned).
  Float32List get floats {
    final d = data.offsetInBytes % 4 == 0 ? data : Uint8List.fromList(data);
    return d.buffer.asFloat32List(d.offsetInBytes, d.lengthInBytes ~/ 4);
  }
}

/// Runs an ONNX model file on some inputs.
abstract class OrtRunner {
  Future<List<Tensor>> run(String model, List<Tensor> inputs);

  /// Lets go of the loaded models.
  Future<void> close();
}

/// [OrtRunner] on the phone (OrtChannel.kt, ONNX Runtime).
class OrtChannel implements OrtRunner {
  OrtChannel._();
  static final instance = OrtChannel._();

  static const _m = MethodChannel('shotdrop/ort');

  @override
  Future<List<Tensor>> run(String model, List<Tensor> inputs) async {
    final out = await _m.invokeListMethod<Object?>('run', {
      'model': model,
      'inputs': [
        for (final t in inputs) {'name': t.name, 'type': t.float ? 'f32' : 'u8', 'shape': t.shape, 'data': t.data},
      ],
    });
    return [
      for (final o in out ?? const [])
        if (o is Map)
          Tensor(
            o['name'] as String,
            [for (final d in o['shape'] as List) (d as num).toInt()],
            o['data'] as Uint8List,
            float: o['type'] == 'f32',
          ),
    ];
  }

  @override
  Future<void> close() => _m.invokeMethod('close');
}
