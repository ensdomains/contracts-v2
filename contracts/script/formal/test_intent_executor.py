"""Regression checks for runtime substitution and historical deployment mismatches."""

import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from check_intent_executor import HELPER, SNAPSHOT, check_immutables, check_rpc, verify


class ExecutorAttestationTests(unittest.TestCase):
    def setUp(self):
        self.snapshot = json.loads(SNAPSHOT.read_text())
        self.helper = HELPER.read_text()

    def verify_copy(self, snapshot=None, helper=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            snapshot_path, helper_path = root / "snapshot.json", root / "helper.sol"
            snapshot_path.write_text(json.dumps(self.snapshot if snapshot is None else snapshot))
            helper_path.write_text(self.helper if helper is None else helper)
            return verify(snapshot_path, helper_path)

    def test_recorded_offline_fixture_passes(self):
        report = self.verify_copy()
        self.assertIs(report["passed"], True)
        self.assertEqual(report["mode"], "offline")
        self.assertGreater(report["immutable_regions"], 0)

    def test_embedded_runtime_substitution_fails(self):
        changed = self.helper.replace('return hex"60', 'return hex"61', 1)
        self.assertNotEqual(changed, self.helper)
        with self.assertRaisesRegex(ValueError, "embedded runtime differs"):
            self.verify_copy(helper=changed)

    def test_incorrect_runtime_hash_fails(self):
        self.snapshot["networks"]["mainnet"]["implementation"]["sha256"] = "00" * 32
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            self.verify_copy()

    def test_proxy_control_storage_substitution_fails(self):
        storage = self.snapshot["networks"]["sepolia"]["proxy"]["storage"]
        storage[next(iter(storage))] = "0x" + "00" * 32
        with self.assertRaisesRegex(ValueError, "control storage differs"):
            self.verify_copy()

    def test_normalization_does_not_hide_changed_opcodes(self):
        implementations = {name: bytes.fromhex(network["implementation"]["runtime"][2:])
                           for name, network in self.snapshot["networks"].items()}
        original = implementations["mainnet"]
        implementations["mainnet"] = bytes([original[0] ^ 1]) + original[1:]
        with self.assertRaisesRegex(ValueError, "outside declared immutable"):
            check_immutables(self.snapshot, implementations)

    def test_incorrect_immutable_value_fails(self):
        source = self.snapshot["source_verification"]["implementation"]
        immutable = next(iter(source["immutable_values"]))
        source["immutable_values"][immutable]["mainnet"][0] = "0x" + "00" * 32
        with self.assertRaisesRegex(ValueError, "value mismatch"):
            self.verify_copy()

    def rpc_fixture(self, method, params):
        network = self.snapshot["networks"]["mainnet"]
        if method == "eth_chainId":
            return hex(network["chain_id"])
        if method == "eth_getBlockByNumber":
            self.assertEqual(params, [hex(network["block_number"]), False])
            return {"number": hex(network["block_number"]), "hash": network["block_hash"],
                    "timestamp": hex(network["block_timestamp"])}
        self.assertEqual(params[-1], hex(network["block_number"]))
        if method == "eth_getCode":
            for kind in ("proxy", "implementation"):
                if params[0] == network[kind]["address"]:
                    return network[kind]["runtime"]
        if method == "eth_getStorageAt":
            self.assertEqual(params[0], network["proxy"]["address"])
            return network["proxy"]["storage"][params[1]]
        self.fail(f"Unexpected RPC request: {method} {params}")

    def test_rpc_checks_exact_historical_block_twice(self):
        with patch("check_intent_executor.rpc", side_effect=lambda endpoint, method, params: self.rpc_fixture(method, params)) as mocked:
            check_rpc("mainnet", self.snapshot["networks"]["mainnet"])
        self.assertEqual(sum(call.args[1] == "eth_getBlockByNumber" for call in mocked.call_args_list), 2)

    def test_rpc_rejects_wrong_chain_block_code_and_storage(self):
        bad_values = {
            "eth_chainId": "0x2",
            "eth_getBlockByNumber": {"hash": "0x" + "00" * 32},
            "eth_getCode": "0x00",
            "eth_getStorageAt": "0x" + "00" * 32,
        }
        for bad_method, bad_value in bad_values.items():
            with self.subTest(method=bad_method):
                def substituted(endpoint, method, params):
                    value = self.rpc_fixture(method, params)
                    if method == bad_method:
                        if isinstance(value, dict):
                            value = {**value, **copy.deepcopy(bad_value)}
                        else:
                            value = bad_value
                    return value

                with patch("check_intent_executor.rpc", side_effect=substituted):
                    with self.assertRaises(ValueError):
                        check_rpc("mainnet", self.snapshot["networks"]["mainnet"])


if __name__ == "__main__":
    unittest.main()
