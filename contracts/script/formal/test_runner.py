"""Regression tests for the verification gate's false-pass failure modes."""

import copy
import unittest

from run_hca import canonical_type, diagnostics, validate_results


IDENTITY = "test/formal/hca/Example.t.sol:ExampleTest"
SIGNATURE = "check_access(address)"
EXPECTED = {(IDENTITY, SIGNATURE)}


def successful_payload():
    return {
        "exitcode": 0,
        "test_results": {
            IDENTITY: [{
                "name": SIGNATURE,
                "exitcode": 0,
                "num_models": 0,
                "models": [],
                "num_paths": [3, 2, 0],
                "num_bounded_loops": 0,
            }]
        },
    }


class ResultGateTests(unittest.TestCase):
    def test_complete_property_passes(self):
        self.assertEqual(validate_results(EXPECTED, successful_payload()), [])

    def test_missing_property_fails(self):
        payload = successful_payload()
        payload["test_results"][IDENTITY] = []
        self.assertTrue(validate_results(EXPECTED, payload))

    def test_wrong_compilation_identity_fails(self):
        payload = successful_payload()
        payload["test_results"]["test/formal/hca/Other.t.sol:ExampleTest"] = payload["test_results"].pop(IDENTITY)
        self.assertTrue(validate_results(EXPECTED, payload))

    def test_unexpected_property_fails(self):
        payload = successful_payload()
        extra = copy.deepcopy(payload["test_results"][IDENTITY][0])
        extra["name"] = "check_other()"
        payload["test_results"][IDENTITY].append(extra)
        self.assertTrue(validate_results(EXPECTED, payload))

    def test_duplicate_property_fails(self):
        payload = successful_payload()
        payload["test_results"][IDENTITY] *= 2
        self.assertTrue(validate_results(EXPECTED, payload))

    def test_incomplete_and_failed_results_fail(self):
        failures = [
            ("exitcode", 1),
            ("exitcode", 2),
            ("exitcode", 3),
            ("exitcode", 4),
            ("exitcode", 5),
            ("num_paths", [3, 0, 0]),
            ("num_paths", [3, 2, 1]),
            ("num_paths", [1, 2, 0]),
            ("num_paths", None),
            ("num_paths", [True, 1, 0]),
            ("num_bounded_loops", 1),
            ("num_bounded_loops", None),
            ("num_models", 1),
            ("num_models", None),
            ("models", [{"is_valid": True}]),
            ("models", None),
        ]
        for field, value in failures:
            with self.subTest(field=field, value=value):
                payload = successful_payload()
                payload["test_results"][IDENTITY][0][field] = value
                self.assertTrue(validate_results(EXPECTED, payload))

    def test_process_failure_cannot_be_hidden_by_passing_properties(self):
        payload = successful_payload()
        payload["exitcode"] = 1
        self.assertTrue(validate_results(EXPECTED, payload))

    def test_malformed_json_shapes_fail(self):
        for payload in [None, [], {}, {"exitcode": 0, "test_results": []}]:
            with self.subTest(payload=payload):
                self.assertTrue(validate_results(EXPECTED, payload))

    def test_engine_diagnostics_fail(self):
        failures, metadata = diagnostics(
            "WARNING  loop bound reached\n"
            "ERROR    solver failed\n"
            "\x1b[31mCRITICAL crash\x1b[0m\n"
        )
        self.assertEqual(len(failures), 3)
        self.assertEqual(metadata, [])

    def test_source_name_warning_is_recorded(self):
        failures, metadata = diagnostics("WARNING  unknown deployed bytecode: 0x6000\n")
        self.assertEqual(failures, [])
        self.assertEqual(len(metadata), 1)

    def test_tuple_array_signature_retains_abi_shape(self):
        parameter = {
            "type": "tuple[]",
            "components": [{"type": "address"}, {"type": "tuple[2]", "components": [{"type": "uint256"}]}],
        }
        self.assertEqual(canonical_type(parameter), "(address,(uint256)[2])[]")


if __name__ == "__main__":
    unittest.main()
