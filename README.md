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
- Shared library imports in `libraries`: `name`, `ref`, `line`, and `form`
  (`annotation` for `@Library`, `step` for `library`, or `implicit` when
  unknown steps appear without any declaration). For
  `library identifier: ..., retriever: ...`, only the retriever type is kept.
  Libraries are reported, not fetched or resolved.
- Calls inside `steps { }` that are not built-in, shell, or known integration
  steps in `unknown_steps`, with `name`, `line`, `stage`, and sanitized
  `source`. These usually come from a shared library and hide the real build
  logic. Calls inside `script { }` are left to the dynamic Groovy fact.
- Declarative directives. Pipeline level: `parameters` (`name`, `type`,
  `default`), `environment`, `tools`, `options`, and `post`. Stage level:
  `environment`, `tools`, `options`, `when`, and `post`. Environment values are
  literal text with URL query parameters removed; `credentials('id')` bindings
  appear as `credential_reference` by ID only.
- `post` blocks as `condition` plus `commands`. Commands inside `post` are not
  listed with the stage's normal commands, so a failure-only cleanup step
  stays failure-only.
- Dynamic Groovy, `when { expression { ... } }`, and interpolated values that
  need review.

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
