#!/bin/sh
# Builds the TensorRT engine for jetbot.ObjectDetector (SSDlite320 backbone + head, FP16, about 10 min).
# Run as the normal user; asks for the sudo password for the engine build (GPU watchdog, see docs/tensorrt.md).
set -e
cd ~/jetbot
~/torch-venv/bin/python -c "import jetbot; jetbot.export_detector_onnx('ssdlite320.onnx')"
sudo nano-trt build ssdlite320.onnx ssdlite320.engine
sudo chown "$(id -u):$(id -g)" ssdlite320.engine
echo "done: ObjectDetector uses TensorRT from now on (restart running notebooks)"
