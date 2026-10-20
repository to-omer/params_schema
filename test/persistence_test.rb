# frozen_string_literal: true

require_relative "test_helper"
require "active_record"
require "action_dispatch/testing/integration"

module PersistenceTestModels
  class Record < ActiveRecord::Base
    self.abstract_class = true
    establish_connection adapter: "sqlite3", database: ":memory:"
  end

  class Project < Record
    self.table_name = "projects"
    has_many :tasks, inverse_of: :project, dependent: :destroy
    accepts_nested_attributes_for :tasks, allow_destroy: true, reject_if: :all_blank
    validates :title, presence: true
  end

  class Task < Record
    self.table_name = "tasks"
    belongs_to :project, inverse_of: :tasks
    validates :title, presence: true
    validates :quantity, numericality: { greater_than: 0 }
  end

  Record.connection_pool.with_connection do |connection|
    connection.create_table :projects do |table|
      table.string :title
      table.string :note
      table.integer :capacity
      table.boolean :enabled
      table.boolean :archived
      table.json :tags
      table.json :metadata
    end
    connection.create_table :tasks do |table|
      table.references :project
      table.string :title
      table.integer :quantity
    end
  end
end

class SchemaPersistenceProjectsController < ActionController::Base
  wrap_parameters false

  INPUT = ActionController::Parameters.schema do |schema|
    schema.object :project, required: true do |project|
      project.param :title, :string
      project.param :note, :string, allow_nil: true
      project.param :capacity, :integer, empty_string_to_nil: true, allow_nil: true
      project.param :enabled, :boolean
      project.array :tags, of: :string
      project.param :metadata, :hash
      project.collection :tasks_attributes do |task|
        task.param :id, :scalar
        task.param :title, :string
        task.param :quantity, :scalar
        task.param :_destroy, :scalar
      end
    end
  end

  rescue_from ParamsSchema::InvalidParameters do |error|
    render json: { code: error.code, path: error.path }, status: :bad_request
  end

  rescue_from ActiveRecord::RecordInvalid do
    render json: { code: "model_invalid" }, status: :unprocessable_content
  end

  def update
    project = PersistenceTestModels::Project.find(params[:id])
    project.update!(project_params)
    render json: { id: project.id }
  end

  private
    def project_params
      params.parse(INPUT).fetch(:project)
    end
end

class PersistenceTest < Minitest::Test
  ROUTES = ActionDispatch::Routing::RouteSet.new
  ROUTES.draw do
    patch "/projects/:id", to: "schema_persistence_projects#update"
  end

  def setup
    PersistenceTestModels::Task.delete_all
    PersistenceTestModels::Project.delete_all
    @client = ActionDispatch::Integration::Session.new(ROUTES)
  end

  def test_patch_saves_declared_changes_and_preserves_other_attributes
    project = create_project
    expected = persisted_state(project)
    expected.first["title"] = "Updated"
    patch(project, title: "Updated", archived: true)

    assert_equal 200, @client.response.status
    assert_equal expected, persisted_state(project)

    expected.first.merge!("note" => nil, "capacity" => nil, "enabled" => false, "tags" => [], "metadata" => {})
    patch(project, note: nil, capacity: "", enabled: false, tags: [], metadata: {})

    assert_equal 200, @client.response.status
    assert_equal expected, persisted_state(project)
  end

  def test_empty_or_invalid_updates_leave_the_record_and_its_children_unchanged
    project = create_project
    original = persisted_state(project)
    first, second = project.tasks.order(:id).to_a
    inputs = [
      [ {}, "empty_object", [ "project" ] ],
      [ { title: "Changed", tasks_attributes: [
        { id: first.id, quantity: "8" }, { id: second.id, quantity: [] }
      ] }, "invalid_scalar", [ "project", "tasks_attributes", 1, "quantity" ] ]
    ]
    inputs.each do |input, code, path|
      patch(project, input)

      assert_equal 400, @client.response.status
      assert_equal({ "code" => code, "path" => path }, @client.response.parsed_body)
      assert_equal original, persisted_state(project)
    end
  end

  def test_nested_arrays_and_form_rows_update_create_reject_blank_and_destroy_records
    [ :array, :hash ].each do |shape|
      project = create_project
      first, second = project.tasks.order(:id).to_a
      rows = [
        { id: first.id, quantity: "8" },
        { id: second.id, quantity: "", _destroy: "1" },
        { title: "", quantity: "" },
        { title: "New", quantity: "3" }
      ]
      rows = %w[02 07 blank new_item].zip(rows).to_h if shape == :hash
      patch(project, { tasks_attributes: rows }, shape == :hash ? nil : :json)
      saved = project.reload.tasks.order(:id)

      assert_equal 200, @client.response.status, shape.to_s
      assert_equal [ [ "First", 8 ], [ "New", 3 ] ], saved.pluck(:title, :quantity)
      assert_equal first.id, saved.first.id
      refute_includes saved.pluck(:id), second.id

      state = persisted_state(project)
      patch(project, tasks_attributes: shape == :hash ? {} : [])

      assert_equal 200, @client.response.status
      assert_equal state, persisted_state(project)
    end
  end

  def test_model_validation_leaves_the_parent_and_children_unchanged
    project = create_project
    original = persisted_state(project)
    first, second = project.tasks.order(:id).to_a
    patch(project, title: "Changed", tasks_attributes: [
      { id: first.id, quantity: "8" }, { id: second.id, title: "" }
    ])

    assert_equal 422, @client.response.status
    assert_equal({ "code" => "model_invalid" }, @client.response.parsed_body)
    assert_equal original, persisted_state(project)
  end

  private
    def create_project
      PersistenceTestModels::Project.create!(title: "Original", note: "Keep", capacity: 42,
        enabled: true, archived: false, tags: [ "red" ], metadata: { "source" => "form" },
        tasks_attributes: [ { title: "First", quantity: 2 }, { title: "Second", quantity: 4 } ])
    end

    def patch(project, attributes, format = :json)
      @client.patch "/projects/#{project.id}", params: { project: attributes }, as: format
    end

    def persisted_state(project)
      [ project.reload.attributes, project.tasks.order(:id).map(&:attributes) ]
    end
end
