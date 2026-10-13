"""Exercise the production UID parser without running checkout preparation.

The CLI executes filesystem transitions at module load. Compile its actual
pure function definitions from the source AST; no OS or process result is
mocked. Native Darwin census behavior remains covered by the real CI setup.
"""
import ast
from pathlib import Path
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "nix/ci-initial-samples-transition.py"
NAMES = {"require", "darwin_numeric_uid", "darwin_uid_diagnostic"}
tree = ast.parse(SOURCE.read_text(), filename=str(SOURCE))
definitions = [node for node in tree.body
                if isinstance(node, ast.FunctionDef) and node.name in NAMES]
assert len(definitions) == len(NAMES)
namespace = {}
exec(compile(ast.Module(body=definitions, type_ignores=[]), str(SOURCE), "exec"), namespace)


class DarwinUIDParser(unittest.TestCase):
    def test_signed_kernel_uid_values(self):
        for text, expected in [
            ("0", 0), ("1003", 1003), ("2147483647", 2147483647),
            ("2147483648", 2147483648), ("4294967295", 4294967295),
            ("-2147483648", 2147483648), ("-2", 4294967294),
            ("-1", 4294967295),
        ]:
            with self.subTest(text=text):
                self.assertEqual(namespace["darwin_numeric_uid"](text), expected)

    def test_malformed_and_out_of_range_values_refuse(self):
        for text in ["", "-", "-0", "+1", " 1", "1 ", "1.0", "root",
                      "١", "4294967296", "-2147483649", "--2", "0x10"]:
            with self.subTest(text=text), self.assertRaises(RuntimeError):
                namespace["darwin_numeric_uid"](text)

    def test_diagnostic_preserves_only_valid_numeric_identity(self):
        diagnostic = namespace["darwin_uid_diagnostic"]
        self.assertEqual(diagnostic(["12702", "-2", "Ss"]), "4294967294")
        self.assertEqual(diagnostic(["12702", "root", "Ss"]), "unknown-uid")
        self.assertEqual(diagnostic(["12702"]), "unknown-uid")


if __name__ == "__main__":
    unittest.main()
