# frozen_string_literal: true

require_relative "testing/request_case"

module ParamsSchema
  # Generates inputs for request tests, using any test framework.
  #
  # Load with `require "params_schema/testing"`. Supply expectations from the
  # endpoint's requirements and send each input in a separate request test.
  #
  # Use {request_cases} to vary one nested field, then assert the endpoint's
  # response and effects with your test framework's normal assertions.
  # @see file:docs/test_support.md
  module Testing
    # @private
    UNSPECIFIED = Object.new.freeze
    private_constant :UNSPECIFIED

    # Generates variations at one path in baseline request parameters.
    #
    # Select integer boundaries, field omission, explicit nil, or concrete input
    # cases. Each option adds its cases; omitted options add none. Supply at least
    # one option that generates a case. {RequestCase#valid?} and
    # {RequestCase#error_code} describe the expectations supplied here.
    #
    # | Option | Omitted | false | true |
    # | --- | --- | --- | --- |
    # | required | No omission case | Omission is accepted | Omission fails with :missing |
    # | allow_nil | No nil case | Nil fails with :nil_not_allowed | Nil is accepted |
    #
    # An integer range contributes its included endpoints and the
    # integers immediately outside it. Open-ended and exclusive ranges work too.
    # Use `representation: :string` for decimal string boundaries. This expects
    # in-range strings to be valid; use integer values for a strict JSON integer
    # field.
    #
    # @param path [Array<String, Symbol, Integer>] field names and zero-based
    #   array indexes; a numeric string addresses a Hash key
    # @param required [Boolean] add an omitted-field case; true expects :missing.
    #   Available for paths ending in a field name
    # @param allow_nil [Boolean] add a nil case; false expects :nil_not_allowed.
    #   Rails normally removes nil array elements before parameter validation
    # @param integer [Range<Integer>, nil] integer range to exercise
    # @param representation [:integer, :string] representation of boundary values
    # @param cases [Array<Hash>] explicit inputs, each with :value and an optional
    #   :error_code (Symbol); absent or nil error_code expects success
    # @return [Array<RequestCase>] a frozen array of frozen cases; pass your
    #   baseline request parameters to each case's {RequestCase#params} method
    # @raise [ArgumentError] for invalid paths, options, or empty ranges
    # @example Generate cases for a JSON request spec
    #   cases = ParamsSchema::Testing.request_cases(
    #     path: [:user, :age], integer: 0..150, required: false, allow_nil: false
    #   )
    #   cases.first.params(user: { name: "Ada", age: 27 })
    #   # => { user: { name: "Ada", age: 0 } }
    # @example Test a scalar array element
    #   cases = ParamsSchema::Testing.request_cases(path: [:order, :tag_ids, 1], integer: 1..100)
    #   cases.first.params(order: { tag_ids: [2, 3] })
    #   # => { order: { tag_ids: [2, 1] } }
    # @example Test an array field that requires at least one element
    #   ParamsSchema::Testing.request_cases(path: [:order, :items], cases: [
    #     { value: {}, error_code: :invalid_array },
    #     { value: [], error_code: :too_few_items }
    #   ])
    def self.request_cases(path:, required: UNSPECIFIED, allow_nil: UNSPECIFIED, integer: nil, representation: :integer, cases: [])
      check_boolean(:required, required)
      check_boolean(:allow_nil, allow_nil)
      unless [ :integer, :string ].include?(representation)
        raise ArgumentError, "representation must be :integer or :string"
      end
      if representation == :string && !integer
        raise ArgumentError, "string representation requires an integer range"
      end

      samples = integer.nil? ? [] : integer_cases(path, integer, representation)
      unless required.equal?(UNSPECIFIED)
        samples << RequestCase.new(path, "omitted", nil, required ? :missing : nil, omitted: true)
      end
      unless allow_nil.equal?(UNSPECIFIED)
        samples << RequestCase.new(path, "explicit nil", nil, allow_nil ? nil : :nil_not_allowed)
      end
      samples.concat(explicit_cases(path, cases))
      raise ArgumentError, "supply integer, required, allow_nil, or nonempty cases" if samples.empty?

      samples.freeze
    end

    class << self
      private
        # @private
        def check_boolean(name, value)
          return if value.equal?(UNSPECIFIED) || value.equal?(true) || value.equal?(false)

          raise ArgumentError, "#{name} must be a boolean"
        end

        # @private
        def integer_cases(path, integer, representation)
          minimum, maximum = integer_bounds(integer)
          boundaries = [ minimum, maximum ].compact.uniq
          outside = [ minimum && (minimum - 1), maximum && (maximum + 1) ].compact.uniq
          boundaries.map do |value|
            input = representation == :string ? value.to_s : value
            RequestCase.new(path, "boundary #{input.inspect}", input)
          end + outside.map do |value|
            input = representation == :string ? value.to_s : value
            RequestCase.new(path, "outside range #{input.inspect}", input, :not_included)
          end
        end

        # @private
        def explicit_cases(path, cases)
          raise ArgumentError, "cases must be an Array" unless Array === cases

          cases.map do |sample|
            unless Hash === sample && sample.key?(:value) && (sample.keys - [ :value, :error_code ]).empty? &&
                (sample[:error_code].nil? || Symbol === sample[:error_code])
              raise ArgumentError, "each case needs value: and an optional Symbol error_code:"
            end
            RequestCase.new(path, "value #{sample[:value].inspect}", sample[:value], sample[:error_code])
          end
        end

        # @private
        def integer_bounds(range)
          unless Range === range && [ range.begin, range.end ].all? { |value| value.nil? || Integer === value } &&
              (range.begin || range.end)
            raise ArgumentError, "integer must be a range with integer endpoints and at least one bound"
          end
          minimum = range.begin
          maximum = range.end && (range.end - (range.exclude_end? ? 1 : 0))
          raise ArgumentError, "integer range must not be empty" if minimum && maximum && minimum > maximum

          [ minimum, maximum ]
        end
    end
  end
end
