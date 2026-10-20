# frozen_string_literal: true

require_relative "test_helper"
require "params_schema/testing"
require "rack/mock"
require "rack/test"
require "action_dispatch/middleware/show_exceptions"
require "json"
require "tempfile"

class ParametersProbeController < ActionController::Base
  wrap_parameters false

  QUERY = ActionController::Parameters.schema(unknown: :reject) do |s|
    s.array :ids, of: s.value(:integer, in: 1..), min_size: 1
  end
  BODY = ActionController::Parameters.schema(unknown: :reject) do |s|
    s.param :n, :integer, coerce: false, required: true
  end
  UPLOAD = ActionController::Parameters.schema do |s|
    s.object :import, required: true, unknown: :reject do |data|
      data.param :attachment, :uploaded_file, required: true
      data.map :rows, keys: /\A[0-9]+\z/ do |row|
        row.param :name, :string, required: true
      end
    end
  end
  NULLS = ActionController::Parameters.schema { |s| s.array :ids, of: :integer }

  def query
    render json: QUERY.parse(request.query_parameters)
  end

  def body
    render json: BODY.parse(request.request_parameters)
  end

  def upload
    input = UPLOAD.parse(request.request_parameters).fetch(:import)
    render json: { file_class: input[:attachment].class.name, rows: input[:rows] }
  end

  def nulls
    render json: NULLS.parse(request.request_parameters)
  end

  def path
    contract = ActionController::Parameters.schema { |s| s.param :id, :integer, required: true }
    render json: contract.parse(request.path_parameters)
  end
end

class WrappedParametersProbeController < ParametersProbeController
  wrap_parameters :probe, format: [ :json ]
end

class RescuedParametersProbeController < ParametersProbeController
  rescue_from ParamsSchema::InvalidParameters do |error|
    render json: { code: error.code, path: error.path }, status: :bad_request
  end
end

class ControlledParametersProbeController < RescuedParametersProbeController
  def body
    render json: BODY.parse!(request.request_parameters)
  end
end

class FormControlsProbeController < ActionController::Base
  INPUT = ActionController::Parameters.schema do |s|
    s.param :name, :string, empty_string_to_nil: true, allow_nil: true
    s.param :subscribed, :boolean, empty_string_to_nil: true, allow_nil: true
    s.param :reference, :scalar, empty_string_to_nil: true, allow_nil: true
    s.param :expires_in, :integer, empty_string_to_nil: true, allow_nil: true, in: (1..)
    s.param :weight, :float, in: -10..10
    s.array :ids, of: :integer, drop_empty_strings: true, max_size: 2
  end

  rescue_from ParamsSchema::InvalidParameters do |error|
    render json: { code: error.code, path: error.path }, status: :bad_request
  end

  def create
    render json: params.parse(INPUT)
  end
end

class UpdateParametersProbeController < ActionController::Base
  wrap_parameters false

  rescue_from ParamsSchema::InvalidParameters do |error|
    render json: { code: error.code, path: error.path }, status: :bad_request
  end

  def update
    render json: user_params
  end

  private
    def user_params
      params.parse do |schema|
        schema.object :user, required: true do |user|
          user.param :name, :string, default: "Guest"
          user.param :age, :integer, allow_nil: true
          user.param :enabled, :boolean
          user.array :tags, of: :string
          user.param :admin, :boolean if request.env["params_schema.admin"]
        end
      end.fetch(:user)
    end
end

class AdoptionProbeController < ActionController::Base
  wrap_parameters false

  INPUT = ActionController::Parameters.schema(name: :adoption) do |s|
    s.object :user, required: true, unknown: :reject do |user|
      user.param :age, :integer, required: true
      user.param :enabled, :boolean, default: false
    end
  end

  rescue_from ParamsSchema::InvalidParameters do |error|
    render json: { code: error.code, path: error.path }, status: :bad_request
  end

  def create
    render json: user_params
  end

  private
    def user_params
      INPUT.try_parse(params)
      params.require(:user).permit(:age)
    end
end

class EnforcedAdoptionProbeController < AdoptionProbeController
  private
    def user_params
      params.parse(INPUT).fetch(:user)
    end
end

