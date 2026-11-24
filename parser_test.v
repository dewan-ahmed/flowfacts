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
