
# Data Specification

This document describes the data format recorded by the app.

The collected datasets are each contained in a folder, named after a random hash, for example `71de12f9`. A dataset folder has the following directory structure:

```
camera_matrix.csv
odometry.csv
imu.csv
depth/
  - 000000.png
  - 000001.png
  - ...
confidence/
  - 000000.png
  - 000001.png
  - ...
distortion/          (optional, present when lens distortion data is available)
  - 000000.bin
  - 000001.bin
  - ...
rgb.mp4
```

`rgb.mp4` is an HEVC encoded video, which contains the recorded data from the iPhone's camera.

The `depth/` directory contains the depth maps. One `.png` file per rgb frame. Each of these is a 16 bit grayscale png image. They have a height of 192 elements and width of 256 elements. The values are the measured depth in millimeters, for that pixel position. In [OpenCV](https://docs.opencv.org/4.5.5/), these can be read with `cv2.imread(depth_frame_path, -1)`.

The `confidence/` directory contains confidence maps corresponding to each depth map. They are grayscale png files encoding 192 x 256 element matrices. The values are either 0, 1 or 2. A higher value means a higher confidence.

The `camera_matrix.csv` is a 3 x 3 matrix containing the [camera intrinsic parameters](https://en.wikipedia.org/wiki/Camera_resectioning#Intrinsic_parameters) from the final recorded frame. This file is kept for backwards compatibility; for per-frame intrinsics use the `fx`, `fy`, `cx`, `cy` columns in `odometry.csv`.

The `odometry.csv` file contains the camera pose and intrinsics for each frame. The first line is a header. The meaning of the fields are:

| Field | <div style="width: 500px">Meaning</div> |
|---|---|
| timestamp | Timestamp in seconds |
| frame | Frame number to which this pose corresponds to e.g. `000005` |
| x | x coordinate in meters from when the session was started |
| y | y coordinate in meters from when the session was started |
| z | z coordinate in meters from when the session was started |
| qx | x component of quaternion representing camera pose rotation |
| qy | y component of quaternion representing camera pose rotation |
| qz | z component of quaternion representing camera pose rotation |
| qw | w component of quaternion representing camera pose rotation |
| fx | Horizontal focal length in pixels |
| fy | Vertical focal length in pixels |
| cx | Principal point x coordinate in pixels |
| cy | Principal point y coordinate in pixels |
| distortion_center_x | x coordinate of the lens distortion center in pixels (empty if unavailable) |
| distortion_center_y | y coordinate of the lens distortion center in pixels (empty if unavailable) |

The `distortion/` directory contains per-frame lens distortion lookup tables, present only when the device exposes calibration data. Each `.bin` file is a raw array of little-endian `float32` values mapping radial distance from the distortion center to a correction factor. The number of entries is `file_size_in_bytes / 4`. The filenames correspond to the `frame` field in `odometry.csv`.

The `imu.csv` file contains timestamps, linear acceleration readings and angular rotation readings. The first line is a header. The meaning of the fields are:

| Field | <div style="width: 500px">Meaning</div> |
|---|---|
| timestamp | Timestamp in seconds |
| a\_x | Acceleration in m/s^2 in x direction |
| a\_y | Acceleration in m/s^2 in y direction |
| a\_z | Acceleration in m/s^2 in z direction |
| alpha\_x | Rotation in rad/s around the x-axis |
| alpha\_y | Rotation in rad/s around the y-axis |
| alpha\_z | Rotation in rad/s around the z-axis |


## kgeoScan addition: `frame_quality.csv`

One row per saved frame, written by the same encoder queue as `odometry.csv`, so `frame` is the same number as the
`frame` column of `odometry.csv`, the `depth/` and `confidence/` file names and the frame index in `rgb.mp4`
(frames the encoder dropped have no row in either file). The first line is the header
`frame,timestamp,blur_px,tracking,omega_dps,speed_mps`. Recordings made before 2026-10-29 do not have this file.

| Field | Meaning |
|---|---|
| frame | Frame number (plain integer, `odometry.csv` writes the same number zero-padded) |
| timestamp | ARFrame timestamp in seconds, same value as `odometry.csv` |
| blur_px | Predicted motion blur during the exposure, in pixels of a 1920 px wide image: (ω·fx + v·fx / z) × exposure, with ω (rad/s) and v (m/s) the rotation and translation speed between this and the previous ARFrame pose, z = median LiDAR depth in the image centre (2 m if unknown), fx scaled to 1920 px width, exposure = `ARCamera.exposureDuration` |
| tracking | ARKit tracking state: `normal`, `excessiveMotion`, `insufficientFeatures`, `initializing`, `relocalizing` or `notAvailable` |
| omega_dps | Camera rotation speed in degrees per second |
| speed_mps | Camera translation speed in metres per second |

The app warns ("천천히") when `blur_px` stays at 6 or more for 0.5 s (4 in area mode) and leaves frames above 8 out of the
on-phone point preview. The server can use the file to weight or drop frames; without it, processing is unchanged.

## kgeoScan addition: `meta.json`

kgeoScan (a fork of Stray Scanner) writes one extra file, `meta.json`, into the dataset folder. Everything above is unchanged.
Keys are snake_case, dates are ISO 8601 (UTC). `fix` is the GPS/compass snapshot taken on the first frame after the record
button was pressed (ARKit tracking is reset at that moment, so the world origin is that point and -z is the camera's forward
direction); `upload` is filled in after the dataset was sent to the server. See the README for a full example.

| Key | Meaning |
|---|---|
| `title`, `note`, `mode` | user input; `mode` is `home` or `survey` (label only for now) |
| `server_base` | upload backend the scan was (or will be) sent to |
| `created_at`, `duration_seconds`, `fps_divider`, `saved_frames` | recording facts |
| `fix.lat`, `fix.lon`, `fix.alt`, `fix.h_acc`, `fix.v_acc` | CLLocation at record start (WGS84, metres) |
| `fix.true_heading`, `fix.magnetic_heading`, `fix.heading_accuracy` | CLHeading at record start, degrees clockwise from north |
| `upload.job_id`, `upload.status`, `upload.step`, `upload.scene_item_id`, `upload.result_url` | server job bookkeeping |
