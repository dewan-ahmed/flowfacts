module main

const directive_sections = ['parameters', 'environment', 'tools', 'options', 'when', 'post']

const post_conditions = ['always', 'success', 'failure', 'unstable', 'aborted', 'changed', 'fixed',
	'regression', 'unsuccessful', 'cleanup']

// DirectiveState tracks which Declarative directive block the parser is in.
struct DirectiveState {
mut:
	section          string
	depth            int = -1
	stage            int = -1
	post_depth       int = -1
	post_index       int = -1
	expression_depth int = -1
}

fn (mut d DirectiveState) leave_closed_blocks(depth int) {
	if d.expression_depth >= 0 && depth < d.expression_depth {
		d.expression_depth = -1
	}
	if d.post_depth >= 0 && depth < d.post_depth {
		d.post_depth = -1
		d.post_index = -1
	}
	if d.depth >= 0 && depth < d.depth {
		d.section = ''
		d.depth = -1
		d.stage = -1
	}
}

fn directive_section(line string) ?string {
	for section in directive_sections {
		if line == '${section} {' || line == '${section}{' {
			return section
		}
	}
	return none
}

// apply_directive records one statement inside a directive block. It returns
// true when the statement belongs to the directive and needs no other handling.
fn apply_directive(mut facts PipelineFacts, mut d DirectiveState, line string, line_number int, depth int) bool {
	if d.section == '' || line == '}' || d.expression_depth >= 0 {
		return d.expression_depth >= 0 && line != '}'
	}
	direct := depth == d.depth
	match d.section {
		'parameters' {
			if direct {
				if parameter := parse_parameter(line, line_number) {
					facts.parameters << parameter
				}
			}
		}
		'environment' {
			if direct && line.contains('=') {
				env := parse_environment(line, line_number)
				if d.stage >= 0 {
					facts.stages[d.stage].environment << env
				} else {
					facts.environment << env
				}
			}
		}
		'tools' {
			if direct {
				if name := first_quoted(line) {
					tool := ToolFact{
						@type: line.all_before(' ').all_before('(').trim_space()
						name:  name
						line:  line_number
					}
					if d.stage >= 0 {
						facts.stages[d.stage].tools << tool
					} else {
						facts.tools << tool
					}
				}
			}
		}
		'options' {
			if direct {
				option := OptionFact{
					name: step_name(line) or { line.all_before('(').trim_space() }
					raw:  sanitize_urls(line)
					line: line_number
				}
				if d.stage >= 0 {
					facts.stages[d.stage].options << option
				} else {
					facts.options << option
				}
			}
		}
		'when' {
			if d.stage >= 0 {
				condition := step_name(line) or { line.all_before(' ') }
				facts.stages[d.stage].when << WhenFact{
					condition: condition
					raw:       sanitize_urls(line)
					line:      line_number
				}
				if condition == 'expression' {
					facts.unresolved << UnresolvedFact{
						reason: 'when expression requires runtime evaluation'
						line:   line_number
						stage:  facts.stages[d.stage].name
						source: sanitize_urls(line)
					}
					if line.ends_with('{') {
						d.expression_depth = depth + 1
					}
				}
			}
		}
		'post' {
			if direct {
				condition := line.all_before('{').trim_space()
				if condition in post_conditions && line.ends_with('{') {
					post := PostFact{
						condition: condition
						line:      line_number
					}
					if d.stage >= 0 {
						facts.stages[d.stage].post << post
						d.post_index = facts.stages[d.stage].post.len - 1
					} else {
						facts.post << post
						d.post_index = facts.post.len - 1
					}
					d.post_depth = depth + 1
				}
			}
		}
		else {}
	}

	return false
}

fn (d DirectiveState) add_post_command(mut facts PipelineFacts, command CommandFact) bool {
	if d.section != 'post' || d.post_index < 0 {
		return false
	}
	if d.stage >= 0 {
		facts.stages[d.stage].post[d.post_index].commands << command
	} else {
		facts.post[d.post_index].commands << command
	}
	return true
}

fn parse_parameter(line string, line_number int) ?ParameterFact {
	kind := line.all_before('(').trim_space()
	name := extract_named_argument(line, 'name') or { return none }
	mut default_value := ''
	if marker := line.index('defaultValue:') {
		rest := line[marker + 'defaultValue:'.len..].trim_space()
		default_value = if rest.starts_with("'") || rest.starts_with('"') {
			first_quoted(rest) or { '' }
		} else {
			rest.all_before(',').all_before(')').trim_space()
		}
	} else if choices := extract_named_argument(line, 'choices') {
		default_value = choices
	}
	return ParameterFact{
		name:    name
		@type:   kind
		default: sanitize_urls(default_value)
		line:    line_number
	}
}

fn parse_environment(line string, line_number int) EnvironmentFact {
	name := line.all_before('=').trim_space()
	value := line.all_after('=').trim_space()
	if credential := extract_call_argument(value, 'credentials') {
		return EnvironmentFact{
			name:                 name
			credential_reference: credential
			line:                 line_number
		}
	}
	literal := if value.starts_with("'") || value.starts_with('"') {
		first_quoted(value) or { value }
	} else {
		value
	}
	return EnvironmentFact{
		name:  name
		value: sanitize_urls(literal)
		line:  line_number
	}
}
