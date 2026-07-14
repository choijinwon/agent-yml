#!/usr/bin/env python3
import argparse
import json
import pathlib
import re


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--schema", required=True)
    parser.add_argument("spec")
    args = parser.parse_args()
    schema = json.loads(pathlib.Path(args.schema).read_text(encoding="utf-8"))
    spec = json.loads(pathlib.Path(args.spec).read_text(encoding="utf-8"))
    missing = [key for key in schema["required"] if not spec.get(key)]
    if missing:
        raise SystemExit(f"build spec is missing required values: {missing}")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", spec["parentImageDigest"]):
        raise SystemExit("parentImageDigest is invalid")
    if not spec["runtimeImage"].endswith("@" + spec["parentImageDigest"]):
        raise SystemExit("runtimeImage and parentImageDigest do not match")
    if not re.fullmatch(r"[0-9a-f]{64}", spec["lockHash"]):
        raise SystemExit("lockHash is invalid")
    if spec.get("imageBuilderMode") and spec["imageBuilderMode"] != "declarative-spec":
        raise SystemExit("imageBuilderMode must be declarative-spec")
    declarative_builder = spec.get("declarativeImageBuilder")
    if declarative_builder:
        if declarative_builder.get("manualDockerfilePerProject") is not False:
            raise SystemExit("manualDockerfilePerProject must be false")
        if not declarative_builder.get("category"):
            raise SystemExit("declarative image builder category is required")
    if spec.get("dockerfileStrategy") and spec["dockerfileStrategy"] != "multi-stage-target":
        raise SystemExit("dockerfileStrategy must be multi-stage-target")
    target_strategy = spec.get("multiStageTargetStrategy")
    if target_strategy:
        targets = target_strategy.get("targets", {})
        if targets.get("dependency") != "dependency-image":
            raise SystemExit("dependency target must be dependency-image")
        if targets.get("test") != "test":
            raise SystemExit("test target must be test")
        if targets.get("release") != "release":
            raise SystemExit("release target must be release")
        if target_strategy.get("releaseRequiresTestStage") is not True:
            raise SystemExit("release target must require test stage")
        if target_strategy.get("pushOnlyReleaseTarget") is not True:
            raise SystemExit("only release target should be pushed as application image")
    if spec.get("modelArtifactPolicy") and spec["modelArtifactPolicy"] != "external":
        raise SystemExit("modelArtifactPolicy must be external; model files should not be embedded in images")
    model_image_policy = spec.get("modelImagePolicy")
    if model_image_policy:
        if model_image_policy.get("embedModelFilesByDefault") is not False:
            raise SystemExit("models must not be embedded by default")
        if model_image_policy.get("excludeModelDirectoriesFromBuildContext") is not True:
            raise SystemExit("model directories must be excluded from build context")
    security_policy = spec.get("securityReproducibilityPolicy")
    if security_policy:
        required_true_keys = [
            "required",
            "runtimeDigestPinned",
            "dependencyDigestPinned",
            "lockHashRequired",
            "noLatestTags",
            "nonRootUserRequired",
            "modelExternalByDefault",
            "buildReportRequired",
        ]
        missing_or_false = [key for key in required_true_keys if security_policy.get(key) is not True]
        if missing_or_false:
            raise SystemExit(f"security/reproducibility policy requires true values: {missing_or_false}")
        expected_key = "runtimeDigest+lockHash+pythonAbi+targetPlatform+builderSpec"
        if security_policy.get("reproducibilityKey") != expected_key:
            raise SystemExit("reproducibilityKey is invalid")
    checks = set(spec.get("securityReproducibilityChecks", []))
    required_checks = {
        "runtime-image-digest-pinned",
        "dependency-image-digest-pinned",
        "lock-hash-recorded",
        "image-digest-recorded",
        "non-root-user",
        "model-external",
        "no-latest-tags",
        "build-report-generated",
    }
    if checks and not required_checks.issubset(checks):
        raise SystemExit(f"missing security/reproducibility checks: {sorted(required_checks - checks)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
