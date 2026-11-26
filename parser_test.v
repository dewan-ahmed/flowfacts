module main

import json

fn test_extracts_jenkins_facts() {
	content := $embed_file('testdata/Jenkinsfile').to_string()
	facts := parse_jenkins(content, 'Jenkinsfile') or {
		assert false, err.msg()
		return
	}
	assert facts.provider == 'jenkins-declarative'
	assert facts.stages.len == 2
	assert facts.stages[0].name == 'Build'
	assert facts.stages[1].depends_on == ['Build']
	assert facts.agents == ['label:linux-large']
	assert facts.stages[0].images == ['golang:1.23']
	assert facts.credentials[0].reference == 'deploy-token'
	assert facts.artifacts.len == 3
	assert facts.endpoints[0].url == 'https://quality.example.com/api'
	assert 'junit' in facts.integrations
	assert facts.unresolved.len == 2
}

fn test_extracts_parallel_dependencies() {
	content := $embed_file('testdata/Jenkinsfile.parallel').to_string()
	facts := parse_jenkins(content, 'Jenkinsfile.parallel') or {
		assert false, err.msg()
		return
	}
	assert facts.stages.len == 5
	assert facts.stages[1].name == 'Verify'
	assert facts.stages[1].depends_on == ['Build']
	assert facts.stages[2].name == 'Unit'
	assert facts.stages[2].depends_on == ['Verify']
	assert facts.stages[2].parallel_parent == 'Verify'
	assert facts.stages[3].name == 'Security'
	assert facts.stages[3].depends_on == ['Verify']
	assert facts.stages[4].name == 'Publish'
	assert facts.stages[4].depends_on == ['Verify']
}

fn test_rejects_file_without_stages() {
	parse_jenkins('pipeline { agent any }', 'Jenkinsfile') or {
		assert err.msg().contains('no declarative Jenkins stages')
		return
	}
	assert false, 'expected parser error'
}

fn test_url_extraction_removes_query_parameters() {
	urls := extract_urls("sh 'curl https://example.com/api?token=secret'")
	assert urls == ['https://example.com/api']
}

fn test_redacts_url_queries_from_all_output_fields() {
	content := 'pipeline { stages { stage(\'Publish\') { steps {
		sh \'curl https://example.com/upload?token=hardcoded-secret\'
		sh "curl https://example.com/runtime?token=\${UPLOAD_TOKEN}"
	} } } }'
	facts := parse_jenkins(content, 'Jenkinsfile') or {
		assert false, err.msg()
		return
	}
	assert facts.stages[0].commands[0].command == 'curl https://example.com/upload'
	assert facts.stages[0].commands[1].command == 'curl https://example.com/runtime'
	assert facts.unresolved[0].source == 'sh "curl https://example.com/runtime"'
	output := json.encode(facts)
	assert !output.contains('hardcoded-secret')
	assert !output.contains('UPLOAD_TOKEN')
	assert !output.contains('?token=')
}

fn test_extracts_one_line_blocks() {
	content := $embed_file('testdata/Jenkinsfile.compact').to_string()
	facts := parse_jenkins(content, 'Jenkinsfile.compact') or {
		assert false, err.msg()
		return
	}
	assert facts.agents == ['label:linux-large']
	assert facts.stages[0].images == ['golang:1.23']
	assert 'docker' in facts.integrations
	assert facts.stages.len == 5
	assert facts.stages[2].name == 'Unit'
	assert facts.stages[2].parallel_parent == 'Checks'
	assert facts.stages[2].commands[0].command == 'make test'
	assert facts.stages[3].commands[0].command == 'make lint'
	assert facts.stages[4].depends_on == ['Checks']
	assert facts.unresolved.len == 2
}

