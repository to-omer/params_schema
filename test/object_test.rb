# frozen_string_literal: true

require_relative "test_helper"

class ObjectTest < Minitest::Test
  def test_required_object_requires_a_submitted_declared_field
    schema = ActionController::Parameters.schema do |s|
      s.object :user, required: true do |user|
        user.param :name, :string
        user.param :age, :integer, allow_nil: true
        user.param :enabled, :boolean
        user.array :tags, of: :string
      end
    end

    assert_invalid schema, {}, :missing, [ "user" ]
    assert_invalid schema, { user: {} }, :empty_object, [ "user" ]
    assert_invalid schema, { user: { admin: true } }, :empty_object, [ "user" ]
    assert_invalid schema, { user: [] }, :invalid_object, [ "user" ]
    assert_invalid schema, { user: nil }, :nil_not_allowed, [ "user" ]

    [ { name: "" }, { age: nil }, { enabled: false }, { tags: [] } ].each do |fields|
      input = ActionController::Parameters.new(user: fields)
      output = schema.parse(input).fetch(:user)

      assert_equal fields.transform_keys(&:to_s), output.to_h
      assert_predicate output, :permitted?
    end
  end

  def test_required_object_nil_policy_is_independent_of_its_empty_policy
    schema = ActionController::Parameters.schema do |s|
      s.object(:user, required: true, allow_nil: true) { |u| u.param :name, :string }
    end

    assert_equal({ "user" => nil }, schema.parse(user: nil).to_h)
    assert_invalid schema, {}, :missing, [ "user" ]
    assert_invalid schema, { user: {} }, :empty_object, [ "user" ]
  end

  def test_required_fields_do_not_change_shared_object_rules_or_explicit_empty_policies
    schema = ActionController::Parameters.schema do |s|
      profile = s.value(:object) { |p| p.param :name, :string, default: "Guest" }
      s.param :optional, profile
      s.param :required, profile, required: true
      s.collection :rows, of: profile
      settings = s.value(:object, reject_empty: false) { |o| o.param :theme, :string }
      s.param :settings, settings, required: true
    end

    assert_invalid schema, { required: {}, settings: {} }, :empty_object, [ "required" ]
    assert_invalid schema, { required: { ignored: true }, settings: {} }, :empty_object, [ "required" ]
    output = schema.parse(required: { name: "Ada" }, optional: {}, rows: { "02" => {} }, settings: {})

    assert_equal({ "required" => { "name" => "Ada" }, "optional" => { "name" => "Guest" },
      "rows" => { "02" => { "name" => "Guest" } }, "settings" => {} }, output.to_h)
  end

  def test_defaults_cannot_make_an_empty_submission_nonempty
    schema = ActionController::Parameters.schema do |s|
      s.object :user, reject_empty: true do |user|
        user.param :name, :string, default: "Guest"
        user.param :age, :integer
      end
    end

    assert_invalid schema, { user: {} }, :empty_object, [ "user" ]
    assert_invalid schema, { user: { admin: true } }, :empty_object, [ "user" ]
    assert_equal({ "user" => { "name" => "Ada" } }, schema.parse(user: { name: "Ada", admin: true }).to_h)
    assert_equal({ "user" => { "age" => 27, "name" => "Guest" } }, schema.parse(user: { age: "27" }).to_h)
    assert_empty schema.parse({}).to_h
  end

  def test_empty_object_policy_preserves_nil_unknown_and_child_error_policies
    schema = ActionController::Parameters.schema do |s|
      s.object :user, allow_nil: true, reject_empty: true, unknown: :reject do |user|
        user.param :age, :integer
      end
      s.object(:settings, required: true, reject_empty: false) { |o| o.param :theme, :string }
    end

    assert_equal({ "user" => nil, "settings" => {} }, schema.parse(user: nil, settings: {}).to_h)
    assert_equal({ "settings" => {} }, schema.parse(settings: {}).to_h)
    assert_invalid schema, { user: { admin: true }, settings: {} }, :unknown_parameter, [ "user", "admin" ]
    assert_invalid schema, { user: { age: "wrong" }, settings: {} }, :invalid_integer, [ "user", "age" ]
  end

  def test_reused_object_rules_keep_nested_error_positions
    schema = ActionController::Parameters.schema do |s|
      update = s.value(:object, reject_empty: true) { |o| o.param :name, :string, default: "Guest" }
      s.param :direct, update
      s.collection :rows, of: update
    end

    assert_invalid schema, { direct: {} }, :empty_object, [ "direct" ]
    assert_invalid schema, { rows: [ { name: "Ada" }, {} ] }, :empty_object, [ "rows", 1 ]
    assert_invalid schema, { rows: { "02" => {} } }, :empty_object, [ "rows", "02" ]
    assert_equal({ "rows" => { "02" => { "name" => "Ada" } } },
      schema.parse(rows: { "02" => { name: "Ada" } }).to_h)
  end

  def test_nonempty_object_defaults_must_supply_a_declared_field
    assert_raises(ArgumentError) do
      ActionController::Parameters.schema do |s|
        s.object(:user, reject_empty: true, default: {}) { |o| o.param :name, :string }
      end
    end
    assert_raises(ArgumentError) do
      ActionController::Parameters.schema do |s|
        s.object :user, reject_empty: true, default: {} do |user|
          user.param :name, :string, default: "Guest"
        end
      end
    end
    schema = ActionController::Parameters.schema do |s|
      s.object :user, reject_empty: true, default: { age: 27 } do |user|
        user.param :name, :string, default: "Guest"
        user.param :age, :integer
      end
    end

    assert_equal({ "user" => { "age" => 27, "name" => "Guest" } }, schema.parse({}).to_h)
    assert_invalid schema, { user: {} }, :empty_object, [ "user" ]
  end

  def test_object_options_reject_nonboolean_empty_policy_and_size_bounds
    [ { reject_empty: nil }, { reject_empty: "false" }, { min_size: 1 }, { max_size: 1 } ].each do |options|
      assert_raises(ArgumentError) do
        ActionController::Parameters.schema { |s| s.object(:user, **options) { |o| o.param :name, :string } }
      end
      assert_raises(ArgumentError) do
        ActionController::Parameters.schema(**options) { |s| s.param :name, :string }
      end
    end
  end

  def test_root_can_reject_an_empty_submission
    schema = ActionController::Parameters.schema(reject_empty: true) do |s|
      s.param :name, :string
      s.param :enabled, :boolean, default: false
    end

    assert_invalid schema, {}, :empty_object, []
    assert_invalid schema, { controller: "users", action: "update" }, :empty_object, []
    assert_equal({ "name" => "Ada", "enabled" => false }, schema.parse(name: "Ada", action: "update").to_h)
    assert_equal({ "enabled" => false }, schema.parse(enabled: false).to_h)

    %i[parse parse!].each do |method|
      input = ActionController::Parameters.new(name: "Ada")
      output = input.public_send(method, reject_empty: true) { |s| s.param :name, :string }

      assert_equal({ "name" => "Ada" }, output.to_h)
      error_class = method == :parse ? ParamsSchema::InvalidParameters : ParamsSchema::UnexpectedParameters
      error = assert_raises(error_class) do
        ActionController::Parameters.new.public_send(method, reject_empty: true) { |s| s.param :name, :string }
      end
      assert_equal :empty_object, error.code
      assert_empty error.path
    end
  end

  private
    def assert_invalid(schema, input, code, path)
      error = assert_raises(ParamsSchema::InvalidParameters) { schema.parse(input) }

      assert_equal code, error.code
      assert_equal path, error.path
    end
end
