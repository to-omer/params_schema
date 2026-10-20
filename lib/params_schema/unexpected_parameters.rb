# frozen_string_literal: true

module ParamsSchema
  # A parameter contract violation raised by {ParamsSchema::Schema#parse!}.
  #
  # Use `parse!` when invalid input indicates a bug in a controlled client.
  # Rails treats this exception as an unhandled error, with HTTP 500 as its
  # default response. An `InvalidParameters` handler does not catch it.
  class UnexpectedParameters < StandardError
    # @return [Array<String, Integer>] location of the invalid value;
    #   see {InvalidParameters#path} for the path format
    attr_reader :path

    # @return [Symbol] validation error code; see {InvalidParameters#code}
    attr_reader :code

    # @private
    def initialize(error)
      @path, @code = error.path, error.code
      super("unexpected parameters: #{code}")
    end
  end
end
