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

struct LibraryFact {
	name      string
	ref       string
	line      int
	form      string
	retriever string @[omitempty]
}

struct UnknownStepFact {
	name   string
	line   int
	stage  string
	source string
}

struct ParameterFact {
	name    string
	@type   string @[json: 'type']
	default string
	line    int
}

struct EnvironmentFact {
	name                 string
	value                string @[omitempty]
	credential_reference string @[omitempty]
	line                 int
}

struct ToolFact {
	@type string @[json: 'type']
	name  string
	line  int
}

struct OptionFact {
	name string
	raw  string
	line int
}

struct WhenFact {
	condition string
	raw       string
	line      int
}

struct PostFact {
	condition string
	line      int
mut:
	commands []CommandFact
}

struct StageFact {
	name            string
	kind            string
	line            int
	depends_on      []string
	parallel_parent string
mut:
	agents      []string
	images      []string
	commands    []CommandFact
	environment []EnvironmentFact
	tools       []ToolFact
	options     []OptionFact
	when        []WhenFact
	post        []PostFact
}

struct PipelineFacts {
	version  int = 1
	provider string
	source   string
mut:
	stages        []StageFact
	agents        []string
	images        []string
	triggers      []string
	credentials   []CredentialFact
	artifacts     []ArtifactFact
	endpoints     []EndpointFact
	integrations  []string
	unresolved    []UnresolvedFact
	libraries     []LibraryFact
	unknown_steps []UnknownStepFact
	parameters    []ParameterFact
	environment   []EnvironmentFact
	tools         []ToolFact
	options       []OptionFact
	post          []PostFact
}
