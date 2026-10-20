# frozen_string_literal: true

require_relative "test_helper"

class NotificationsTest < Minitest::Test
  def test_inline_schemas_apply_root_options_and_report_their_name
    events = []
    subscriber = ->(event) { events << event.payload }
    input = ActionController::Parameters.new(age: "27", extra: "unexpected")
    definition = ->(s) { s.param :age, :integer }

    ActiveSupport::Notifications.subscribed(subscriber, "invalid.params_schema") do
      { parse: ParamsSchema::InvalidParameters, parse!: ParamsSchema::UnexpectedParameters }.each do |method, error_class|
        events.clear
        parsed = input.public_send(method, name: :inline, unknown: :drop, &definition)

        assert_equal({ "age" => 27 }, parsed.to_h)
        assert_predicate parsed, :permitted?
        assert_empty events
        error = assert_raises(error_class) { input.public_send(method, name: :inline, unknown: :reject, &definition) }

        assert_equal :unknown_parameter, error.code
        assert_equal [ "extra" ], error.path
        assert_equal [ { schema: "inline", code: :unknown_parameter } ], events
        refute_predicate input, :permitted?
        assert_equal({ "age" => "27", "extra" => "unexpected" }, input.to_unsafe_h)
      end
    end
  end

  def test_entrypoints_report_once_without_values_paths_or_exceptions
    name = +"users_create"
    schema = ActionController::Parameters.schema(name: name) { |s| s.param :age, :integer }
    name.replace("edited")
    events = []
    subscriber = ActiveSupport::Notifications.subscribe("invalid.params_schema") { |event| events << event.payload }

    schema.parse(age: "27")
    schema.try_parse(age: "28")
    schema.parse!(age: "29")

    assert_empty events

    result = schema.try_parse("private-key" => "secret", age: "private value")
    assert_raises(ParamsSchema::InvalidParameters) { result.value! }
    assert_equal [ { schema: "users_create", code: :invalid_integer } ], events

    assert_raises(ParamsSchema::InvalidParameters) { schema.parse(age: "bad") }
    assert_equal 2, events.length
    assert_equal events.first, events.last
    assert_raises(ParamsSchema::UnexpectedParameters) { schema.parse!(age: "bad") }
    assert_equal 3, events.length
    assert_equal events.first, events.last
    refute_predicate name, :frozen?
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def test_subscriber_errors_propagate_even_when_they_are_invalid_parameters
    schema = ActionController::Parameters.schema { |s| s.param :age, :integer }
    failure = ParamsSchema::InvalidParameters.new([], :invalid_string)
    subscriber = ActiveSupport::Notifications.subscribe("invalid.params_schema") { raise failure }

    error = assert_raises(ParamsSchema::InvalidParameters) { schema.try_parse(age: "bad") }
    assert_same failure, error
    error = assert_raises(ParamsSchema::InvalidParameters) { schema.parse(age: "bad") }
    assert_same failure, error
    error = assert_raises(ParamsSchema::InvalidParameters) { schema.parse!(age: "bad") }
    assert_same failure, error
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def test_api_and_definition_errors_do_not_publish_validation_events
    events = []
    subscriber = ActiveSupport::Notifications.subscribe("invalid.params_schema") { |event| events << event }
    schema = ActionController::Parameters.schema { |s| s.param :age, :integer }

    assert_raises(ArgumentError) { schema.try_parse({}) { flunk "unused block was called" } }
    assert_raises(ArgumentError) { schema.parse({}) { flunk "unused block was called" } }
    assert_raises(ArgumentError) { schema.parse!({}) { flunk "unused block was called" } }
    assert_raises(ArgumentError) { ActionController::Parameters.schema(name: []) { flunk "invalid name was accepted" } }
    assert_raises(ArgumentError) { ActionController::Parameters.schema { |s| s.param :age, :integer, default: "1" } }
    input = ActionController::Parameters.new(age: "27")
    [ :parse, :parse! ].each do |method|
      assert_raises(ArgumentError) { input.public_send(method, schema, name: :ignored) }
      assert_raises(ArgumentError) { input.public_send(method, unknown: :invalid) { |s| s.param :age, :integer } }
      assert_raises(ArgumentError) { input.public_send(method, name: []) { |s| s.param :age, :integer } }
      assert_raises(ArgumentError) { input.public_send(method, typo: true) { |s| s.param :age, :integer } }
    end
    assert_empty events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end
