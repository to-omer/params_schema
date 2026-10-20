# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"

class LoadingTest < Minitest::Test
  def test_request_cases_load_without_rails_or_a_test_framework
    script = <<~RUBY
      require "params_schema/testing"
      abort "Loaded a framework" if defined?(ActionController) || defined?(RSpec) || defined?(Minitest)
      cases = ParamsSchema::Testing.request_cases(path: [:age], required: true, allow_nil: false)
      abort "Omission did not remove the field" unless cases.first.params(age: 27).empty?
    RUBY
    stdout, stderr, status = Open3.capture3({ "RUBYOPT" => nil, "RUBYLIB" => nil },
      RbConfig.ruby, "--disable-gems", "-I", File.expand_path("../lib", __dir__), "-e", script)

    assert_predicate status, :success?, "#{stdout}\n#{stderr}"
  end

  def test_entrypoint_loads_before_and_after_action_controller
    [ [], [ "action_controller" ] ].each do |preloads|
      script = <<~RUBY
        #{preloads.map { |name| "require #{name.inspect}" }.join("\n")}
        require "params_schema"
        abort "Loaded RSpec into the application" if defined?(RSpec)
        abort "Loaded test support into the application" if defined?(ParamsSchema::Testing)
        schema = ActionController::Parameters.schema { |s| s.param :page, :integer }
        input = ActionController::Parameters.new(page: "2", admin: true)
        output = input.parse(schema)
        abort "wrong result" unless output.to_h == { "page" => 2 }
        abort "input was permitted" if input.permitted?
        abort "missing HTTP mapping" unless
          ActionDispatch::ExceptionWrapper.status_code_for_exception("ParamsSchema::InvalidParameters") == 400
      RUBY
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script)

      assert_predicate status, :success?, "#{stdout}\n#{stderr}"
    end
  end

  def test_parameters_subclasses_inherit_the_public_api
    subclass = Class.new(ActionController::Parameters)
    schema = subclass.schema { |s| s.param :page, :integer }
    input = subclass.new(page: "2")

    assert_equal 2, input.parse(schema)[:page]
    assert_equal 2, input.parse { |s| s.param :page, :integer }[:page]
  end

  def test_loading_preserves_action_controller_exception_classes_and_responses
    script = <<~RUBY
      require "action_controller"
      require "action_dispatch/middleware/exception_wrapper"
      module ActionController
        class InvalidParameters < ArgumentError; end
        class UnexpectedParameters < ArgumentError; end
      end
      errors = [ActionController::InvalidParameters, ActionController::UnexpectedParameters]
      responses = ActionDispatch::ExceptionWrapper.rescue_responses
      errors.each { |error| responses[error.name] = :conflict }

      require "params_schema"

      abort "Replaced existing exception classes" unless
        errors == [ActionController::InvalidParameters, ActionController::UnexpectedParameters]
      abort "Changed existing HTTP responses" unless
        errors.all? { |error| responses.fetch(error.name) == :conflict }
      schema = ActionController::Parameters.schema { |s| s.param :page, :integer }
      { parse: ParamsSchema::InvalidParameters, parse!: ParamsSchema::UnexpectedParameters }.each do |method, expected|
        begin
          schema.public_send(method, page: "bad")
          abort "Accepted invalid input"
        rescue expected => error
          abort "Wrong diagnostic" unless error.code == :invalid_integer && error.path == ["page"]
        end
      end
    RUBY
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script)

    assert_predicate status, :success?, "#{stdout}\n#{stderr}"
  end

  def test_gemspec_loads_its_files_from_outside_the_checkout
    gemspec = File.expand_path("../params_schema.gemspec", __dir__)
    script = "puts Gem::Specification.load(ARGV.fetch(0)).files"

    Dir.mktmpdir("params-schema-gemspec-") do |directory|
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-e", script, gemspec, chdir: directory)

      assert_predicate status, :success?, stderr
      files = stdout.lines.map(&:chomp)

      assert_includes files, "lib/params_schema.rb"
      assert_includes files, "sig/params_schema.rbs"
      assert_includes files, "LICENSE"
    end
  end
end