class LocalizedProbeController < ParametersProbeController
  around_action :with_request_locale

  rescue_from ParamsSchema::InvalidParameters do |error|
    message = I18n.t(error.code, scope: "params_schema.errors", locale: request_locale, default: :invalid)
    render json: { code: error.code, message: message }, status: :bad_request
  end

  private
    def request_locale
      I18n.available_locales.find { |locale| locale.to_s == params[:locale] } || I18n.default_locale
    end

    def with_request_locale(&action)
      I18n.with_locale(request_locale, &action)
    end
end

class RailsIntegrationTest < Minitest::Test
  def setup
    @schema = ActionController::Parameters.schema do |s|
      s.object :user do |u|
        u.param :age, :integer
        u.array :labels, of: :string
        u.map(:options) { |o| o.param :name, :string }
      end
    end
  end

  def test_schema_alone_rejects_missing_empty_and_malformed_update_objects
    client = Rack::MockRequest.new(UpdateParametersProbeController.action(:update))
    [ [ {}, "missing" ],
      [ { user: {} }, "empty_object" ],
      [ { user: { ignored: "value" } }, "empty_object" ],
      [ { user: "invalid" }, "invalid_object" ] ].each do |input, code|
      response = client.patch("/", "CONTENT_TYPE" => "application/json", input: JSON.generate(input))

      assert_equal 400, response.status
      assert_equal({ "code" => code, "path" => [ "user" ] }, JSON.parse(response.body))
    end
  end

  def test_clearing_values_count_as_supplied_fields
    client = Rack::MockRequest.new(UpdateParametersProbeController.action(:update))
    response = client.patch("/", "CONTENT_TYPE" => "application/json",
      input: '{"user":{"age":null,"enabled":false,"tags":[]}}')

    assert_equal 200, response.status
    assert_equal({ "age" => nil, "enabled" => false, "tags" => [], "name" => "Guest" }, JSON.parse(response.body))

    response = client.patch("/", "CONTENT_TYPE" => "application/json", input: '{"user":{"name":""}}')

    assert_equal 200, response.status
    assert_equal({ "name" => "" }, JSON.parse(response.body))
  end

  def test_conditional_fields_are_selected_before_validation_and_empty_checks
    client = Rack::MockRequest.new(UpdateParametersProbeController.action(:update))
    environment = { "CONTENT_TYPE" => "application/json", input: '{"user":{"name":"Ada","admin":[]}}' }
    response = client.patch("/", environment)

    assert_equal 200, response.status
    assert_equal({ "name" => "Ada" }, JSON.parse(response.body))

    response = client.patch("/", environment.merge("params_schema.admin" => true))

    assert_equal 400, response.status
    assert_equal({ "code" => "invalid_boolean", "path" => [ "user", "admin" ] }, JSON.parse(response.body))

    environment[:input] = '{"user":{"admin":true}}'
    response = client.patch("/", environment.merge("params_schema.admin" => true))

    assert_equal 200, response.status
    assert_equal({ "admin" => true, "name" => "Guest" }, JSON.parse(response.body))

    response = client.patch("/", environment)

    assert_equal 400, response.status
    assert_equal({ "code" => "empty_object", "path" => [ "user" ] }, JSON.parse(response.body))
  end

  def test_empty_fields_and_multiple_selection_controls_through_form_requests
    client = Rack::MockRequest.new(FormControlsProbeController.action(:create))
    environment = { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }
    response = client.post("/", environment.merge(input: "name=&subscribed=&reference=&expires_in=&weight=1.25&ids[]=&ids[]=1&ids[]=2"))

    assert_equal 200, response.status
    assert_equal({ "name" => nil, "subscribed" => nil, "reference" => nil,
      "expires_in" => nil, "weight" => 1.25, "ids" => [ 1, 2 ] }, JSON.parse(response.body))

    cleared = client.post("/", environment.merge(input: "ids[]="))

    assert_equal({ "ids" => [] }, JSON.parse(cleared.body))
    omitted = client.post("/", environment.merge(input: ""))

    assert_equal({}, JSON.parse(omitted.body))

    rejected = client.post("/", environment.merge(input: "ids[]=&ids[]=1&ids[]=bad"))

    assert_equal 400, rejected.status
    assert_equal({ "code" => "invalid_integer", "path" => [ "ids", 2 ] }, JSON.parse(rejected.body))
  end

  def test_real_parameters_input_and_nested_permission_state
    child = ActionController::Parameters.new(age: "2", labels: [ "a" ], options: { a: { name: "x" } })
    input = ActionController::Parameters.new(user: child, ignored: "x")
    input_raw, child_raw = input.__send__(:parameters), child.__send__(:parameters)
    labels, options = child_raw.values_at("labels", "options")
    result = input.parse(@schema)

    assert_predicate result, :permitted?
    assert_predicate result[:user], :permitted?
    assert_predicate result[:user][:options], :permitted?
    assert_predicate result[:user][:options][:a], :permitted?
    assert_equal 2, result[:user][:age]
    refute_predicate input, :permitted?
    refute_predicate child, :permitted?
    assert_same input_raw, input.__send__(:parameters)
    assert_same child_raw, child.__send__(:parameters)
    assert_same labels, child_raw["labels"]
    assert_same options, child_raw["options"]
    assert_equal({ "user" => { "age" => "2", "labels" => [ "a" ], "options" => { "a" => { "name" => "x" } } },
      "ignored" => "x" }, input.to_unsafe_h)
    result[:user][:labels][0].replace("changed")

    assert_equal "a", child_raw["labels"][0]
  end

  def test_frozen_and_already_permitted_inputs
    input = ActionController::Parameters.new(user: { age: "3", labels: [ "x" ] })
    input.__send__(:parameters).freeze
    input.freeze

    assert_equal 3, input.parse(@schema)[:user][:age]
    assert_equal 4, @schema.parse({ user: { age: "4" } }.with_indifferent_access)[:user][:age]
    invalid = ActionController::Parameters.new(user: { age: "bad" }).permit!
    assert_raises(ParamsSchema::InvalidParameters) { invalid.parse(@schema) }
    assert_predicate invalid, :permitted?
    assert_equal "bad", invalid[:user][:age]
  end

  def test_public_inline_api_and_invalid_call_forms
    input = ActionController::Parameters.new(page: "2")
    %i[parse parse!].each do |method|
      output = input.public_send(method) { |s| s.param :page, :integer }

      assert_predicate output, :permitted?
      assert_equal({ "page" => 2 }, output.to_h)
      assert_raises(ArgumentError) { input.public_send(method) }
      assert_raises(ArgumentError) { input.public_send(method, nil) }
      assert_raises(ArgumentError) { input.public_send(method, @schema) { |s| s.param :page, :integer } }
    end
    assert_raises(ArgumentError) { ActionController::Parameters.schema }
  end

  def test_bang_is_an_unhandled_server_error_despite_a_shared_invalid_input_handler
    exceptions = lambda do |env|
      [ env.fetch("PATH_INFO").delete_prefix("/").to_i, { "content-type" => "application/json" },
        [ JSON.generate(report: env.fetch("action_dispatch.report_exception")) ] ]
    end
    app = ActionDispatch::ShowExceptions.new(ControlledParametersProbeController.action(:body), exceptions)
    client = Rack::MockRequest.new(app)
    environment = { "CONTENT_TYPE" => "application/json", "action_dispatch.show_exceptions" => :all }

    accepted = client.post("/", environment.merge(input: '{"n":2}'))

    assert_equal 200, accepted.status
    assert_equal({ "n" => 2 }, JSON.parse(accepted.body))

    rejected = client.post("/", environment.merge(input: '{"n":"bad"}'))

    assert_equal 500, rejected.status
    assert_equal({ "report" => true }, JSON.parse(rejected.body))

    error = assert_raises(ParamsSchema::UnexpectedParameters) do
      client.post("/", environment.merge("action_dispatch.show_exceptions" => :rescuable, input: '{"n":"bad"}'))
    end
    assert_equal :invalid_integer, error.code
    assert_equal [ "n" ], error.path
  end

  def test_reusable_schema_rejects_an_unused_block
    assert_raises(ArgumentError) do
      @schema.parse({}) { flunk "schema.parse must not evaluate a block" }
    end
  end

  def test_files_are_shared_and_not_read_or_modified
    temp = Tempfile.new([ "upload", ".txt" ])
    temp.write("content"); temp.rewind; temp.read(2)
    uploaded = ActionDispatch::Http::UploadedFile.new(tempfile: temp, filename: "test.txt", type: "text/plain")
    position = temp.pos
    rack_file = Rack::Test::UploadedFile.new(temp.path, "text/plain")
    [ :uploaded_file, :scalar ].each do |type|
      contract = ActionController::Parameters.schema { |s| s.param :file, type }

      assert_same uploaded, contract.parse(file: uploaded)[:file]
      assert_same rack_file, contract.parse(file: rack_file)[:file]
    end
    attachments = ActionController::Parameters.schema do |s|
      s.array :files, of: :scalar, drop_empty_strings: true
    end
    signed_id = +"existing-attachment-signed-id"
    input = ActionController::Parameters.new(files: [ "", signed_id, uploaded ])
    output = attachments.parse(input)

    assert_equal [ signed_id, uploaded ], output[:files]
    refute_same signed_id, output[:files].first
    assert_same uploaded, output[:files].last
    assert_predicate output, :permitted?
    refute_predicate input, :permitted?
    assert_equal [ "", signed_id, uploaded ], input[:files]
    error = assert_raises(ParamsSchema::InvalidParameters) { attachments.parse(files: [ "", signed_id, { filename: "fake" } ]) }
    assert_equal :invalid_scalar, error.code
    assert_equal [ "files", 2 ], error.path
    assert_equal position, temp.pos
    refute_predicate temp, :closed?
    assert_equal "test.txt", uploaded.original_filename
  ensure
    rack_file&.close
    temp&.close!
  end

  def test_existing_strong_parameters_keep_their_behavior
    input = ActionController::Parameters.new(user: { name: "A", hidden: "B" })
    expected = { "name" => "A" }

    assert_equal expected, input.require(:user).permit(:name).to_h
    assert_equal expected, input.expect(user: [ :name ]).to_h
    assert_raises(ActionController::ParameterMissing) do
      ActionController::Parameters.new(user: "x").expect(user: [ :name ])
    end
    refute_predicate input, :permitted?
  end

  def test_query_and_path_sources_remain_separate
    query = Rack::MockRequest.new(ParametersProbeController.action(:query)).get("/?ids[]=2&ids[]=3")

    assert_equal 200, query.status
    assert_equal({ "ids" => [ 2, 3 ] }, JSON.parse(query.body))
    body = Rack::MockRequest.new(ParametersProbeController.action(:query)).post("/?ids[]=4",
      "CONTENT_TYPE" => "application/x-www-form-urlencoded", input: "ids[]=5")

    assert_equal({ "ids" => [ 4 ] }, JSON.parse(body.body))
    path = Rack::MockRequest.new(ParametersProbeController.action(:path)).get("/?id=bad",
      "action_dispatch.request.path_parameters" => { controller: "parameters_probe", action: "path", id: "7" })

    assert_equal({ "id" => 7 }, JSON.parse(path.body))
  end

  def test_json_strictness_and_wrapper_configuration
    client = Rack::MockRequest.new(ParametersProbeController.action(:body))
    good = client.post("/", "CONTENT_TYPE" => "application/json", input: '{"n":2}')

    assert_equal 200, good.status
    assert_equal({ "n" => 2 }, JSON.parse(good.body))
    assert_raises(ParamsSchema::InvalidParameters) do
      client.post("/", "CONTENT_TYPE" => "application/json", input: '{"n":"2"}')
    end
    wrapped = Rack::MockRequest.new(WrappedParametersProbeController.action(:body))
    error = assert_raises(ParamsSchema::InvalidParameters) do
      wrapped.post("/", "CONTENT_TYPE" => "application/json", input: '{"n":2}')
    end
    assert_equal :unknown_parameter, error.code
    assert_equal [ "probe" ], error.path
  end

  def test_real_multipart_and_form_control_fields
    temp = Tempfile.new([ "upload", ".txt" ])
    temp.write("abc"); temp.close
    session = Rack::Test::Session.new(Rack::MockSession.new(ParametersProbeController.action(:upload)))
    session.post("/", import: {
      attachment: Rack::Test::UploadedFile.new(temp.path, "text/plain"),
      rows: { "10" => { name: "A" }, "02" => { name: "B" } }
    }, authenticity_token: "unused-in-this-no-session-test", commit: "Upload")

    assert_equal 200, session.last_response.status
    parsed = JSON.parse(session.last_response.body)

    assert_equal "ActionDispatch::Http::UploadedFile", parsed["file_class"]
    assert_equal({ "10" => { "name" => "A" }, "02" => { "name" => "B" } }, parsed["rows"])
    assert_equal [ "10", "02" ], parsed.fetch("rows").keys
  ensure
    temp&.unlink
  end

  def test_upload_type_rejects_json_values
    client = Rack::MockRequest.new(RescuedParametersProbeController.action(:upload))
    [ "not a file", { "filename" => "example.txt" } ].each do |value|
      response = client.post("/", "CONTENT_TYPE" => "application/json",
        input: JSON.generate({ import: { attachment: value } }))

      assert_equal 400, response.status
      assert_equal({ "code" => "invalid_uploaded_file", "path" => [ "import", "attachment" ] },
        JSON.parse(response.body))
    end
  end

  def test_deep_munge_is_before_the_schema
    response = Rack::MockRequest.new(ParametersProbeController.action(:nulls)).post("/",
      "CONTENT_TYPE" => "application/json", input: '{"ids":[null,1]}')

    assert_equal({ "ids" => [ 1 ] }, JSON.parse(response.body))
    assert_raises(ParamsSchema::InvalidParameters) { ParametersProbeController::NULLS.parse(ids: [ nil, 1 ]) }
  end

  def test_observation_preserves_legacy_values_until_enforcement
    [ AdoptionProbeController, EnforcedAdoptionProbeController ].each do |controller|
      client = Rack::MockRequest.new(controller.action(:create))
      enforce = controller == EnforcedAdoptionProbeController
      reports = []
      subscriber = ActiveSupport::Notifications.subscribe("invalid.params_schema") { |event| reports << event.payload }
      environment = { "CONTENT_TYPE" => "application/json" }
      accepted = client.post("/", environment.merge(input: '{"user":{"age":"027"}}'))

      assert_equal 200, accepted.status
      assert_equal(enforce ? { "age" => 27, "enabled" => false } : { "age" => "027" }, JSON.parse(accepted.body))
      assert_empty reports

      rejected = client.post("/", environment.merge(input: '{"user":{"age":"027","admin":true}}'))

      assert_equal(enforce ? 400 : 200, rejected.status)
      assert_equal(enforce ? { "code" => "unknown_parameter", "path" => [ "user", "admin" ] } : { "age" => "027" },
        JSON.parse(rejected.body))
      assert_equal [ { schema: "adoption", code: :unknown_parameter } ], reports
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end
  end

  def test_omitting_the_only_submitted_field_reports_the_missing_child
    sample = ParamsSchema::Testing.request_cases(path: [ :user, :age ], required: true).first
    client = Rack::MockRequest.new(EnforcedAdoptionProbeController.action(:create))
    response = client.post("/", "CONTENT_TYPE" => "application/json",
      input: JSON.generate(sample.params(user: { age: 27 })))

    assert_equal 400, response.status
    assert_equal({ "code" => sample.error_code.to_s, "path" => sample.path }, JSON.parse(response.body))
  end

  def test_shared_error_handler_uses_the_request_locale_after_the_around_action_unwinds
    original_backend, original_locales, original_locale = I18n.backend, I18n.available_locales, I18n.locale
    I18n.backend = I18n::Backend::Simple.new
    I18n.available_locales = [ :en, :ja ]
    I18n.backend.store_translations(:en, params_schema: { errors: {
      invalid: "Invalid request parameters.", invalid_integer: "An integer is required."
    } })
    I18n.backend.store_translations(:ja, params_schema: { errors: {
      invalid: "リクエストのパラメータが不正です。", invalid_integer: "整数を指定してください。"
    } })
    client = Rack::MockRequest.new(LocalizedProbeController.action(:body))

    I18n.with_locale(:en) do
      { "ja" => "整数を指定してください。", "en" => "An integer is required." }.each do |locale, message|
        response = client.post("/?locale=#{locale}", "CONTENT_TYPE" => "application/json", input: '{"n":"bad"}')

        assert_equal 400, response.status
        assert_equal({ "code" => "invalid_integer", "message" => message }, JSON.parse(response.body))
        assert_equal :en, I18n.locale
      end
      response = client.post("/?locale=ja", "CONTENT_TYPE" => "application/json", input: "{}")

      assert_equal 400, response.status
      assert_equal({ "code" => "missing", "message" => "リクエストのパラメータが不正です。" }, JSON.parse(response.body))
      assert_equal :en, I18n.locale
    end
  ensure
    I18n.backend = original_backend
    I18n.available_locales = original_locales
    I18n.locale = original_locale
  end
end
