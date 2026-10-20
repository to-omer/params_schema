# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "json"

class RSpecSupportTest < Minitest::Test
  def test_request_examples_detect_validation_response_persistence_and_observation_regressions
    { "" => nil, "range" => "outside range 151", "required" => "omitted", "nil" => "explicit nil",
      "skip_parse" => "outside range 151", "discard_output" => "valid baseline", "reject_all" => "valid baseline",
      "nested_range" => '["user", "ids", 1]: outside range 11', "partial_write" => "omitted",
      "response_body" => "valid baseline", "skip_observation" => "reports known invalid input",
      "use_observed_result" => "keeps the legacy defaults" }.each do |regression, failure|
      stdout, stderr, status = Open3.capture3({ "REQUEST_REGRESSION" => regression },
        RbConfig.ruby, "-Ilib", "-rrspec/core", "-rrspec/expectations", "-e", "exit RSpec::Core::Runner.run(ARGV)",
        File.join(__dir__, "support/rspec_request_consumer.rb"), "--format", "json", "--order", "rand", "--seed", "39417")
      report = JSON.parse(stdout)

      assert_equal 24, report.fetch("summary").fetch("example_count"), "#{stdout}\n#{stderr}"
      failures = report.fetch("examples").select { |example| example.fetch("status") == "failed" }

      if failure
        assert_equal 1, status.exitstatus, "#{stdout}\n#{stderr}"
        refute_nil failures.find { |example| example.fetch("full_description").include?(failure) }, "Missing #{failure} failure:\n#{stdout}"
        failures.each do |example|
          assert_includes [ "RSpec::Expectations::ExpectationNotMetError", "RSpec::Expectations::MultipleExpectationsNotMetError" ],
            example.fetch("exception").fetch("class")
          assert_includes example.fetch("exception").fetch("message"), "expected"
        end
      else
        assert_predicate status, :success?, "#{stdout}\n#{stderr}"
        assert_empty failures
      end
    end
  end
end
