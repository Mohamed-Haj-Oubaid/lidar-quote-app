# LiDAR Room Scanner — Complete Implementation Guide

## 1. Purpose

This document records the complete development work performed on the iPad LiDAR room-scanning project. It explains the final architecture, the implementation steps, the important algorithms and thresholds, the user workflow, known limitations, and how to build and test the app.

The final goal of the project is an iPad application that can:

1. Scan an indoor room using Apple LiDAR, ARKit, and RoomPlan.
2. Capture walls, doors, windows, openings, floor geometry, depth, and camera color.
3. Display scan progress and live reconstructed geometry while the worker scans.
4. Save an interactive 3D model locally.
5. Switch between Real 3D, Laser, Color, White, Raw Mesh, and Points views.
6. Display wall, door, and window dimensions directly on the 3D model.
7. Estimate door and window reveal depth automatically from LiDAR.
8. Let the worker correct an incorrect window depth by measuring two points on the saved 3D model.
9. Apply the corrected depth to one window, all windows on the same wall, or all windows in the room.

All architectural measurements are stored and displayed in meters.

---

## 2. Final user workflow

### 2.1 Scan a room

1. Open a job.
2. Start a room scan.
3. Select a capture mode:
   - **Room LiDAR** for a faster architectural scan.
   - **High Detail** for denser geometry, smaller objects, and improved color coverage.
4. Move slowly around the room.
5. Capture every wall, corner, floor area, ceiling area, door, and window.
6. Continue until the coverage indicator reaches at least **80%**.
7. Press **Done**.
8. Wait while RoomPlan and the app process and save the result.

### 2.2 Review the room

The room detail screen displays:

- Floor area.
- Perimeter.
- Average wall height.
- Gross and net wall area.
- Number of doors and windows.
- A separate detail section for every wall.
- Width, height, area, position, and reveal depth for each opening.
- Editable names for walls, doors, windows, and openings.

### 2.3 Review the 3D model

Press **View 3D Model** to open the full-screen viewer. The default mode is **Laser**.

Available modes:

- **Real 3D** — camera-colored and textured geometry when available.
- **Laser** — classified colored geometry and lines.
- **Color** — model materials and captured color.
- **White** — clean white solid model.
- **Raw Mesh** — mesh topology.
- **Points** — point representation of the model vertices.

### 2.4 Correct a wrong window depth

The LiDAR result remains the default. Manual correction is only needed when glass causes an incorrect window depth.

1. Open the required wall.
2. Find the required window.
3. Press **Measure Window Depth**.
4. The saved 3D model opens automatically in **Laser** mode with measurement enabled.
5. Tap the first solid reveal surface.
6. Tap the second solid reveal surface.
7. Confirm the displayed measurement.
8. Press **Save as window depth**.
9. After the viewer closes, choose one of these scopes:
   - **Only this window**.
   - **All windows on this wall**.
   - **All windows in this room**.

This correction system affects windows only. Door depth continues to use the automatic LiDAR result because door measurements were found to be reliable.

---

## 3. Main architecture

### 3.1 Apple frameworks

| Framework | Responsibility |
|---|---|
| SwiftUI | Application UI and state-driven screens |
| SwiftData | Local persistent survey, job, measurement, and media metadata |
| RoomPlan | Architectural room, wall, door, window, and opening detection |
| ARKit | LiDAR depth, scene reconstruction mesh, camera frames, tracking, and transforms |
| SceneKit | Interactive 3D rendering, model modes, labels, borders, points, and manual measurement |
| Core Image / UIKit | Camera image conversion, texture generation, and material images |

### 3.2 Core data flow

```text
ARKit + RoomPlan scan
        |
        +--> CapturedRoom architectural result
        |
        +--> ARMeshAnchor scene geometry
        |
        +--> LiDAR depth + RGB camera color
                    |
                    v
        PhotoPointCloudRecorder
                    |
                    +--> ColoredSurfaceMesh
                    +--> TexturedSurfaceMesh
                    +--> LiveScanFrame
                    |
                    v
        RoomMeshPostProcessor
                    |
                    v
        Local model/archive storage
                    |
                    v
        RoomModelViewer + room details
```

### 3.3 Important files

