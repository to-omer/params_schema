# frozen_string_literal: true

module ParamsSchema
  module Testing
    # One input variation and its expected classification from {Testing.request_cases}.
    #
    # Pass successful baseline parameters to {#params} to build the request input.
    # Use {#description} as the example name so a failure identifies the field,
    # input, and expected validity.
    class RequestCase
      # The location changed in the request input. It may differ from an error path
      # when validation fails within the replacement value or the application
      # parses only part of the request.
      # @return [Array<String, Integer>] frozen path of the changed input
      attr_reader :path
      # @return [Symbol, nil] expected validation error code, or nil for a valid case
      attr_reader :error_code
      # @return [String] example label including path and expected validity
      attr_reader :description

      # @private
      def initialize(path, name, value, error_code = nil, omitted: false)
        unless Array === path && !path.empty? && path.all? { |part| String === part || Symbol === part || (Integer === part && part >= 0) }
          raise ArgumentError, "path must contain field names or nonnegative array indexes"
        end
        raise ArgumentError, "required applies to a named field, not an array element" if omitted && Integer === path.last

        @path = path.map { |part| Integer === part ? part : part.to_s.dup.freeze }.freeze
        @value = copy(value)
        freeze_input(@value)
        @omitted = omitted
        @error_code = error_code
        @description = "#{@path.inspect}: #{name} (#{error_code || 'valid'})".freeze
        freeze
      end

      # Whether this case is expected to satisfy the supplied field conditions.
      #
      # @return [Boolean] the expectation supplied when generating this case
      def valid?
        error_code.nil?
      end

      # @return [Boolean] whether this case removes the field
      def omitted?
        @omitted
      end

      # @return [Object] replacement field value before HTTP encoding; hashes, arrays, and strings
      #   are recursively copied and frozen when the case is generated
      # @raise [KeyError] for an omitted field; use {#omitted?} to distinguish it
      def value
        raise KeyError, "#{path.inspect} is omitted" if omitted?

        @value
      end

      # Copies baseline request parameters and changes only the selected value.
      #
      # The baseline must contain the selected value and all its parent containers. A
      # missing, ambiguous, or incompatible path raises ArgumentError. Hashes,
      # arrays, and strings are copied recursively, including unchanged branches.
      # Other objects, such as uploaded files, remain shared.
      #
      # @param baseline [Hash] baseline request parameters
      # @return [Hash] a new parameter Hash with the selected value replaced,
      #   or the selected field removed for omission
      # @raise [ArgumentError] for a missing, ambiguous, or mismatched path
      def params(baseline)
        raise ArgumentError, "baseline must be a Hash" unless Hash === baseline

        root = copy(baseline)
        parent = path[0...-1].reduce(root) { |container, part| container.fetch(input_key(container, part)) }
        key = input_key(parent, path.last)
        if omitted?
          parent.delete(key)
        else
          parent[key] = copy(value)
        end
        root
      end

      private
        # @private
        def copy(value)
          case value
          when Hash
            value.dup.tap { |hash| value.each { |key, child| hash[key] = copy(child) } }
          when Array then value.map { |child| copy(child) }
          when String then value.dup
          else value
          end
        end

        # Freeze after copying: Hash subclasses can convert values on assignment.
        # @private
        def freeze_input(value)
          case value
          when Hash then value.each_value { |child| freeze_input(child) }
          when Array then value.each { |child| freeze_input(child) }
          when String then return value.freeze
          else return
          end
          value.freeze
        end

        # @private
        def input_key(container, part)
          if Hash === container && String === part
            keys = container.keys.select { |key| (String === key || Symbol === key) && key.to_s == part }
            return keys.first if keys.one?
          elsif Array === container && Integer === part && part < container.size
            return part
          end
          raise ArgumentError, "baseline path #{path.inspect} is missing, ambiguous, or has the wrong container type"
        end
    end
  end
end
