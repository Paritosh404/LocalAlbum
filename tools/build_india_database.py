#!/usr/bin/env python3
"""Build the compact GeoNames assets bundled by Location Albums."""

from __future__ import annotations

import argparse
import json
import re
import sqlite3
import zipfile
from pathlib import Path


INDIA_GEONAME_ID = "1269750"


def clean_state_name(value: str) -> str:
    value = re.sub(r"^(State|Union Territory|National Capital Territory) of ", "", value)
    return value.strip()


def fields(line: str) -> list[str]:
    result = line.rstrip("\n").split("\t")
    if len(result) < 19:
        result.extend([""] * (19 - len(result)))
    return result


def read_states(source_zip: Path) -> dict[str, str]:
    states: dict[str, str] = {}
    with zipfile.ZipFile(source_zip) as archive, archive.open("IN.txt") as raw:
        for byte_line in raw:
            row = fields(byte_line.decode("utf-8"))
            if row[6] == "A" and row[7] == "ADM1":
                display_name = row[2] or row[1]
                states[row[10]] = clean_state_name(display_name)
    return states


def build_database(source_zip: Path, destination: Path) -> tuple[int, int]:
    if destination.exists():
        destination.unlink()
    destination.parent.mkdir(parents=True, exist_ok=True)
    states = read_states(source_zip)

    connection = sqlite3.connect(destination)
    try:
        connection.executescript(
            """
            PRAGMA journal_mode = OFF;
            PRAGMA synchronous = OFF;
            PRAGMA temp_store = MEMORY;
            PRAGMA page_size = 4096;

            CREATE TABLE metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            ) WITHOUT ROWID;

            CREATE TABLE states (
                code TEXT PRIMARY KEY,
                name TEXT NOT NULL
            ) WITHOUT ROWID;

            CREATE TABLE places (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                latitude REAL NOT NULL,
                longitude REAL NOT NULL,
                state_code TEXT NOT NULL,
                population INTEGER NOT NULL,
                feature_code TEXT NOT NULL
            );

            CREATE VIRTUAL TABLE place_rtree USING rtree(
                id,
                min_latitude, max_latitude,
                min_longitude, max_longitude
            );
            """
        )
        connection.executemany(
            "INSERT INTO states(code, name) VALUES (?, ?)", sorted(states.items())
        )
        connection.executemany(
            "INSERT INTO metadata(key, value) VALUES (?, ?)",
            [
                ("source", "GeoNames IN.zip"),
                ("license", "CC BY 4.0"),
                ("country", "IN"),
                ("schema_version", "1"),
            ],
        )

        place_batch: list[tuple[object, ...]] = []
        rtree_batch: list[tuple[object, ...]] = []
        place_count = 0
        with zipfile.ZipFile(source_zip) as archive, archive.open("IN.txt") as raw:
            for byte_line in raw:
                row = fields(byte_line.decode("utf-8"))
                if row[6] != "P":
                    continue
                identifier = int(row[0])
                name = row[2] or row[1]
                latitude = float(row[4])
                longitude = float(row[5])
                state_code = row[10]
                population = int(row[14] or 0)
                feature_code = row[7]
                place_batch.append(
                    (
                        identifier,
                        name,
                        latitude,
                        longitude,
                        state_code,
                        population,
                        feature_code,
                    )
                )
                rtree_batch.append(
                    (identifier, latitude, latitude, longitude, longitude)
                )
                place_count += 1

                if len(place_batch) >= 10_000:
                    connection.executemany(
                        "INSERT INTO places VALUES (?, ?, ?, ?, ?, ?, ?)", place_batch
                    )
                    connection.executemany(
                        "INSERT INTO place_rtree VALUES (?, ?, ?, ?, ?)", rtree_batch
                    )
                    place_batch.clear()
                    rtree_batch.clear()

        if place_batch:
            connection.executemany(
                "INSERT INTO places VALUES (?, ?, ?, ?, ?, ?, ?)", place_batch
            )
            connection.executemany(
                "INSERT INTO place_rtree VALUES (?, ?, ?, ?, ?)", rtree_batch
            )

        connection.commit()
        connection.execute("VACUUM")
        connection.execute("PRAGMA optimize")
        return place_count, len(states)
    finally:
        connection.close()


def extract_india_boundary(shape_zip: Path, destination: Path) -> None:
    with zipfile.ZipFile(shape_zip) as archive:
        with archive.open("shapes_simplified_low.json") as source:
            collection = json.load(source)
    india = next(
        feature
        for feature in collection["features"]
        if str(feature["properties"].get("geoNameId")) == INDIA_GEONAME_ID
    )
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(
        json.dumps(india["geometry"], ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--india-zip", type=Path, required=True)
    parser.add_argument("--shapes-zip", type=Path, required=True)
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--boundary", type=Path, required=True)
    args = parser.parse_args()

    places, states = build_database(args.india_zip, args.database)
    extract_india_boundary(args.shapes_zip, args.boundary)
    print(f"Built {args.database}: {places:,} populated places, {states} states/UTs")
    print(f"Built {args.boundary}")


if __name__ == "__main__":
    main()

