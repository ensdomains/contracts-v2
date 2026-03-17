import { expect } from "vitest";

export { expect };

// expectVar({ x }) <==> expect(x, 'x')
export function expectVar<T>(obj: Record<string, T>, tag?: string) {
  const [[k, v]] = Object.entries(obj);
  return expect(v, tag ? `k: ${tag}` : k);
}
