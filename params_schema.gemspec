# frozen_string_literal: true

require_relative "lib/params_schema/version"

Gem::Specification.new do |spec|
  spec.name = "params_schema"
  spec.version = ParamsSchema::VERSION
  spec.summary = "Explicit, typed parameter contracts for Action Controller"
  spec.description = "Validates, converts and extracts declared request parameters into permitted ActionController::Parameters."
  spec.authors = [ "to-omer" ]
  spec.homepage = "https://github.com/to-omer/params_schema"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir.glob([ "lib/**/*.rb", "sig/**/*.rbs", "docs/{index,development,integration,forms,errors,test_support}.md",
    "README.md", "LICENSE", ".yardopts" ],
    base: __dir__)
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["documentation_uri"] = "https://to-omer.github.io/params_schema/"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.add_dependency "actionpack", ">= 8.0", "< 8.2"
  spec.add_dependency "bigdecimal"
end
