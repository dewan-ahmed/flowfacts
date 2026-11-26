module main

// Steps Jenkins provides without a shared library. Calls to anything else
// inside `steps { }` are reported as unknown steps.
const builtin_steps = [
	'archiveArtifacts',
	'bat',
	'build',
	'catchError',
	'checkout',
	'cleanWs',
	'copyArtifacts',
	'deleteDir',
	'dir',
	'echo',
	'emailext',
	'error',
	'fileExists',
	'fingerprint',
	'git',
	'input',
	'isUnix',
	'junit',
	'lock',
	'mail',
	'milestone',
	'powershell',
	'publishChecks',
	'pwd',
	'pwsh',
	'readFile',
	'recordIssues',
	'retry',
	'script',
	'sh',
	'sleep',
	'stash',
	'step',
	'timeout',
	'tool',
	'unstable',
	'unstash',
	'waitUntil',
	'warnError',
	'withEnv',
	'wrap',
	'writeFile',
]

// extract_libraries returns shared library imports declared on one line:
// `@Library('a@ref')`, `@Library(['a@ref', 'b'])`, `library 'a@ref'`,
// `library('a@ref')`, and `library identifier: 'a@ref', retriever: ...`.
fn extract_libraries(line string, line_number int) []LibraryFact {
	mut libraries := []LibraryFact{}
	if index := line.index('@Library(') {
		arguments := line[index + '@Library('.len..].all_before(')')
		for spec in quoted_values(arguments) {
			libraries << library_fact(spec, line_number, 'annotation', '')
		}
		return libraries
	}
	if !(line.starts_with('library ') || line.starts_with('library(')) {
		return libraries
	}
	if spec := extract_named_argument(line, 'identifier') {
		mut retriever := ''
		if marker := line.index('retriever:') {
			retriever = line[marker + 'retriever:'.len..].trim_space().all_before('(').trim_space()
		}
		libraries << library_fact(spec, line_number, 'step', retriever)
	} else if spec := first_quoted(line['library'.len..]) {
		libraries << library_fact(spec, line_number, 'step', '')
	}
	return libraries
}

fn library_fact(spec string, line_number int, form string, retriever string) LibraryFact {
	return LibraryFact{
		name:      spec.all_before('@').trim_space()
		ref:       if spec.contains('@') { spec.all_after('@').trim_space() } else { '' }
		line:      line_number
		form:      form
		retriever: retriever
	}
}

fn quoted_values(value string) []string {
	mut values := []string{}
	mut remaining := value
	for {
		quoted := first_quoted(remaining) or { break }
		values << quoted
		quote_index := remaining.index(quoted) or { break }
		remaining = remaining[quote_index + quoted.len + 1..]
	}
	return values
}

// step_name returns the identifier a statement starts with when the statement
// looks like a step call, for example `deployToCluster env: 'prod'`.
fn step_name(line string) ?string {
	mut end := 0
	for end < line.len && (line[end].is_letter() || line[end].is_digit() || line[end] == `_`) {
		end++
	}
	if end == 0 || line[0].is_digit() {
		return none
	}
	rest := line[end..]
	if rest != '' && !rest.starts_with('(') && !rest.starts_with(' ') && !rest.starts_with('{') {
		return none
	}
	trimmed := rest.trim_space()
	// Assignments, method calls, and operators are Groovy, not step calls.
	if trimmed.starts_with('=') || trimmed.starts_with('.') || trimmed.starts_with('+')
		|| trimmed.starts_with('-') {
		return none
	}
	return line[..end]
}

fn is_known_step(name string) bool {
	return name in builtin_steps || name in integration_steps
}
