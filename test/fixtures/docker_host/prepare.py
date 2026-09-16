#!/usr/bin/env python3
"""Stage only SDK source and the Docker test application. Does not run Docker."""
import argparse
from pathlib import Path
import shutil

WORKER_SOURCES = (
    "examples/09_host_providers/09_01_acquired_topology/topology.ex",
    "examples/09_host_providers/09_02_lost_acquire_reply/topology.ex",
    "examples/09_host_providers/09_03_borrowed_and_incompatible/topology.ex",
    "examples/09_host_providers/09_04_release_guard/topology.ex",
    "examples/09_host_providers/09_05_abrupt_death_cleanup/topology.ex",
    "examples/11_system/11_01_deployment_lifecycle/subscriber.ex",
    "examples/11_system/11_02_provider_lifecycle/subscriber.ex",
    "test/examples/support/location_visibility_barrier.ex",
)


def prepare(sdk_root, output):
    if output.exists():
        raise ValueError("The output path must not exist")
    output.mkdir(parents=True)
    for package in ("jido_action", "jido_signal", "jido", "jido_cluster"):
        source = sdk_root / package
        target = output / package
        target.mkdir()
        for name in ("lib", "config", "mix.exs", "mix.lock", "README.md", "LICENSE"):
            item = source / name
            if item.is_dir():
                shutil.copytree(item, target / name)
            elif item.is_file():
                shutil.copy2(item, target / name)
    fixture = Path(__file__).resolve().parent
    app = output / "docker_host"
    app.mkdir()
    for name in ("lib", "rel"):
        shutil.copytree(fixture / name, app / name)
    # Compile the exact application definitions and worker-side barrier. Never
    # compile ExUnit runners or the full test-support tree into the release.
    for relative in WORKER_SOURCES:
        destination = app / "lib" / "worker_sources" / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(sdk_root / "jido_cluster" / relative, destination)
    shutil.copy2(fixture / "mix.exs", app / "mix.exs")
    shutil.copy2(sdk_root / "jido_cluster" / "mix.lock", app / "mix.lock")
    shutil.copy2(fixture / "Dockerfile", output / "Dockerfile")
    shutil.copy2(fixture / ".dockerignore", output / ".dockerignore")
    shutil.copy2(sdk_root / "jido_cluster" / ".tool-versions", output / ".tool-versions")
    print(f"Prepared {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk-root", type=Path, default=Path(__file__).resolve().parents[4])
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    prepare(args.sdk_root.resolve(), args.output.resolve())