fn test_extracts_shared_libraries_and_unknown_steps() {
	content := $embed_file('testdata/Jenkinsfile.libraries').to_string()
	facts := parse_jenkins(content, 'Jenkinsfile.libraries') or {
		assert false, err.msg()
		return
	}
	assert facts.libraries.len == 5
	assert facts.libraries[0] == LibraryFact{
		name: 'shared-pipeline'
		ref:  'v2'
		line: 1
		form: 'annotation'
	}
	assert facts.libraries[1].name == 'security-steps'
	assert facts.libraries[1].ref == '1.4.0'
	assert facts.libraries[2].name == 'notify'
	assert facts.libraries[2].ref == ''
	assert facts.libraries[3].name == 'deploy-lib'
	assert facts.libraries[3].form == 'step'
	assert facts.libraries[4].name == 'infra-lib'
	assert facts.libraries[4].ref == 'release/3'
	assert facts.libraries[4].retriever == 'modernSCM'
	names := facts.unknown_steps.map(it.name)
	assert names == ['standardBuild', 'publishToNexus', 'deployToCluster']
	assert facts.unknown_steps[0].stage == 'Build'
	assert facts.unknown_steps[0].line == 11
	assert facts.unknown_steps[2].stage == 'Deploy'
	assert !facts.unknown_steps[2].source.contains('secret')
	encoded := json.encode(facts)
	assert !encoded.contains('token=abc')
	assert facts.unresolved.any(it.source.starts_with('script {'))
}

fn test_unknown_steps_without_declaration_imply_a_library() {
	content := "pipeline {\n  agent any\n  stages {\n    stage('Build') {\n      steps {\n        buildJavaService()\n      }\n    }\n  }\n}\n"
	facts := parse_jenkins(content, 'Jenkinsfile') or {
		assert false, err.msg()
		return
	}
	assert facts.libraries.len == 1
	assert facts.libraries[0].form == 'implicit'
	assert facts.libraries[0].line == 6
	assert facts.unknown_steps[0].name == 'buildJavaService'
}

fn test_existing_fixtures_report_no_unknown_steps() {
	for content in [$embed_file('testdata/Jenkinsfile').to_string(),
		$embed_file('testdata/Jenkinsfile.parallel').to_string(),
		$embed_file('testdata/Jenkinsfile.compact').to_string()] {
		facts := parse_jenkins(content, 'Jenkinsfile') or {
			assert false, err.msg()
			return
		}
		assert facts.unknown_steps.len == 0, facts.unknown_steps.str()
		assert facts.libraries.len == 0
	}
}

fn test_extracts_declarative_directives() {
	content := $embed_file('testdata/Jenkinsfile.directives').to_string()
	facts := parse_jenkins(content, 'Jenkinsfile.directives') or {
		assert false, err.msg()
		return
	}
	assert facts.parameters.map('${it.@type}:${it.name}=${it.default}') == [
		'string:TARGET_ENV=staging',
		'booleanParam:RUN_E2E=true',
		'choice:REGION=us-east-1',
	]
	assert facts.environment.len == 3
	assert facts.environment[0].value == 'registry.example.com'
	assert facts.environment[1].credential_reference == 'deploy-token'
	assert facts.environment[1].value == ''
	assert facts.environment[2].value == 'https://hooks.example.com/notify'
	assert facts.tools.map('${it.@type}:${it.name}') == ['maven:maven-3.9', 'jdk:temurin-21']
	assert facts.options.map(it.name) == ['timeout', 'retry']
	build := facts.stages[0]
	assert build.environment[0].name == 'PROFILE'
	assert build.options[0].name == 'skipDefaultCheckout'
	assert build.commands.map(it.command) == ['make build']
	assert build.post.len == 1
	assert build.post[0].condition == 'failure'
	assert build.post[0].commands[0].command == 'make clean'
	deploy := facts.stages[1]
	assert deploy.when.map(it.condition) == ['branch', 'expression']
	assert deploy.when[0].raw == "branch 'main'"
	assert facts.unresolved.any(it.reason == 'when expression requires runtime evaluation'
		&& it.stage == 'Deploy')
	assert facts.post.map(it.condition) == ['always', 'cleanup']
	assert facts.post[0].commands[0].command == './notify.sh'
	assert facts.post[1].commands[0].command == 'rm -rf tmp'
	assert !json.encode(facts).contains('secret')
}

fn test_semicolons_split_statements_outside_parentheses() {
	assert split_segments("timeout(time: 30, unit: 'MINUTES'); retry(2)") == [
		"timeout(time: 30, unit: 'MINUTES')",
		'retry(2)',
	]
	assert split_segments("sh 'a; b'") == ["sh 'a; b'"]
}
