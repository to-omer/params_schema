# frozen_string_literal: true

require "params_schema"
require "params_schema/testing"
require "action_dispatch/testing/integration"
require "active_model"

class RequestCasesUser
  include ActiveModel::Model
  include ActiveModel::Attributes

  attribute :name, :string
  attribute :age, :integer
  attribute :tags
  attribute :items
  attribute :ids
end

class RequestCasesController < ActionController::Base
  wrap_parameters false
  class_attribute :records

  INPUT = ActionController::Parameters.schema(name: :users_create) do |s|
    s.object :user, required: true, unknown: :reject do |user|
      user.param :name, :string, required: ENV["REQUEST_REGRESSION"] != "required", min_bytes: 1, max_bytes: 100
      user.param :age, :integer, allow_nil: ENV["REQUEST_REGRESSION"] == "nil",
        in: 0..(ENV["REQUEST_REGRESSION"] == "range" ? 151 : 150)
      user.array :tags, of: :string, default: [], max_size: 10
      user.array :items, min_size: 1 do |item|
        item.param :quantity, :integer, required: true, in: 1..10
      end
      user.array :ids, of: user.value(:integer, in: 1..(ENV["REQUEST_REGRESSION"] == "nested_range" ? 11 : 10))
    end
  end

  rescue_from ParamsSchema::InvalidParameters do |error|
    render json: { code: error.code, path: error.path }, status: :bad_request
  end

  def create
    if ENV["REQUEST_REGRESSION"] == "reject_all"
      render json: { code: "missing", path: [ "user", "name" ] }, status: :bad_request
      return
    end
    self.class.records << { "partial" => true } if ENV["REQUEST_REGRESSION"] == "partial_write"
    attributes = RequestCasesUser.new(user_params).attributes
    self.class.records << attributes
    body = ENV["REQUEST_REGRESSION"] == "response_body" ? { broken: true } : attributes
    render json: body, status: :created
  end

  def observe
    result = INPUT.try_parse(params) unless ENV["REQUEST_REGRESSION"] == "skip_observation"
    attributes = if ENV["REQUEST_REGRESSION"] == "use_observed_result"
      result.value!.fetch(:user)
    else
      params.require(:user).permit(:name, :age)
    end
    attributes = RequestCasesUser.new(attributes).attributes
    self.class.records << attributes
    render json: attributes, status: :created
  end

  private
    def user_params
      result = params.parse(INPUT) unless ENV["REQUEST_REGRESSION"] == "skip_parse"
      if %w[skip_parse discard_output].include?(ENV["REQUEST_REGRESSION"])
        params.expect(user: [ :name, :age, tags: [], ids: [], items: [ [ :quantity ] ] ])
      else
        result.fetch(:user)
      end
    end
end

routes = ActionDispatch::Routing::RouteSet.new
routes.draw do
  post "/users", to: "request_cases#create"
  post "/observed_users", to: "request_cases#observe"
end

