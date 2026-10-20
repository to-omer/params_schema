# frozen_string_literal: true

require "active_support/concern"

module ParamsSchema
  # Schema methods mixed into ActionController::Parameters when the gem is loaded.
  module Parameters
    extend ActiveSupport::Concern

    # Schema construction methods installed on ActionController::Parameters.
    module ClassMethods
      # Builds a reusable schema with a fixed set of root fields.
      #
      # Declare fields with the {ParamsSchema::Builder} yielded to the block.
      # Reuse the resulting schema across requests. `unknown:` applies to root fields;
      # nested objects use their own setting, which defaults to `:drop`.
      #
      # Definitions may nest up to 32 value positions below the root. Field names,
      # defaults, enumerations, and patterns are copied or compiled
      # at construction. Later edits to these inputs do not change the schema.
      #
      # @param name [String, Symbol, nil] identifier included in failure notifications;
      #   strings and symbols become a string, and nil remains nil. Use a fixed
      #   application-defined name
      # @param unknown [:drop, :reject] how to handle undeclared root fields:
      #   :drop omits them from the output; :reject raises an input validation error
      # @param reject_empty [Boolean] when true, require at least one declared root field in
      #   the input, before defaults; defaults to false. See {ParamsSchema::Builder#object}
      # @yield [schema] declare the root fields in this required block
      # @yieldparam schema [ParamsSchema::Builder] the declaration DSL
      # @return [ParamsSchema::Schema] the schema to apply to request parameters
      # @raise [ArgumentError] for a missing block or invalid definitions
      # @see ParamsSchema::Schema#parse
      # @example Validate nested input and apply defaults
      #   input_schema = ActionController::Parameters.schema do |s|
      #     s.object :user, required: true, unknown: :reject do |user|
      #       user.param :name, :string, required: true, min_bytes: 1
      #       user.param :age, :integer, in: 0..150
      #       user.param :enabled, :boolean, default: false
      #     end
      #   end
      #   input = ActionController::Parameters.new(user: { name: "Ada", age: "27" })
      #   input.parse(input_schema).to_h
      #   # => { "user" => { "name" => "Ada", "age" => 27, "enabled" => false } }
      # @example Reject empty flat input
      #   input_schema = ActionController::Parameters.schema(reject_empty: true) do |s|
      #     s.param :enabled, :boolean, default: true
      #   end
      #   input_schema.parse(enabled: false).to_h # => { "enabled" => false }
      #   error = input_schema.try_parse({}).error
      #   [error.code, error.path] # => [:empty_object, []]
      def schema(name: nil, unknown: :drop, reject_empty: false, &block)
        ParamsSchema::Schema.new(name: name, unknown: unknown, reject_empty: reject_empty, &block)
      end
    end

    # Validates these parameters and returns a new, permitted Parameters instance.
    #
    # Supply a reusable schema, or declare one for this call in a block.
    #
    # @overload parse(schema)
    #   @param schema [ParamsSchema::Schema] a reusable schema
    # @overload parse(name: nil, unknown: :drop, reject_empty: false)
    #   @param name [String, Symbol, nil] identifier for failure notifications
    #   @param unknown [:drop, :reject] how to handle undeclared root fields
    #   @param reject_empty [Boolean] when true, require at least one declared root field before defaults
    #   @yield [schema] declares a schema for this call
    #   @yieldparam schema [ParamsSchema::Builder] the declaration DSL
    # @return [ActionController::Parameters] new, recursively permitted parameters
    # @raise [ArgumentError] if both a schema and a block are supplied, neither is
    #   supplied, the argument is not a Schema, or schema options are supplied
    #   with a reusable schema
    # @raise [ParamsSchema::InvalidParameters] if input does not match the schema
    # @see ParamsSchema::Builder Field types and options
    # @see ParamsSchema::Schema#parse Input conversion, copying, and errors
    # @example Declare a schema for a single call
    #   input = ActionController::Parameters.new(page: "2")
    #   result = input.parse do |s|
    #     s.param :page, :integer, in: 1..100
    #   end
    #   result.to_h # => { "page" => 2 }
    def parse(schema = UNSET, **options, &block)
      resolve_parameter_schema(schema, **options, &block).parse(self)
    end

    # Validates these parameters and raises an application error for invalid input.
    #
    # Accepts the same schema or block forms as {#parse}. Use this when invalid
    # input from a controlled client should be reported as an application bug.
    #
    # @overload parse!(schema)
    #   @param schema [ParamsSchema::Schema] the schema to apply
    # @overload parse!(name: nil, unknown: :drop, reject_empty: false)
    #   @param name [String, Symbol, nil] identifier for failure notifications
    #   @param unknown [:drop, :reject] how to handle undeclared root fields
    #   @param reject_empty [Boolean] when true, require at least one declared root field before defaults
    #   @yield [schema] define the fields for this call
    #   @yieldparam schema [ParamsSchema::Builder] the schema builder
    # @return [ActionController::Parameters] new, recursively permitted parameters
    # @raise [ParamsSchema::UnexpectedParameters] on validation failure
    # @raise [ArgumentError] if the schema or block arguments are invalid
    # @see ParamsSchema::Schema#parse!
    def parse!(schema = UNSET, **options, &block)
      resolve_parameter_schema(schema, **options, &block).parse!(self)
    end

    private
      # @private
      def resolve_parameter_schema(schema, **options, &block)
        supplied = !schema.equal?(UNSET)
        raise ArgumentError, "choose a schema or a block" unless supplied ^ !!block
        raise ArgumentError, "schema options require a block" if supplied && !options.empty?

        schema = self.class.schema(**options, &block) if block
        raise ArgumentError, "parameter schema expected" unless Schema === schema

        schema
      end
  end
end
