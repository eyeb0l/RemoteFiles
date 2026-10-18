"""Shared fail-closed finalization for the disposable Simulator runners."""


def finalize_report(report, cleanup_checks):
    """Attempt every cleanup/check, retain failures, and return the process status.

    A failed cleanup must not prevent later source-integrity checks or hide the
    original test failure. Callers save the finalized report before exiting.
    """
    for name, check in cleanup_checks:
        try:
            report["cleanup"][name] = check() is True
        except BaseException as error:
            report["cleanup"][name] = False
            report.setdefault("cleanup_errors", {})[name] = (
                type(error).__name__ + ": " + str(error)
            )

    lanes = report["lanes"]
    if report["status"] == "blocked" or any(lane["status"] == "blocked" for lane in lanes):
        report["status"] = "blocked"
    elif (report["status"] != "passed"
          or any(lane["status"] != "passed" for lane in lanes)
          or not all(report["cleanup"].values())):
        report["status"] = "failed"
    return 0 if report["status"] == "passed" else 1
