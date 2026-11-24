module main

struct CredentialFact {
	reference string
	line      int
	stage     string
}

struct ArtifactFact {
	operation string
	value     string
	line      int
	stage     string
}

struct CommandFact {
	shell   string
	command string
	line    int
	stage   string
}

struct EndpointFact {
	url   string
	line  int
	stage string
}

struct UnresolvedFact {
	reason string
	line   int
	stage  string
	source string
}

struct StageFact {
	name            string
	kind            string
	line            int
	depends_on      []string
	parallel_parent string
mut:
	agents   []string
	images   []string
	commands []CommandFact
}

struct PipelineFacts {
	version  int = 1
	provider string
	source   string
mut:
	stages       []StageFact
	agents       []string
	images       []string
	triggers     []string
	credentials  []CredentialFact
	artifacts    []ArtifactFact
	endpoints    []EndpointFact
	integrations []string
	unresolved   []UnresolvedFact
}
