# frozen_string_literal: true

require_relative "test_helper"
require "active_support/core_ext/object/deep_dup"

class CollectionTest < Minitest::Test
  def test_selection_arrays_remove_only_empty_strings_and_keep_error_positions
    schema = ActionController::Parameters.schema do |s|
      s.array :ids, of: :integer, drop_empty_strings: true, min_size: 1, max_size: 2
    end

    assert_equal [ 1, 2 ], schema.parse(ids: [ "", "1", "2" ])[:ids]
    assert_invalid schema, { ids: [ "" ] }, :too_few_items, [ "ids" ]
    assert_invalid schema, { ids: [ "", "1", "2", "3" ] }, :too_many_items, [ "ids" ]
    assert_invalid schema, { ids: [ "", "1", "bad" ] }, :invalid_integer, [ "ids", 2 ]
    assert_invalid schema, { ids: [ " " ] }, :invalid_integer, [ "ids", 0 ]

    clearing = ActionController::Parameters.schema do |s|
      s.array :values, of: s.value(:scalar, allow_nil: true), drop_empty_strings: true
    end

    assert_empty clearing.parse(values: [ "" ])[:values]
    assert_equal [ nil, false, 0, " " ], clearing.parse(values: [ "", nil, false, 0, " " ])[:values]
    assert_empty clearing.parse({}).to_h
    assert_raises(ArgumentError) do
      ActionController::Parameters.schema { |s| s.array :values, of: :string, drop_empty_strings: true, default: [ "" ] }
    end
  end

  def test_one_or_many_empty_values_follow_the_nil_policy_at_their_position
    %i[string integer float boolean scalar].product([ true, false ], [ true, false ]).each do |type, field_nil, element_nil|
      schema = ActionController::Parameters.schema do |s|
        s.one_or_many :value, allow_nil: field_nil,
          of: s.value(type, empty_string_to_nil: true, allow_nil: element_nil)
      end
      [ nil, "" ].each do |value|
        if field_nil
          assert_nil schema.parse(value: value)[:value]
        else
          assert_invalid schema, { value: value }, :nil_not_allowed, [ "value" ]
        end
      end
      if element_nil
        assert_equal [ nil ], schema.parse(value: [ "" ])[:value]
      else
        assert_invalid schema, { value: [ "" ] }, :nil_not_allowed, [ "value", 0 ]
      end
    end
    schema = ActionController::Parameters.schema do |s|
      s.one_or_many :value, of: s.value(:integer, empty_string_to_nil: true), allow_nil: true, min_size: 2
    end

    assert_nil schema.parse(value: "")[:value]
    assert_invalid schema, { value: "1" }, :too_few_items, [ "value" ]
  end

  def test_form_rows_preserve_shape_keys_order_and_value_cardinality
    schema = form_schema
    rows = [ { value: +"one" }, { value: [ +"", +"two" ] } ]
    [ rows, { "02" => rows[0], "-1" => rows[1] } ].each do |input_rows|
      input = ActionController::Parameters.new(rule: { actions_attributes: input_rows })
      before = input.to_unsafe_h.deep_dup
      output = schema.parse(input)
      result_rows = output[:rule][:actions_attributes]
      result_row = result_rows.is_a?(Array) ? result_rows[1] : result_rows["-1"]

      assert_equal before, output.to_h
      assert_predicate output[:rule], :permitted?
      assert_predicate result_row, :permitted?
      result_row[:value].last.replace("edited")
      result_row[:value] << "new"

      assert_equal before, input.to_unsafe_h
      refute_predicate input, :permitted?
      assert_equal before, schema.parse(input).to_h
    end
  end

  def test_nested_errors_keep_original_keys_and_indices_for_all_entry_points
    schema = form_schema
    [
      [ { "03" => { value: [ "ok", {} ] } }, [ "rule", "actions_attributes", "03", "value", 1 ] ],
      [ [ { value: "ok" }, { value: [ "ok", {} ] } ], [ "rule", "actions_attributes", 1, "value", 1 ] ],
      [ { "03" => { value: {} } }, [ "rule", "actions_attributes", "03", "value" ] ]
    ].each do |rows, path|
      input = { rule: { actions_attributes: rows } }
      [ :parse, :parse!, :try_parse ].each do |method|
        events = []
        subscriber = ->(event) { events << event.payload }
        ActiveSupport::Notifications.subscribed(subscriber, "invalid.params_schema") do
          if method == :try_parse
            result = schema.try_parse(input)

            refute_predicate result, :success?
            error = assert_raises(ParamsSchema::InvalidParameters) { result.value! }
          else
            error_class = method == :parse! ? ParamsSchema::UnexpectedParameters : ParamsSchema::InvalidParameters
            error = assert_raises(error_class) { schema.public_send(method, input) }
          end

          assert_equal :invalid_scalar, error.code
          assert_equal path, error.path
          assert_predicate error.path, :frozen?
          assert_equal [ { schema: "form", code: :invalid_scalar } ], events
        end
      end
    end
  end

  def test_collection_keys_preserve_row_identifiers_and_reject_the_reserved_id_key
    schema = ActionController::Parameters.schema do |s|
      s.collection(:rows) { |row| row.param :id, :integer }
    end
    keys = [ "0", "02", "2", "-1", "-02", "+1", "1.0", "new_item", "", "行", "02".encode("UTF-16LE") ]
    input = keys.to_h { |key| [ key, { id: "1" } ] }

    assert_equal keys, schema.parse(rows: input)[:rows].keys
    assert_equal({ "02" => { "id" => 1 } }, schema.parse(rows: { "02": { id: "1" } })[:rows].to_h)
    [ "id", :id ].each do |key|
      assert_invalid schema, { rows: { "first" => { id: 1 }, key => { id: 2 } } }, :invalid_map_key, [ "rows", "id" ]
    end
    assert_invalid schema, { rows: { "02" => {}, :"02" => {} } }, :ambiguous_key, [ "rows", "02" ]
    assert_invalid schema, { rows: { 2 => {} } }, :invalid_key, [ "rows" ]
    assert_invalid schema, { rows: { "\xff".b.force_encoding("UTF-8") => {} } }, :invalid_encoding, [ "rows" ]
    assert_invalid schema, { rows: { "new_item" => "wrong" } }, :invalid_object, [ "rows", "new_item" ]
    assert_invalid schema, { rows: [ {}, "wrong" ] }, :invalid_object, [ "rows", 1 ]
    assert_invalid schema, { rows: "wrong" }, :invalid_collection, [ "rows" ]

    map = ActionController::Parameters.schema { |s| s.map :labels, of: :string }

    assert_equal({ "id" => "Identifier" }, map.parse(labels: { id: "Identifier" })[:labels].to_h)
    assert_raises(ArgumentError) do
      ActionController::Parameters.schema { |s| s.collection(:rows, default: { id: {} }) { |r| r.param :id, :integer } }
    end
  end

  def test_one_or_many_applies_one_leaf_rule_and_counts_a_single_value_as_one
    schema = ActionController::Parameters.schema do |s|
      s.one_or_many :ids, of: s.value(:integer, in: 1..3), min_size: 1, max_size: 2
    end

    assert_equal 2, schema.parse(ids: "2")[:ids]
    assert_equal [ 1, 2 ], schema.parse(ids: [ "1", "2" ])[:ids]
    assert_invalid schema, { ids: [] }, :too_few_items, [ "ids" ]
    assert_invalid schema, { ids: [ 1, 2, 3 ] }, :too_many_items, [ "ids" ]
    assert_invalid schema, { ids: "4" }, :not_included, [ "ids" ]
    assert_invalid schema, { ids: [ "1", "4" ] }, :not_included, [ "ids", 1 ]
    assert_invalid schema, { ids: [ [ "1" ] ] }, :invalid_integer, [ "ids", 0 ]
    [ [ 2, :too_few_items ], [ 0, :too_many_items ] ].each do |bound, code|
      bounded = ActionController::Parameters.schema do |s|
        s.one_or_many :ids, of: :integer, min_size: bound, max_size: bound
      end

      assert_invalid bounded, { ids: 1 }, code, [ "ids" ]
    end
  end

  def test_one_or_many_filters_hidden_array_values_without_changing_single_values
    schema = ActionController::Parameters.schema do |s|
      s.one_or_many :ids, of: :integer, drop_empty_strings: true, max_size: 2
      s.one_or_many :label, of: :string, drop_empty_strings: true
    end

    assert_equal({ "ids" => 1, "label" => "" }, schema.parse(ids: "1", label: "").to_h)
    assert_equal [ 1, 2 ], schema.parse(ids: [ "", "1", "2" ])[:ids]
    assert_empty schema.parse(ids: [ "" ])[:ids]
    assert_empty schema.parse(label: [ "" ])[:label]
    assert_invalid schema, { ids: "" }, :invalid_integer, [ "ids" ]
    assert_invalid schema, { ids: [ "", "1", "bad" ] }, :invalid_integer, [ "ids", 2 ]
    assert_invalid schema, { ids: [ "", "1", "2", "3" ] }, :too_many_items, [ "ids" ]
    assert_raises(ArgumentError) do
      ActionController::Parameters.schema { |s| s.one_or_many :labels, of: :string, drop_empty_strings: true, default: [ "" ] }
    end

    nullable = ActionController::Parameters.schema do |s|
      s.one_or_many :ids, drop_empty_strings: true, allow_nil: true,
        of: s.value(:integer, empty_string_to_nil: true, allow_nil: true)
    end

    assert_equal [ nil, 1 ], nullable.parse(ids: [ "", nil, "1" ])[:ids]
    assert_nil nullable.parse(ids: "")[:ids]
  end

  def test_nil_required_and_empty_inputs_have_separate_meanings
    schema = ActionController::Parameters.schema do |s|
      s.one_or_many :value, of: s.value(:string, allow_nil: true), required: true
      s.one_or_many :nullable, of: :string, allow_nil: true
      s.collection(:rows, allow_nil: true) { |row| row.param :id, :integer }
      s.collection :nullable_rows, of: s.value(:object, allow_nil: true) { |row| row.param :id, :integer }
    end

    assert_invalid schema, {}, :missing, [ "value" ]
    assert_invalid schema, { value: nil }, :nil_not_allowed, [ "value" ]
    assert_invalid schema, { value: "", nullable: [ nil ] }, :nil_not_allowed, [ "nullable", 0 ]
    assert_invalid schema, { value: "", rows: [ nil ] }, :nil_not_allowed, [ "rows", 0 ]
    assert_invalid schema, { value: "", rows: { "02" => nil } }, :nil_not_allowed, [ "rows", "02" ]
    assert_equal [ nil ], schema.parse(value: "", nullable_rows: [ nil ])[:nullable_rows]
    assert_nil schema.parse(value: "", nullable_rows: { "02" => nil })[:nullable_rows]["02"]
    assert_equal({ "value" => [ nil, "" ], "nullable" => nil, "rows" => nil },
      schema.parse(value: [ nil, "" ], nullable: nil, rows: nil).to_h)
    assert_equal({ "value" => [], "rows" => {} }, schema.parse(value: [], rows: {}).to_h)
    assert_equal({ "value" => "", "rows" => [] }, schema.parse(value: "", rows: []).to_h)
  end

  def test_collection_bounds_and_child_constraints_apply_to_both_forms
    schema = ActionController::Parameters.schema do |s|
      s.collection :rows, min_size: 1, max_size: 2, unknown: :reject do |row|
        row.param :id, :integer, required: true
      end
    end

    [ [], {} ].each { |rows| assert_invalid schema, { rows: rows }, :too_few_items, [ "rows" ] }
    [ [ {}, {}, {} ], { "0" => {}, "1" => {}, "2" => {} } ].each do |rows|
      assert_invalid schema, { rows: rows }, :too_many_items, [ "rows" ]
    end
    assert_invalid schema, { rows: [ {} ] }, :missing, [ "rows", 0, "id" ]
    assert_invalid schema, { rows: { "new_item" => { id: 1, typo: 2 } } }, :unknown_parameter, [ "rows", "new_item", "typo" ]
  end

  def test_defaults_and_reused_rules_preserve_the_selected_form_without_coercion
    seed = { "02" => { value: [ +"seed" ] } }
    schema = ActionController::Parameters.schema do |s|
      row = s.value(:object) { |r| r.one_or_many :value, of: :string }
      rows = s.value(:collection, of: row)
      s.param :rows, rows, default: seed
      s.param :ids, s.value(:one_or_many, of: :integer), default: [ 1 ]
    end
    seed["02"][:value].first.replace("changed")
    schema.parse({})[:rows]["02"][:value].first.replace("edited")

    assert_equal({ "rows" => { "02" => { "value" => [ "seed" ] } }, "ids" => [ 1 ] }, schema.parse({}).to_h)
    assert_equal [ { "value" => "single" } ], schema.parse(rows: [ { value: "single" } ])[:rows].map(&:to_h)
    [ "1", [ "1" ] ].each do |default|
      assert_raises(ArgumentError) do
        ActionController::Parameters.schema { |s| s.one_or_many :ids, of: :integer, default: default }
      end
    end
    assert_raises(ArgumentError) do
      ActionController::Parameters.schema do |s|
        s.collection(:rows, default: { "02" => { id: "1" } }) { |r| r.param :id, :integer }
      end
    end
  end

  def test_shape_rules_reject_unsupported_combinations_at_definition
    fields = ->(row) { row.param :id, :integer }
    declarations = [
      ->(s) { s.one_or_many :value },
      ->(s) { s.one_or_many(:value) { |row| row.param :id, :integer } },
      ->(s) { s.one_or_many :value, of: s.value(:array, of: :string) },
      ->(s) { s.collection :rows, of: :string },
      ->(s) { s.collection(:rows, keys: /0/, &fields) },
      ->(s) { s.collection(:rows, of: s.value(:object, &fields), &fields) }
    ]

    declarations.each do |declaration|
      assert_raises(ArgumentError, declaration.source_location.inspect) do
        ActionController::Parameters.schema(&declaration)
      end
    end
  end

  def test_new_rules_count_their_deepest_value_positions_toward_the_depth_limit
    [
      [ ->(s) { s.value(:one_or_many, of: :integer) }, 30 ],
      [ ->(s) { s.value(:collection) { |r| r.param :id, :integer } }, 29 ]
    ].each do |build, wrappers|
      ActionController::Parameters.schema do |s|
        node = build.call(s)
        wrappers.times { node = s.value(:array, of: node) }
        s.param :tree, node
      end

      assert_raises(ArgumentError) do
        ActionController::Parameters.schema do |s|
          node = build.call(s)
          (wrappers + 1).times { node = s.value(:array, of: node) }
          s.param :tree, node
        end
      end
    end
  end

  private
    def form_schema
      ActionController::Parameters.schema(name: :form) do |s|
        s.object :rule, required: true do |rule|
          rule.collection :actions_attributes do |action|
            action.one_or_many :value, of: :scalar
          end
        end
      end
    end

    def assert_invalid(schema, input, code, path)
      error = assert_raises(ParamsSchema::InvalidParameters) { schema.parse(input) }
      assert_equal code, error.code
      assert_equal path, error.path
    end
end
