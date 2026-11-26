# flowfacts

Deterministic CI/CD facts and context for migration agents.

`flowfacts` turns a pipeline file into compact JSON. An agent can reason over
stages, dependencies, runners, credentials, artifacts, and unresolved dynamic
code without reading the entire pipeline into its context.

It extracts facts only. It does not convert pipelines or call any CI/CD service.

## Status

Early development. Two providers are available:

- `jenkins`: common Jenkins Declarative Pipeline patterns.
- `harness`: Harness pipeline YAML (CI, Deployment, and Custom stages).

## Build

Install the V version in `.v-version`, then run:

```sh
v -prod -o flowfacts .
```

## Use

```sh
flowfacts pipeline --provider jenkins --file Jenkinsfile
flowfacts pipeline --provider harness --file pipeline.yaml
```

The command prints one JSON document to standard output.

## Extracted facts

- Stages, source lines, sequential dependencies, and parallel parents.
- Pipeline and stage agents, labels, and container images.
- Shell, batch, and PowerShell commands with URL query parameters removed.
- Credential references by ID, never credential values.
- Triggers such as `cron`, `pollSCM`, and `upstream`.
- Archived, stashed, and unstashed artifacts.
- External HTTP endpoints with query parameters removed.
- Common integration steps.
- Dynamic Groovy and interpolated values that need review.

## Harness pipeline facts

The `harness` provider reads a pipeline YAML file without contacting any
service and maps it to the same fact model:

- Stages with their `type`, plus sequential and parallel stage dependencies.
- Build infrastructure, runtime, platform, and deployment environments as
  agents.
- Step images, `Run`, `Background`, and `ShellScript` commands.
- Connector references as `connector:<id>` and secret references as
  `secret:<id>`, never secret values.
- Cache, upload, image push, and test report artifacts.
- Step types as integrations.
- Templates, runtime inputs, expressions, looping strategies, and conditions
  as unresolved facts.

Fact lines point to the enclosing stage or step. Triggers are stored outside
pipeline YAML, so `triggers` is empty for this provider.

Unresolved entries are deliberate. They tell an agent where deterministic
extraction stops and human or model judgment is required.

## Inventory

```sh
flowfacts inventory --provider jenkins --dir ./exports --exclude 'vendor/**'
```

`inventory` scans a directory tree and parses every matching pipeline in one
run. Default includes are `Jenkinsfile`, `Jenkinsfile.*`, and `*.jenkinsfile`
for Jenkins, and `*.yaml` and `*.yml` for Harness. `--include` and
`--exclude` are repeatable globs: `*` stays within one path segment, `**`
crosses segments, and a pattern without `/` matches the file name. Symlinks
are never followed, so an untrusted export cannot point the scan outside
`--dir`.

The default `--format ndjson` prints one record per file, sorted by path, as
each file is parsed:

```json
{"type":"file","path":"services/api/Jenkinsfile","status":"ok","facts":{}}
{"type":"file","path":"empty/Jenkinsfile","status":"no_stages","error":"no declarative Jenkins stages found"}
```

`facts` is the same document `pipeline` prints. `status` is `ok`,
`no_stages`, `read_error`, or `parse_error`. A final `summary` record has
per-status counts, total stages, the number of files with unresolved facts,
and sorted distinct agents, images, credential IDs, and integrations.
`--format json` prints one `{"files": [...], "summary": {...}}` document.

The scan exits `0` even when some files fail, `2` for invalid options, and
`1` with `--fail-on-error` when any file is not `ok`.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Facts were extracted. |
| `1` | The file could not be read or contained no supported stages. |
| `2` | The command or options were invalid. |

## Roadmap

- Stage slicing with transitive dependencies.
- GitHub Actions and GitLab CI providers.
- Deployment manifest facts.
- Log failure facts.

## License

MIT
