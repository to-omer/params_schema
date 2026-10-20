# frozen_string_literal: true

require_relative "test_helper"
require "active_model"

class AttributeAssignmentTest < Minitest::Test
  class Profile
    include ActiveModel::Model

    attr_accessor :name, :admin
  end

  class Subscription
    include ActiveModel::Model
    include ActiveModel::Attributes

    attribute :enabled, :boolean
  end

  def test_only_declared_attributes_reach_mass_assignment
    input = ActionController::Parameters.new(name: "Ada", admin: true)
    assert_raises(ActiveModel::ForbiddenAttributesError) { Profile.new(input) }

    schema = ActionController::Parameters.schema { |s| s.param :name, :string, required: true }
    profile = Profile.new(input.parse(schema))

    assert_equal "Ada", profile.name
    assert_nil profile.admin
    refute_predicate input, :permitted?
  end

  def test_scalar_preserves_values_for_model_attribute_casting
    schema = ActionController::Parameters.schema { |s| s.param :enabled, :scalar }
    attributes = schema.parse(enabled: "off")

    assert_equal "off", attributes[:enabled]
    assert_same false, Subscription.new(attributes).enabled
  end
end
