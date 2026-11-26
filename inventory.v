module main

import json
import os

const default_includes = {
	'jenkins': ['Jenkinsfile', 'Jenkinsfile.*', '*.jenkinsfile']
	'harness': ['*.yaml', '*.yml']
}

struct InventoryOptions {
mut:
	provider      string = 'jenkins'
	dir           string
	includes      []string
	excludes      []string
	format        string = 'ndjson'
	fail_on_error bool
}

struct InventoryRecord {
	path   string
	status string
	error  string
	facts  PipelineFacts
}

struct InventorySummary {
	@type                 string = 'summary' @[json: 'type']
	files                 int
	ok                    int
	no_stages             int
	read_error            int
	parse_error           int
	stages                int
	files_with_unresolved int
	agents                []string
	images                []string
	credentials           []string
	integrations          []string
}

fn parse_inventory_args(args []string) !InventoryOptions {
	mut options := InventoryOptions{}
	mut index := 0
	for index < args.len {
		flag := args[index]
		if flag == '--fail-on-error' {
			options.fail_on_error = true
			index++
			continue
		}
		if flag !in ['--provider', '--dir', '--include', '--exclude', '--format'] {
			return error('unknown option "${flag}"')
		}
		if index + 1 >= args.len {
			return error('${flag} requires a value')
		}
		value := args[index + 1]
		match flag {
			'--provider' { options.provider = value }
			'--dir' { options.dir = value }
			'--include' { options.includes << value }
			'--exclude' { options.excludes << value }
			else { options.format = value }
		}

		index += 2
	}
	if options.provider !in default_includes {
		return error('unsupported provider "${options.provider}"')
	}
	if options.format !in ['ndjson', 'json'] {
		return error('--format must be ndjson or json')
	}
	if options.dir == '' {
		return error('inventory requires --dir')
	}
	if !os.is_dir(options.dir) {
		return error('--dir is not a directory: ${options.dir}')
	}
	if options.includes.len == 0 {
		options.includes = default_includes[options.provider].clone()
	}
	return options
}

// discover returns matching files relative to root, sorted. Symlinks are never
// followed, so an untrusted export cannot point the scan outside root.
fn discover(root string, includes []string, excludes []string) []string {
	mut found := []string{}
	walk(root, '', includes, excludes, mut found)
	found.sort()
	return found
}

fn walk(root string, relative string, includes []string, excludes []string, mut found []string) {
	entries := os.ls(os.join_path(root, relative)) or { return }
	for name in entries {
		rel := if relative == '' { name } else { '${relative}/${name}' }
		full := os.join_path(root, rel)
		if os.is_link(full) || excludes.any(glob_match(it, rel) || glob_match(it, '${rel}/')) {
			continue
		}
		if os.is_dir(full) {
			walk(root, rel, includes, excludes, mut found)
		} else if includes.any(glob_match(it, if it.contains('/') { rel } else { name })) {
			found << rel
		}
	}
}

// glob_match supports `*` (within one path segment), `**` (any depth), and `?`.
fn glob_match(pattern string, path string) bool {
	if pattern == '' {
		return path == ''
	}
	if pattern.starts_with('**') {
		rest := pattern[2..].trim_left('/')
		for i in 0 .. path.len + 1 {
			if glob_match(rest, path[i..]) {
				return true
			}
		}
		return false
	}
	if path == '' {
		return false
	}
	match pattern[0] {
		`*` {
			for i in 0 .. path.len + 1 {
				if i > 0 && path[i - 1] == `/` {
					break
				}
				if glob_match(pattern[1..], path[i..]) {
					return true
				}
			}
			return false
		}
		`?` {
			return path[0] != `/` && glob_match(pattern[1..], path[1..])
		}
		else {
			return pattern[0] == path[0] && glob_match(pattern[1..], path[1..])
		}
	}
}

fn inventory_record(options InventoryOptions, rel string) InventoryRecord {
	path := os.join_path(options.dir, rel)
	content := os.read_file(path) or {
		return InventoryRecord{
			path:   rel
			status: 'read_error'
			error:  err.msg()
		}
	}
	facts := parse_pipeline_content(options.provider, content, rel) or {
		status := if err.msg().contains('no ') && err.msg().contains('stages') {
			'no_stages'
		} else {
			'parse_error'
		}
		return InventoryRecord{
			path:   rel
			status: status
			error:  err.msg()
		}
	}
	return InventoryRecord{
		path:   rel
		status: 'ok'
		facts:  facts
	}
}

fn parse_pipeline_content(provider string, content string, source string) !PipelineFacts {
	return match provider {
		'harness' { parse_harness(content, source)! }
		else { parse_jenkins(content, source)! }
	}
}

fn record_json(record InventoryRecord) string {
	mut out := '{"type":"file","path":${json.encode(record.path)},"status":"${record.status}"'
	if record.status == 'ok' {
		out += ',"facts":${json.encode(record.facts)}'
	} else {
		out += ',"error":${json.encode(record.error)}'
	}
	return out + '}'
}

fn summarize(records []InventoryRecord) InventorySummary {
	mut counts := map[string]int{}
	mut stages := 0
	mut unresolved := 0
	mut agents := []string{}
	mut images := []string{}
	mut credentials := []string{}
	mut integrations := []string{}
	for record in records {
		counts[record.status]++
		if record.status != 'ok' {
			continue
		}
		facts := record.facts
		stages += facts.stages.len
		if facts.unresolved.len > 0 {
			unresolved++
		}
		for value in facts.agents {
			add_unique(mut agents, value)
		}
		for value in facts.images {
			add_unique(mut images, value)
		}
		for stage in facts.stages {
			for value in stage.agents {
				add_unique(mut agents, value)
			}
			for value in stage.images {
				add_unique(mut images, value)
			}
		}
		for credential in facts.credentials {
			add_unique(mut credentials, credential.reference)
		}
		for value in facts.integrations {
			add_unique(mut integrations, value)
		}
	}
	agents.sort()
	images.sort()
	credentials.sort()
	integrations.sort()
	return InventorySummary{
		files:                 records.len
		ok:                    counts['ok']
		no_stages:             counts['no_stages']
		read_error:            counts['read_error']
		parse_error:           counts['parse_error']
		stages:                stages
		files_with_unresolved: unresolved
		agents:                agents
		images:                images
		credentials:           credentials
		integrations:          integrations
	}
}

// run_inventory emits NDJSON records as each file is parsed, or one JSON
// document at the end, and returns true when every file parsed.
fn run_inventory(options InventoryOptions, emit fn (string)) bool {
	mut records := []InventoryRecord{}
	for rel in discover(options.dir, options.includes, options.excludes) {
		record := inventory_record(options, rel)
		if options.format == 'ndjson' {
			emit(record_json(record))
		}
		records << record
	}
	summary := json.encode(summarize(records))
	if options.format == 'ndjson' {
		emit(summary)
	} else {
		emit('{"files":[${records.map(record_json(it)).join(',')}],"summary":${summary}}')
	}
	return records.all(it.status == 'ok')
}