| File | Main responsibility |
|---|---|
| `lidar/SurveyEngine/RoomCaptureRepresentable.swift` | Configures RoomPlan/ARKit and displays the live reconstructed scan overlay |
| `lidar/SurveyEngine/PhotoPointCloud.swift` | Captures LiDAR geometry, RGB color, texture frames, coverage, and the local reality archive |
| `lidar/SurveyEngine/SurveyEngine.swift` | Converts RoomPlan output to application measurements and estimates opening depth |
| `lidar/SurveyEngine/RoomMeshPostProcessor.swift` | Cleans and prepares captured geometry before storage |
| `lidar/Views/ScanRoomView.swift` | Scan mode selection, progress, 80% requirement, processing, and media persistence |
| `lidar/Views/RoomModelViewer.swift` | Full-screen 3D viewer, rendering modes, labels, borders, points, and measurement tools |
| `lidar/Views/RoomDetailView.swift` | Wall/opening details, naming, manual window depth, model launch, and save-scope selection |
| `lidar/Views/OpeningRescanView.swift` | High-detail rescan flow for an individual opening |
| `lidar/Domain/DomainTypes.swift` | Room measurement, wall, opening, and related domain types |
| `lidar/Persistence/Models.swift` | Stored media names and SwiftData models |
| `lidar/Persistence/LocalStore.swift` | Saving, deleting, and cleaning associated local media |
| `tools/open3d/reconstruct_room.py` | Optional desktop Open3D reconstruction pipeline |

---

## 4. Scan capture implementation

### 4.1 AR session configuration

`RoomCaptureRepresentable` creates an `ARSession` and configures:

- World tracking.
- Vertical and horizontal plane detection.
- Scene reconstruction using `meshWithClassification` when supported.
- Fallback to ordinary scene reconstruction mesh.
- `sceneDepth` and `smoothedSceneDepth` when supported.

The session is passed into `RoomCaptureView`, so RoomPlan and the custom geometry recorder share the same tracking coordinate system.

### 4.2 Capture modes

The project has two scan modes in `ScanCaptureMode`.

| Setting | Room LiDAR | High Detail |
|---|---:|---:|
| Sample interval | 0.65 s | 0.32 s |
| Pixel stride fallback | 6 | 3 |
| Maximum points | 180,000 | 350,000 |
| Maximum texture frames | 4 | 5 |
| Minimum texture coverage | 18% | 12% |
| JPEG quality | 0.82 | 0.90 |

The High Detail mode consumes more processing time and memory but preserves more geometry and camera detail.

### 4.3 Mesh-first capture

The recorder first tries to capture `ARMeshAnchor` geometry. This is preferable to a loose depth point cloud because it already contains connected vertices and triangle indices.

For every mesh anchor, the recorder:

1. Reads each local mesh vertex.
2. transforms it into world coordinates.
3. Projects it into the current camera frame.
4. Checks that the vertex is visible in the image.
5. Compares camera-space mesh depth with LiDAR depth to reduce color bleeding between surfaces.
6. Computes an observation score using surface orientation and camera distance.
7. Keeps the best color observation for each vertex.
8. Stores the mesh per anchor and later combines all anchors.

### 4.4 Depth-map fallback

If scene mesh anchors are unavailable, the recorder samples the LiDAR depth map directly.

For each accepted pixel:

1. Validate depth and confidence.
2. Unproject the pixel through camera intrinsics.
3. Transform the camera point into world coordinates.
4. Read the corresponding RGB camera pixel.
5. Store a colored 3D vertex.
6. Connect neighboring valid samples into triangles.

Depth samples are accepted only when finite, inside the supported distance range, and sufficiently confident.

### 4.5 Texture capture

Selected camera frames are stored as compressed JPEG images with camera transforms and intrinsics.

During archive generation:

1. Mesh vertices are projected into each texture frame.
2. UV texture coordinates are calculated.
3. Only triangles whose vertices project into the image are accepted.
4. Triangles are assigned to the best frames first.
5. The output is stored as multiple `TexturedSurfaceChunk` values.

This avoids relying on a single photograph for the entire room.

---

## 5. Live scan visualization and coverage

### 5.1 Live geometry

The scanning screen contains a transparent `ARSCNView` overlay above RoomPlan.

The overlay displays:

- The geometry already captured by LiDAR.
- A translucent colored surface.
- A fine triangular wire layer.
- A continuous scan-quality color gradient.

The geometry remains fixed in the AR world coordinate system. It does not move with the camera like a screen-space drawing.

### 5.2 Quality colors

The live quality visualization blends smoothly between:

