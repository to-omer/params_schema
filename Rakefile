# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new do |task|
  task.pattern = "test/**/*_test.rb"
end

desc "Check Ruby style and lint"
task :rubocop do
  sh "bundle", "exec", "rubocop", "lib", "test", "script", "gemfiles",
    "params_schema.gemspec", "Gemfile", "Rakefile", "Steepfile"
end

desc "Generate the public API reference"
task :yard do
  sh "bundle", "exec", "yard", "doc"
end

desc "Validate public signatures, consumer examples, and runtime signature contracts"
task :typecheck do
  sh "bundle", "exec", "rbs", "-I", "sig", "validate"
  sh "bundle", "exec", "steep", "check", "--jobs=2", "--with-expectations=test/types/expectations.yml"
  sh({ "RBS_TEST_TARGET" => "ParamsSchema::Builder,ParamsSchema::Schema,ParamsSchema::Result,ParamsSchema::Parameters,ParamsSchema::Parameters::ClassMethods,ParamsSchema::Testing,ParamsSchema::Testing::RequestCase",
       "RBS_TEST_OPT" => "-I sig", "RBS_TEST_SAMPLE_SIZE" => "ALL" },
    Gem.ruby, "-rrbs/test/setup", "test/types/consumer.rb")
end

desc "Install and consume the built gem outside the source tree"
task package_check: :build do
  ruby "script/check_package.rb", "pkg/params_schema-#{ParamsSchema::VERSION}.gem"
end

task default: :test
