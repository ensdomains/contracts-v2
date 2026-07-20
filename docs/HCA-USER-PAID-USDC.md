# HCA user-paid USDC execution

## Goal

Pay registration and Rhinestone execution fees from USDC. A fresh source wallet needs no native gas and two signatures.

## Route

1. The wallet signs an EIP-2612 permit for its counterfactual source Nexus.
2. The wallet signs the Permit2 intent.
3. Rhinestone deploys the source Nexus, pulls the route budget, and claims the required USDC.
4. The destination fill deploys and funds the HCA, enables a refund-bounded session, and commits.
5. After the commitment delay, the session reveals. Later session operations need no wallet prompt.

The Permit2 signature is also the HCA owner signature. Do not request another destination signature.

Submit with `sponsored: false` and USDC as `feeAsset`. The source budget must cover the destination funds and Rhinestone's quoted fees.

Unused source budget remains in the user's Nexus. Show that balance and let the user reuse or withdraw it.

The tested route uses two wallet signatures, no wallet transactions, and no native gas. An onchain approval is a fallback for tokens without permits and requires source-chain gas.

## Session refunds

`enableSessionWithRefund(...)` binds the session to a refund token and maximum exchange rate, gas overhead, and token amount. Each session intent signs Rhinestone's existing `GasRefund` fields.

The validator accepts only the signed amount approved to Rhinestone's fixed refund paymaster. Registrar payment approval remains separate. The SDK adapter packs the existing refund fields; the orchestrator format does not change.

## Live evidence

The Arbitrum Sepolia-to-Sepolia route passed live with a fresh wallet on 17 July 2026:

- Wallet: `0xa2915FB9260b8aACc6069997Ca23cFdA07f7FDDf`
- Source Nexus: `0xd80E212b776622c951a495DaAD14e22720C10D4f`
- Destination HCA: `0xFc97122D308DA72E05b56b04AE88923E26EA93D2`
- Names: `hcamrof67nea.eth`, `hcamrof67neb.eth`
- Source claim: `0xeab1e751074bc57e71dcf9245283e93cfb7bde1773c8d70a848f72c71696499d`
- Destination fill: `0x085a37764d88c25ee7b4fdc19e755e7666de66f8bd86ba49b2ea34a3200182ce`
- First reveal: `0x082c4f5ae24401fe47cfeda0dd740cec800a0173297271489a7d2d26427998e9`
- Second commit: `0x62338be6acbc629d67a0789e9c6f5ca906f6ae0d935b236ce436d0e8e8ca4e0c`
- Second reveal: `0x26e1b9e8320809e5c8213a05915b6812e9a3fd437df6b60882170ba2c8898e96`

The wallet used two signatures, zero transactions, and zero native gas. The source pull consumed its EIP-2612 allowance, the Permit2 signature authorized both chains, and 14 USDC reached the HCA. The route spent 23.806801 of its 28 USDC source budget and left 4.193199 USDC in the Nexus. Session execution fees were 3.211147, 0.720191, and 2.289414 USDC.

Both names belong to the wallet. The wallet and HCA retain resolver roles, and the second name is the wallet's primary name.

No registrar, orchestrator, or registration-protocol change is required.

The live check stops if Circle rate-limits its faucet. Set `HCA_ALLOW_SOURCE_TEST_TOP_UP=1` only when funding the test wallet from `DEPLOYER_KEY` is acceptable.
