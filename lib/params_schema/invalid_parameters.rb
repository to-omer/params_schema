# frozen_string_literal: true

module ParamsSchema
  # One input validation failure, mapped to HTTP 400 by Action Dispatch by default.
  #
  # Inspect {#code} for the kind of failure and {#path} for its location. Use a
  # controller's `rescue_from` handler to choose the application's response.
  #
  # The exception's message and inspect output include the fixed code, without
  # input values or paths.
  #
  # @example Handle an invalid request
  #   rescue_from ParamsSchema::InvalidParameters do |error|
  #     render json: { error: error.code }, status: :bad_request
  #   end
  class InvalidParameters < StandardError
    # The location of the invalid value, starting at the root of the parsed input.
    #
    # Keys are frozen strings; array indices are zero-based integers from the
    # input passed to `parse`, before any empty-string removal. Request input
    # already reflects Rails normalization, including removal of null array elements
    # by default.
    # Invalid key types or invalid byte sequences point to the containing object,
    # map, or hash. An encoding mismatch with a map's `keys:` pattern points to
    # that key, as do unknown or ambiguous keys. When several values are invalid,
    # parsing stops at the first failure detected; error order is not guaranteed.
    #
    # Dynamic keys can contain private data. Check what the path contains before
    # logging it or including it in a response.
    #
    # @return [Array<String, Integer>] a frozen path, such as ["items", 0, "name"]
    attr_reader :path

    # The stable classification of the input error.
    #
    # | Code | Condition |
    # | --- | --- |
    # | missing | A required key is absent |
    # | invalid_string, invalid_integer, invalid_float, invalid_boolean, invalid_scalar | Invalid scalar type or representation |
    # | invalid_uploaded_file | A value is not a supported upload object |
    # | invalid_object, invalid_array, invalid_map, invalid_hash | A container has the wrong shape |
    # | empty_object | With reject_empty enabled, an object has no supplied declared fields, or a :hash has no entries |
    # | invalid_collection | A collection is neither an Array nor a Hash/Parameters |
    # | invalid_encoding | An input or key has invalid or incompatible encoding |
    # | invalid_key | A key is neither a string nor a symbol |
    # | ambiguous_key | String and symbol keys normalize to the same key |
    # | nil_not_allowed | A value is nil where nil is not allowed |
    # | not_included | A converted value is outside its enumeration or range |
    # | invalid_format | A string does not match its pattern |
    # | invalid_map_key | A map key does not match its pattern, or a collection uses the reserved outer key "id" |
    # | value_too_short, value_too_long | A string violates its byte length bounds |
    # | too_few_items, too_many_items | An array, map, collection, or one_or_many field violates its size bounds |
    # | integer_too_long | An integer string exceeds 256 bytes |
    # | float_too_long | A float string exceeds 256 bytes |
    # | unknown_parameter | An object with unknown: :reject contains an undeclared key |
    # | pattern_timeout | A regular expression exceeds its timeout |
    # | nesting_too_deep | A :hash value contains more than 32 levels of nesting |
    #
    # @return [Symbol] an error code
    attr_reader :code

    # @private
    def initialize(path, code)
      @path = path.map { |part| String === part ? String.new(part).freeze : part }.freeze
      @code = code
      # Keep input-derived keys out of the exception message.
      super("invalid parameters: #{code}")
    end
  end
end
