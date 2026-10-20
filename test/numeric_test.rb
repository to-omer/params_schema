# frozen_string_literal: true

require_relative "test_helper"

class NumericTest < Minitest::Test
  def test_empty_numeric_controls_can_clear_a_value_without_accepting_malformed_numbers
    %i[integer float].each do |type|
      schema = ActionController::Parameters.schema do |s|
        s.param :weight, type, empty_string_to_nil: true, allow_nil: true, in: 1..10, default: type == :integer ? 1 : 1.0
      end

      assert_equal(type == :integer ? 1 : 1.0, schema.parse({})[:weight])
      assert_nil schema.parse(weight: "")[:weight]
      assert_nil schema.parse(weight: nil)[:weight]
      assert_invalid schema, " ", :"invalid_#{type}"
      assert_invalid schema, "1junk", :"invalid_#{type}"
      strict = ActionController::Parameters.schema { |s| s.param :weight, type, allow_nil: true }

      assert_invalid strict, "", :"invalid_#{type}"
    end
    nonnullable = ActionController::Parameters.schema { |s| s.param :weight, :integer, empty_string_to_nil: true }

    assert_invalid nonnullable, "", :nil_not_allowed
    assert_raises(ArgumentError) do
      ActionController::Parameters.schema { |s| s.param :weight, :integer, empty_string_to_nil: true, allow_nil: true, default: "" }
    end
  end

  def test_float_conversion_uses_the_entire_decimal_value
    schema = ActionController::Parameters.schema { |s| s.param :weight, :float }
    { "1.25" => 1.25, "+.5" => 0.5, "-1." => -1.0, "1e2" => 100.0,
      "1.e2" => 100.0, "1.E-2" => 0.01, 2 => 2.0 }.each do |input, expected|
      result = schema.parse(weight: input)[:weight]

      assert_instance_of Float, result
      assert_equal expected, result
    end
    [ "1.25abc", "rubbish", " 1.25", "1_000", "0x1p2", "NaN", "Infinity", "1e9999", true, {} ].each do |input|
      assert_invalid schema, input, :invalid_float
    end
    assert_invalid schema, "0" * 257, :float_too_long
    assert_invalid schema, "\xff".b.force_encoding("UTF-8"), :invalid_encoding
    assert_invalid schema, "1.25".encode("UTF-16LE"), :invalid_encoding
  end

  def test_native_float_values_must_be_finite_and_strict_mode_rejects_conversion
    schema = ActionController::Parameters.schema { |s| s.param :weight, :float, coerce: false }

    assert_in_delta 1.25, schema.parse(weight: 1.25)[:weight]
    [ 1, "1.25", Float::NAN, Float::INFINITY, -Float::INFINITY ].each do |input|
      assert_invalid schema, input, :invalid_float
    end
    converting = ActionController::Parameters.schema { |s| s.param :weight, :float }

    assert_invalid converting, 10**1000, :invalid_float
  end

  def test_float_ranges_defaults_and_reused_rules_validate_converted_values
    schema = ActionController::Parameters.schema do |s|
      s.param :weight, :float, in: -10...10, default: 0.5
      s.array :weights, of: s.value(:float, in: [ 0.5, 1.5 ])
    end

    assert_equal({ "weight" => 0.5, "weights" => [ 0.5, 1.5 ] }, schema.parse(weights: [ "0.5", "1.5" ]).to_h)
    assert_in_delta(-10.0, schema.parse(weight: "-10")[:weight])
    assert_invalid schema, "10", :not_included
    [ "1.25", 1, Float::INFINITY ].each do |default|
      assert_raises(ArgumentError) do
        ActionController::Parameters.schema { |s| s.param :weight, :float, default: default }
      end
    end
    [ "a".."z", 0..Float::INFINITY ].each do |range|
      assert_raises(ArgumentError) do
        ActionController::Parameters.schema { |s| s.param :weight, :float, in: range }
      end
    end
  end

  def test_numeric_extremes_do_not_emit_input_or_change_decimal_settings
    schema = ActionController::Parameters.schema { |s| s.param :weight, :float }
    BigDecimal.save_exception_mode do
      BigDecimal.mode(BigDecimal::EXCEPTION_ALL, true)
      mode = BigDecimal.mode(BigDecimal::EXCEPTION_ALL)

      assert_silent do
        assert_invalid schema, "1e9999", :invalid_float
        assert_invalid schema, 10**1000, :invalid_float
        assert_in_delta 0.0, schema.parse(weight: "1e-9999")[:weight]
        [ "1.7976931348623158e308", 17_976_931_348_623_158 * (10**292) ].each do |input|
          assert_equal Float::MAX, schema.parse(weight: input)[:weight]
        end
      end
      assert_equal mode, BigDecimal.mode(BigDecimal::EXCEPTION_ALL)
    end
  end

  private
    def assert_invalid(schema, value, code)
      error = assert_raises(ParamsSchema::InvalidParameters) { schema.parse(weight: value) }
      assert_equal code, error.code
      assert_equal [ "weight" ], error.path
    end
end
