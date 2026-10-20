# frozen_string_literal: true

require_relative "test_helper"

class ResultTest < Minitest::Test
  def setup
    @schema = ActionController::Parameters.schema do |s|
      s.object :user, required: true do |user|
        user.param :name, :string
        user.param :age, :integer, required: true
      end
    end
  end

  def test_success_keeps_the_parsed_output_without_reparsing
    input = { user: { name: "private name", age: "027" } }
    result = @schema.try_parse(input)
    output = result.value!
    input[:user][:age] = "invalid"

    assert_predicate result, :success?
    assert_nil result.error
    assert_equal({ "user" => { "name" => "private name", "age" => 27 } }, output.to_h)
    assert_predicate output[:user], :permitted?
    assert_same output, result.value!
    refute_includes result.inspect, "private name"
    output[:user][:name].replace("changed")

    assert_equal "private name", input[:user][:name]
  end

  def test_failure_preserves_the_input_and_raises_the_saved_diagnostic
    input = ActionController::Parameters.new(user: { name: "private name", age: "invalid" })
    result = @schema.try_parse(input)

    refute_predicate result, :success?
    assert_equal :invalid_integer, result.error.code
    assert_equal [ "user", "age" ], result.error.path
    error = assert_raises(ParamsSchema::InvalidParameters) { result.value! }

    assert_same result.error, error
    refute_predicate input, :permitted?
    assert_equal({ "user" => { "name" => "private name", "age" => "invalid" } }, input.to_unsafe_h)
    assert_equal "#<ParamsSchema::Result failure: invalid_integer>", result.inspect
  end

  def test_only_validation_errors_become_failure_results
    assert_raises(ArgumentError) { @schema.try_parse({}) { flunk "unused block was called" } }
    broken_input = Class.new(Hash) do
      def each_pair = raise(NoMethodError, "broken input reader")
    end.new

    error = assert_raises(NoMethodError) { @schema.try_parse(broken_input) }

    assert_equal "broken input reader", error.message
    assert_raises(NoMethodError) { @schema.parse!(broken_input) }
  end

  def test_bang_preserves_the_validation_diagnostic_and_input
    input = ActionController::Parameters.new(user: { name: "private name", age: "bad" })
    error = assert_raises(ParamsSchema::UnexpectedParameters) { input.parse!(@schema) }

    assert_equal :invalid_integer, error.code
    assert_equal [ "user", "age" ], error.path
    assert_predicate error.path, :frozen?
    assert error.path.all?(&:frozen?)
    assert_nil error.cause
    refute_includes error.inspect, "private name"
    refute_predicate input, :permitted?
    assert_equal "bad", input.dig(:user, :age)
  end
end
