module main

import json

fn test_extracts_harness_facts() {
	content := $embed_file('testdata/harness-pipeline.yaml').to_string()
	facts := parse_harness(content, 'harness-pipeline.yaml') or {
		assert false, err.msg()
		return
	}
	assert facts.provider == 'harness-pipeline'
	assert facts.stages.map(it.name) == ['Build', 'Security', 'Integration', 'Deploy']
	assert facts.stages[0].kind == 'CI'
	assert facts.stages[0].line == 17
	assert facts.stages[0].agents == ['runtime:Cloud', 'platform:Linux/Amd64']
	assert facts.stages[0].images == ['golang:1.23', 'golangci/golangci-lint:v1.61',
		'example/scanner:2']
	assert facts.stages[0].commands.len == 2
	assert facts.stages[0].commands[1].shell == 'bash'
	assert facts.stages[2].agents == ['infrastructure:KubernetesDirect']
	assert facts.stages[3].agents == ['environment:production',
		'infrastructureDefinition:production_cluster']
	assert facts.stages[3].commands[0].command == 'curl -X POST https://hooks.example.com/deploy'
	assert facts.artifacts.map(it.operation) == ['restore-cache', 'test-report', 'push-image',
		'save-cache']
	assert facts.endpoints.map(it.url) == ['https://quality.example.com/api',
		'https://hooks.example.com/deploy']
	assert 'BuildAndPushDockerRegistry' in facts.integrations
}

fn test_harness_parallel_stage_dependencies() {
	content := $embed_file('testdata/harness-pipeline.yaml').to_string()
	facts := parse_harness(content, 'harness-pipeline.yaml') or {
		assert false, err.msg()
		return
	}
	assert facts.stages[1].depends_on == ['Build']
	assert facts.stages[2].depends_on == ['Build']
	assert facts.stages[3].depends_on == ['Security', 'Integration']
}

fn test_harness_credentials_are_references_only() {
	content := $embed_file('testdata/harness-pipeline.yaml').to_string()
	facts := parse_harness(content, 'harness-pipeline.yaml') or {
		assert false, err.msg()
		return
	}
	references := facts.credentials.map(it.reference)
	assert 'connector:git_connector' in references
	assert 'connector:build_cluster' in references
	assert 'secret:registry_password' in references
	assert 'secret:scanner_token' in references
	output := json.encode(facts)
	assert !output.contains('hardcoded-secret')
	assert !output.contains('?token=')
}

fn test_harness_unresolved_facts() {
	content := $embed_file('testdata/harness-pipeline.yaml').to_string()
	facts := parse_harness(content, 'harness-pipeline.yaml') or {
		assert false, err.msg()
		return
	}
	reasons := facts.unresolved.map(it.reason)
	assert 'runtime input requires a value at execution' in reasons
	assert 'stage template requires resolution' in reasons
	assert 'step template requires resolution' in reasons
	assert 'looping strategy expands at runtime' in reasons
	assert 'conditional execution requires runtime evaluation' in reasons
	assert facts.unresolved.any(it.source == 'templateRef: security_scan@v2')
	assert facts.unresolved.any(it.source == 'make integration SHARD=<+matrix.shard>')
	assert !facts.unresolved.any(it.source.contains('secrets.getValue'))
}

fn test_rejects_harness_file_without_stages() {
	parse_harness('pipeline:\n  name: Empty\n  identifier: empty\n', 'pipeline.yaml') or {
		assert err.msg().contains('no Harness pipeline stages')
		return
	}
	assert false, 'expected parser error'
}

fn test_rejects_non_pipeline_yaml() {
	parse_harness('trigger:\n  name: Nightly\n', 'trigger.yaml') or {
		assert err.msg().contains('no Harness pipeline found')
		return
	}
	assert false, 'expected parser error'
}
