module main

import os
import yaml

struct HarnessParser {
	lines []string
mut:
	cursor int
	facts  PipelineFacts
}

fn parse_harness_file(path string) !PipelineFacts {
	content := os.read_file(path)!
	return parse_harness(content, path)
}

fn parse_harness(content string, source string) !PipelineFacts {
	doc := yaml.parse_text(content) or { return error('invalid Harness pipeline YAML: ${err}') }
	pipeline := yaml_map(doc.to_any(), 'pipeline')
	if pipeline.len == 0 {
		return error('no Harness pipeline found')
	}
	mut parser := HarnessParser{
		lines: content.split_into_lines()
		facts: PipelineFacts{
			provider: 'harness-pipeline'
			source:   source
		}
	}
	pipeline_line := parser.next_line('pipeline:')
	if template_value := pipeline['template'] {
		parser.add_template(template_value, 'pipeline template requires resolution', pipeline_line,
			-1)
	}
	if properties := pipeline['properties'] {
		parser.scan_value('properties', properties, pipeline_line, -1)
	}
	parser.add_variables(pipeline['variables'] or { yaml.Any(yaml.null) }, pipeline_line, -1)
	parser.walk_stages(yaml_list(pipeline['stages'] or { yaml.Any(yaml.null) }), [])
	if parser.facts.stages.len == 0 {
		return error('no Harness pipeline stages found')
	}
	return parser.facts
}

fn (mut p HarnessParser) walk_stages(entries []yaml.Any, previous []string) []string {
	mut dependencies := previous.clone()
	for entry in entries {
		node := yaml_map(entry, '')
		if stage := node['stage'] {
			dependencies = [p.add_stage(stage, dependencies)]
		} else if group := node['parallel'] {
			mut names := []string{}
			for parallel_entry in yaml_list(group) {
				if stage := yaml_map(parallel_entry, '')['stage'] {
					names << p.add_stage(stage, dependencies)
				}
			}
			dependencies = names.clone()
		}
	}
	return dependencies
}

fn (mut p HarnessParser) add_stage(stage yaml.Any, dependencies []string) string {
	line := p.next_line('- stage:')
	node := yaml_map(stage, '')
	name := yaml_name(node)
	p.facts.stages << StageFact{
		name:       name
		kind:       yaml_string(node, 'type')
		line:       line
		depends_on: dependencies.clone()
	}
	index := p.facts.stages.len - 1
	if template_value := node['template'] {
		p.add_template(template_value, 'stage template requires resolution', line, index)
		return name
	}
	if 'strategy' in node {
		p.add_unresolved('looping strategy expands at runtime', line, index, 'strategy')
	}
	when := yaml_map(stage, 'when')
	if condition := when['condition'] {
		p.add_unresolved('conditional execution requires runtime evaluation', line, index,
			'condition: ${yaml_scalar(condition)}')
	}
	p.add_variables(node['variables'] or { yaml.Any(yaml.null) }, line, index)
	spec := yaml_map(stage, 'spec')
	infrastructure := yaml_map(spec['infrastructure'] or { yaml.Any(yaml.null) }, '')
	if infrastructure.len > 0 {
		if source_stage := infrastructure['useFromStage'] {
			p.add_agent(index, 'useFromStage:${yaml_scalar(source_stage)}')
		}
		p.add_agent(index, prefixed('infrastructure', yaml_string(infrastructure, 'type')))
	}
	runtime := yaml_map(spec['runtime'] or { yaml.Any(yaml.null) }, '')
	p.add_agent(index, prefixed('runtime', yaml_string(runtime, 'type')))
	platform := yaml_map(spec['platform'] or { yaml.Any(yaml.null) }, '')
	if platform.len > 0 {
		p.add_agent(index,
			'platform:${yaml_string(platform, 'os')}/${yaml_string(platform, 'arch')}')
	}
	environment := yaml_map(spec['environment'] or { yaml.Any(yaml.null) }, '')
	p.add_agent(index, prefixed('environment', yaml_string(environment, 'environmentRef')))
	for definition in yaml_list(environment['infrastructureDefinitions'] or { yaml.Any(yaml.null) }) {
		p.add_agent(index, prefixed('infrastructureDefinition', yaml_string(yaml_map(definition, ''),
			'identifier')))
	}
	for key, value in spec {
		if key != 'execution' {
			p.scan_value(key, value, line, index)
		}
	}
	execution := yaml_map(spec['execution'] or { yaml.Any(yaml.null) }, '')
	p.walk_steps(yaml_list(execution['steps'] or { yaml.Any(yaml.null) }), index)
	p.walk_steps(yaml_list(execution['rollbackSteps'] or { yaml.Any(yaml.null) }), index)
	return name
}

