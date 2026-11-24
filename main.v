module main

import json
import os

fn main() {
	if os.args.len < 2 || os.args[1] in ['help', '--help', '-h'] {
		print_help()
		return
	}
	if os.args[1] != 'pipeline' {
		eprintln('flowfacts: unknown command "${os.args[1]}"')
		exit(2)
	}
	provider, path := parse_pipeline_args(os.args[2..]) or {
		eprintln('flowfacts: ${err}')
		exit(2)
	}
	facts := parse_pipeline_file(provider, path) or {
		eprintln('flowfacts: ${err}')
		exit(1)
	}
	println(json.encode(facts))
}

fn parse_pipeline_args(args []string) !(string, string) {
	mut path := ''
	mut provider := 'jenkins'
	mut index := 0
	for index < args.len {
		match args[index] {
			'--file', '-f' {
				if index + 1 >= args.len {
					return error('${args[index]} requires a value')
				}
				path = args[index + 1]
				index += 2
			}
			'--provider' {
				if index + 1 >= args.len {
					return error('--provider requires a value')
				}
				provider = args[index + 1]
				index += 2
			}
			else {
				return error('unknown option "${args[index]}"')
			}
		}
	}
	if provider !in ['jenkins', 'harness'] {
		return error('unsupported provider "${provider}"')
	}
	if path == '' {
		return error('pipeline requires --file')
	}
	return provider, path
}

fn parse_pipeline_file(provider string, path string) !PipelineFacts {
	return match provider {
		'harness' { parse_harness_file(path)! }
		else { parse_jenkins_file(path)! }
	}
}

fn print_help() {
	println('flowfacts extracts deterministic CI/CD facts for migration agents.')
	println('')
	println('Usage:')
	println('  flowfacts pipeline --provider jenkins --file Jenkinsfile')
	println('  flowfacts pipeline --provider harness --file pipeline.yaml')
}
