import 'dart:developer';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

class MyML extends StatefulWidget {
  const MyML({super.key});

  @override
  State<MyML> createState() => _MyMLState();
}

class _MyMLState extends State<MyML> {
  final imagePicker = ImagePicker();

  ObjectDetection? objectDetection;

  Uint8List? image;

  @override
  void initState() {
    super.initState();
    objectDetection = ObjectDetection();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: Center(
                child: (image != null) ? Image.memory(image!) : Container(),
              ),
            ),
            SizedBox(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  if (Platform.isAndroid || Platform.isIOS)
                    IconButton(
                      onPressed: () async {
                        final result = await imagePicker.pickImage(
                          source: ImageSource.camera,
                        );
                        if (result != null) {
                          image = objectDetection!.analyseImage(result.path);
                          setState(() {});
                        }
                      },
                      icon: const Icon(
                        Icons.camera,
                        size: 64,
                      ),
                    ),
                  IconButton(
                    onPressed: () async {
                      final result = await imagePicker.pickImage(
                        source: ImageSource.gallery,
                      );
                      if (result != null) {
                        image = objectDetection!.analyseImage(result.path);
                        setState(() {});
                      }
                    },
                    icon: const Icon(
                      Icons.photo,
                      size: 64,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ObjectDetection {
  static const String _modelPath =
      'assets/models/custom_ssd_mobilenet_v2.tflite';
  static const String _labelPath = 'assets/models/labelmap.txt';

  Interpreter? _interpreter;
  List<String>? _labels;

  ObjectDetection() {
    _loadModel();
    _loadLabels();
    log('Done.');
  }

  Future<void> _loadModel() async {
    log('Loading interpreter options...');
    final interpreterOptions = InterpreterOptions();

    // Use XNNPACK Delegate
    if (Platform.isAndroid) {
      interpreterOptions.addDelegate(XNNPackDelegate());
    }

    // Use Metal Delegate
    if (Platform.isIOS) {
      interpreterOptions.addDelegate(GpuDelegate());
    }

    log('Loading interpreter...');
    _interpreter =
        await Interpreter.fromAsset(_modelPath, options: interpreterOptions);
  }

  Future<void> _loadLabels() async {
    log('Loading labels...');
    final labelsRaw = await rootBundle.loadString(_labelPath);
    _labels = labelsRaw.split('\n');
  }

  Uint8List analyseImage(String imagePath) {
    log('Analysing image...');
    // Reading image bytes from file
    final imageData = File(imagePath).readAsBytesSync();

    // Decoding image
    final image = img.decodeImage(imageData);

    // Resizing image fpr model, [300, 300]
    final imageInput = img.copyResize(
      image!,
      width: 300,
      height: 300,
    );

    // Creating matrix representation, [300, 300, 3]
    final imageMatrix = List.generate(
      imageInput.height,
      (y) => List.generate(
        imageInput.width,
        (x) {
          final pixel = imageInput.getPixel(x, y);
          return [pixel.r, pixel.g, pixel.b];
        },
      ),
    );

    final output = _runInference(imageMatrix);

    // Process Tensors from the output
    final scoresTensor = output[0].first as List<double>;
    final boxesTensor = output[1].first as List<List<double>>;
    final classesTensor = output[3].first as List<double>;

    log('Processing outputs...');

    // Process bounding boxes
    final List<List<int>> locations = boxesTensor
        .map((box) => box.map((value) => ((value * 300).toInt())).toList())
        .toList();

    // Convert class indices to int
    final classes = classesTensor.map((value) => value.toInt()).toList();

    // Number of detections
    final numberOfDetections = output[2].first as double;

    // Get classifcation with label
    final List<String> classification = [];
    for (int i = 0; i < numberOfDetections; i++) {
      classification.add(_labels![classes[i]]);
    }

    log('Outlining objects...');
    for (var i = 0; i < numberOfDetections; i++) {
      if (scoresTensor[i] > 0.85) {
        // Rectangle drawing
        img.drawRect(
          imageInput,
          x1: locations[i][1],
          y1: locations[i][0],
          x2: locations[i][3],
          y2: locations[i][2],
          color: img.ColorRgb8(0, 255, 0),
          thickness: 3,
        );

        // Label drawing
        img.drawString(
          imageInput,
          '${classification[i]} ${scoresTensor[i]}',
          font: img.arial14,
          x: locations[i][1] + 7,
          y: locations[i][0] + 7,
          color: img.ColorRgb8(0, 255, 0),
        );
      }
    }

    log('Done.');
    return img.encodeJpg(imageInput);
  }

  List<List<Object>> _runInference(
    List<List<List<num>>> imageMatrix,
  ) {
    log('Running inference...');

    // Set input tensor [1, 256, 256, 3]
    final input = [imageMatrix];

    // Set output tensor
    // Locations: [1, 10, 4]
    // Classes: [1, 10],
    // Scores: [1, 10],
    // Number of detections: [1]
    final output = {
      0: [List<num>.filled(10, 0)],
      1: [List<List<num>>.filled(10, List<num>.filled(4, 0))],
      2: [0.0],
      3: [List<num>.filled(10, 0)],
    };

    _interpreter!.runForMultipleInputs([input], output);
    return output.values.toList();
  }
}