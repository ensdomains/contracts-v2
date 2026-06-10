// Stub for tsx module - Bun handles TypeScript natively, so tsx is not needed.
// This file is mapped via tsconfig paths so that `import 'tsx'` resolves here
// instead of loading the real tsx package (which fails under Bun).
if (!("Bun" in globalThis)) {
  await import("tsx");
}
