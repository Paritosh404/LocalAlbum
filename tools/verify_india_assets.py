#!/usr/bin/env python3
"""Verify the generated offline assets with representative coordinates."""

from __future__ import annotations

import argparse
import json
import sqlite3
from pathlib import Path


def point_in_ring(point: tuple[float, float], ring: list[list[float]]) -> bool:
    inside = False
    previous = len(ring) - 1
    for current in range(len(ring)):
        xi, yi = ring[current]
        xj, yj = ring[previous]
        if (yi > point[1]) != (yj > point[1]):
            intersection = (xj - xi) * (point[1] - yi) / (yj - yi) + xi
            if point[0] < intersection:
                inside = not inside
        previous = current
    return inside


def contains(geometry: dict, latitude: float, longitude: float) -> bool:
    point = (longitude, latitude)
    for polygon in geometry["coordinates"]:
        if not polygon or not point_in_ring(point, polygon[0]):
            continue
        if not any(point_in_ring(point, hole) for hole in polygon[1:]):
            return True
    return False


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--boundary", type=Path, required=True)
    args = parser.parse_args()

    connection = sqlite3.connect(args.database)
    try:
        places = connection.execute("SELECT count(*) FROM places").fetchone()[0]
        states = connection.execute("SELECT count(*) FROM states").fetchone()[0]
        leh = connection.execute(
            """
            SELECT p.name, s.name, p.latitude, p.longitude
            FROM places p JOIN states s ON s.code = p.state_code
            WHERE p.name = 'Leh' AND s.name = 'Ladakh'
            ORDER BY p.population DESC LIMIT 1
            """
        ).fetchone()
    finally:
        connection.close()

    geometry = json.loads(args.boundary.read_text(encoding="utf-8"))
    assert places == 557_995, places
    assert states == 36, states
    assert leh is not None, "Leh, Ladakh is missing"
    assert contains(geometry, 34.16504, 77.58402), "Leh should be inside India"
    assert contains(geometry, 19.0760, 72.8777), "Mumbai should be inside India"
    assert not contains(geometry, 31.5204, 74.3587), "Lahore should be outside India"
    assert not contains(geometry, 27.7172, 85.3240), "Kathmandu should be outside India"
    print(f"Verified {places:,} places, {states} states/UTs, and India boundary checks")


if __name__ == "__main__":
    main()

