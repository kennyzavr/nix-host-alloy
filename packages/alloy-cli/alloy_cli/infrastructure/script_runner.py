import sys
import os
import subprocess


class ScriptRunnerAdapter:
    def run(
        self, script_path: str, force: bool = False, add_to_git: bool = False
    ) -> int:
        env = os.environ.copy()

        alloy_bin_path = os.path.abspath(sys.argv[0])
        alloy_bin_dir = os.path.dirname(alloy_bin_path)

        env["PATH"] = f"{alloy_bin_dir}:{env.get('PATH', '')}"
        env["ALLOY_BIN"] = alloy_bin_path
        env["ALLOY_CLI_DEPTH"] = str(int(env.get("ALLOY_CLI_DEPTH", "0")) + 1)

        if force:
            env["ALLOY_FORCE"] = "1"
        if add_to_git:
            env["ALLOY_ADD_TO_GIT"] = "1"

        result = subprocess.run([script_path], env=env)
        return result.returncode
