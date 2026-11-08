#!/usr/bin/env python3
"""Reconstruct an indoor room from Apple LiDAR RGB-D frames with Open3D."""

from __future__ import annotations

import argparse
import json
import logging
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Sequence

import cv2
import numpy as np
import open3d as o3d


LOG = logging.getLogger("open3d-room-reconstruction")


@dataclass(frozen=True)
class Config:
    voxel_size: float = 0.015
    sdf_truncation: float = 0.060
    minimum_depth: float = 0.15
    maximum_depth: float = 6.0
    depth_sampling_stride: int = 1
    point_voxel_size: float = 0.015
    outlier_neighbors: int = 30
    outlier_std_ratio: float = 2.5
    normal_radius: float = 0.060
    normal_max_neighbors: int = 50
    normal_orientation_neighbors: int = 40
    plane_distance_threshold: float = 0.025
    plane_ransac_n: int = 3
    plane_iterations: int = 2_000
    plane_min_points: int = 1_500
    plane_max_count: int = 12
    plane_min_remaining_fraction: float = 0.10
    plane_angular_tolerance_degrees: float = 15.0
    use_manhattan_world: bool = True
    poisson_depth: int = 10
    poisson_scale: float = 1.08
    poisson_density_quantile: float = 0.02
    minimum_component_area_ratio: float = 0.005
    crop_padding_fraction: float = 0.05
    hole_size: float = 0.25


@dataclass(frozen=True)
class PlaneRegion:
    indices: np.ndarray
    normal: np.ndarray
    point_count: int


def load_frames(manifest_path: Path) -> list[dict]:
    with manifest_path.open("r", encoding="utf-8") as file:
        payload = json.load(file)
    frames = payload.get("frames")
    if not isinstance(frames, list) or not frames:
        raise ValueError("Manifest must contain a non-empty 'frames' array")
    return frames


def validate_transform(transform: np.ndarray) -> None:
    if transform.shape != (4, 4) or not np.all(np.isfinite(transform)):
        raise ValueError("Camera transform must be a finite 4x4 matrix")
    if not np.allclose(transform[3], [0, 0, 0, 1], atol=1e-5):
        raise ValueError("Invalid homogeneous transform")
    rotation = transform[:3, :3]
    if not np.allclose(rotation.T @ rotation, np.eye(3), atol=2e-2):
        raise ValueError("Camera rotation is not orthonormal")


def prepare_rgbd(
    root: Path,
    frame: dict,
    config: Config,
) -> tuple[o3d.geometry.RGBDImage, o3d.camera.PinholeCameraIntrinsic, np.ndarray]:
    color_path = root / frame["color"]
    depth_path = root / frame["depth"]
    color_bgr = cv2.imread(str(color_path), cv2.IMREAD_COLOR)
    if color_bgr is None:
        raise FileNotFoundError(color_path)

    depth = np.load(depth_path).astype(np.float32)
    if depth.ndim != 2:
        raise ValueError(f"Depth must be HxW: {depth_path}")

    depth_height, depth_width = depth.shape
    color_height, color_width = color_bgr.shape[:2]
    color_bgr = cv2.resize(
        color_bgr,
        (depth_width, depth_height),
        interpolation=cv2.INTER_AREA,
    )
    color_rgb = cv2.cvtColor(color_bgr, cv2.COLOR_BGR2RGB)

    matrix = np.asarray(frame["intrinsics"], dtype=np.float64)
    if matrix.shape != (3, 3):
        raise ValueError("Intrinsics must be 3x3")
    scale_x = depth_width / color_width
    scale_y = depth_height / color_height
    intrinsic = o3d.camera.PinholeCameraIntrinsic(
        depth_width,
        depth_height,
        matrix[0, 0] * scale_x,
        matrix[1, 1] * scale_y,
        matrix[0, 2] * scale_x,
        matrix[1, 2] * scale_y,
    )

    valid = (
        np.isfinite(depth)
        & (depth >= config.minimum_depth)
        & (depth <= config.maximum_depth)
    )
    depth = np.ascontiguousarray(np.where(valid, depth, 0).astype(np.float32))
    rgbd = o3d.geometry.RGBDImage.create_from_color_and_depth(
        o3d.geometry.Image(np.ascontiguousarray(color_rgb.astype(np.uint8))),
        o3d.geometry.Image(depth),
        depth_scale=1.0,
        depth_trunc=config.maximum_depth,
        convert_rgb_to_intensity=False,
    )

    world_from_arkit_camera = np.asarray(
        frame["T_world_from_camera"], dtype=np.float64
    )
    validate_transform(world_from_arkit_camera)
    arkit_to_opencv = np.diag([1.0, -1.0, -1.0, 1.0])
    world_from_opencv_camera = world_from_arkit_camera @ arkit_to_opencv
    return rgbd, intrinsic, np.linalg.inv(world_from_opencv_camera)