RSpec.describe "POST /users" do
  let(:client) { ActionDispatch::Integration::Session.new(routes) }
  let(:valid_params) { { user: { name: "Ada", age: "027" } } }
  let(:existing_records) { [ { "name" => "Existing", "age" => 31 } ] }
  let(:records) { RequestCasesController.records }
  let(:events) { [] }

  before { RequestCasesController.records = existing_records.map(&:dup) }

  around do |example|
    capture = ->(event) { events << event.payload }
    ActiveSupport::Notifications.subscribed(capture, "invalid.params_schema") { example.run }
  end

  it "saves and returns the converted valid baseline", :aggregate_failures do
    client.post "/users", params: valid_params, as: :json

    expected = { "name" => "Ada", "age" => 27, "tags" => [], "items" => nil, "ids" => nil }
    expect(records).to eq(existing_records + [ expected ])
    expect(client.response.status).to eq(201)
    expect(client.response.parsed_body).to eq(expected)
    expect(events).to eq([])
  end

  cases = ParamsSchema::Testing.request_cases(path: [ :user, :age ], integer: 0..150,
    required: false, allow_nil: false) + ParamsSchema::Testing.request_cases(path: [ :user, :name ],
    required: true, allow_nil: false)

  cases.each do |sample|
    it sample.description, :aggregate_failures do
      client.post "/users", params: sample.params(valid_params), as: :json

      if sample.valid?
        expected = { "name" => "Ada", "age" => sample.omitted? ? nil : sample.value, "tags" => [], "items" => nil, "ids" => nil }
        expect(records).to eq(existing_records + [ expected ])
        expect(client.response.status).to eq(201)
        expect(client.response.parsed_body).to eq(expected)
        expect(events).to eq([])
      else
        expect(records).to eq(existing_records)
        expect(client.response.status).to eq(400)
        expect(client.response.parsed_body).to eq("code" => sample.error_code.to_s, "path" => sample.path)
        expect(events).to eq([ { schema: "users_create", code: sample.error_code } ])
      end
    end
  end

  context "nested inputs" do
    let(:valid_params) do
      { user: { name: "Ada", age: 27, items: [ { quantity: "2" }, { quantity: "3" } ], ids: [ 1, 2 ] } }
    end

    cases = ParamsSchema::Testing.request_cases(path: [ :user, :items, 1, :quantity ], integer: 1..10,
      required: true, allow_nil: false) + ParamsSchema::Testing.request_cases(path: [ :user, :ids, 1 ], integer: 1..10) +
      ParamsSchema::Testing.request_cases(path: [ :user, :items ], cases: [
        { value: {}, error_code: :invalid_array }, { value: [], error_code: :too_few_items }
      ])

    cases.each do |sample|
      it sample.description, :aggregate_failures do
        client.post "/users", params: sample.params(valid_params), as: :json

        if sample.valid?
          expected = { "name" => "Ada", "age" => 27, "tags" => [], "items" => [ { "quantity" => 2 }, { "quantity" => 3 } ], "ids" => [ 1, 2 ] }
          case sample.path
          when [ "user", "items", 1, "quantity" ] then expected["items"][1]["quantity"] = sample.value
          when [ "user", "ids", 1 ] then expected["ids"][1] = sample.value
          else raise "unexpected valid variation"
          end
          expect(records).to eq(existing_records + [ expected ])
          expect(client.response.status).to eq(201)
          expect(client.response.parsed_body).to eq(expected)
          expect(events).to eq([])
        else
          expect(records).to eq(existing_records)
          expect(client.response.status).to eq(400)
          expect(client.response.parsed_body).to eq("code" => sample.error_code.to_s, "path" => sample.path)
          expect(events).to eq([ { schema: "users_create", code: sample.error_code } ])
        end
      end
    end
  end

  context "observation" do
    it "keeps the legacy defaults and response for valid input", :aggregate_failures do
      client.post "/observed_users", params: valid_params, as: :json

      expected = { "name" => "Ada", "age" => 27, "tags" => nil, "items" => nil, "ids" => nil }
      expect(records).to eq(existing_records + [ expected ])
      expect(client.response.status).to eq(201)
      expect(client.response.parsed_body).to eq(expected)
      expect(events).to eq([])
    end

    it "reports known invalid input while preserving the legacy result", :aggregate_failures do
      client.post "/observed_users", params: { user: { name: "Ada", age: "151" } }, as: :json

      expected = { "name" => "Ada", "age" => 151, "tags" => nil, "items" => nil, "ids" => nil }
      expect(records).to eq(existing_records + [ expected ])
      expect(client.response.status).to eq(201)
      expect(client.response.parsed_body).to eq(expected)
      expect(events).to eq([ { schema: "users_create", code: :not_included } ])
    end

    it "propagates subscriber failures before saving", :aggregate_failures do
      failure = RuntimeError.new("monitor unavailable")
      failing_subscriber = ->(_event) { raise failure }
      ActiveSupport::Notifications.subscribed(failing_subscriber, "invalid.params_schema") do
        expect do
          client.post "/observed_users", params: { user: { name: "Ada", age: "151" } }, as: :json
        end.to(raise_error { |error| expect(error).to equal(failure) })
      end
      expect(records).to eq(existing_records)
    end
  end
end
