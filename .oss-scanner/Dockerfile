# Build for Anthropic's OSS Scanner (https://github.com/anthropics/oss-scanner), mirroring CI (.github/actions/setup
# and .github/workflows/main.yml). The root Dockerfile builds the pruned devnet image and is unrelated.
FROM node:24.1.0-bookworm
ENV DEBIAN_FRONTEND=noninteractive \
    CI=true \
    FOUNDRY_DISABLE_NIGHTLY_WARNING=true \
    NODE_OPTIONS=--max-old-space-size=6144
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl git unzip \
    && rm -rf /var/lib/apt/lists/*

# Bun at .bun-version, and Foundry.
RUN curl -fsSL https://bun.sh/install | bash -s "bun-v1.3.14"
RUN curl -fsSL https://foundry.paradigm.xyz | bash && /root/.foundry/bin/foundryup
ENV PATH="/root/.bun/bin:/root/.foundry/bin:${PATH}"

# scanner contract: the checkout lives inside the image, at /src
COPY . /src
WORKDIR /src

# The scanner clones without submodules; the Solidity dependencies (forge-std, OpenZeppelin, solady, ens-contracts,
# Nexus and others) are all submodules under contracts/lib.
RUN git config --global --add safe.directory '*' \
    && git submodule update --init --recursive --jobs 8

# The root postinstall unpacks the migration fixture corpus used by the unit tests.
RUN bun install --frozen-lockfile

# The ens-contracts submodule is compiled separately; its artifacts are inputs to this repo's Hardhat build. The
# repo's devnet Dockerfile patches the locked @unruggable/gateways exports first (docker/patchUnruggableGateways.cjs,
# which expects the checkout at /app).
RUN ln -s /src /app \
    && cd contracts/lib/ens-contracts \
    && bun install \
    && node /src/docker/patchUnruggableGateways.cjs \
    && bun run compile

# forge build and hardhat compile download solc on first use; both have to run now, while online.
WORKDIR /src/contracts
RUN bun run compile

# Fast sanity run of the suites. Fuzz runs are reduced here only; foundry.toml's default (4096) still applies to the
# scanner. The e2e suite (bun run test:e2e) starts local anvil instances and is left for the scanner to run.
RUN FOUNDRY_FUZZ_RUNS=256 forge test || echo "WARNING: forge test reported failures"
RUN bun run test:hardhat || echo "WARNING: hardhat tests reported failures"
RUN bun run test:unit || echo "WARNING: unit tests reported failures"

# From here on there is no network: stop forge from trying to fetch solc versions or check for releases.
ENV FOUNDRY_OFFLINE=true