def integrate_tsdf(
    root: Path,
    frames: Sequence[dict],
    config: Config,
) -> tuple[o3d.geometry.PointCloud, o3d.geometry.TriangleMesh, int]:
    volume = o3d.pipelines.integration.ScalableTSDFVolume(
        voxel_length=config.voxel_size,
        sdf_trunc=config.sdf_truncation,
        color_type=o3d.pipelines.integration.TSDFVolumeColorType.RGB8,
        volume_unit_resolution=16,
        depth_sampling_stride=config.depth_sampling_stride,
    )
    integrated = 0
    for index, frame in enumerate(frames):
        try:
            rgbd, intrinsic, extrinsic = prepare_rgbd(root, frame, config)
            volume.integrate(rgbd, intrinsic, extrinsic)
            integrated += 1
        except (OSError, ValueError, KeyError) as error:
            LOG.warning("Skipping frame %d: %s", index, error)
    if integrated == 0:
        raise RuntimeError("No valid RGB-D frames were integrated")
    cloud = volume.extract_point_cloud()
    mesh = volume.extract_triangle_mesh()
    mesh.compute_vertex_normals()
    if not cloud.has_points():
        raise RuntimeError("TSDF produced an empty point cloud")
    return cloud, mesh, integrated


def clean_cloud(cloud: o3d.geometry.PointCloud, config: Config) -> o3d.geometry.PointCloud:
    cloud = cloud.voxel_down_sample(config.point_voxel_size)
    cloud, _ = cloud.remove_statistical_outlier(
        nb_neighbors=config.outlier_neighbors,
        std_ratio=config.outlier_std_ratio,
    )
    cloud.estimate_normals(
        o3d.geometry.KDTreeSearchParamHybrid(
            radius=config.normal_radius,
            max_nn=config.normal_max_neighbors,
        )
    )
    cloud.normalize_normals()
    return cloud


def detect_planes(cloud: o3d.geometry.PointCloud, config: Config) -> list[PlaneRegion]:
    remaining = cloud
    global_indices = np.arange(len(cloud.points), dtype=np.int64)
    initial_count = len(cloud.points)
    planes: list[PlaneRegion] = []
    for _ in range(config.plane_max_count):
        if len(remaining.points) < config.plane_min_points:
            break
        if len(remaining.points) < initial_count * config.plane_min_remaining_fraction:
            break
        model, local_inliers = remaining.segment_plane(
            distance_threshold=config.plane_distance_threshold,
            ransac_n=config.plane_ransac_n,
            num_iterations=config.plane_iterations,
        )
        if len(local_inliers) < config.plane_min_points:
            break
        local = np.asarray(local_inliers, dtype=np.int64)
        normal = np.asarray(model[:3], dtype=np.float64)
        normal /= np.linalg.norm(normal)
        planes.append(PlaneRegion(global_indices[local], normal, len(local)))
        keep = np.ones(len(remaining.points), dtype=bool)
        keep[local] = False
        keep_indices = np.flatnonzero(keep)
        remaining = remaining.select_by_index(keep_indices.tolist())
        global_indices = global_indices[keep_indices]
    return planes


