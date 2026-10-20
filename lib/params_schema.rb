# frozen_string_literal: true

require "action_controller"
require "action_dispatch/middleware/exception_wrapper"
require_relative "params_schema/version"
require_relative "params_schema/core"
require_relative "params_schema/parameters"

# Action Pack extensions provided by Params Schema.
module ActionController
  # Rails request parameters extended with typed schemas.
  #
  # @!method self.schema(name: nil, unknown: :drop, reject_empty: false, &block)
  #   (see ParamsSchema::Parameters::ClassMethods#schema)
  class Parameters
    include ParamsSchema::Parameters
  end
end

ActionDispatch::ExceptionWrapper.rescue_responses["ParamsSchema::InvalidParameters"] = :bad_request