- Red for poor capture quality.
- Orange for acceptable capture quality.
- Green for good capture quality.

A smooth-step interpolation is used instead of hard color bands, preventing the harsh point-by-point appearance seen in early versions.

### 5.3 Coverage percentage

The scan screen displays a percentage from 0% to 100%.

Coverage considers captured geometry and visited viewing sectors. The highest reached value is retained so the percentage does not jump backward while moving.

The **Done** button is disabled until coverage reaches **80%**. This encourages the worker to continue scanning missing surfaces.

---

## 6. Saved 3D assets

The app stores multiple representations:

1. **RoomPlan model** — currently stored as a USDZ model and opened by SceneKit.
2. **Reality mesh archive** — encoded colored geometry plus textured chunks.
3. **Optional wall texture files** — used when separately captured wall photographs exist.

The user often refers to the saved model as “OBJ.” In the current iPad implementation, the main RoomPlan model is USDZ, while SceneKit treats it as the interactive triangle model. The optional Open3D desktop pipeline can export PLY or OBJ for external CAD workflows.

Associated media filenames are stored in the `Survey` persistence model and are removed when the room is deleted.

---

## 7. 3D viewer modes

### 7.1 Default behavior

The standard 3D viewer opens in **Laser** mode. Camera controls allow orbiting and zooming around the room.

### 7.2 Real 3D

Real 3D loads the saved colored surface and textured chunks. It uses:

- Per-vertex camera color as a fallback.
- Captured JPEG texture chunks when available.
- Depth-buffered materials so nearer surfaces correctly hide surfaces behind them.

### 7.3 Laser

Laser mode builds geometry from the captured reality mesh and classifies vertices by their closest architectural element.

Colors are assigned to:

- Individual walls.
- Doors.
- Windows.
- Other openings.

Laser mode intentionally avoids the duplicated gray wire model that appeared in earlier versions. It displays classified colored geometry instead.

### 7.4 Color

Color mode retains the available model materials and camera-derived appearance.

### 7.5 White

White mode renders a clean white surface with physically based lighting and a rough material. It is useful for inspecting geometry without color distractions.

### 7.6 Raw Mesh

Raw Mesh uses line fill mode to expose triangle topology.

### 7.7 Points

Points mode converts model vertices into point primitives. Point screen-space radius is bounded to remain readable while zooming.

---

## 8. Wall, door, and window visualization

### 8.1 Element colors

- Every wall receives a stable color from a rotating palette.
- Doors use one shared orange color.
- Windows use one shared cyan color.
- Other openings use purple.

### 8.2 Borders and labels

For non-Laser modes, the viewer can display:

- A border around each wall.
- A border around each door/window/opening.
- Wall length and height.
- Opening width, height, and depth.

Borders and labels use the depth buffer, so they follow the model surface instead of floating visibly above it.

Laser mode avoids drawing a second gray border layer on top of the classified geometry.

### 8.3 Wall-only viewer

Each wall detail section includes a button to open a viewer focused on that wall. It includes the selected wall and all of its associated door/window details.

### 8.4 Editable names

The worker can rename:

- Walls.
- Doors.
- Windows.
- Other openings.

Names are stored in the measurement model and persisted through `LocalStore`.

---

## 9. Automatic opening depth

### 9.1 Door depth

Door depth is taken automatically from LiDAR/mesh processing. It remains unchanged by the window correction workflow.

The generic opening estimator:

1. Transforms nearby captured vertices into opening-local coordinates.
2. Collects their absolute local Z distance.
3. Uses robust near and far percentiles.
4. Accepts a result only inside a physical validity range.

### 9.2 Why windows are harder

LiDAR often behaves incorrectly around glass because the signal can:

- Pass through the glass.
- Reflect away from the sensor.
- Return geometry from outside the building.
- Mix the glass plane, frame, reveal, and outdoor surfaces.

This produced examples where a real depth near 0.18–0.24 m was reported as 0.32, 0.34, or 0.51 m.

### 9.3 Conservative window algorithm

The final automatic window estimator ignores the glass-filled center and samples only small solid patches around the four window corners.

Current important values:

| Parameter | Value |
|---|---:|
| Corner band | 0.18 m |
| Accepted local Z | -0.10…0.34 m |
| Minimum samples per corner/cluster | 12 |
| Cluster gap | 0.018 m |
| Near percentile | 5% |
| Far percentile | 80% |
| Accepted reveal depth | 0.02…0.28 m |
| Corner agreement tolerance | ±0.02 m |
| Minimum agreeing corners | 2 |

