module main

import os

const integration_steps = [
	'checkout',
	'docker',
	'junit',
	'kubernetes',
	'publishHTML',
	'slackSend',
	'sshagent',
	'withAWS',
	'withCredentials',
	'withSonarQubeEnv',
]

fn parse_jenkins_file(path string) !PipelineFacts {
	content := os.read_file(path)!
	return parse_jenkins(content, path)
}

fn parse_jenkins(content string, source string) !PipelineFacts {
	mut facts := PipelineFacts{
		provider: 'jenkins-declarative'
		source:   source
	}
	mut depth := 0
	mut current_stage := -1
	mut stage_depth := -1
	mut previous_stage := ''
	mut parallel_depth := -1
	mut parallel_parent := ''
	for line_index, raw_line in content.split_into_lines() {
		line_number := line_index + 1
		line := strip_comment(raw_line).trim_space()
		if line == '' {
			continue
		}
		if current_stage >= 0 && depth < stage_depth {
			current_stage = -1
			stage_depth = -1
		}
		if parallel_depth >= 0 && depth < parallel_depth {
			parallel_depth = -1
			parallel_parent = ''
		}
		if line.starts_with('parallel {') {
			parallel_depth = depth + 1
			parallel_parent = if current_stage >= 0 { facts.stages[current_stage].name } else { '' }
		}
		if stage_name := extract_call_argument(line, 'stage') {
			mut dependencies := []string{}
			if parallel_depth >= 0 && parallel_parent != '' {
				dependencies << parallel_parent
			} else if previous_stage != '' {
				dependencies << previous_stage
			}
			facts.stages << StageFact{
				name:            stage_name
				line:            line_number
				depends_on:      dependencies
				parallel_parent: parallel_parent
			}
			current_stage = facts.stages.len - 1
			stage_depth = depth + 1
			if parallel_depth < 0 {
				previous_stage = stage_name
			}
		}
		stage_name := if current_stage >= 0 { facts.stages[current_stage].name } else { '' }
		if line.starts_with('agent ') {
			agent := normalize_value(line.all_after('agent '))
			add_context_value(mut facts, current_stage, 'agent', agent)
		}
		if label := extract_step_argument(line, 'label') {
			add_context_value(mut facts, current_stage, 'agent', 'label:${label}')
		}
		if image := extract_step_argument(line, 'image') {
			add_context_value(mut facts, current_stage, 'image', image)
		}
		for credential in extract_call_arguments(line, 'credentials') {
			facts.credentials << CredentialFact{
				reference: credential
				line:      line_number
				stage:     stage_name
			}
		}
		if credential := extract_named_argument(line, 'credentialsId') {
			facts.credentials << CredentialFact{
				reference: credential
				line:      line_number
				stage:     stage_name
			}
		}
		for trigger in ['cron', 'pollSCM', 'upstream'] {
			if value := extract_call_argument(line, trigger) {
				add_unique(mut facts.triggers, '${trigger}:${value}')
			}
		}
		for shell in ['sh', 'bat', 'powershell'] {
			if command := extract_step_argument(line, shell) {
				command_fact := CommandFact{
					shell:   shell
					command: command
					line:    line_number
					stage:   stage_name
				}
				if current_stage >= 0 {
					facts.stages[current_stage].commands << command_fact
				}
			}
		}
		if value := extract_named_or_first_argument(line, 'archiveArtifacts', 'artifacts') {
			facts.artifacts << ArtifactFact{
				operation: 'archive'
				value:     value
				line:      line_number
				stage:     stage_name
			}
		}
		if value := extract_named_or_first_argument(line, 'stash', 'name') {
			facts.artifacts << ArtifactFact{
				operation: 'stash'
				value:     value
				line:      line_number
				stage:     stage_name
			}
		}
		if value := extract_step_argument(line, 'unstash') {
			facts.artifacts << ArtifactFact{
				operation: 'unstash'
				value:     value
				line:      line_number
				stage:     stage_name
			}
		}
		for endpoint in extract_urls(line) {
			facts.endpoints << EndpointFact{
				url:   endpoint
				line:  line_number
				stage: stage_name
			}
		}
		for step in integration_steps {
			if contains_step(line, step) {
				add_unique(mut facts.integrations, step)
			}
		}
		if line.starts_with('script {') || line.contains('evaluate(') || line.contains('load ')
			|| line.contains('library ') {
			facts.unresolved << UnresolvedFact{
				reason: 'dynamic Groovy requires agent review'
				line:   line_number
				stage:  stage_name
				source: line
			}
		} else if line.contains(r'${') {
			facts.unresolved << UnresolvedFact{
				reason: 'interpolated value requires runtime resolution'
				line:   line_number
				stage:  stage_name
				source: line
			}
		}
		depth += brace_delta(line)
	}
	if facts.stages.len == 0 {
		return error('no declarative Jenkins stages found')
	}
	return facts
}

