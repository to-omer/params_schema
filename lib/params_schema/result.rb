# frozen_string_literal: true

module ParamsSchema
  # The result of {Schema#try_parse}: parsed parameters or a validation error.
  #
  # Check {#success?}, inspect {#error}, or call {#value!} to retrieve the output.
  class Result
    # The validation error, or nil on success.
    # @return [ParamsSchema::InvalidParameters, nil]
    attr_reader :error

    # @private
    def initialize(value, error)
      @value = value
      @error = error
      freeze
    end

    # Whether validation and conversion succeeded.
    # @return [Boolean]
    def success?
      @error.nil?
    end

    # Returns the saved output or re-raises the validation error.
    #
    # Repeated calls return the same saved output, which can be edited as with
    # the return value of {Schema#parse}.
    # @return [ActionController::Parameters] recursively permitted output
    # @raise [ParamsSchema::InvalidParameters] if validation failed
    def value!
      raise @error, cause: nil if @error

      @value
    end

    # Describes the outcome without exposing parameter values or paths.
    # @return [String]
    def inspect
      "#<#{self.class.name} #{success? ? 'success' : "failure: #{@error.code}"}>"
    end
  end
end