fn (mut p HarnessParser) walk_steps(entries []yaml.Any, stage_index int) {
	for entry in entries {
		node := yaml_map(entry, '')
		if step := node['step'] {
			p.add_step(step, stage_index)
		} else if group := node['parallel'] {
			p.walk_steps(yaml_list(group), stage_index)
		} else if group := node['stepGroup'] {
			line := p.next_line('- stepGroup:')
			group_node := yaml_map(group, '')
			if template_value := group_node['template'] {
				p.add_template(template_value, 'step group template requires resolution', line,
					stage_index)
				continue
			}
			if 'strategy' in group_node {
				p.add_unresolved('looping strategy expands at runtime', line, stage_index,
					'strategy')
			}
			p.walk_steps(yaml_list(group_node['steps'] or { yaml.Any(yaml.null) }), stage_index)
		}
	}
}

fn (mut p HarnessParser) add_step(step yaml.Any, stage_index int) {
	line := p.next_line('- step:')
	node := yaml_map(step, '')
	if template_value := node['template'] {
		p.add_template(template_value, 'step template requires resolution', line, stage_index)
		return
	}
	step_type := yaml_string(node, 'type')
	add_unique(mut p.facts.integrations, step_type)
	if 'strategy' in node {
		p.add_unresolved('looping strategy expands at runtime', line, stage_index, 'strategy')
	}
	spec := yaml_map(step, 'spec')
	image := yaml_string(spec, 'image')
	if image != '' {
		add_context_value(mut p.facts, stage_index, 'image', image)
	}
	shell := yaml_string(spec, 'shell').to_lower()
	if step_type in ['Run', 'Background'] {
		p.add_command(if shell == '' { 'sh' } else { shell }, yaml_string(spec, 'command'), line,
			stage_index)
	} else if step_type == 'ShellScript' {
		script := yaml_string(yaml_map(yaml_map(spec['source'] or { yaml.Any(yaml.null) }, ''),
			'spec'), 'script')
		p.add_command(if shell == '' { 'bash' } else { shell }, script, line, stage_index)
	}
	operation := if step_type.starts_with('SaveCache') {
		'save-cache'
	} else if step_type.starts_with('RestoreCache') {
		'restore-cache'
	} else if step_type in ['S3Upload', 'GCSUpload', 'ArtifactoryUpload'] {
		'upload'
	} else if step_type.starts_with('BuildAndPush') {
		'push-image'
	} else {
		''
	}
	if operation != '' {
		value := match operation {
			'save-cache', 'restore-cache' { yaml_string(spec, 'key') }
			'upload' { yaml_join(spec['sourcePaths'] or { yaml.Any(yaml.null) }) }
			else { yaml_string(spec, 'repo') }
		}

		p.add_artifact(operation, value, line, stage_index)
	}
	reports := yaml_map(yaml_map(spec['reports'] or { yaml.Any(yaml.null) }, ''), 'spec')
	report_paths := yaml_join(reports['paths'] or { yaml.Any(yaml.null) })
	if report_paths != '' {
		p.add_artifact('test-report', report_paths, line, stage_index)
	}
	for key, value in spec {
		if key !in ['command', 'source'] {
			p.scan_value(key, value, line, stage_index)
		}
	}
}

fn (mut p HarnessParser) add_command(shell string, command string, line int, stage_index int) {
	if command == '' {
		return
	}
	if stage_index >= 0 {
		p.facts.stages[stage_index].commands << CommandFact{
			shell:   shell
			command: sanitize_urls(command)
			line:    line
			stage:   p.stage_name(stage_index)
		}
	}
	p.scan_text('', command, line, stage_index)
}

fn (mut p HarnessParser) add_artifact(operation string, value string, line int, stage_index int) {
	if value == '' {
		return
	}
	p.facts.artifacts << ArtifactFact{
		operation: operation
		value:     sanitize_urls(value)
		line:      line
		stage:     p.stage_name(stage_index)
	}
}

fn (mut p HarnessParser) add_variables(variables yaml.Any, line int, stage_index int) {
	for variable in yaml_list(variables) {
		node := yaml_map(variable, '')
		if yaml_string(node, 'type') == 'Secret' {
			p.add_credential('secret:${yaml_string(node, 'value')}', line, stage_index)
		} else if value := node['value'] {
			p.scan_value(yaml_string(node, 'name'), value, line, stage_index)
		}
	}
}

fn (mut p HarnessParser) add_template(template yaml.Any, reason string, line int, stage_index int) {
	node := yaml_map(template, '')
	mut reference := yaml_string(node, 'templateRef')
	version := yaml_string(node, 'versionLabel')
	if version != '' {
		reference += '@${version}'
	}
	p.add_unresolved(reason, line, stage_index, 'templateRef: ${reference}')
}

