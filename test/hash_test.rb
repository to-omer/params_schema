# frozen_string_literal: true

require_relative "test_helper"

class HashTest < Minitest::Test
  def test_nested_content_is_permitted_and_copied_without_conversion
    schema = ActionController::Parameters.schema { |s| s.param :metadata, :hash }
    nested = ActionController::Parameters.new(label: +"draft")
    upload = ActionDispatch::Http::UploadedFile.new(tempfile: StringIO.new("data"), filename: "data.txt")
    input = { metadata: { crm: { score: +"3", flags: [ nil, true, false, 2, 0.5 ] }, rows: [ nested ], file: upload }, admin: true }

    output = schema.parse(input)

    assert_equal({ "metadata" => {
      "crm" => { "score" => "3", "flags" => [ nil, true, false, 2, 0.5 ] },
      "rows" => [ { "label" => "draft" } ], "file" => upload
    } }, output.to_h)
    assert_predicate output[:metadata][:crm], :permitted?
    assert_predicate output[:metadata][:rows].first, :permitted?
    refute_predicate nested, :permitted?
    assert_same upload, output[:metadata][:file]

    output[:metadata][:crm][:score].replace("4")
    output[:metadata][:crm][:flags] << "new"
    output[:metadata][:rows].first[:label].replace("published")

    assert_equal "3", input[:metadata][:crm][:score]
    assert_equal [ nil, true, false, 2, 0.5 ], input[:metadata][:crm][:flags]
    assert_equal "draft", nested[:label]
  end

  def test_invalid_contents_report_the_original_location_without_permitting_input
    schema = ActionController::Parameters.schema { |s| s.param :metadata, :hash }

    assert_invalid schema, { metadata: [] }, :invalid_hash, [ "metadata" ]
    assert_invalid schema, { metadata: nil }, :nil_not_allowed, [ "metadata" ]
    assert_invalid schema, { metadata: { rows: [ { key: Object.new } ] } }, :invalid_scalar, [ "metadata", "rows", 0, "key" ]
    assert_invalid schema, { metadata: { rows: [ { "key" => 1, key: 2 } ] } }, :ambiguous_key, [ "metadata", "rows", 0, "key" ]
    assert_invalid schema, { metadata: { rows: [ { 1 => "value" } ] } }, :invalid_key, [ "metadata", "rows", 0 ]
    assert_invalid schema, { metadata: { text: "\xFF".b.force_encoding(Encoding::UTF_8) } }, :invalid_encoding, [ "metadata", "text" ]

    input = ActionController::Parameters.new(metadata: { rows: [ { key: Object.new } ] })

    assert_invalid schema, input, :invalid_scalar, [ "metadata", "rows", 0, "key" ]
    refute_predicate input, :permitted?
    refute_predicate input[:metadata], :permitted?
    refute_predicate input[:metadata][:rows].first, :permitted?
  end

  def test_hash_rules_work_in_fields_arrays_and_maps
    schema = ActionController::Parameters.schema do |s|
      metadata = s.value(:hash)
      s.param :metadata, metadata, required: true
      s.array :documents, of: metadata
      s.map :profiles, of: s.value(:hash, allow_nil: true)
    end

    assert_invalid schema, {}, :missing, [ "metadata" ]
    assert_invalid schema, { metadata: {} }, :empty_object, [ "metadata" ]
    assert_equal({ "metadata" => { "a" => [] }, "documents" => [ {} ], "profiles" => { "guest" => nil } },
      schema.parse(metadata: { a: [] }, documents: [ {} ], profiles: { guest: nil }).to_h)
    assert_invalid schema, { metadata: { a: [] }, documents: [ {}, [] ] }, :invalid_hash, [ "documents", 1 ]

    assert_raises(ArgumentError) do
      ActionController::Parameters.schema { |s| s.one_or_many :values, of: :hash }
    end
    assert_raises(ArgumentError) do
      ActionController::Parameters.schema { |s| s.value(:hash) { |h| h.param :name, :string } }
    end
  end

  def test_empty_hash_policy_controls_the_field_without_rejecting_nested_empty_values
    schema = ActionController::Parameters.schema do |s|
      s.param :metadata, :hash, reject_empty: true, allow_nil: true
      s.param :replacement, :hash, required: true, reject_empty: false
      s.array :documents, of: s.value(:hash, reject_empty: true)
    end

    assert_equal({ "replacement" => {} }, schema.parse(replacement: {}).to_h)
    assert_equal({ "metadata" => nil, "replacement" => {} }, schema.parse(metadata: nil, replacement: {}).to_h)
    assert_invalid schema, { metadata: {}, replacement: {} }, :empty_object, [ "metadata" ]
    assert_invalid schema, { replacement: {}, documents: [ {} ] }, :empty_object, [ "documents", 0 ]
    values = { object: {}, array: [], nullable: nil, flag: false }
    output = schema.parse(metadata: values, replacement: {})

    assert_equal values.transform_keys(&:to_s), output[:metadata].to_h
    assert_raises(ArgumentError) do
      ActionController::Parameters.schema { |s| s.param :metadata, :hash, reject_empty: true, default: {} }
    end
    assert_raises(ArgumentError) do
      ActionController::Parameters.schema { |s| s.param :metadata, :hash, reject_empty: "false" }
    end
  end

  def test_defaults_snapshot_nested_values_and_cannot_contain_uploads
    defaults = { rows: [ { label: +"draft" } ] }
    schema = ActionController::Parameters.schema do |s|
      s.param :metadata, :hash, default: defaults, allow_nil: true
    end
    defaults[:rows].first[:label].replace("changed")
    first = schema.parse({})
    first[:metadata][:rows].first[:label].replace("edited")

    assert_equal({ "metadata" => { "rows" => [ { "label" => "draft" } ] } }, schema.parse({}).to_h)
    assert_nil schema.parse(metadata: nil)[:metadata]
    assert_empty schema.parse(metadata: {})[:metadata]
    refute_predicate defaults[:rows], :frozen?

    upload = ActionDispatch::Http::UploadedFile.new(tempfile: StringIO.new("data"), filename: "data.txt")
    assert_raises(ArgumentError) do
      ActionController::Parameters.schema { |s| s.param :metadata, :hash, default: { rows: [ { file: upload } ] } }
    end
    refute_predicate upload, :frozen?
  end

  def test_depth_limit_is_relative_to_the_hash_for_input_and_defaults
    boundary = 32.times.reduce("end") { |value, _| { child: value } }
    schema = ActionController::Parameters.schema do |s|
      metadata = s.value(:hash)
      s.param :metadata, metadata, default: boundary
      s.object(:record) { |r| r.param :metadata, metadata, default: boundary }
    end
    parsed = schema.parse(metadata: boundary, record: {})

    assert_equal "end", parsed.dig(:metadata, *Array.new(32, :child))
    assert_equal parsed[:metadata], parsed[:record][:metadata]
    assert_equal parsed[:metadata], schema.parse({})[:metadata]
    assert_invalid schema, { metadata: { child: boundary } }, :nesting_too_deep, [ "metadata", *Array.new(33, "child") ]
    assert_raises(ArgumentError) do
      ActionController::Parameters.schema { |s| s.param :metadata, :hash, default: { child: boundary } }
    end
  end

  def test_cycles_fail_and_repeated_references_are_copied_independently
    schema = ActionController::Parameters.schema { |s| s.param :metadata, :hash }
    circular_hash = {}
    circular_hash[:child] = circular_hash
    circular_array = []
    circular_array << circular_array
    [ circular_hash, { children: circular_array } ].each do |value|
      error = assert_raises(ParamsSchema::InvalidParameters) { schema.parse(metadata: value) }
      assert_equal :nesting_too_deep, error.code
    end

    shared = { label: +"draft" }
    output = schema.parse(metadata: { left: shared, right: shared })
    output[:metadata][:left][:label].replace("edited")

    assert_equal "draft", output[:metadata][:right][:label]
    assert_equal "draft", shared[:label]
  end

  private
    def assert_invalid(schema, input, code, path)
      error = assert_raises(ParamsSchema::InvalidParameters) { schema.parse(input) }
      assert_equal code, error.code
      assert_equal path, error.path
    end
end