fn add_context_value(mut facts PipelineFacts, stage_index int, kind string, value string) {
	if value == '' {
		return
	}
	if stage_index >= 0 {
		if kind == 'agent' {
			add_unique(mut facts.stages[stage_index].agents, value)
		} else {
			add_unique(mut facts.stages[stage_index].images, value)
		}
	} else if kind == 'agent' {
		add_unique(mut facts.agents, value)
	} else {
		add_unique(mut facts.images, value)
	}
}

fn add_unique(mut values []string, value string) {
	if value != '' && value !in values {
		values << value
	}
}

fn normalize_value(value string) string {
	return value.trim_space().trim('{}').trim_space().trim('\'"')
}

fn contains_step(line string, step string) bool {
	return line == step || line.starts_with('${step} ') || line.starts_with('${step}(')
		|| line.contains(' ${step}(')
}

fn extract_step_argument(line string, step string) ?string {
	if value := extract_call_argument(line, step) {
		return value
	}
	if !line.starts_with('${step} ') {
		return none
	}
	return first_quoted(line.all_after('${step} '))
}

fn extract_named_or_first_argument(line string, step string, name string) ?string {
	if !contains_step(line, step) {
		return none
	}
	if value := extract_named_argument(line, name) {
		return value
	}
	return extract_step_argument(line, step)
}

fn extract_named_argument(line string, name string) ?string {
	if marker_index := line.index('${name}:') {
		return first_quoted(line[marker_index + name.len + 1..])
	}
	return none
}

fn extract_call_argument(line string, name string) ?string {
	values := extract_call_arguments(line, name)
	if values.len == 0 {
		return none
	}
	return values[0]
}

fn extract_call_arguments(line string, name string) []string {
	mut values := []string{}
	mut remaining := line
	marker := '${name}('
	for {
		index := remaining.index(marker) or { break }
		after := remaining[index + marker.len..]
		if value := first_quoted(after) {
			values << value
		}
		remaining = after
	}
	return values
}

fn first_quoted(value string) ?string {
	mut quote := u8(0)
	mut start := -1
	for index, character in value.bytes() {
		if quote == 0 && (character == `'` || character == `"`) {
			quote = character
			start = index + 1
		} else if quote != 0 && character == quote {
			return value[start..index]
		}
	}
	return none
}

fn extract_urls(line string) []string {
	mut urls := []string{}
	for prefix in ['https://', 'http://'] {
		mut remaining := line
		for {
			index := remaining.index(prefix) or { break }
			candidate := remaining[index..]
			mut end := candidate.len
			for position, character in candidate.bytes() {
				if character in [`'`, `"`, ` `, `)`, `,`] {
					end = position
					break
				}
			}
			url := candidate[..end].all_before('?')
			add_unique(mut urls, url)
			remaining = candidate[end..]
		}
	}
	return urls
}

fn strip_comment(line string) string {
	mut quote := u8(0)
	mut escaped := false
	bytes := line.bytes()
	for index, character in bytes {
		if escaped {
			escaped = false
			continue
		}
		if character == `\\` && quote != 0 {
			escaped = true
			continue
		}
		if character == `'` || character == `"` {
			if quote == 0 {
				quote = character
			} else if quote == character {
				quote = 0
			}
		}
		if quote == 0 && character == `/` && index + 1 < bytes.len && bytes[index + 1] == `/` {
			return line[..index]
		}
	}
	return line
}

fn brace_delta(line string) int {
	mut delta := 0
	mut quote := u8(0)
	mut escaped := false
	for character in line.bytes() {
		if escaped {
			escaped = false
			continue
		}
		if character == `\\` && quote != 0 {
			escaped = true
			continue
		}
		if character == `'` || character == `"` {
			if quote == 0 {
				quote = character
			} else if quote == character {
				quote = 0
			}
			continue
		}
		if quote == 0 {
			if character == `{` {
				delta++
			} else if character == `}` {
				delta--
			}
		}
	}
	return delta
}
