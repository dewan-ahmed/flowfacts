# flowfacts

Deterministic CI/CD facts and context for migration agents.

`flowfacts` turns a pipeline file into compact JSON. An agent can reason over
stages, dependencies, runners, credentials, artifacts, and unresolved dynamic
code without reading the entire pipeline into its context.

It extracts facts only. It does not convert pipelines or call any CI/CD service.

## Status

Early development. The first provider supports common Jenkins Declarative
Pipeline patterns.

## Build

Install the V version in `.v-version`, then run:

```sh
v -prod -o flowfacts .
```

## Use

```sh
flowfacts pipeline --provider jenkins --file Jenkinsfile
```

The command prints one JSON document to standard output.

## Extracted facts

- Stages, source lines, sequential dependencies, and parallel parents.
- Pipeline and stage agents, labels, and container images.
- Shell, batch, and PowerShell commands.
- Credential references by ID, never credential values.
- Triggers such as `cron`, `pollSCM`, and `upstream`.
- Archived, stashed, and unstashed artifacts.
- External HTTP endpoints with query parameters removed.
- Common integration steps.
- Dynamic Groovy and interpolated values that need review.

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
