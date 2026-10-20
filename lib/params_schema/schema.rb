# frozen_string_literal: true

require "active_support/notifications"

module ParamsSchema
  # Validates and converts parameters according to a fixed set of root fields.
  #
  # Construct a schema with {ActionController::Parameters.schema}, then call
  # {#parse}, {#parse!}, or {#try_parse} for each input. A schema can be shared
  # across requests.
  #
  # @example Validate a page number
  #   query = ActionController::Parameters.schema do |s|
  #     s.param :page, :integer, default: 1, in: 1..
  #   end
  #   query.parse(page: "2").to_h # => { "page" => 2 }
  class Schema
    # (see ParamsSchema::Parameters::ClassMethods#schema)
    def initialize(name: nil, unknown: :drop, reject_empty: false, &block)
      unless name.nil? || String === name || Symbol === name
        raise ArgumentError, "schema name must be a String or Symbol"
      end
      @name = name.nil? ? nil : String.new(name.to_s).freeze
      raise ArgumentError, "invalid schema name encoding" if @name && !@name.valid_encoding?

      @root = Builder.new.value(:object, unknown: unknown, reject_empty: reject_empty, &block)
      freeze
    end

    # Validates input and returns a new, permitted Parameters instance.
    #
    # Parsing checks the input even if it is already permitted. The first
    # validation failure raises {ParamsSchema::InvalidParameters}.
    #
    # #### Missing fields and nil
    #
    # Missing optional fields remain absent unless they have a default. A missing
    # optional parent object without its own default stays absent even if its
    # children have defaults.
    # A declared value rule accepts nil only with `allow_nil: true`. Accepted nil remains nil.
    # Other value constraints apply to non-nil values.
    #
    # #### Input and output
    #
    # Input values and permission states remain unchanged on success and failure.
    #
    # | Output | Copying and conversion |
    # | --- | --- |
    # | Objects, maps, and hashes | New, permitted Parameters; maps and hashes retain normalized keys and entry order |
    # | Arrays | New arrays in input order; drop_empty_strings: true removes empty strings |
    # | Values returned as strings | New ordinary strings with the same content and encoding |
    # | Uploads | The original upload objects, shared with the input |
    #
    # Output strings and containers can be edited independently of the input.
    # Uploads remain shared: changes to an upload are visible through either
    # reference. Parsing preserves the current position within the file, its open state, and metadata.
    #
    # #### Keys and undeclared fields
    #
    # Keys must be validly encoded strings or symbols. Symbols normalize to
    # strings; a Hash containing both "page" and :page is rejected as ambiguous.
    # Objects drop undeclared keys by default, or reject them with `unknown: :reject`.
    #
    # #### Failure notifications
    #
    # Each failed parse publishes `invalid.params_schema` through ActiveSupport::Notifications.
    # The payload contains `schema` (the schema's `name:` as a string, or nil)
    # and `code` (the validation error code).
    # Subscribers run synchronously; their exceptions propagate.
    # See the {file:docs/errors.md error-handling guide} for application setup.
    #
    # @param input [Hash, ActionController::Parameters] parameter tree, stable for
    #   the duration of parsing. Request parameters reflect Rails decoding,
    #   wrapping, and normalization; by default, Rails removes null array elements
    # @return [ActionController::Parameters] new, recursively permitted parameters
    # @raise [ParamsSchema::InvalidParameters] at the first invalid value or
    #   regular-expression timeout; no partial output is returned
    # @raise [ArgumentError] if a block is supplied; declarations belong to
    #   schema construction, not parsing
    # @see ParamsSchema::Builder Field types and options
    # @see ParamsSchema::InvalidParameters#code
    def parse(input)
      raise ArgumentError, "schema.parse does not accept a block" if block_given?

      try_parse(input).value!
    end

    # Validates input and treats a contract violation as an application error.
    #
    # Use this for a controlled client whose invalid requests indicate a bug.
    # Successful output and failure notifications are the same as {#parse}.
    # A validation failure raises {ParamsSchema::UnexpectedParameters},
    # which Rails treats as an unhandled error (HTTP 500 by default).
    #
    # @param input [Hash, ActionController::Parameters] parameters to validate
    # @return [ActionController::Parameters] new, recursively permitted parameters
    # @raise [ParamsSchema::UnexpectedParameters] on validation failure
    # @raise [ArgumentError] if a block is supplied
    def parse!(input)
      raise ArgumentError, "schema.parse! does not accept a block" if block_given?

      result = try_parse(input)
      # Rails also searches exception causes for rescue_from handlers.
      raise ParamsSchema::UnexpectedParameters.new(result.error), cause: nil if result.error

      result.value!
    end

    # Validates input and returns a {Result} containing output or a validation error.
    #
    # Only validation failures become failure results. All other exceptions,
    # including notification subscriber failures, propagate. Input copying,
    # output permissions, and notifications are the same as {#parse}.
    #
    # @overload try_parse(input)
    #   @param input [Hash, ActionController::Parameters] the parameter tree
    #   @return [Result] the successful output or validation error
    # @raise [ArgumentError] if a block is supplied
    # @see file:docs/errors.md Gradual adoption, notifications, and translations
    # @example Inspect a validation failure
    #   ids = ActionController::Parameters.schema { |s| s.param :id, :integer }
    #   result = ids.try_parse(id: "invalid")
    #   result.success?   # => false
    #   result.error.code # => :invalid_integer
    #   result.error.path # => [ "id" ]
    #   result.value!     # raises ParamsSchema::InvalidParameters
    def try_parse(input, &block)
      raise ArgumentError, "schema.try_parse does not accept a block" if block

      result = parse_result(input)
      if result.error
        ActiveSupport::Notifications.instrument("invalid.params_schema", schema: @name, code: result.error.code)
      end
      result
    end

    private
      # Keep reporting outside this rescue: subscriber failures are not input errors.
      # @private
      def parse_result(input)
        output = Parser.new.call(input, @root)
        Result.new(ActionController::Parameters.new(output).permit!, nil)
      rescue ParamsSchema::InvalidParameters => error
        Result.new(nil, error)
      end
  end
end
