#!/usr/bin/env python3
"""Require successful selected CI jobs; accept only intentional skips."""
import json
import os
import sys


LANE_OUTPUTS = {
    "quick": "quick",
    "simulator-ui": "ui",
    "voiceover": "voiceover",
    "release-device-compile": "release",
}


def validate(needs):
    """Validate GitHub's needs context without treating missing outputs as false."""
    if not isinstance(needs, dict):
        return ["Expected a needs object"]
    errors = []
    expected = {"repository-checks", *LANE_OUTPUTS}
    if set(needs) != expected:
        errors.append("Expected dependencies: " + ", ".join(sorted(expected)))
    repository = needs.get("repository-checks")
    if not isinstance(repository, dict) or repository.get("result") != "success":
        errors.append("repository-checks must succeed")
    outputs = repository.get("outputs") if isinstance(repository, dict) else None
    if not isinstance(outputs, dict):
        outputs = {}
    for job, output in LANE_OUTPUTS.items():
        selected = outputs.get(output)
        if selected not in ("true", "false"):
            errors.append(f"{output}: expected an explicit true/false selection")
            continue
        dependency = needs.get(job)
        result = dependency.get("result") if isinstance(dependency, dict) else None
        # Even an unselected job must not hide a failure or cancellation if it ran.
        allowed = ("success",) if selected == "true" else ("success", "skipped")
        if result not in allowed:
            errors.append(f"{job}: selected={selected}, result={result!r}; expected {' or '.join(allowed)}")
    return errors


def main():
    try:
        needs = json.loads(os.environ["CI_NEEDS"])
    except (KeyError, ValueError) as error:
        print("CI gate failed: invalid CI_NEEDS: " + str(error), file=sys.stderr)
        return 1
    errors = validate(needs)
    if errors:
        for error in errors:
            print("CI gate failed: " + error, file=sys.stderr)
        return 1
    print("CI gate passed: repository checks and all selected lanes succeeded; other lanes succeeded or intentionally skipped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