// scan_value walks nested YAML values and records connectors, secrets,
// endpoints, and runtime expressions without copying secret values.
fn (mut p HarnessParser) scan_value(key string, value yaml.Any, line int, stage_index int) {
	match value {
		map[string]yaml.Any {
			for child_key, child in value {
				p.scan_value(child_key, child, line, stage_index)
			}
		}
		[]yaml.Any {
			for child in value {
				p.scan_value(key, child, line, stage_index)
			}
		}
		string {
			if key == 'connectorRef' && !value.starts_with('<+') {
				p.add_credential('connector:${value}', line, stage_index)
			}
			p.scan_text(key, value, line, stage_index)
		}
		else {}
	}
}

fn (mut p HarnessParser) scan_text(key string, text string, line int, stage_index int) {
	for text_line in text.split_into_lines() {
		for secret in extract_call_arguments(text_line, '<+secrets.getValue') {
			p.add_credential('secret:${secret}', line, stage_index)
		}
		for endpoint in extract_urls(text_line) {
			p.facts.endpoints << EndpointFact{
				url:   endpoint
				line:  line
				stage: p.stage_name(stage_index)
			}
		}
		source := sanitize_urls(if key == '' {
			text_line.trim_space()
		} else {
			'${key}: ${text_line.trim_space()}'
		})
		if text_line.contains('<+input>') {
			p.add_unresolved('runtime input requires a value at execution', line, stage_index,
				source)
		} else if has_runtime_expression(text_line) {
			p.add_unresolved('expression requires runtime resolution', line, stage_index, source)
		}
	}
}

fn has_runtime_expression(text string) bool {
	mut remaining := text
	for {
		index := remaining.index('<+') or { return false }
		remaining = remaining[index + 2..]
		if !remaining.starts_with('secrets.getValue(') {
			return true
		}
	}
	return false
}

fn (mut p HarnessParser) add_credential(reference string, line int, stage_index int) {
	stage := p.stage_name(stage_index)
	for credential in p.facts.credentials {
		if credential.reference == reference && credential.line == line && credential.stage == stage {
			return
		}
	}
	p.facts.credentials << CredentialFact{
		reference: reference
		line:      line
		stage:     stage
	}
}

fn (mut p HarnessParser) add_unresolved(reason string, line int, stage_index int, source string) {
	p.facts.unresolved << UnresolvedFact{
		reason: reason
		line:   line
		stage:  p.stage_name(stage_index)
		source: source
	}
}

fn (mut p HarnessParser) add_agent(stage_index int, value string) {
	add_context_value(mut p.facts, stage_index, 'agent', value)
}

fn (p &HarnessParser) stage_name(stage_index int) string {
	return if stage_index >= 0 { p.facts.stages[stage_index].name } else { '' }
}

// next_line returns the 1-based line of the next marker after the cursor.
// Stages and steps are visited in document order, so a forward-only cursor
// maps each parsed node to its source line.
fn (mut p HarnessParser) next_line(marker string) int {
	for index in p.cursor .. p.lines.len {
		if p.lines[index].trim_space().starts_with(marker) {
			p.cursor = index + 1
			return index + 1
		}
	}
	return 0
}

fn prefixed(prefix string, value string) string {
	return if value == '' { '' } else { '${prefix}:${value}' }
}

fn yaml_map(value yaml.Any, key string) map[string]yaml.Any {
	node := if key == '' {
		value
	} else {
		match value {
			map[string]yaml.Any { value[key] or { yaml.Any(yaml.null) } }
			else { yaml.Any(yaml.null) }
		}
	}
	return match node {
		map[string]yaml.Any {
			node
		}
		else {
			map[string]yaml.Any{}
		}
	}
}

fn yaml_list(value yaml.Any) []yaml.Any {
	return match value {
		[]yaml.Any { value }
		else { []yaml.Any{} }
	}
}

fn yaml_scalar(value yaml.Any) string {
	return match value {
		string { value }
		bool, f64, i64, int, u64 { value.str() }
		else { '' }
	}
}

fn yaml_string(node map[string]yaml.Any, key string) string {
	return yaml_scalar(node[key] or { yaml.Any(yaml.null) })
}

fn yaml_join(value yaml.Any) string {
	return match value {
		[]yaml.Any { value.map(yaml_scalar(it)).filter(it != '').join(', ') }
		else { yaml_scalar(value) }
	}
}

fn yaml_name(node map[string]yaml.Any) string {
	name := yaml_string(node, 'name')
	return if name == '' { yaml_string(node, 'identifier') } else { name }
}
