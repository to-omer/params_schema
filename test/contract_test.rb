# frozen_string_literal: true

require_relative "test_helper"

class ContractTest < Minitest::Test
  def schema(**options, &block)
    ActionController::Parameters.schema(**options, &block)
  end

  def parse(contract, input)
    contract.parse(input).to_h
  end

  def invalid(contract, input, code, path = nil)
    error = assert_raises(ParamsSchema::InvalidParameters) { parse(contract, input) }
    assert_equal code, error.code
    assert_equal path, error.path if path

    error
  end

  def value_schema(rule = :integer, **options)
    schema { |s| s.param :v, rule, **options }
  end

  def test_integer_acceptance_and_full_decimal_conversion
    contract = value_schema
    good = { "0" => 0, "+0" => 0, "-0" => 0, "0012" => 12,
      "+12" => 12, "-12" => -12, ("0" * 16) + "1" => 1, "9" * 256 => (10**256) - 1 }
    good.each do |raw, expected|
      actual = parse(contract, v: raw)

      assert({ "v" => expected }.eql?(actual), "integer output for #{raw.inspect}: #{actual.inspect}")
    end
    [ 0, -1, 1, 10**300, -(10**300) ].each do |n|
      actual = parse(contract, v: n)

      assert({ "v" => n }.eql?(actual), "integer output for #{n.inspect}: #{actual.inspect}")
    end
    [ "", " ", " 12", "12 ", "1_2", "0x12", "12abc", "1\n2", "1.0", "1e2", "１２", "-", true, false, [], {}, 1.0 ].each do |v|
      invalid(contract, { v: v }, :invalid_integer, [ "v" ])
    end
    invalid(contract, { v: "0" * 257 }, :integer_too_long)
    invalid(value_schema(:integer, coerce: false), { v: "2" }, :invalid_integer)
    invalid(contract, { v: "2".encode("UTF-16LE") }, :invalid_encoding)
  end

  def test_reused_rules_check_range_boundaries_in_fields_arrays_and_maps
    contract = schema do |s|
      id = s.value(:integer, in: -50..50)
      s.param :one, id
      s.array :many, of: id
      s.map :named, of: id
    end
    [ -51, -50, -1, 0, 1, 50, 51 ].each do |n|
      source = n.negative? ? "-#{(-n).to_s.rjust(4, '0')}" : "+#{n.to_s.rjust(4, '0')}"
      input = { one: source, many: [ source ], named: { a: source } }
      if (-50..50).cover?(n)
        expected = { "one" => n, "many" => [ n ], "named" => { "a" => n } }
        actual = parse(contract, input)

        assert expected.eql?(actual), "expected #{expected.inspect}, got #{actual.inspect}"
      else
        # Keep earlier fields valid so fail-fast parsing reaches each position.
        [
          [ { one: source, many: [ "0" ], named: { a: "0" } }, [ "one" ] ],
          [ { one: "0", many: [ "0", source ], named: { a: "0" } }, [ "many", 1 ] ],
          [ { one: "0", many: [ "0" ], named: { a: "0", b: source } }, [ "named", "b" ] ]
        ].each { |candidate, path| invalid(contract, candidate, :not_included, path) }
      end
    end
  end

  def test_boolean_is_not_ruby_truthiness
    contract = value_schema(:boolean)

    { true => true, false => false, "true" => true, "false" => false, "1" => true, "0" => false }.each do |v, expected|
      assert_equal({ "v" => expected }, parse(contract, v: v))
    end
    [ 0, 1, "yes", "off", "TRUE", "False", "", :not_a_boolean, [], {} ].each do |v|
      invalid(contract, { v: v }, :invalid_boolean)
    end
    invalid(value_schema(:boolean, coerce: false), { v: "false" }, :invalid_boolean)
  end

  def test_string_scalar_and_encoding_rules
    text = "あいう"
    encoded = text.encode("UTF-16LE")
    [ text, encoded, "" ].each do |v|
      result = parse(value_schema(:string), v: v).fetch("v")

      assert_equal v, result
      assert_equal v.encoding, result.encoding
      refute_same v, result
    end
    [ 1, false, {}, [], :symbol ].each { |v| invalid(value_schema(:string), { v: v }, :invalid_string) }
    bad = "\xff".b.force_encoding("UTF-8")
    invalid(value_schema(:string), { v: bad }, :invalid_encoding)
    invalid(value_schema(:scalar), { v: bad }, :invalid_encoding)
    [ 0, -4, 2.5, "0", "", true, false ].each do |v|
      result = parse(value_schema(:scalar), v: v)["v"]

      assert_equal v, result
      assert_equal v.class, result.class
    end
    [ Float::INFINITY, -Float::INFINITY, Float::NAN, [], {}, Object.new, :s ].each do |v|
      invalid(value_schema(:scalar), { v: v }, :invalid_scalar)
    end
  end

  def test_presence_nil_and_defaults_are_distinct
    contract = schema do |s|
      s.param :page, :integer, default: 1
      s.param :flag, :boolean, default: false
      s.param :optional, :string
      s.param :nullable, :integer, allow_nil: true, in: 1..2
    end

    assert_equal({ "page" => 1, "flag" => false }, parse(contract, {}))
    assert_equal({ "page" => 1, "flag" => false, "nullable" => nil }, parse(contract, nullable: nil))
    invalid(contract, { page: nil }, :nil_not_allowed)
    invalid(contract, { page: "" }, :invalid_integer)
    required = value_schema(:boolean, required: true)
    invalid(required, {}, :missing, [ "v" ])

    assert_equal({ "v" => false }, parse(required, v: false))
    assert_equal({ "v" => "" }, parse(value_schema(:string, required: true), v: ""))
  end

  def test_nullable_defaults
    contract = schema do |s|
      s.param :n, :integer, allow_nil: true, default: nil
      s.param :v, :integer, coerce: false, allow_nil: true, default: 2
      s.param :flag, :boolean, default: true
    end

    assert_equal({ "n" => nil, "v" => 2, "flag" => true }, parse(contract, {}))
    assert_equal({ "n" => 3, "v" => nil, "flag" => false }, parse(contract, n: 3, v: nil, flag: false))
  end

  def test_string_subclass_flags_and_regexp_encoding
    text = Class.new(String).new("text")
    [ :string, :scalar ].each do |type|
      result = parse(value_schema(type), v: text)["v"]

      assert_instance_of String, result
      refute_same text, result
    end
    error = invalid(value_schema(:string, format: /\A.+\z/u), { v: "\xff".b }, :invalid_encoding)

    assert_nil error.cause
    keyed = schema { |s| s.map :v, of: :integer, keys: /\A.+\z/u }
    invalid(keyed, { v: { "\xff".b => 1 } }, :invalid_encoding, [ "v", "\xff".b ])
    invalid(keyed, { v: { "\xff".b.force_encoding("UTF-8") => 1 } }, :invalid_encoding, [ "v" ])
  end

  def test_nested_defaults_do_not_synthesize_missing_parents
    contract = schema do |s|
      s.object(:optional) { |p| p.param :x, :integer, default: 3 }
      s.object(:nullable, allow_nil: true) { |p| p.param :x, :integer, default: 4 }
      s.array(:records) { |p| p.param :x, :integer, default: 5 }
    end

    assert_equal({}, parse(contract, {}))
    assert_equal({ "optional" => { "x" => 3 }, "nullable" => nil, "records" => [ { "x" => 5 } ] },
      parse(contract, optional: {}, nullable: nil, records: [ {} ]))
  end

  def test_arrays_maps_and_objects_keep_their_shapes
    contract = schema do |s|
      s.array :ids, of: :integer, min_size: 1, max_size: 2
      s.map :rows, keys: /\A[0-9]+\z/, min_size: 1, max_size: 2, unknown: :reject do |row|
        row.param :name, :string, required: true
        row.param :enabled, :scalar
      end
    end
    output = parse(contract, ids: [ "2", "1" ], rows: { "10" => { name: "A" }, "02" => { name: "B", enabled: "0" } })

    assert_equal({ "ids" => [ 2, 1 ], "rows" => { "10" => { "name" => "A" }, "02" => { "name" => "B", "enabled" => "0" } } }, output)
    assert_equal [ "10", "02" ], output.fetch("rows").keys
    invalid(contract, { ids: { "0" => 1 } }, :invalid_array)
    invalid(contract, { ids: [] }, :too_few_items)
    invalid(contract, { ids: [ 1, 2, 3 ] }, :too_many_items)
    invalid(contract, { rows: [] }, :invalid_map)
    invalid(contract, { rows: {} }, :too_few_items)
    invalid(contract, { rows: { "x" => { name: "A" } } }, :invalid_map_key, [ "rows", "x" ])
    invalid(contract, { rows: { "10" => {} } }, :missing, [ "rows", "10", "name" ])
    invalid(contract, { rows: { "10" => { name: "A", extra: 1 } } }, :unknown_parameter, [ "rows", "10", "extra" ])
  end

  def test_finite_structures_compose_without_special_runtime_paths
    contract = schema do |s|
      row = s.value(:array, of: s.value(:integer, in: 0..), min_size: 1)
      s.array :matrix, of: row
      s.map :groups, of: row
      s.param :settings, s.value(:object) { |o| o.param :enabled, :boolean }
    end

    assert_equal({ "matrix" => [ [ 1, 2 ], [ 3 ] ], "groups" => { "a" => [ 4 ] }, "settings" => { "enabled" => false } },
      parse(contract, matrix: [ [ "1", "2" ], [ "3" ] ], groups: { a: [ "4" ] }, settings: { enabled: "false" }))
    invalid(contract, { matrix: [ [ 1 ], [ -1 ] ] }, :not_included, [ "matrix", 1, 0 ])
    invalid(contract, { groups: { a: [] } }, :too_few_items, [ "groups", "a" ])
  end

  def test_container_nil_and_element_nil_are_independent
    contract = schema do |s|
      s.array :a, of: s.value(:integer, allow_nil: true)
      s.array :b, of: :integer, allow_nil: true
      s.map :c, of: s.value(:object, allow_nil: true) { |o| o.param :id, :integer }
    end

    assert_equal({ "a" => [ nil, 1 ], "b" => nil, "c" => { "x" => nil } }, parse(contract, a: [ nil, 1 ], b: nil, c: { x: nil }))
    invalid(contract, { a: nil }, :nil_not_allowed, [ "a" ])
    invalid(contract, { b: [ nil ] }, :nil_not_allowed, [ "b", 0 ])
  end

  def test_string_lengths_are_bytes_and_all_constraints_apply
    contract = value_schema(:string, min_bytes: 3, max_bytes: 6, format: /\Aあ+\z/)

    assert_equal({ "v" => "あ" }, parse(contract, v: "あ"))
    assert_equal({ "v" => "ああ" }, parse(contract, v: "ああ"))
    invalid(contract, { v: "aa" }, :value_too_short)
    invalid(contract, { v: "あああ" }, :value_too_long)
    invalid(contract, { v: "abc" }, :invalid_format)
    contract = value_schema(:string, in: [ "aa", "bbb" ], min_bytes: 3)
    invalid(contract, { v: "aa" }, :value_too_short)

    assert_equal({ "v" => "bbb" }, parse(contract, v: "bbb"))
  end

  def test_enumerations_preserve_eql_and_range_boundaries
    contract = value_schema(:scalar, in: [ 1 ])
    invalid(contract, { v: 1.0 }, :not_included)

    assert_equal({ "v" => 1 }, parse(contract, v: 1))
    [ (1..3), (1...3), (..3), (1..) ].each do |range|
      rule = value_schema(:integer, in: range)
      [ -1, 0, 1, 2, 3, 4 ].each do |n|
        if range.cover?(n)
          assert_equal({ "v" => n }, parse(rule, v: n.to_s))
        else
          invalid(rule, { v: n }, :not_included)
        end
      end
    end
  end

  def test_empty_enumerations_reject_values_without_rejecting_omission_or_nil
    { string: "open", integer: 1, float: 1.0, boolean: false, scalar: "open" }.each do |type, value|
      choices = []
      contract = schema do |s|
        s.param :optional, type, in: choices
        s.param :nullable, type, in: choices, allow_nil: true, default: nil
        s.array :values, of: s.value(type, in: choices)
      end
      choices << value

      assert_equal({ "nullable" => nil, "values" => [] }, parse(contract, values: []))
      assert_equal({ "nullable" => nil }, parse(contract, nullable: nil))
      invalid(contract, { optional: value }, :not_included, [ "optional" ])
      invalid(contract, { nullable: value }, :not_included, [ "nullable" ])
      invalid(contract, { values: [ value ] }, :not_included, [ "values", 0 ])
      assert_raises(ArgumentError) { schema { |s| s.param :v, type, in: [], default: value } }
    end
  end

  def test_patterns_guard_line_anchors_and_allow_explicit_multiline
    assert_raises(ArgumentError) { value_schema(:string, format: /^[a-z]+$/) }
    assert_raises(ArgumentError) { schema { |s| s.map :rows, of: :integer, keys: /^\d+$/ } }
    [ /\A[a-z]+$/, /\A[a-z]+\\$/, /\A[a-z]+\\\\$/ ].each do |pattern|
      assert_raises(ArgumentError) { value_schema(:string, format: pattern) }
      assert_raises(ArgumentError) { schema { |s| s.map :rows, of: :integer, keys: pattern } }
    end
    contract = value_schema(:string, format: /\A[a-z]+\z/)
    invalid(contract, { v: "valid\n123" }, :invalid_format)
    permitted = value_schema(:string, format: /^[a-z]+$/, multiline: true)

    assert_equal({ "v" => "valid\n123" }, parse(permitted, v: "valid\n123"))
    permitted = value_schema(:string, format: /\A[a-z]+\\$/, multiline: true)

    assert_equal({ "v" => "valid\\\n123" }, parse(permitted, v: "valid\\\n123"))
    assert_equal({ "v" => "x$" }, parse(value_schema(:string, format: /\$/), v: "x$"))
    assert_equal({ "v" => "x\\$" }, parse(value_schema(:string, format: /\\\$/), v: "x\\$"))
  end

  def test_patterns_preserve_non_ascii_compatible_encodings
    %w[UTF-16LE UTF-16BE UTF-32LE UTF-32BE].each do |encoding|
      text = "ABC".encode(encoding)
      pattern = Regexp.new('\\Aabc\\z'.encode(encoding), Regexp::IGNORECASE)
      contract = schema do |s|
        s.param :text, :string, format: pattern
        s.map :counts, of: :integer, keys: pattern
      end

      result = parse(contract, text: text, counts: { text => "1" })

      assert_equal text, result.fetch("text")
      assert_equal text.encoding, result.fetch("text").encoding
      assert_equal({ text => 1 }, result.fetch("counts"))
      invalid(contract, { text: "ABD".encode(encoding) }, :invalid_format, [ "text" ])
      invalid(contract, { counts: { "ABD".encode(encoding) => 1 } }, :invalid_map_key)

      [ "^abc", "abc$", "abc" + ("\\" * 2) + "$" ].each do |source|
        anchored = Regexp.new(source.encode(encoding))

        assert_raises(ArgumentError) { value_schema(:string, format: anchored) }
        assert_raises(ArgumentError) { schema { |s| s.map :v, of: :integer, keys: anchored } }
      end

      escaped = Regexp.new('abc\\$'.encode(encoding))
      literal = "abc$".encode(encoding)

      assert_equal({ "v" => literal }, parse(value_schema(:string, format: escaped), v: literal))
      multiline = value_schema(:string, format: Regexp.new("^abc$".encode(encoding)), multiline: true)

      assert_equal({ "v" => "abc\ndef".encode(encoding) }, parse(multiline, v: "abc\ndef".encode(encoding)))
    end
  end

  def test_pattern_timeouts_and_global_configuration
    original = Regexp.timeout
    Regexp.timeout = 0.001
    contract = value_schema(:string, format: /\A[a-z]+\z/)
    root = contract.instance_variable_get(:@root)
    compiled = root.children.fetch("v").rule.options[:format]

    assert_in_delta 0.001, compiled.timeout, 1e-9
    assert_in_delta 0.001, Regexp.timeout, 1e-9
    supplied = Regexp.new('\\A[a-z]+\\z', timeout: 0.02)
    explicit = value_schema(:string, format: supplied).instance_variable_get(:@root).children.fetch("v").rule.options[:format]

    assert_in_delta 0.02, explicit.timeout, 1e-9
    assert_in_delta 0.02, supplied.timeout, 1e-9
  ensure
    Regexp.timeout = original
  end

  def test_regexp_timeout_becomes_a_safe_validation_error
    original = ParamsSchema::INTEGER_PATTERN
    pattern = Regexp.new(original)
    ParamsSchema.send(:remove_const, :INTEGER_PATTERN)
    ParamsSchema.const_set(:INTEGER_PATTERN, pattern)

    # Inject the dependency failure; exercise the parser's real exception boundary.
    pattern.stub(:match?, ->(*) { raise Regexp::TimeoutError, "private input" }) do
      error = invalid(value_schema, { v: "2" }, :pattern_timeout, [ "v" ])

      assert_nil error.cause
      refute_includes error.message, "private input"
    end
  ensure
    ParamsSchema.send(:remove_const, :INTEGER_PATTERN)
    ParamsSchema.const_set(:INTEGER_PATTERN, original)
  end

  def test_key_normalization_collisions_and_unknown_fields
    contract = schema { |s| s.param :v, :integer }

    assert_equal({ "v" => 2 }, parse(contract, "v" => "2"))
    assert_equal({ "v" => 2 }, parse(contract, v: "2"))
    invalid(contract, { "v" => 1, v: 2 }, :ambiguous_key, [ "v" ])
    invalid(contract, { 1 => "x" }, :invalid_key, [])
    invalid(contract, { "\xff".b.force_encoding("UTF-8") => "x" }, :invalid_encoding)

    assert_equal({}, parse(contract, extra: [ Object.new ]))
    rejected = schema(unknown: :reject) { |s| s.param :v, :integer }
    invalid(rejected, { typo: 1 }, :unknown_parameter, [ "typo" ])
    child = schema(unknown: :reject) { |s| s.object(:obj) { |o| o.param :v, :integer } }

    assert_equal({ "obj" => {} }, parse(child, obj: { extra: 1 }))
  end

  def test_errors_have_log_safe_messages_and_logical_paths
    contract = schema { |s| s.map :counts, of: :integer }
    [ { "secret@example.test" => "bad", "ok" => 2 }, { "ok" => 2, "secret@example.test" => "bad" } ].each do |map|
      error = invalid(contract, { counts: map }, :invalid_integer, [ "counts", "secret@example.test" ])

      assert_predicate error.path, :frozen?
      assert error.path.all?(&:frozen?)
      refute_includes error.message, "secret"
      refute_includes error.inspect, "secret"
      refute_includes error.message, "bad"
    end
  end

  def test_definitions_and_results_have_independent_ownership
    name, default, option = +"v", +"a", +"b"
    enum = [ default, option ]
    contract = schema { |s| s.param name, :string, default: default, in: enum }

    assert_predicate contract, :frozen?
    refute_predicate name, :frozen?
    refute_predicate default, :frozen?
    refute_predicate option, :frozen?
    name.replace("changed"); default.replace("changed"); option.replace("changed")
    enum.clear

    first = parse(contract, {})

    assert_equal({ "v" => "a" }, first)
    first["v"].replace("changed")

    assert_equal({ "v" => "a" }, parse(contract, {}))
    shared = +"b"
    result = parse(contract, v: shared)
    result["v"].replace("changed")

    assert_equal "b", shared
    assert_equal({ "v" => "b" }, parse(contract, v: shared.freeze))
  end

  def test_nested_aliases_are_copied_and_inputs_may_be_frozen
    contract = schema do |s|
      s.array(:v) { |o| o.array :names, of: :string }
      s.map(:m) { |o| o.array :names, of: :string }
    end
    text = +"original"
    shared = { names: [ text ].freeze }.freeze
    input = { v: [ shared, shared ].freeze, m: { a: shared, b: shared }.freeze }.freeze
    output = parse(contract, input)
    output["v"][0]["names"][0].replace("changed")
    output["m"]["a"]["names"][0].replace("changed")

    assert_equal "original", text
    assert_equal "original", output["v"][1]["names"][0]
    assert_equal "original", output["m"]["b"]["names"][0]
  end

  def test_invalid_elements_are_not_dropped_and_failures_do_not_change_input
    contract = schema { |s| s.array :v, of: :integer }
    input = { v: [ "1", "bad", "3" ] }
    invalid(contract, input, :invalid_integer, [ "v", 1 ])

    assert_equal({ v: [ "1", "bad", "3" ] }, input)
  end

  def test_invalid_declarations_are_definition_errors
    empty_block = ->(*) { }
    definitions = [
      ->(s) { s.param :x, :unknown },
      ->(s) { s.param :x, :integer, required: nil },
      ->(s) { s.param(:x, :integer, &empty_block) },
      ->(s) { s.value(:integer, &empty_block) },
      ->(s) { s.param :x, :integer, coerce: nil },
      ->(s) { s.param :x, :scalar, coerce: false },
      ->(s) { s.param :x, :string, max_bytes: false },
      ->(s) { s.param :x, :string, min_bytes: 2, max_bytes: 1 },
      ->(s) { s.param :x, :string, format: "x" },
      ->(s) { s.param :x, :string, multiline: true },
      ->(s) { s.param :x, :integer, in: nil },
      ->(s) { s.param :x, :integer, in: [ "1" ] },
      ->(s) { s.param :x, :scalar, in: [ nil ] },
      ->(s) { s.param :x, :string, in: ("a".."z") },
      ->(s) { s.param :x, :integer, in: Range.new(nil, nil) },
      ->(s) { s.param :x, :integer, default: "1" },
      ->(s) { s.param :x, :integer, required: true, default: 1 },
      ->(s) { s.param :x, :integer, default: nil },
      ->(s) { s.param :x, :string, min_bytes: 1, default: "" },
      ->(s) { s.array :x },
      ->(s) { s.array(:x, of: :integer, &empty_block) },
      ->(s) { s.array :x, of: :integer, unknown: :drop },
      ->(s) { s.array :x, of: :integer, min_size: 2, max_size: 1 },
      ->(s) { s.object :x },
      ->(s) { s.object(:x, unknown: :other, &empty_block) },
      ->(s) { s.param :x, :integer; s.param "x", :string },
      ->(s) { s.param 1, :integer },
      ->(s) { s.param :x, s.value(:integer), in: 1.. }
    ]

    definitions.each { |definition| assert_raises(ArgumentError, definition.source_location.inspect) { schema(&definition) } }
    assert_raises(ArgumentError) { ParamsSchema::Schema.new }
  end

  def test_depth_is_checked_at_construction_including_reused_rules
    schema do |s|
      node = s.value(:integer)
      31.times { node = s.value(:array, of: node) }
      s.param :tree, node
    end
    assert_raises(ArgumentError) do
      schema do |s|
        node = s.value(:integer)
        32.times { node = s.value(:array, of: node) }
        s.param :tree, node
      end
    end
  end

  def test_reusing_a_schema_starts_fresh_after_success_and_failure
    contract = schema do |s|
      s.param :v, :integer, default: 1, in: 1..3
    end
    invalid(contract, { v: "10" }, :not_included)

    assert_equal({ "v" => 1 }, parse(contract, {}))
    invalid(contract, { v: "x" }, :invalid_integer)

    assert_equal({ "v" => 2 }, parse(contract, v: "2"))
    assert_equal({ "v" => 3 }, parse(contract, v: "3"))
    assert_equal({ "v" => 1 }, parse(contract, {}))
  end
end
