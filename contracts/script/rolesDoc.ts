/// Who controls a v2 deployment, read live from the chain and written as
/// `deployments/<namespace>/roles.md` beside the namespace's `addresses.md`.
///
/// Every account and contract is named as well as addressed, so a reader can check
/// the table against the chain without a lookup. The roles come from each
/// contract's `roles()` at the current block, for every (resource, account) its
/// role-change events ever named; ownership and upgrade authority come from
/// `owner()` and the ERC-1967 admin slot. Nothing is taken from what the deploy
/// meant to grant.

import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { type Address, getAddress, zeroAddress } from "viem";

import { explorerUrl, isProxyArtifact, markdownTable } from "./addressDocs.js";
import { describeRoleBitmap } from "./migrations/roleAudit.js";

export type RoleFamily = "REGISTRY" | "RESOLVER" | "ORACLE" | "ADDRESS_SET";

/// A named address: a deployed contract or a known account.
export type Labelled = { label: string; address: Address };

export type RoleHolding = {
  contract: Labelled;
  /// The resource the roles are held at: zero for the whole contract, else one entry.
  resource: bigint;
  /// The label of the entry the resource belongs to, where the contract registered it.
  entry?: string;
  holder: Labelled;
  roles: bigint;
  family: RoleFamily;
};

/// Where a holding applies, as the role mapping shows it.
export function scopeOf(holding: RoleHolding): string {
  if (holding.resource === 0n) return "registry-wide";
  return holding.entry
    ? `"${holding.entry}" entry`
    : `resource 0x${holding.resource.toString(16)}`;
}

export type ContractControl = {
  contract: Labelled;
  owner?: Labelled;
  proxyAdmin?: Labelled;
  /// Whether a registry counts as emancipated; undefined for anything else.
  emancipated?: boolean;
};

export type RoleMap = {
  network: string;
  chainId: number;
  block: bigint;
  readAt: string;
  holdings: RoleHolding[];
  control: ContractControl[];
  /// Registries whose per-name roles are left out: they belong to the names'
  /// owners, not to anyone administering the deployment.
  namespaceRegistries: string[];
  /// The role audit run against the same reads: the migration stage it checked, and
  /// every difference it found.
  audit?: { stage: string; findings: string[] };
};

/// The role vocabulary a contract uses, from the contract type its deployment
/// record names. Registries, resolvers, the rent oracle and address sets reuse the
/// same bit positions for different roles.
export function roleFamily(contractName: string): RoleFamily {
  if (/AddressSet/.test(contractName)) return "ADDRESS_SET";
  if (/Oracle/.test(contractName)) return "ORACLE";
  if (/Resolver/.test(contractName) && !/Registry/.test(contractName))
    return "RESOLVER";
  return "REGISTRY";
}

/// Names each address. A deployed contract takes its deployment name, preferring
/// the base name over its `_Proxy`/`_Implementation` artifacts; a known account takes
/// every label given for it, so the owner on mainnet reads as the DAO and as the owner.
export function addressLabels(
  deploymentNames: Array<{ name: string; address: Address }>,
  accounts: Labelled[],
): (address: Address) => string {
  const names = new Set(deploymentNames.map((d) => d.name));
  const byAddress = new Map<string, string>();
  for (const { name, address } of [...deploymentNames].sort((a, b) =>
    a.name.localeCompare(b.name),
  )) {
    const key = address.toLowerCase();
    const existing = byAddress.get(key);
    if (!existing || isProxyArtifact(existing, names)) byAddress.set(key, name);
  }
  const accountLabels = new Map<string, string[]>();
  for (const { label, address } of accounts) {
    const key = address.toLowerCase();
    const list = accountLabels.get(key) ?? [];
    if (!list.includes(label)) list.push(label);
    accountLabels.set(key, list);
  }
  return (address) => {
    if (address === zeroAddress) return "nobody";
    const key = address.toLowerCase();
    const parts = [
      ...(accountLabels.get(key) ?? []),
      ...(byAddress.has(key) ? [byAddress.get(key)!] : []),
    ];
    return parts.length ? parts.join(" / ") : "unlabelled";
  };
}

function addressCell(chainId: number, address: Address): string {
  const url = explorerUrl(chainId, address);
  return url ? `[${address}](${url})` : address;
}

function named(chainId: number, item: Labelled | undefined): string {
  if (!item) return "—";
  return `**${item.label}**<br>${addressCell(chainId, item.address)}`;
}

