# YAML parity with JSON

## Goal
`std.yaml` gets parse + `fromYaml<T>` support equivalent to `std.json`, reusing the format-agnostic `SerdeValue` pipeline.

## Tasks
- [x] Task 1: `YamlValue` model + `YamlParser` (block maps/lists, nesting by indent, comments, quoted/plain scalars) in `src/std/yaml.ei` → Verify: `./bin/eiwac run` scratch parsing nested doc prints expected fields
- [x] Task 2: `toSerde()` bridge + `parseYamlToSerde` + `fromYaml<T>` (+ `serializeYaml` free fns mirroring `serializeJson`) → Verify: `fromYaml<User>` populates all field kinds in scratch
- [x] Task 3: Scalar coercions (null/`~`, bool variants, int/double, quoted stays string) → Verify: scratch asserts per coercion
- [x] Task 4: Missing-key semantics via existing generated deserialize (throw required, null nullable, defaults honored) → Verify: YAML throw + default scratch tests pass
- [x] Task 5: Commit `samples/tests/yaml_parse_test.ei` + `samples/tests/yaml_serde_test.ei` (round-trips, List/Map/alias) → Verify: both files green via `./bin/eiwac test`
- [x] Task 6 (LAST): Full verification → Verify: `./bin/eiwac test` ALL PASS + `zig build test` clean

## Done When
- [x] `fromYaml<T>` + `toYaml` round-trip at parity with JSON; suite fully green (830/830)

## Notes
- Deserialize codegen is format-agnostic already (L1–L4); no compiler changes expected — stdlib-only unless a gap surfaces
- JSON object keys are strings; YAML mapping keys likewise — non-string keys out of scope
