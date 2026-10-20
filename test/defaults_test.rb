# frozen_string_literal: true

require_relative "test_helper"

class DefaultsTest < Minitest::Test
  def test_container_defaults_are_snapshots_and_each_parse_owns_its_output
    defaults = [ { name: +"seed", tags: [ +"one" ] } ]
    schema = ActionController::Parameters.schema do |s|
      s.array :records, default: defaults do |record|
        record.param :name, :string, required: true
        record.array :tags, of: :string
      end
    end
    defaults.first[:name].replace("changed")
    defaults.first[:tags] << "two"
    first = schema.parse({})
    first[:records].first[:name].replace("edited")
    first[:records].first[:tags] << "three"
    second = schema.parse({})

    assert_equal [ { "name" => "seed", "tags" => [ "one" ] } ], second.to_h.fetch("records")
    assert_predicate second[:records].first, :permitted?
    refute_predicate defaults, :frozen?
    assert_equal [ "one", "two" ], defaults.first[:tags]
  end

  def test_missing_nil_empty_and_parent_defaults_remain_distinct
    schema = ActionController::Parameters.schema do |s|
      s.array :ids, of: :integer, default: [ 1 ], allow_nil: true
      s.object(:absent) { |o| o.param :page, :integer, default: 2 }
      s.object(:options, default: {}) { |o| o.param :page, :integer, default: 3 }
      s.map :counts, of: :integer, default: { a: 4 }
      s.param :matrix, s.value(:array, of: s.value(:array, of: :integer)), default: [ [ 5 ] ]
      s.param :attachment, :uploaded_file, allow_nil: true, default: nil
    end

    assert_equal({ "ids" => [ 1 ], "options" => { "page" => 3 }, "counts" => { "a" => 4 }, "matrix" => [ [ 5 ] ],
      "attachment" => nil }, schema.parse({}).to_h)
    assert_nil schema.parse(ids: nil)[:ids]
    assert_empty schema.parse(ids: [])[:ids]
  end

  def test_invalid_defaults_fail_at_definition_without_coercion_or_dropping_keys
    upload = ActionDispatch::Http::UploadedFile.new(tempfile: StringIO.new("content"), filename: "seed.txt")
    declarations = [
      ->(s) { s.array :ids, of: :integer, default: [ "1" ] },
      ->(s) { s.array :ids, of: :integer, default: nil },
      ->(s) { s.array :ids, of: :integer, min_size: 1, default: [] },
      ->(s) { s.array :ids, of: :integer, required: true, default: [] },
      ->(s) { s.map :counts, of: s.value(:integer, in: 0..), default: { a: -1 } },
      ->(s) { s.object(:options, default: { typo: 1 }) { |o| o.param :page, :integer } },
      ->(s) { s.array(:records, default: [ {} ]) { |o| o.param :name, :string, required: true } },
      ->(s) { s.array(:records, default: [ { file: upload } ]) { |o| o.param :file, :uploaded_file } },
      ->(s) { s.param :file, :scalar, default: upload },
      ->(s) { s.array :files, of: :scalar, default: [ upload ] },
      ->(s) { s.param :file, :scalar, in: [ upload ] }
    ]

    declarations.each do |declaration|
      assert_raises(ArgumentError, declaration.source_location.inspect) do
        ActionController::Parameters.schema(&declaration)
      end
    end
    refute_predicate upload, :frozen?
  end

  def test_parent_defaults_obey_nested_object_constraints
    assert_raises(ArgumentError) do
      ActionController::Parameters.schema do |s|
        s.object :settings, default: { profile: {} } do |settings|
          settings.object :profile, required: true do |profile|
            profile.param :name, :string, default: "Guest"
          end
        end
      end
    end

    schema = ActionController::Parameters.schema do |s|
      s.object :settings, default: { profile: {} } do |settings|
        settings.object :profile, required: true, reject_empty: false do |profile|
          profile.param :name, :string, default: "Guest"
        end
      end
    end

    assert_equal({ "settings" => { "profile" => { "name" => "Guest" } } }, schema.parse({}).to_h)
  end
end
