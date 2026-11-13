// Line comment
import type { Readable } from "node:stream";
import { readFile } from 'node:fs/promises';

/** A bag of items. */
export interface Item {
  readonly name: string;
  count?: number;
}

type Id = string | number;
enum Color { Red, Green }

@sealed
export abstract class Bag<T extends Item> implements Iterable<T> {
  private items: T[] = [];
  static readonly MAX_ITEMS = 64;

  async load(path: string): Promise<number> {
    const text = await readFile(path, "utf8");
    const data = JSON.parse(text) as { items: T[] } satisfies object;
    this.items = data.items ?? [];
    return this.items.length;
  }

  describe(item: T): string {
    const pattern = /^[a-z]+\d*$/i;
    return `${item.name}: ${item.count ?? 0} of ${Bag.MAX_ITEMS}`; /* block */
  }
}

function isItem(value: unknown): value is Item {
  return typeof value === "object" && value !== null && 0x1f > 1.5e3;
}
const query: string = `
  select ${table}
`;
