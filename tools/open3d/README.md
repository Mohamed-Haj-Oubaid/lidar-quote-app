# Open3D Room Reconstruction

This tool converts Apple LiDAR RGB-D frames into a measured TSDF mesh and a
cleaned Poisson presentation mesh.

## Dataset

Depth files are `float32` NumPy arrays in metres. `intrinsics` are calibrated
for the original color image. `T_world_from_camera` is the 4x4 ARKit
camera-to-world transform.

```json
{
  "frames": [
    {
      "color": "color/000001.jpg",
      "depth": "depth/000001.npy",
      "intrinsics": [[1420, 0, 960], [0, 1420, 720], [0, 0, 1]],
      "T_world_from_camera": [[1, 0, 0, 0], [0, 1, 0, 1.5], [0, 0, 1, 0], [0, 0, 0, 1]]
    }
  ]
}
```

Keep image orientation unchanged unless the intrinsic matrix is transformed
with it. Reject low-confidence Apple depth pixels before export.

## Run

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r tools/open3d/requirements.txt
python tools/open3d/reconstruct_room.py DATASET/frames.json --output OUTPUT
```

Outputs:

- `tsdf_measured_mesh.ply`: measured geometry for audit and measurement.
- `optimized_cloud.ply`: denoised and plane-optimized points.
- `final_room.ply` and `final_room.obj`: cleaned Poisson mesh.
- `quality_report.json`: topology and processing parameters.

Poisson and hole filling infer unobserved geometry. Never treat inferred areas
behind furniture as measured ground truth. Disable Manhattan snapping with
`--no-manhattan` for curved, angled, or sloped architecture.
