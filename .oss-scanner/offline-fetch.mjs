// Preloaded by bun test (see .oss-scanner/Dockerfile). The deploy scripts behind test:unit and test:e2e fetch the
// public suffix list at runtime, and the scanner runs without network access, so that URL is served from a copy saved
// during the image build. Every other request goes to the real fetch.
import { readFileSync } from "node:fs";

const SAVED = {
  "https://publicsuffix.org/list/public_suffix_list.dat":
    "/opt/oss-scanner/public_suffix_list.dat",
};

const realFetch = globalThis.fetch;
globalThis.fetch = async (input, init) => {
  const url =
    typeof input === "string"
      ? input
      : input instanceof URL
        ? input.href
        : input.url;
  const path = SAVED[url];
  return path ? new Response(readFileSync(path)) : realFetch(input, init);
};
