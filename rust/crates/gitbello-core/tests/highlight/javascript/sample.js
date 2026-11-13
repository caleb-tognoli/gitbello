// Line comment
import { readFile } from "node:fs/promises";
export default class Store extends EventTarget {
  static #count = 0;
  constructor(name = 'store') {
    super();
    this.name = name; /* block */ this.items = [];
  }

  async load(path) {
    const text = await readFile(path, "utf8");
    const data = JSON.parse(text);
    return data.items?.length ?? 0;
  }
}

/** JSDoc comment */
function greet(user) {
  const message = `Hello ${user.name}, you have ${user.count} items`;
  let re = /ab+c/gi;
  if (typeof user === "undefined" || user == null) {
    throw new Error("no user");
  }
  for (const [key, value] of Object.entries(user)) console.log(key, value);
  return 0x1f + 1.5e3 + 10n;
}
const page = `<p>${user.name}</p>
<p>${user.age}</p>`;
/* a block comment
   on two lines */ const after = 1;
