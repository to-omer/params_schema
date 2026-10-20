# frozen_string_literal: true

require_relative "invalid_parameters"
require_relative "unexpected_parameters"

# Validates and converts Rails parameters using declared types and constraints.
#
# Start with {ActionController::Parameters.schema}, then reuse the resulting
# {Schema} across requests. The schema block receives a {Builder}.
module ParamsSchema
  # @private
  UNSET = Object.new.freeze
  # @private
  MAX_DEPTH = 32
  # @private
  PATTERN_TIMEOUT = 0.05
  # @private
  INTEGER_PATTERN = /\A[+-]?[0-9]+\z/
  # @private
  FLOAT_PATTERN = /\A[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z/
  # @private
  BOOLEAN_TEXT = { "true" => true, "1" => true, "false" => false, "0" => false }.freeze
  # @private
  Field = Data.define(:rule, :required, :default)
  # @private
  Rule = Data.define(:type, :options, :children, :depth)

  # @private
  def self.invalid(path, code)
    raise ParamsSchema::InvalidParameters.new(path, code), cause: nil
  end
end

require_relative "schema"
require_relative "result"
require_relative "builder"
require_relative "parser"

module ParamsSchema
  private_constant :Rule, :Field, :Builder, :Parser
end