def canonical_normal(normal: np.ndarray) -> np.ndarray:
    normal = normal / np.linalg.norm(normal)
    for component in normal:
        if abs(component) > 1e-8:
            return normal if component > 0 else -normal
    return normal


def manhattan_axes(
    planes: Sequence[PlaneRegion], tolerance_degrees: float
) -> tuple[np.ndarray, np.ndarray, np.ndarray] | None:
    up = np.array([0.0, 1.0, 0.0])
    tolerance = np.deg2rad(tolerance_degrees)
    vertical = []
    for plane in planes:
        normal = canonical_normal(plane.normal)
        angle = np.arccos(np.clip(abs(normal @ up), 0, 1))
        if abs(angle - np.pi / 2) <= tolerance:
            vertical.append(plane)
    if not vertical:
        return None
    strongest = max(vertical, key=lambda value: value.point_count)
    axis_x = strongest.normal - up * (strongest.normal @ up)
    axis_x = canonical_normal(axis_x)
    axis_z = np.cross(up, axis_x)
    axis_z /= np.linalg.norm(axis_z)
    return axis_x, up, axis_z


def snap_normal(
    normal: np.ndarray,
    axes: tuple[np.ndarray, np.ndarray, np.ndarray] | None,
    tolerance_degrees: float,
) -> np.ndarray:
    normal = canonical_normal(normal)
    if axes is None:
        return normal
    candidates = [axis * sign for axis in axes for sign in (1, -1)]
    best = max(candidates, key=lambda axis: normal @ axis)
    return best.copy() if normal @ best >= np.cos(np.deg2rad(tolerance_degrees)) else normal


def optimize_planes(
    cloud: o3d.geometry.PointCloud,
    planes: Sequence[PlaneRegion],
    config: Config,
) -> o3d.geometry.PointCloud:
    optimized = o3d.geometry.PointCloud(cloud)
    points = np.asarray(optimized.points).copy()
    axes = (
        manhattan_axes(planes, config.plane_angular_tolerance_degrees)
        if config.use_manhattan_world else None
    )
    for plane in planes:
        region = points[plane.indices]
        normal = snap_normal(
            plane.normal, axes, config.plane_angular_tolerance_degrees
        )
        offset = -np.median(region @ normal)
        distances = region @ normal + offset
        points[plane.indices] = region - distances[:, None] * normal[None, :]
    optimized.points = o3d.utility.Vector3dVector(points)
    optimized.estimate_normals(
        o3d.geometry.KDTreeSearchParamHybrid(
            radius=config.normal_radius,
            max_nn=config.normal_max_neighbors,
        )
    )
    optimized.orient_normals_consistent_tangent_plane(
        config.normal_orientation_neighbors
    )
    optimized.normalize_normals()
    return optimized


def poisson_mesh(cloud: o3d.geometry.PointCloud, config: Config) -> o3d.geometry.TriangleMesh:
    mesh, densities = o3d.geometry.TriangleMesh.create_from_point_cloud_poisson(
        cloud,
        depth=config.poisson_depth,
        width=0,
        scale=config.poisson_scale,
        linear_fit=False,
        n_threads=-1,
    )
    density = np.asarray(densities)
    mesh.remove_vertices_by_mask(
        density < np.quantile(density, config.poisson_density_quantile)
    )
    bounds = cloud.get_axis_aligned_bounding_box()
    bounds = bounds.scale(1 + config.crop_padding_fraction, bounds.get_center())
    return mesh.crop(bounds)


def keep_components(
    mesh: o3d.geometry.TriangleMesh, minimum_area_ratio: float
) -> o3d.geometry.TriangleMesh:
    if not len(mesh.triangles):
        return mesh
    labels, counts, areas = mesh.cluster_connected_triangles()
    labels = np.asarray(labels)
    counts = np.asarray(counts)
    areas = np.asarray(areas)
    keep = np.flatnonzero(
        (areas >= areas.max() * minimum_area_ratio) & (counts >= 20)
    )
    mesh.remove_triangles_by_mask(~np.isin(labels, keep))
    mesh.remove_unreferenced_vertices()
    return mesh


