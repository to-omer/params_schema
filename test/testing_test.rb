# frozen_string_literal: true

require_relative "test_helper"
require "params_schema/testing"

class TestingTest < Minitest::Test
  def test_integer_cases_cover_included_endpoints_and_adjacent_rejections
    { (0..150) => [ 0, 150, -1, 151 ], (0...150) => [ 0, 149, -1, 150 ],
      (0..) => [ 0, -1 ], (...150) => [ 149, 150 ], (2..2) => [ 2, 1, 3 ] }.each do |range, values|
      cases = age_cases(integer: range)
      numeric = cases.reject { |sample| sample.omitted? || sample.value.nil? }

      assert_equal values, numeric.map(&:value)
      numeric.each do |sample|
        assert_equal range.cover?(sample.value), sample.valid?, sample.description
        if sample.valid?
          assert_nil sample.error_code
        else
          assert_equal :not_included, sample.error_code
        end
      end
    end
    strings = age_cases(integer: 0..150, representation: :string)

    assert_equal [ "0", "150", "-1", "151" ], strings.first(4).map(&:value)
    assert_equal [ true, true, false, false ], strings.first(4).map(&:valid?)
  end

  def test_omission_and_nil_are_independent_and_omission_has_no_value
    [ true, false ].product([ true, false ]).each do |required, allow_nil|
      omitted, null = age_cases(required: required, allow_nil: allow_nil)

      assert_predicate omitted, :omitted?
      refute_predicate null, :omitted?
      assert_equal !required, omitted.valid?
      assert_equal allow_nil, null.valid?
      assert_equal [ required ? :missing : nil, allow_nil ? nil : :nil_not_allowed ], [ omitted.error_code, null.error_code ]
      assert_raises(KeyError) { omitted.value }
      assert_nil null.value
      refute omitted.params(user: { age: 27 }).fetch(:user).key?(:age)
      assert_equal({ user: { age: nil } }, null.params(user: { age: 27 }))
    end
  end

  def test_each_case_copies_all_mutable_request_data_including_unedited_branches
    baseline = { "rows" => [ { id: "7".freeze }.freeze, { id: "8".freeze }.freeze ].freeze,
      notes: [ "keep".freeze ].freeze }.freeze
    omitted, null = ParamsSchema::Testing.request_cases(path: [ :rows, 1, :id ], required: true, allow_nil: false)
    first = omitted.params(baseline)
    second = null.params(baseline)
    first.fetch("rows")[0][:id].replace("changed")
    first.fetch(:notes).first.replace("changed")

    assert_equal [ { id: "7" }, { id: "8" } ], baseline.fetch("rows")
    assert_equal [ "keep" ], baseline.fetch(:notes)
    assert_equal [ { id: "7" }, { id: nil } ], second.fetch("rows")
    assert_equal [ "keep" ], second.fetch(:notes)
    assert_equal({}, first.fetch("rows")[1])
    assert_equal [ "rows", 1, "id" ], omitted.path
    assert_predicate omitted.path, :frozen?
    assert_includes null.description, '["rows", 1, "id"]: explicit nil'
  end

  def test_scalar_array_elements_preserve_positions_and_only_generate_selected_cases
    cases = ParamsSchema::Testing.request_cases(path: [ :order, :ids, 1 ], integer: 1..3)
    baseline = { order: { ids: [ 2, 2, 3 ] } }

    assert_equal [ 1, 3, 0, 4 ], cases.map(&:value)
    assert_equal [ [ 2, 1, 3 ], [ 2, 3, 3 ], [ 2, 0, 3 ], [ 2, 4, 3 ] ],
      (cases.map { |sample| sample.params(baseline).dig(:order, :ids) })
    assert_equal [ 2, 2, 3 ], baseline.dig(:order, :ids)
    null = ParamsSchema::Testing.request_cases(path: [ :order, :ids, 1 ], allow_nil: false).first

    assert_equal [ 2, nil, 3 ], null.params(baseline).dig(:order, :ids)
    assert_equal :nil_not_allowed, null.error_code
  end

  def test_explicit_nested_inputs_are_snapshots_and_each_request_owns_its_copy
    input = [ { sku: +"new" } ]
    cases = ParamsSchema::Testing.request_cases(path: [ :order, :items ], cases: [
      { value: {}, error_code: :invalid_array }, { value: "invalid", error_code: :invalid_array },
      { value: [], error_code: :too_few_items }, { value: input }
    ])
    input.first[:sku].replace("edited")
    baseline = { order: { items: [ { sku: "old" } ] } }
    request = cases.last.params(baseline)
    request[:order][:items].first[:sku].replace("sent")

    assert_equal({ order: { items: {} } }, cases.first.params(baseline))
    assert_equal({ order: { items: "invalid" } }, cases[1].params(baseline))
    assert_equal [ :invalid_array, :invalid_array, :too_few_items, nil ], cases.map(&:error_code)
    assert_equal({ order: { items: [ { sku: "new" } ] } }, cases.last.params(baseline))
    assert_equal "old", baseline[:order][:items].first[:sku]
    assert_equal "edited", input.first[:sku]
    assert_raises(FrozenError) { cases.last.value.first[:sku].replace("leak") }
    assert_raises(FrozenError) { cases.last.value << {} }
    assert_raises(FrozenError) { cases.last.value.first[:sku] = "leak" }
    indifferent = { items: [ { sku: "new" } ] }.with_indifferent_access
    snapshot = ParamsSchema::Testing.request_cases(path: [ :order ], cases: [ { value: indifferent } ]).first

    assert_raises(FrozenError) { snapshot.value[:items] << {} }
    assert_raises(FrozenError) { snapshot.value[:items].first[:sku].replace("leak") }
    snapshot.params(order: {})[:order][:items] << { sku: "sent" }

    assert_equal [ { "sku" => "new" } ], snapshot.params(order: {})[:order][:items]
    indifferent[:items] << { sku: "mutable" }

    assert_equal 2, indifferent[:items].size
    numeric_key = ParamsSchema::Testing.request_cases(path: [ :rows, "02", :id ], required: true).first

    assert_equal({ rows: { "02" => {}, "2" => { id: 2 } } }, numeric_key.params(rows: { "02" => { id: 1 }, "2" => { id: 2 } }))
  end

  def test_empty_or_malformed_case_definitions_raise
    [ {}, { cases: [] }, { cases: {} }, { cases: [ {} ] }, { cases: [ { value: 1, code: :not_included } ] },
      { cases: [ { value: 1, error_code: false } ] }, { allow_nil: nil }, { required: nil } ].each do |options|
      assert_raises(ArgumentError) { ParamsSchema::Testing.request_cases(path: [ :id ], **options) }
    end
    [ true, false ].each do |required|
      assert_raises(ArgumentError) { ParamsSchema::Testing.request_cases(path: [ :ids, 0 ], required: required) }
    end
  end

  def test_bad_paths_and_options_fail_instead_of_exercising_the_wrong_field
    omitted = age_cases.first
    [ nil, {}, { user: {} }, { user: [] }, { user: { age: 27, "age" => 28 } }, { user: 27 } ].each do |baseline|
      error = assert_raises(ArgumentError) { omitted.params(baseline) }
      assert_match(/baseline/, error.message)
    end
    [ { path: [] }, { path: [ :user, -1, :age ] }, { path: [ :user, 0 ] },
      { required: nil }, { allow_nil: :yes }, { integer: false }, { integer: "0..150" },
      { integer: 2...2 }, { integer: (nil..nil) }, { representation: :float },
      { representation: :string } ].each do |options|
      assert_raises(ArgumentError) { age_cases(**options) }
    end
  end

  private
    def age_cases(**options)
      ParamsSchema::Testing.request_cases(**{
        path: [ :user, :age ], required: false, allow_nil: false
      }.merge(options))
    end
end