/// The roles a holder has, named in the contract's own vocabulary, with the raw
/// bitmap so the names can be checked against the contract.
function rolesCell(holding: RoleHolding): string {
  // A bare `|` would end the table cell.
  const names = describeRoleBitmap(holding.roles, holding.family)
    .split(" | ")
    .join(", ");
  return `${names}<br>\`0x${holding.roles.toString(16)}\``;
}

export function renderRolesMarkdown(
  map: RoleMap,
  generatedBy = "`bun run migration -- phase verify-roles`",
): string {
  const { chainId } = map;
  const lines: string[] = [
    `# ENSv2 ${map.network} role mapping`,
    "",
    `> Auto-generated by ${generatedBy}. Do not edit by hand.`,
    "",
    "Who can do what on each contract of this deployment, read from the chain. A",
    "role named `X_ADMIN` lets its holder grant and revoke `X`, and grant `X_ADMIN`",
    "itself.",
    "",
    `- **Network:** ${map.network}`,
    `- **Chain ID:** ${chainId}`,
    `- **Read at block:** ${map.block}`,
    `- **Read at:** ${map.readAt}`,
  ];
  if (map.namespaceRegistries.length) {
    lines.push(
      `- **Not listed:** the roles each name's owner holds on its own name in ${map.namespaceRegistries.join(", ")}`,
    );
  }

  if (map.audit) {
    const { stage, findings } = map.audit;
    lines.push(
      "",
      "## Audit",
      "",
      findings.length === 0
        ? `The root and .eth registries match what the migration intends at the \`${stage}\` stage, in both directions: nobody holds a role the stage does not grant, and nobody lacks one it does.`
        : `**The root and .eth registries do not match what the migration intends at the \`${stage}\` stage:**`,
      ...(findings.length ? ["", ...findings.map((f) => `- ${f}`)] : []),
    );
  }

  const byContract = new Map<string, RoleHolding[]>();
  for (const holding of map.holdings) {
    const key = holding.contract.address.toLowerCase();
    byContract.set(key, [...(byContract.get(key) ?? []), holding]);
  }
  const contracts = [...byContract.values()].sort((a, b) =>
    a[0].contract.label.localeCompare(b[0].contract.label),
  );

  lines.push("", "## Roles");
  for (const holdings of contracts) {
    const { contract } = holdings[0];
    lines.push(
      "",
      `### ${contract.label}`,
      "",
      addressCell(chainId, contract.address),
      "",
      markdownTable([
        ["Scope", "Holder", "Roles"],
        ...holdings
          .sort(
            (a, b) =>
              scopeOf(a).localeCompare(scopeOf(b)) ||
              a.holder.label.localeCompare(b.holder.label),
          )
          .map((holding) => [
            scopeOf(holding),
            named(chainId, holding.holder),
            rolesCell(holding),
          ]),
      ]),
    );
  }

  const owned = map.control
    .filter((c) => c.owner || c.proxyAdmin)
    .sort((a, b) => a.contract.label.localeCompare(b.contract.label));
  lines.push(
    "",
    "## Owners and upgrade admins",
    "",
    "`owner()` where the contract has one, and the ERC-1967 proxy admin where it is set.",
    "",
    markdownTable([
      ["Contract", "Owner", "Proxy admin"],
      ...owned.map((c) => [
        named(chainId, c.contract),
        named(chainId, c.owner),
        named(chainId, c.proxyAdmin),
      ]),
    ]),
  );

  const registries = map.control
    .filter((c) => c.emancipated !== undefined)
    .sort((a, b) => a.contract.label.localeCompare(b.contract.label));
  if (registries.length) {
    lines.push(
      "",
      "## Registry emancipation",
      "",
      "A registry is emancipated when nobody holds a registry-wide role that reaches its names: setting a name's child registry or resolver, unregistering it, upgrading the registry, or controlling transfers. Until then the registry refuses safe transfers of its names.",
      "",
      markdownTable([
        ["Registry", "Emancipated"],
        ...registries.map((c) => [
          named(chainId, c.contract),
          c.emancipated ? "yes" : "**no**",
        ]),
      ]),
    );
  }
  lines.push("");
  return lines.join("\n");
}

/// Writes the role mapping to `<deploymentsDir>/<namespace>/roles.md` and returns
/// its path.
export function writeRolesMarkdown(
  map: RoleMap,
  deploymentsDir: string,
  namespace: string,
): string {
  const dir = join(deploymentsDir, namespace);
  mkdirSync(dir, { recursive: true });
  const path = join(dir, "roles.md");
  writeFileSync(path, renderRolesMarkdown(map));
  return path;
}

export const labelled = (
  label: (address: Address) => string,
  address: Address,
): Labelled => ({ label: label(getAddress(address)), address: getAddress(address) });
