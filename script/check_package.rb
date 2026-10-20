# frozen_string_literal: true

require "bundler"
require "fileutils"
require "rubygems/package"
require "tmpdir"

archive = File.expand_path(ARGV.fetch(0))
package = Gem::Package.new(archive)
spec = package.spec
required = %w[lib/params_schema.rb lib/params_schema/testing.rb
  lib/params_schema/testing/request_case.rb lib/params_schema/unexpected_parameters.rb
  sig/params_schema.rbs docs/test_support.md README.md LICENSE]
raise "Missing package files: #{required - spec.files}" unless (required - spec.files).empty?

# Install only the declared runtime dependency graph from the current Bundle.
dependencies = {}
pending = spec.runtime_dependencies
until pending.empty?
  dependency = pending.shift
  next if dependencies.key?(dependency.name)

  resolved = Gem::Specification.find_by_name(dependency.name, dependency.requirement)
  dependencies[dependency.name] = resolved
  pending.concat(resolved.runtime_dependencies)
end
archives = dependencies.values.reject(&:default_gem?).map(&:cache_file)
archives.each { |path| raise "Missing cached dependency: #{path}" unless File.file?(path) }
tool_paths = Gem.path
steep_version = Gem::Specification.find_by_name("steep").version.to_s
steep_executable = Gem.bin_path("steep", "steep")
rbs_version = Gem::Specification.find_by_name("rbs").version.to_s
collection = File.expand_path(".gem_rbs_collection")
raise "Run rbs collection install first" unless File.directory?(collection)

Dir.mktmpdir("params-schema-package-") do |directory|
  gem_home = File.join(directory, "gems")
  consumer = File.join(directory, "consumer.rb")
  FileUtils.cp(File.expand_path("../test/types/consumer.rb", __dir__), consumer)
  Bundler.with_unbundled_env do
    environment = ENV.keys.grep(/\ABUNDLE_/).to_h { |name| [ name, nil ] }.merge(
      "GEM_HOME" => gem_home, "GEM_PATH" => gem_home, "RUBYOPT" => nil, "RUBYLIB" => nil,
      "BUNDLE_USER_HOME" => File.join(directory, "bundler"), "BUNDLE_IGNORE_CONFIG" => "true"
    )
    system(environment, Gem.ruby, "-S", "gem", "install", "--local", "--no-document",
      "--ignore-dependencies", "--install-dir", gem_home, *archives, archive,
      chdir: directory, exception: true)
    installed = File.join(gem_home, "gems", spec.full_name)
    system(environment, Gem.ruby, "-e", <<~RUBY, installed, consumer, chdir: directory, exception: true)
      require "params_schema"
      loaded = Gem.loaded_specs.fetch("params_schema").full_gem_path
      abort "Loaded source tree instead of package" unless File.realpath(loaded) == File.realpath(ARGV.fetch(0))
      load ARGV.fetch(1)
    RUBY

    # A separate consumer loads signatures from the installed gem, without -I sig.
    FileUtils.cp_r(collection, File.join(directory, "rbs"))
    File.write(File.join(directory, "Gemfile"), <<~GEMFILE)
      source "https://rubygems.org"
      gem "params_schema", #{spec.version.to_s.inspect}
      gem "rbs", #{rbs_version.inspect}, require: false
      gem "steep", #{steep_version.inspect}, require: false
    GEMFILE
    File.write(File.join(directory, "Steepfile"), <<~STEEP)
      target :package do
        configure_code_diagnostics Steep::Diagnostic::Ruby.strict
        disable_collection
        repo_path "rbs"
        library "actionpack", "params_schema"
        check "consumer.rb"
      end
    STEEP
    type_environment = environment.merge("GEM_PATH" => [ gem_home, *tool_paths ].join(File::PATH_SEPARATOR))
    system(type_environment, Gem.ruby, "-S", "bundle", "install", "--local", chdir: directory, exception: true)
    system(type_environment, Gem.ruby, "-S", "bundle", "exec", Gem.ruby, steep_executable, "check", "--jobs=2",
      chdir: directory, exception: true)
  end
end

puts "Package runtime and signature consumption passed"
