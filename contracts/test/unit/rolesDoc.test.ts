import { describe, expect, it } from "bun:test";
import { getAddress, zeroAddress } from "viem";

import { DEPLOYMENT_ROLES, ROLES } from "../../script/deploy-constants.js";
import {
  addressLabels,
  renderRolesMarkdown,
  roleFamily,
  type RoleMap,
} from "../../script/rolesDoc.js";

const DAO = getAddress("0xFe89cc7aBB2C4183683ab71653C4cdc9B02D44b7");
const REGISTRY = getAddress("0x00000000000000000000000000000000000000e1");
const REGISTRAR = getAddress("0x00000000000000000000000000000000000000e2");
const PROXY = getAddress("0x00000000000000000000000000000000000000e3");

describe("roleFamily", () => {
  it("names roles in the vocabulary of the contract type", () => {
    expect(roleFamily("PermissionedRegistry")).toBe("REGISTRY");
    expect(roleFamily("PermissionedAddressSet")).toBe("ADDRESS_SET");
    expect(roleFamily("StandardRentPriceOracle")).toBe("ORACLE");
    expect(roleFamily("PermissionedResolver")).toBe("RESOLVER");
  });
});

describe("addressLabels", () => {
  const label = addressLabels(
    [
      { name: "ContractNamer_Proxy", address: PROXY },
      { name: "ContractNamer", address: PROXY },
      { name: "ETHRegistry", address: REGISTRY },
    ],
    [
      { label: "owner", address: DAO },
      { label: "ENS DAO timelock", address: DAO },
    ],
  );

  it("names a proxied contract by its base deployment", () => {
    expect(label(PROXY)).toBe("ContractNamer");
    expect(label(REGISTRY)).toBe("ETHRegistry");
  });

  it("gives an account every label it has", () => {
    expect(label(DAO)).toBe("owner / ENS DAO timelock");
  });

  it("names the zero address and leaves an unknown one unlabelled", () => {
    expect(label(zeroAddress)).toBe("nobody");
    expect(label(REGISTRAR)).toBe("unlabelled");
  });
});

describe("renderRolesMarkdown", () => {
  const map: RoleMap = {
    network: "mainnet",
    chainId: 1,
    block: 123n,
    readAt: "2026-10-02T00:00:00.000Z",
    holdings: [
      {
        contract: { label: "ETHRegistry", address: REGISTRY },
        resource: 0n,
        holder: { label: "owner / ENS DAO timelock", address: DAO },
        roles: DEPLOYMENT_ROLES.ETH_REGISTRY_ROOT,
        family: "REGISTRY",
      },
      {
        contract: { label: "ETHRegistry", address: REGISTRY },
        resource: 0n,
        holder: { label: "ETHRegistrar", address: REGISTRAR },
        roles: DEPLOYMENT_ROLES.ETH_REGISTRAR_ROOT,
        family: "REGISTRY",
      },
    ],
    control: [
      {
        contract: { label: "ETHRegistry", address: REGISTRY },
        emancipated: false,
      },
      {
        contract: { label: "ETHRegistrar", address: REGISTRAR },
        owner: { label: "owner / ENS DAO timelock", address: DAO },
      },
    ],
    namespaceRegistries: ["ETHRegistry"],
  };
  const markdown = renderRolesMarkdown(map);

  it("names and addresses every holder and contract", () => {
    expect(markdown).toContain("### ETHRegistry");
    expect(markdown).toContain(
      `**owner / ENS DAO timelock**<br>[${DAO}](https://etherscan.io/address/${DAO})`,
    );
    expect(markdown).toContain(
      `**ETHRegistrar**<br>[${REGISTRAR}](https://etherscan.io/address/${REGISTRAR})`,
    );
  });

  it("keeps every table row to its columns", () => {
    // A role list joined with a bare `|` would split its cell into more columns.
    for (const table of markdown
      .split("\n\n")
      .filter((b) => b.startsWith("|"))) {
      const rows = table.trim().split("\n");
      const columns = rows[0].split(" | ").length;
      for (const row of rows) expect(row.split(" | ").length).toBe(columns);
    }
    expect(markdown).toContain("REGISTRAR, RENEW");
  });

  it("shows the raw bitmap beside the role names", () => {
    expect(markdown).toContain(
      `\`0x${(ROLES.REGISTRY.REGISTRAR | ROLES.REGISTRY.RENEW).toString(16)}\``,
    );
  });

  it("flags a registry that is not emancipated", () => {
    expect(markdown).toMatch(/ETHRegistry\*\*<br>.*\| \*\*no\*\* \|/);
  });

  it("says which per-name roles it leaves out", () => {
    expect(markdown).toContain(
      "the roles each name's owner holds on its own name in ETHRegistry",
    );
  });
});
