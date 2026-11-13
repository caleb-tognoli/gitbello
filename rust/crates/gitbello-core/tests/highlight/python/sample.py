#!/usr/bin/env python3
"""Module docstring on one line."""
from __future__ import annotations

import os
from dataclasses import dataclass

MAX_SIZE = 1_000


@dataclass(frozen=True)
class Item:
    name: str
    count: int = 0

    def total(self, price: float) -> float:
        return self.count * price  # multiply


async def main(items: list[Item]) -> None:
    path = os.path.join("a", 'b')
    raw = r"C:\temp"; data = b"\x00\xff"
    label = f"{len(items)} items, {MAX_SIZE=}"
    both = rf"\d{{2}} {path!r:>10}" + B'\x00'
    for item in items:
        if item.count > 0 and not item.name.startswith("_"):
            print(item.total(1.5e-3))
        elif item is None:
            continue
    try:
        await run()
    except (ValueError, KeyError) as err:
        raise RuntimeError("failed") from err
    lambda x: x ** 2
doc = """A docstring that
goes on, with "quotes" inside
"""
raw = rb'''raw \d
bytes'''
after = f"""{doc} and
{raw}"""
