import argparse
from pathlib import Path


TREES = ("App/Survey", "App/Providers", "App/HIL")
FILES = (
    "App/Core/FlightModels.swift",
    "App/Core/EventLog.swift",
    "App/Core/FlightControlSupervisor.swift",
    "App/Core/PositionController.swift",
    "App/Core/Providers.swift",
    "App/Core/SafetyGate.swift",
    "App/Views/FlightMapPanel.swift",
    "App/Views/SurveyPlannerView.swift",
    "App/Views/DJILiveVideoView.swift",
    "Tests/PhoneCaptureRetentionTests.swift",
)


def main():
    parser = argparse.ArgumentParser(description="Compare shared iOS mission fixes without copying private features.")
    parser.add_argument("--private-root", required=True, type=Path)
    args = parser.parse_args()
    public = Path(__file__).resolve().parents[1]
    private = args.private_root.resolve()
    paths = set(FILES)
    errors = []
    for tree in TREES:
        for root in (public, private):
            directory = root / tree
            if not directory.is_dir():
                errors.append(f"MISSING TREE: {directory}")
            paths.update(str(path.relative_to(root)) for path in directory.rglob("*.swift"))
    passed = 0
    for path in sorted(paths):
        try:
            if (public / path).read_text() != (private / path).read_text():
                errors.append(f"DIFF: {path}")
            else:
                passed += 1
        except OSError:
            errors.append(f"MISSING: {path}")
    for error in errors:
        print(error)
    print(f"Shared checks passed: {passed}; failed: {len(errors)}")
    print("MANUAL REVIEW: model exclusions, cloud endpoint, build features, FlightViewModel and remaining UI/tests.")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