The triangle normal must indicate a reveal-facing side surface:

- Strong X or Y normal component: at least 0.70.
- Limited Z normal component: at most 0.40.

This suppresses front-facing glass and wall triangles while favoring jamb, sill, and head surfaces.

### 9.4 Consensus

Each corner produces a candidate depth only when it has a sufficiently large coherent cluster. Candidate corner depths are grouped using a 2 cm tolerance. At least two corners must agree before the automatic window depth is accepted.

If no reliable consensus exists, the estimator returns no window mesh depth instead of inventing a large value from outdoor geometry.

---

## 10. Individual opening rescan

`OpeningRescanView` reuses the main scanner in **High Detail** mode.

The worker is instructed to capture:

- The complete frame.
- The surrounding wall.
- Both solid reveal sides.
- More than only the glass center.

After processing, the app finds the best matching opening using width, height, and depth similarity. If a reliable depth cannot be isolated, the old measurement is preserved and an error is shown.

The rescan Done button requires at least 15% local coverage.

---

## 11. Manual 3D measurement system

### 11.1 General measurement modes

The 3D viewer supports:

- Free 3D distance.
- Horizontal distance.
- Vertical height.

The worker taps the model, not empty screen space. SceneKit hit-testing finds the actual triangle location.

### 11.2 Drawing

For every measurement:

1. The first tap creates a fixed model-space point.
2. The second tap creates another fixed point.
3. A cylinder is oriented between the two points.
4. The Euclidean distance is calculated.
5. A billboard label displays the result.
6. The result is added to the measurement list.

The points use a physical model-space radius of 0.012 m and the line radius is 0.003 m. Depth testing is enabled, so the markers respect the model surface and do not appear as screen-space floating graphics.

Undo and Clear controls are available.

---

## 12. Window depth correction from the saved model

### 12.1 Opening the correction mode

Pressing **Measure Window Depth** does not start a new AR camera scan. It opens the already saved room model.

The viewer is initialized with:

- **Laser** display mode.
- Measurement mode already active.
- Free distance selected.
- A **Save as window depth** button.

Measurement activation is applied in the viewer initializer, not delayed until `onAppear`. This fixed a bug where the viewer opened but measurement remained inactive.

### 12.2 Saving after measurement

When two points are selected:

1. The measured distance becomes available.
2. The Save button is enabled.
3. Pressing Save sends the value back to `RoomDetailView`.
4. The 3D viewer dismisses.
5. Only after dismissal, a confirmation dialog is presented.

Waiting until the full-screen viewer closes fixed the issue where the save options were hidden behind the viewer.

### 12.3 Save scope

The worker chooses:

| Option | Result |
|---|---|
| Only this window | Updates the selected window ID only |
| All windows on this wall | Updates only windows with the same wall ID |
| All windows in this room | Updates every opening whose kind is `window` |

Doors are explicitly excluded by the `opening.kind == .window` guard.

After applying the selected scope:

- The room is marked as manually adjusted.
- The updated measurement is saved through `LocalStore`.
- Pending measurement state is cleared.

---

## 13. Units and detail-screen layout

All dimensions are now displayed in meters.

Examples:

- `0.24 m`, not `24 cm`.
- `2.51 m` wall height.
- `0.90 × 1.20 m` window size.

The manual window depth row uses a fixed one-line layout:

```text
Manual depth                         0.240 m
```

The numeric field and `m` suffix are grouped in a fixed-size horizontal stack. This prevents the unit from wrapping under the number or placing the label between the value and unit.

---

## 14. Features removed or replaced

### 14.1 Gaussian viewer

A Gaussian viewer experiment was removed because it produced a black screen and did not integrate reliably with the saved room asset. The final viewer uses SceneKit triangle/point geometry and captured texture chunks.

### 14.2 Camera-based AR depth correction

An AR two-point camera measurement flow was tested, but the requested final behavior was to measure directly on the saved 3D model. The AR correction screen was removed from the final window-depth workflow.

### 14.3 Floating overlay lines

Earlier annotation materials ignored the depth buffer, causing lines and labels to appear above the model. The current implementation enables depth reads for model annotations and uses surface/model-space positions.

---

## 15. Optional Open3D desktop pipeline

The `tools/open3d` directory contains a separate reconstruction path for desktop/server processing.