def clean_mesh(mesh: o3d.geometry.TriangleMesh, config: Config) -> o3d.geometry.TriangleMesh:
    mesh.remove_duplicated_vertices()
    mesh.remove_duplicated_triangles()
    mesh.remove_degenerate_triangles()
    mesh.remove_non_manifold_edges()
    mesh.remove_unreferenced_vertices()
    mesh = keep_components(mesh, config.minimum_component_area_ratio)
    tensor = o3d.t.geometry.TriangleMesh.from_legacy(mesh)
    mesh = tensor.fill_holes(hole_size=config.hole_size).to_legacy()
    mesh.remove_duplicated_vertices()
    mesh.remove_duplicated_triangles()
    mesh.remove_degenerate_triangles()
    mesh.remove_non_manifold_edges()
    mesh.remove_unreferenced_vertices()
    mesh.compute_vertex_normals()
    return mesh


def quality_report(mesh: o3d.geometry.TriangleMesh) -> dict[str, object]:
    return {
        "vertices": len(mesh.vertices),
        "triangles": len(mesh.triangles),
        "watertight": mesh.is_watertight(),
        "edge_manifold_without_boundaries": mesh.is_edge_manifold(False),
        "vertex_manifold": mesh.is_vertex_manifold(),
        "self_intersecting": mesh.is_self_intersecting(),
        "orientable": mesh.is_orientable(),
    }


def reconstruct(manifest: Path, output: Path, config: Config) -> dict[str, object]:
    frames = load_frames(manifest)
    output.mkdir(parents=True, exist_ok=True)
    cloud, measured_mesh, integrated = integrate_tsdf(
        manifest.parent, frames, config
    )
    cleaned_cloud = clean_cloud(cloud, config)
    planes = detect_planes(cleaned_cloud, config)
    optimized_cloud = optimize_planes(cleaned_cloud, planes, config)
    final_mesh = clean_mesh(poisson_mesh(optimized_cloud, config), config)
    report = quality_report(final_mesh)
    report.update({
        "frames_submitted": len(frames),
        "frames_integrated": integrated,
        "planes_detected": len(planes),
        "configuration": asdict(config),
    })
    o3d.io.write_triangle_mesh(str(output / "tsdf_measured_mesh.ply"), measured_mesh)
    o3d.io.write_point_cloud(str(output / "optimized_cloud.ply"), optimized_cloud)
    o3d.io.write_triangle_mesh(str(output / "final_room.ply"), final_mesh)
    o3d.io.write_triangle_mesh(str(output / "final_room.obj"), final_mesh)
    with (output / "quality_report.json").open("w", encoding="utf-8") as file:
        json.dump(report, file, indent=2)
    return report


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--output", type=Path, default=Path("reconstruction"))
    parser.add_argument("--voxel-size", type=float, default=0.015)
    parser.add_argument("--plane-threshold", type=float, default=0.025)
    parser.add_argument("--poisson-depth", type=int, default=10)
    parser.add_argument("--maximum-depth", type=float, default=6.0)
    parser.add_argument("--no-manhattan", action="store_true")
    arguments = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    config = Config(
        voxel_size=arguments.voxel_size,
        point_voxel_size=arguments.voxel_size,
        sdf_truncation=arguments.voxel_size * 4,
        normal_radius=arguments.voxel_size * 4,
        plane_distance_threshold=arguments.plane_threshold,
        poisson_depth=arguments.poisson_depth,
        maximum_depth=arguments.maximum_depth,
        use_manhattan_world=not arguments.no_manhattan,
    )
    report = reconstruct(arguments.manifest, arguments.output, config)
    LOG.info("Quality report: %s", report)
    if not report["watertight"]:
        LOG.warning("Final mesh is not watertight; inspect quality_report.json")


if __name__ == "__main__":
    main()
