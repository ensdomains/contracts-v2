# Fast Vyper repair audit

- Ready for full validation: **False**

```json
{
  "timestamp": 1787334854,
  "baseline": "a971bd6449154045e2b26ff13d0e56027452f407",
  "head": "26cb550a0c96864ae03ad3c2ef39ee8cbbb5f773",
  "source_executables": 58,
  "vyper_sources": 18,
  "missing_ports": [
    "dns/DNSAliasResolver.sol",
    "dns/DNSTLDResolver.sol",
    "dns/DNSTXTResolver.sol",
    "dns/libraries/DNSTXTParserLib.sol",
    "erc1155/ERC1155Singleton.sol",
    "hca/HCAAuthorizer.sol",
    "hca/HCAFundingSessionValidator.sol",
    "hca/HCAOwnerAndSessionValidator.sol",
    "hca/StandaloneHCAFactory.sol",
    "hca/StandaloneSingleOwnerHCA.sol",
    "migration/AbstractWrapperReceiver.sol",
    "migration/Graveyard.sol",
    "migration/LockedMigrationController.sol",
    "migration/LockedWrapperReceiver.sol",
    "migration/MigrationHelper.sol",
    "migration/UnlockedMigrationController.sol",
    "migration/libraries/LibMigration.sol",
    "registrar/AbstractETHRegistrar.sol",
    "registrar/ETHRegistrar.sol",
    "registrar/ETHRenewerV1.sol",
    "registrar/StandardRentPriceOracle.sol",
    "registry/PermissionedRegistry.sol",
    "registry/UserRegistry.sol",
    "registry/WrapperRegistry.sol",
    "registry/libraries/RegistryRolesLib.sol",
    "resolver/AbstractMirrorResolver.sol",
    "resolver/AbstractRecordResolver.sol",
    "resolver/ENSV1Resolver.sol",
    "resolver/ENSV2Resolver.sol",
    "resolver/PermissionedResolver.sol",
    "resolver/PublicResolverV2.sol",
    "resolver/libraries/PermissionedResolverLib.sol",
    "resolver/libraries/ResolverProfileRewriterLib.sol",
    "reverse-registrar/DefaultReverseRegistrarAdapter.sol",
    "reverse-registrar/L2ReverseRegistrar.sol",
    "reverse-registrar/L2ReverseRegistrarWithMigration.sol",
    "reverse-registrar/ReverseRegistrarAdapter.sol",
    "reverse-registrar/StandaloneReverseRegistrar.sol",
    "reverse-registrar/libraries/AccountNamerLib.sol",
    "testnet/TestnetV1PremigrationRegistrar.sol",
    "universalResolver/UniversalHelper.sol",
    "universalResolver/UniversalResolverV2.sol",
    "universalResolver/UpgradableUniversalResolverProxy.sol",
    "universalResolver/libraries/LibRegistry.sol",
    "utils/LibISO8601.sol",
    "utils/LibMem.sol",
    "utils/WrappedErrorLib.sol"
  ],
  "compile_rc": 1,
  "compile_failures": [
    "vyper/access_control/EnhancedAccessControl.vy",
    "vyper/common/UUPSUpgradeable.vy"
  ],
  "forge_rc": 0,
  "hardhat_rc": -1,
  "e2e_rc": -1,
  "gas_csv_ok": false,
  "gas_json_ok": false,
  "gas_md_ok": false,
  "eip170_failures": [],
  "forbidden_patterns": [
    "contracts/vyper/access_control/EnhancedAccessControl.vy: unconditional test success"
  ],
  "complete": false
}
```

Long Forge/Hardhat/E2E validation is performed by downstream parallel jobs.
