from __future__ import annotations

import os
import unittest
from unittest.mock import patch

from bolsa_licitacoes.scheduler import _bool_env, _csv_ints, _non_negative_int, _positive_int


class SchedulerConfigurationTests(unittest.TestCase):
    def test_configuration_parsers(self) -> None:
        with patch.dict(os.environ, {
            "TEST_LIST": "1, 6,13",
            "TEST_POSITIVE": "15",
            "TEST_ZERO": "0",
            "TEST_BOOL": "sim",
        }):
            self.assertEqual((1, 6, 13), _csv_ints("TEST_LIST", ""))
            self.assertEqual(15, _positive_int("TEST_POSITIVE", 1))
            self.assertEqual(0, _non_negative_int("TEST_ZERO", 1))
            self.assertTrue(_bool_env("TEST_BOOL", False))

    def test_positive_interval_rejects_zero(self) -> None:
        with patch.dict(os.environ, {"TEST_INTERVAL": "0"}):
            with self.assertRaises(ValueError):
                _positive_int("TEST_INTERVAL", 10)


if __name__ == "__main__":
    unittest.main()
