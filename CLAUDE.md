# Forge/foundry tests

- When running tests they should be run from the contracts/ subfolder.
- See package.json for the test commands.
- When testing for event emission never use vm.expectEmit, always use vm.recordLogs and actually check the logs properly.
- Do not use --via-ir when compiling contracts and tests. If there are Solidity stack too deep errors then fix them through code refactoring.
- When doing vm.prank and vm.expectRevert together for a call, always place the vm.expectRevert call before the vm.prank call.

### Test commands:

These are all to be run from within the contracts/ folder:

* `forge test` - run forge solidity tests
* `bun run test:hardhat` - run hardhat tests
* `bun run test:e2e` - run end-to-end tests

# Lint command:

Run this in the contracts/ folder:

* `bun run lint`

# Comment Guidelines

When writing comments in code:
- Comments should describe what the code does, not what changed
- Avoid hardcoded values in comments - describe the behavior conceptually
- Don't refer to specific variables or constants by name unless necessary
- Write comments as descriptors of functionality, not as a changelog

# Inline Documentation

All Solidity contracts, libraries, and interfaces must have NatSpec inline documentation. When making any code changes, inline docs MUST be kept updated alongside the code — adding, modifying, or removing documentation as needed to accurately reflect the current behavior.

# important-instruction-reminders
Do what has been asked; nothing more, nothing less.
NEVER create files unless they're absolutely necessary for achieving your goal.
ALWAYS prefer editing an existing file to creating a new one.
NEVER proactively create documentation files (*.md) or README files. Only create documentation files if explicitly requested by the User.
- when writing tests that involve constants already defined in the source (e.g contracts/src/registry/libraries/RegistryRolesLib.sol) use those defined constants directly instead of hardcoding their values in the tests.