Its intended stages are:

1. Load sequential RGB-D frames or point clouds.
2. Integrate frames with volumetric TSDF fusion.
3. Downsample and remove statistical/radius outliers.
4. Detect architectural planes using RANSAC.
5. Estimate and orient normals.
6. Reconstruct a surface using Screened Poisson reconstruction.
7. Remove low-density geometry.
8. Crop to the observed room bounds.
9. Export PLY or OBJ.

This path is not the real-time iPad renderer. It is an optional heavier post-processing tool for CAD/export workflows.

---

## 16. Build and installation

### 16.1 Requirements

- Xcode with the project opened.
- An Apple development signing identity/team.
- A connected LiDAR-capable iPad Pro or iPhone Pro.
- Camera permission.
- A valid selected run destination.

### 16.2 Build

1. Select the `lidar` scheme.
2. Select Omar’s connected iPad as the destination.
3. Build with **Product → Build**.
4. Resolve signing only if Xcode reports a signing error.

### 16.3 Install and run

Use **Product → Run**. Xcode builds, installs, and launches the app on the selected iPad.

During development, the app was repeatedly built successfully and launched directly on Omar’s connected iPad after each requested change.

---

## 17. Verification checklist

### 17.1 Main scan

- [ ] Room LiDAR mode starts.
- [ ] High Detail mode starts.
- [ ] Live colored mesh remains fixed in the room.
- [ ] Quality color changes smoothly.
- [ ] Coverage increases while new surfaces are captured.
- [ ] Done stays disabled below 80%.
- [ ] Processing completes without a black screen.
- [ ] Room and local model are saved.

### 17.2 Viewer

- [ ] Viewer opens full screen.
- [ ] Laser is the default mode.
- [ ] Real 3D shows color/texture when captured.
- [ ] White shows a clean solid surface.
- [ ] Raw Mesh shows topology.
- [ ] Points shows model vertices.
- [ ] Camera orbit and zoom work.
- [ ] Wall and opening annotations align with geometry.

### 17.3 Measurements

- [ ] Width, height, and area are shown in meters.
- [ ] Door depth remains automatic.
- [ ] Window depth is automatically populated when reliable.
- [ ] Manual depth field is one line and uses meters.
- [ ] Measure Window Depth opens Laser mode.
- [ ] Measurement is active immediately.
- [ ] First and second model taps create visible points.
- [ ] The line and result remain attached to the model.
- [ ] Save as window depth becomes enabled.
- [ ] Save options appear after the viewer closes.
- [ ] Current-window scope changes only the selected window.
- [ ] Same-wall scope changes only windows on that wall.
- [ ] All-room scope changes all windows and no doors.

---

## 18. Known limitations

1. LiDAR cannot physically guarantee correct glass depth; glass can still generate missing or outdoor geometry.
2. Manual 3D correction depends on the required solid reveal surfaces existing in the saved mesh.
3. Automatically filling large unscanned regions can create plausible but non-measured geometry and must not be treated as survey-grade evidence.
4. Real 3D texture quality depends strongly on lighting, motion speed, viewing angle, and coverage.
5. The iPad real-time pipeline is optimized for usability and local processing; the optional Open3D pipeline can perform heavier reconstruction externally.
6. A measurement is only as accurate as the two selected model points and the underlying LiDAR mesh.

---

## 19. Recommended scan technique

For the clearest model and most reliable measurements:

1. Use bright, even indoor lighting.
2. Move slowly.
3. Keep the device roughly 0.5–3 m from the surface.
4. Avoid rapid rotation.
5. Observe each wall from more than one angle.
6. Capture window jambs, sill, and head—not only the glass center.
7. Capture door reveals from both sides when possible.
8. Continue beyond 80% when important areas are still missing.
9. Inspect the Laser model before accepting window depth.
10. Use manual correction only when the automatic value is visibly wrong.

---

## 20. Final behavior summary

The final implementation uses LiDAR as the automatic source of all room and opening dimensions. Door depth remains fully automatic. Window depth uses a conservative four-corner solid-surface algorithm to reduce glass/outdoor contamination. When that automatic value is wrong, the worker can open the saved Laser model, select two exact model points, and save the measured result to one window, the wall’s windows, or every window in the room.

The application keeps the full scan, review, correction, and persistence workflow on the iPad while retaining an optional Open3D route for heavier offline reconstruction and CAD export.
