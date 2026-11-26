module main

import json
import os

@[heap]
struct Collector {
mut:
	lines []string
}

fn collect(options InventoryOptions) ([]string, bool) {
	mut c := &Collector{}
	ok := run_inventory(options, fn [mut c] (line string) {
		c.lines << line
	})
	return c.lines, ok
}

fn inventory_options(extra []string) InventoryOptions {
	mut args := ['--dir', 'testdata/inventory']
	args << extra
	return parse_inventory_args(args) or { panic(err) }
}

fn test_discovery_uses_default_includes_and_sorts() {
	files := discover('testdata/inventory', default_includes['jenkins'], [])
	assert files == ['Jenkinsfile', 'empty/Jenkinsfile', 'services/api/Jenkinsfile.release',
		'services/web/ci.jenkinsfile', 'vendor/lib/Jenkinsfile']
}

fn test_exclude_and_include_patterns() {
	assert discover('testdata/inventory', default_includes['jenkins'], ['vendor/**']) == [
		'Jenkinsfile',
		'empty/Jenkinsfile',
		'services/api/Jenkinsfile.release',
		'services/web/ci.jenkinsfile',
	]
	assert discover('testdata/inventory', ['services/**/*.jenkinsfile'], []) == [
		'services/web/ci.jenkinsfile',
	]
}

fn test_glob_match() {
	assert glob_match('Jenkinsfile.*', 'Jenkinsfile.release')
	assert !glob_match('*.jenkinsfile', 'a/b.jenkinsfile')
	assert glob_match('**/*.jenkinsfile', 'a/b/c.jenkinsfile')
	assert glob_match('vendor/**', 'vendor/lib/Jenkinsfile')
	assert !glob_match('vendor/**', 'src/vendor.txt')
	assert glob_match('Jenkins?ile', 'Jenkinsfile')
}

fn test_ndjson_records_and_summary() {
	lines, ok := collect(inventory_options(['--exclude', 'vendor/**']))
	assert !ok
	assert lines.len == 5
	assert lines[0].starts_with('{"type":"file","path":"Jenkinsfile","status":"ok","facts":{')
	assert lines[1] == '{"type":"file","path":"empty/Jenkinsfile","status":"no_stages","error":"no declarative Jenkins stages found"}'
	summary := json.decode(InventorySummary, lines[4])!
	assert summary.@type == 'summary'
	assert summary.files == 4
	assert summary.ok == 3
	assert summary.no_stages == 1
	assert summary.stages == 2 + 5 + 5
	assert summary.credentials == ['deploy-token']
	assert 'golang:1.23' in summary.images
	assert summary.files_with_unresolved > 0
}

fn test_json_format_is_one_document_and_deterministic() {
	first, _ := collect(inventory_options(['--format', 'json']))
	second, _ := collect(inventory_options(['--format', 'json']))
	assert first.len == 1
	assert first == second
	assert first[0].starts_with('{"files":[')
	assert first[0].contains('"summary":{"type":"summary","files":5')
}

fn test_symlinks_are_not_followed() {
	root := os.join_path(os.temp_dir(), 'flowfacts-inventory-${os.getpid()}')
	outside := os.join_path(os.temp_dir(), 'flowfacts-outside-${os.getpid()}')
	os.mkdir_all(root)!
	os.mkdir_all(outside)!
	defer {
		os.rmdir_all(root) or {}
		os.rmdir_all(outside) or {}
	}
	os.write_file(os.join_path(outside, 'Jenkinsfile'), 'secret')!
	os.write_file(os.join_path(root, 'Jenkinsfile'),
		"pipeline { stages { stage('A') { steps { sh 'x' } } } }")!
	os.symlink(outside, os.join_path(root, 'linked-dir'))!
	os.symlink(os.join_path(outside, 'Jenkinsfile'), os.join_path(root, 'Jenkinsfile.linked'))!
	assert discover(root, default_includes['jenkins'], []) == ['Jenkinsfile']
}

fn test_invalid_inventory_options() {
	for args in [['--dir'], ['--provider', 'gitlab', '--dir', '.'],
		['--format', 'xml', '--dir', '.'], ['--bogus'], ['--provider', 'jenkins'],
		['--dir', 'testdata/missing']] {
		if _ := parse_inventory_args(args) {
			assert false, 'expected error for ${args}'
		}
	}
}
