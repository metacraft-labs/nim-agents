"""Exercise the actual sample predicate with real selected-Git filesystem copies.

Extract only the production function because the CLI performs hook installation
at import. No process/filesystem results are mocked. This authenticates inactive
samples, not managed authority or an absence of historical chmod.
"""
import ast
import hashlib
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "nix/hook-ownership-guard.py"
tree = ast.parse(SOURCE.read_text(), filename=str(SOURCE))
definitions = [node for node in tree.body
                if isinstance(node, ast.FunctionDef) and node.name == "sample_inventory"]
assert len(definitions) == 1
namespace = {"hashlib": hashlib, "stat": stat}
exec(compile(ast.Module(body=definitions, type_ignores=[]), str(SOURCE), "exec"), namespace)
sample_inventory = namespace["sample_inventory"]
# Retain the exact production factory-only name guard as well: the general
# sample predicate intentionally leaves active, nonsample hooks to census().
factory_checks = [node for node in ast.walk(tree)
                  if isinstance(node, ast.If) and any(
                      isinstance(child, ast.Constant) and child.value ==
                      "Selected Git initialized an unexpected factory entry"
                      for child in ast.walk(node))]
assert len(factory_checks) == 1
factory_check = compile(ast.Module(body=factory_checks, type_ignores=[]), str(SOURCE), "exec")


class GitSampleModes(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="nim-agents-git-sample-modes-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.git = Path(shutil.which("git")).resolve(strict=True)
        self.templates = self.git.parent.parent / "share/git-core/templates"
        self.expected = {}
        for path in (self.templates / "hooks").iterdir():
            info = path.lstat()
            self.assertTrue(stat.S_ISREG(info.st_mode))
            self.assertTrue(path.name.endswith(".sample"))
            self.expected[path.name] = [stat.S_IMODE(info.st_mode), hashlib.sha256(path.read_bytes()).hexdigest()]
        self.assertGreater(len(self.expected), 1)
        self.assertTrue(all(mode & 0o111 for mode, _ in self.expected.values()))
        # Private Git configuration prevents inherited shared/template settings
        # from changing the real creation-boundary control.
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)

    def initialize(self, mask):
        repo = self.root / ("repo-" + oct(mask))
        subprocess.run([str(self.git), "init", "--template=" + str(self.templates), str(repo)],
                        env=self.env, check=True, capture_output=True, umask=mask)
        return repo / ".git/hooks"

    def test_distinct_historical_masks_preserve_real_identity(self):
        parent_mask = subprocess.check_output(["sh", "-c", "umask"], text=True)
        observations = []
        for mask in (0o022, 0o077):
            hooks = self.initialize(mask)
            before = sample_inventory(hooks, self.expected)
            self.assertEqual(set(before), set(self.expected))
            self.assertEqual({entry[0] for entry in before.values()}, {0o777 & ~mask})
            self.assertEqual(sample_inventory(hooks, self.expected), before)
            observations.append(before)
        self.assertNotEqual(observations[0], observations[1])
        self.assertEqual(subprocess.check_output(["sh", "-c", "umask"], text=True), parent_mask)

    def test_factory_refuses_real_nonsample_entry(self):
        hooks = self.initialize(0o022)
        context = {"fixture": hooks.parent.parent, "SAMPLES": self.expected}
        exec(factory_check, context)
        (hooks / "foreign-hook").write_text("foreign fixture entry\n")
        with self.assertRaises(RuntimeError):
            exec(factory_check, context)

    def test_real_foreign_sample_mutations_refuse(self):
        hooks = self.initialize(0o022)
        path = hooks / sorted(self.expected)[0]
        original = path.read_bytes()
        for mode in (0o700, 0o4755):
            with self.subTest(mode=oct(mode)):
                path.chmod(mode)
                with self.assertRaises(RuntimeError):
                    sample_inventory(hooks, self.expected)
                path.chmod(0o755)
        path.write_bytes(original + b"# foreign body\n")
        with self.assertRaises(RuntimeError):
            sample_inventory(hooks, self.expected)
        path.write_bytes(original)
        foreign = hooks / "foreign.sample"
        foreign.write_bytes(original)
        with self.assertRaises(RuntimeError):
            sample_inventory(hooks, self.expected)
        foreign.unlink()
        path.unlink()
        target = self.root / "unchanged-target"
        target.write_bytes(original)
        path.symlink_to(target)
        with self.assertRaises(RuntimeError):
            sample_inventory(hooks, self.expected)
        self.assertEqual(target.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
