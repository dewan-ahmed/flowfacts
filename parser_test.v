module main

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
