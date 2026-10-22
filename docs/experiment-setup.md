# Experiment setup

The workflow was developed for a knee phantom, but the same general arrangement can be used with a cadaver leg. The physical setup must connect the CT anatomy, tracked bone pins, ultrasound probe, and motion-capture reference frame without changing their geometry between calibration, CT imaging, and ultrasound acquisition.

## Equip the specimen with tracked bone pins

Attach a bone pin to each bone that will be registered, such as the femur or tibia. Each pin carries an optical-marker rigid body so the bone pose can be measured by the motion-capture system. The pin must remain rigidly attached to the bone throughout CT scanning and ultrasound acquisition.

Also provide a fixed reference rigid body in the experimental workspace. This reference defines the common coordinate frame in which the tracked ultrasound images, bone-pin measurements, CT meshes, coarse estimates, and final optimization results are compared.

## Acquire the CT scan before the ultrasound experiment

CT-scan the knee phantom or cadaver leg together with the attached bone pins and their optical-marker geometry. The CT scan must contain enough information to reconstruct:

- The surface mesh of each bone.
- The anatomical coordinate system of each bone.
- The CT-side coordinate system of each bone pin.
- The optical-marker geometry needed to relate the physical tracked pin to the corresponding CT geometry.

Keeping the pin and marker assembly unchanged is essential. Reattaching or moving a pin after the CT scan breaks the rigid relationship used to obtain the ground-truth bone pose.

## Process the CT anatomy and tracking geometry

Segment or prepare the bone meshes, define their anatomical coordinate systems, and identify the pin-marker geometry in the CT data. The tools in [`tools/`](../tools/README.md) describe the expected processing order and output structures.

The processed CT result connects the CT mesh to the tracked bone pin. During the ultrasound experiment, this relationship allows the measured pin pose to place the complete CT bone mesh in the common reference frame.

## Place the specimen in the motion-capture workspace

Place the instrumented knee under the working volume of an optical motion-capture system. This project is being developed with a Qualisys system. Confirm that the reference object, bone-pin rigid bodies, and probe rigid body are simultaneously visible and use consistent rigid-body names.

Before collecting ultrasound data, check the marker definitions, axis directions, units, and coordinate-system handedness. These definitions must agree with those used during CT processing. A mismatch can create a plausible-looking but incorrect bone registration.

## Track and calibrate the ultrasound probe

Attach an optical-marker rigid body to the B-mode ultrasound probe. Calibrate the relationship between the image and probe coordinate systems beforehand. This workflow uses the [PLUS Toolkit](https://plustoolkit.github.io/) and expects an fCal/PLUS calibration containing the `ImageToProbe` transform.

The calibration connects an ultrasound pixel to a physical location relative to the tracked probe. Together with the measured probe and reference poses, it allows each B-mode image to be represented as a finite plane in the common three-dimensional reference frame.

## Acquire tracked B-mode ultrasound snapshots

Move the tracked probe over the bone surface and record B-mode ultrasound snapshots. Save the ultrasound image data together with the corresponding probe, reference, and bone-pin tracking measurements. The acquisition software used for this work is maintained in the separate [BmodeMocapIntegration repository](https://github.com/dacvm/BmodeMocapIntegration).

Each accepted snapshot ultimately provides:

- A B-mode image.
- A calibrated image plane in three-dimensional reference coordinates.
- A timestamp and source record that connect the image to its tracking data.

## Build the estimation and ground-truth data

The tracked and calibrated probe provides the estimated position of each ultrasound image in 3D space. The CT mesh and the optically tracked bone pin provide an independent ground-truth bone pose. These two information paths serve different purposes:

- The optimizer receives the CT mesh, tracked ultrasound planes, image intensities, and a coarse initial pose.
- The ground-truth bone pose and ground-truth intersections are kept separate and are used only for validation after estimation.

This separation prevents the optimization cost from using the answer that it is intended to estimate.
