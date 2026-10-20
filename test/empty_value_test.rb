# frozen_string_literal: true

require_relative "test_helper"

class EmptyValueTest < Minitest::Test
  def test_empty_strings_follow_nil_policy_without_using_defaults
    { string: "Ada", boolean: false, scalar: 0 }.each do |type, default|
      schema = ActionController::Parameters.schema do |s|
        s.param :value, type, empty_string_to_nil: true, allow_nil: true, default: default, in: [ default ]
      end

      assert_equal({ "value" => default }, schema.parse({}).to_h)
      assert_equal({ "value" => default }, schema.parse(value: default).to_h)
      assert_equal({ "value" => nil }, schema.parse(value: "").to_h)
      assert_equal({ "value" => nil }, schema.parse(value: nil).to_h)

      nonnullable = ActionController::Parameters.schema { |s| s.param :value, type, empty_string_to_nil: true }

      assert_invalid nonnullable, { value: "" }, :nil_not_allowed, [ "value" ]
    end
  end

  def test_normalization_preserves_presence_and_only_converts_empty_strings
    schema = ActionController::Parameters.schema do |s|
      s.param :name, :string, empty_string_to_nil: true, allow_nil: true, required: true
      s.param :subscribed, :boolean, empty_string_to_nil: true, allow_nil: true
      s.param :reference, :scalar, empty_string_to_nil: true, allow_nil: true
    end

    assert_equal({ "name" => nil }, schema.parse(name: "").to_h)
    assert_invalid schema, {}, :missing, [ "name" ]
    assert_equal({ "name" => " \t", "subscribed" => false, "reference" => 0 },
      schema.parse(name: " \t", subscribed: "0", reference: 0).to_h)
    assert_equal({ "name" => "Ada", "reference" => false }, schema.parse(name: "Ada", reference: false).to_h)
    assert_equal " ", schema.parse(name: "Ada", reference: " ")[:reference]
    assert_invalid schema, { name: "Ada", subscribed: " " }, :invalid_boolean, [ "subscribed" ]
    assert_invalid schema, { name: "Ada", subscribed: "wrong" }, :invalid_boolean, [ "subscribed" ]

    unchanged = ActionController::Parameters.schema do |s|
      s.param :name, :string, empty_string_to_nil: false
      s.param :reference, :scalar
      s.param :subscribed, :boolean, allow_nil: true, empty_string_to_nil: false
    end

    assert_equal({ "name" => "", "reference" => "" }, unchanged.parse(name: "", reference: "").to_h)
    assert_invalid unchanged, { subscribed: "" }, :invalid_boolean, [ "subscribed" ]
  end

  def test_string_constraints_apply_after_normalization
    schema = ActionController::Parameters.schema do |s|
      s.param :name, :string, empty_string_to_nil: true, allow_nil: true, min_bytes: 2, format: /\A[A-Za-z]+\z/
    end

    assert_nil schema.parse(name: "")[:name]
    assert_equal "Ada", schema.parse(name: "Ada")[:name]
    assert_invalid schema, { name: "A" }, :value_too_short, [ "name" ]
    assert_invalid schema, { name: "12" }, :invalid_format, [ "name" ]
  end

  def test_defaults_are_validated_and_returned_without_normalization
    %i[string scalar].each do |type|
      schema = ActionController::Parameters.schema do |s|
        s.param :value, type, empty_string_to_nil: true, allow_nil: true, default: ""
      end

      assert_equal "", schema.parse({})[:value]
      assert_nil schema.parse(value: "")[:value]
    end
    assert_raises(ArgumentError) do
      ActionController::Parameters.schema do |s|
        s.param :name, :string, empty_string_to_nil: true, allow_nil: true, min_bytes: 1, default: ""
      end
    end
    assert_raises(ArgumentError) do
      ActionController::Parameters.schema { |s| s.param :subscribed, :boolean, empty_string_to_nil: true, allow_nil: true, default: "" }
    end
  end

  def test_nested_rules_normalize_values_and_preserve_error_positions
    schema = ActionController::Parameters.schema do |s|
      s.array :names, of: s.value(:string, empty_string_to_nil: true, allow_nil: true, min_bytes: 1)
      s.map :flags, of: s.value(:boolean, empty_string_to_nil: true)
    end

    assert_equal({ "names" => [ nil, "Ada" ], "flags" => { "02" => false } },
      schema.parse(names: [ "", "Ada" ], flags: { "02" => "0" }).to_h)
    assert_invalid schema, { flags: { "02" => "" } }, :nil_not_allowed, [ "flags", "02" ]
  end

  def test_empty_normalization_preserves_strict_types_for_nonempty_values
    { integer: 1, float: 1.0, boolean: false }.each do |type, value|
      schema = ActionController::Parameters.schema do |s|
        s.param :value, type, empty_string_to_nil: true, coerce: false, allow_nil: true
      end

      assert_equal({ "value" => value }, schema.parse(value: value).to_h)
      assert_equal({ "value" => nil }, schema.parse(value: "").to_h)
      assert_invalid schema, { value: value.to_s }, :"invalid_#{type}", [ "value" ]
      assert_invalid schema, { value: " " }, :"invalid_#{type}", [ "value" ]

      nonnullable = ActionController::Parameters.schema do |s|
        s.param :value, type, empty_string_to_nil: true, coerce: false
      end

      assert_invalid nonnullable, { value: "" }, :nil_not_allowed, [ "value" ]
    end
  end

  def test_empty_normalization_rejects_invalid_options
    [ nil, :nil, "true", 1 ].each do |option|
      assert_raises(ArgumentError) do
        ActionController::Parameters.schema { |s| s.param :value, :string, empty_string_to_nil: option }
      end
    end
  end

  private
    def assert_invalid(schema, input, code, path)
      error = assert_raises(ParamsSchema::InvalidParameters) { schema.parse(input) }

      assert_equal code, error.code
      assert_equal path, error.path
    end
end
