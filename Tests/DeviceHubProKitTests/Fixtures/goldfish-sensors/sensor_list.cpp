/*
 * Copyright (C) 2020 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "sensor_list.h"

namespace goldfish {
using ahs::V2_1::SensorType;
using ahs::V1_0::SensorFlagBits;

constexpr char kAospVendor[] = "The Android Open Source Project";

const char* const kQemuSensorName[] = {
    "acceleration",
    "gyroscope",
    "magnetic-field",
    "orientation",
    "temperature",
    "proximity",
    "light",
    "pressure",
    "humidity",
    "magnetic-field-uncalibrated",
    "gyroscope-uncalibrated",
    "hinge-angle0",
    "hinge-angle1",
    "hinge-angle2",
    "heart-rate",
    "rgbc-light",
    "wrist-tilt",
    "acceleration-uncalibrated",
};

const SensorInfo kAllSensors[] = {
    {
        .sensorHandle = kSensorHandleAccelerometer,
        .name = "Goldfish 3-axis Accelerometer",
        .vendor = kAospVendor,
        .version = 1,
        .type = SensorType::ACCELEROMETER,
        .typeAsString = "android.sensor.accelerometer",
        .maxRange = 39.3,
        .resolution = 1.0 / 4032.0,
        .power = 3.0,
        .minDelay = 10000,
        .fifoReservedEventCount = 0,
        .fifoMaxEventCount = 0,
        .requiredPermission = "",
        .maxDelay = 500000,
        .flags = SensorFlagBits::DATA_INJECTION |
                 SensorFlagBits::ADDITIONAL_INFO |
                 SensorFlagBits::CONTINUOUS_MODE
    },
    {
        .sensorHandle = kSensorHandleGyroscope,
        .name = "Goldfish 3-axis Gyroscope",
        .vendor = kAospVendor,
        .version = 1,
        .type = SensorType::GYROSCOPE,
        .typeAsString = "android.sensor.gyroscope",
        .maxRange = 16.46,
        .resolution = 1.0 / 1000.0,
        .power = 3.0,
        .minDelay = 10000,
        .fifoReservedEventCount = 0,
        .fifoMaxEventCount = 0,
        .requiredPermission = "",
        .maxDelay = 500000,
        .flags = SensorFlagBits::DATA_INJECTION |
                 SensorFlagBits::ADDITIONAL_INFO |
                 SensorFlagBits::CONTINUOUS_MODE
    },
    {
        .sensorHandle = kSensorHandleMagneticField,
        .name = "Goldfish 3-axis Magnetic field sensor",
        .vendor = kAospVendor,
        .version = 1,
        .type = SensorType::MAGNETIC_FIELD,
        .typeAsString = "android.sensor.magnetic_field",
        .maxRange = 2000.0,
        .resolution = .5,
        .power = 6.7,
        .minDelay = 10000,
        .fifoReservedEventCount = 0,
        .fifoMaxEventCount = 0,
        .requiredPermission = "",
        .maxDelay = 500000,
        .flags = SensorFlagBits::DATA_INJECTION |
                 SensorFlagBits::CONTINUOUS_MODE
    },
    {
        .sensorHandle = kSensorHandleOrientation,
        .name = "Goldfish Orientation sensor",
        .vendor = kAospVendor,
        .version = 1,
        .type = SensorType::ORIENTATION,
        .typeAsString = "android.sensor.orientation",
        .maxRange = 360.0,
        .resolution = 1.0,
        .power = 9.7,
        .minDelay = 10000,
        .fifoReservedEventCount = 0,
        .fifoMaxEventCount = 0,
        .requiredPermission = "",
        .maxDelay = 500000,
        .flags = SensorFlagBits::DATA_INJECTION |
                 SensorFlagBits::CONTINUOUS_MODE
    },
    {
        .sensorHandle = kSensorHandleAmbientTemperature,
        .name = "Goldfish Ambient Temperature sensor",
        .vendor = kAospVendor,
        .version = 1,
        .type = SensorType::AMBIENT_TEMPERATURE,
        .typeAsString = "android.sensor.ambient_temperature",
        .maxRange = 80.0,
        .resolution = 1.0,
        .power = 0.0,
        .minDelay = 0,
        .fifoReservedEventCount = 0,
        .fifoMaxEventCount = 0,
        .requiredPermission = "",
        .maxDelay = 0,
        .flags = SensorFlagBits::DATA_INJECTION |
                 SensorFlagBits::ON_CHANGE_MODE
    },
    {
        .sensorHandle = kSensorHandleProximity,
        .name = "Goldfish Proximity sensor",
        .vendor = kAospVendor,
        .version = 1,
        .type = SensorType::PROXIMITY,
        .typeAsString = "android.sensor.proximity",
        .maxRange = 1.0,
        .resolution = 1.0,
        .power = 20.0,
        .minDelay = 0,
        .fifoReservedEventCount = 0,
        .fifoMaxEventCount = 0,
        .requiredPermission = "",
        .maxDelay = 0,
        .flags = SensorFlagBits::DATA_INJECTION |
                 SensorFlagBits::ON_CHANGE_MODE |
                 SensorFlagBits::WAKE_UP
    },
    {
        .sensorHandle = kSensorHandleLight,
        .name = "Goldfish Light sensor",
        .vendor = kAospVendor,
        .version = 1,
        .type = SensorType::LIGHT,
        .typeAsString = "android.sensor.light",
        .maxRange = 40000.0,
        .resolution = 1.0,
        .power = 20.0,
        .minDelay = 0,
        .fifoReservedEventCount = 0,
        .fifoMaxEventCount = 0,
        .requiredPermission = "",
        .maxDelay = 0,
        .flags = SensorFlagBits::DATA_INJECTION |
                 SensorFlagBits::ON_CHANGE_MODE
    },
    {
        .sensorHandle = kSensorHandlePressure,
        .name = "Goldfish Pressure sensor",
        .vendor = kAospVendor,
        .version = 1,
        .type = SensorType::PRESSURE,
        .typeAsString = "android.sensor.pressure",
        .maxRange = 800.0,
        .resolution = 1.0,
        .power = 20.0,
        .minDelay = 10000,
        .fifoReservedEventCount = 0,
        .fifoMaxEventCount = 0,
        .requiredPermission = "",
        .maxDelay = 500000,
        .flags = SensorFlagBits::DATA_INJECTION |
                 SensorFlagBits::CONTINUOUS_MODE
    },
    {
        .sensorHandle = kSensorHandleRelativeHumidity,
        .name = "Goldfish Humidity sensor",
        .vendor = kAospVendor,
        .version = 1,
        .type = SensorType::RELATIVE_HUMIDITY,
        .typeAsString = "android.sensor.relative_humidity",
        .maxRange = 100.0,
        .resolution = 1.0,
        .power = 20.0,
        .minDelay = 0,
        .fifoReservedEventCount = 0,
        .fifoMaxEventCount = 0,
        .requiredPermission = "",
        .maxDelay = 0,
        .flags = SensorFlagBits::DATA_INJECTION |
                 SensorFlagBits::ON_CHANGE_MODE
    },
    {
        .sensorHandle = kSensorHandleMagneticFieldUncalibrated,
        .name = "Goldfish 3-axis Magnetic field sensor (uncalibrated)",
        .vendor = kAospVendor,
        .version = 1,
        .type = SensorType::MAGNETIC_FIELD_UNCALIBRATED,
        .typeAsString = "android.sensor.magnetic_field_uncalibrated",
        .maxRange = 2000.0,
        .resolution = 0.5,
        .power = 6.7,
        .minDelay = 10000,
        .fifoReservedEventCount = 0,
        .fifoMaxEventCount = 0,
        .requiredPermission = "",
        .maxDelay = 500000,
        .flags = SensorFlagBits::DATA_INJECTION | 0
    },
    {
        .sensorHandle = kSensorHandleGyroscopeFieldUncalibrated,
        .name = "Goldfish 3-axis Gyroscope (uncalibrated)",
        .vendor = kAospVendor,
        .version = 1,
        .type = SensorType::GYROSCOPE_UNCALIBRATED,
        .typeAsString = "android.sensor.gyroscope_uncalibrated",
        .maxRange = 16.46,
        .resolution = 1.0 / 1000.0,
        .power = 3.0,
        .minDelay = 10000,
        .fifoReservedEventCount = 0,
        .fifoMaxEventCount = 0,
        .requiredPermission = "",
        .maxDelay = 500000,
        .flags = SensorFlagBits::DATA_INJECTION |
                 SensorFlagBits::CONTINUOUS_MODE
    },
    {
        .sensorHandle = kSensorHandleHingeAngle0,
        .name = "Goldfish hinge sensor0 (in degrees)",
        .vendor = kAospVendor,
        .version = 1,
        .type = SensorType::HINGE_ANGLE,
        .typeAsString = "android.sensor.hinge_angle",
        .maxRange = 360,
        .resolution = 1.0,
        .power = 3.0,
        .minDelay = 0,
        .fifoReservedEventCount = 0,
        .fifoMaxEventCount = 0,
        .requiredPermission = "",
        .maxDelay = 0,
        .flags = SensorFlagBits::DATA_INJECTION |
                 SensorFlagBits::ON_CHANGE_MODE |
                 SensorFlagBits::WAKE_UP
    },
    {
        .sensorHandle = kSensorHandleHingeAngle1,
        .name = "Goldfish hinge sensor1 (in degrees)",
        .vendor = kAospVendor,
        .version = 1,
        .type = SensorType::HINGE_ANGLE,
        .typeAsString = "android.sensor.hinge_angle",
        .maxRange = 360,
        .resolution = 1.0,
        .power = 3.0,
        .minDelay = 0,
        .fifoReservedEventCount = 0,
        .fifoMaxEventCount = 0,
        .requiredPermission = "",
        .maxDelay = 0,
        .flags = SensorFlagBits::DATA_INJECTION |
                 SensorFlagBits::ON_CHANGE_MODE |
                 SensorFlagBits::WAKE_UP
    },
    {
        .sensorHandle = kSensorHandleHingeAngle2,
        .name = "Goldfish hinge sensor2 (in degrees)",
        .vendor = kAospVendor,
        .version = 1,
        .type = SensorType::HINGE_ANGLE,
        .typeAsString = "android.sensor.hinge_angle",
        .maxRange = 360,
        .resolution = 1.0,
        .power = 3.0,
        .minDelay = 0,
        .fifoReservedEventCount = 0,
        .fifoMaxEventCount = 0,
        .requiredPermission = "",
        .maxDelay = 0,
        .flags = SensorFlagBits::DATA_INJECTION |
                 SensorFlagBits::ON_CHANGE_MODE |
                 SensorFlagBits::WAKE_UP
    },
    {
        .sensorHandle = kSensorHandleHeartRate,
        .name = "Goldfish Heart rate sensor",
        .vendor = kAospVendor,
        .version = 1,
        .type = SensorType::HEART_RATE,
        .typeAsString = "android.sensor.heart_rate",
        .maxRange = 500.0,
        .resolution = 1.0,
        .power = 20.0,
        .minDelay = 0,
        .fifoReservedEventCount = 0,
        .fifoMaxEventCount = 0,
        .requiredPermission = "android.permission.BODY_SENSORS",
        .maxDelay = 500000,
        .flags = SensorFlagBits::DATA_INJECTION |
                 SensorFlagBits::ON_CHANGE_MODE
    },
    {
      // rgbc-light
    },
    {
        .sensorHandle = kSensorHandleWristTilt,
        .name = "Goldfish wrist tilt gesture sensor",
        .vendor = kAospVendor,
        .version = 1,
        .type = SensorType::WRIST_TILT_GESTURE,
        .typeAsString = "android.sensor.wrist_tilt_gesture",
        .maxRange = 1.0,
        .resolution = 1.0,
        .power = 20.0,
        .minDelay = 0,
        .fifoReservedEventCount = 0,
        .fifoMaxEventCount = 0,
        .maxDelay = 500000,
        .flags = SensorFlagBits::DATA_INJECTION |
                 SensorFlagBits::SPECIAL_REPORTING_MODE |
                 SensorFlagBits::WAKE_UP
    },
    {
        .sensorHandle = kSensorHandleAccelerometerUncalibrated,
        .name = "Goldfish 3-axis Accelerometer Uncalibrated",
        .vendor = kAospVendor,
        .version = 1,
        .type = SensorType::ACCELEROMETER_UNCALIBRATED,
        .typeAsString = "android.sensor.accelerometer_uncalibrated",
        .maxRange = 39.3,
        .resolution = 1.0 / 4032.0,
        .power = 3.0,
        .minDelay = 10000,
        .fifoReservedEventCount = 0,
        .fifoMaxEventCount = 0,
        .requiredPermission = "",
        .maxDelay = 500000,
        .flags = SensorFlagBits::DATA_INJECTION |
                 SensorFlagBits::ADDITIONAL_INFO |
                 SensorFlagBits::CONTINUOUS_MODE
    }};

constexpr int kSensorNumber = sizeof(kAllSensors) / sizeof(kAllSensors[0]);

static_assert(kSensorNumber == sizeof(kQemuSensorName) / sizeof(kQemuSensorName[0]),
              "sizes of kAllSensors and kQemuSensorName arrays must match");

int getSensorNumber() { return kSensorNumber; }

bool isSensorHandleValid(const int h) {
    return h >= 0 && h < kSensorNumber;
}

const SensorInfo* getSensorInfoByHandle(const int h) {
    return isSensorHandleValid(h) ? &kAllSensors[h] : nullptr;
}

const char* getQemuSensorNameByHandle(const int h) {
    return kQemuSensorName[h];
}

}  // namespace goldfish
