# frozen_string_literal: true

require "bigdecimal"

module ParamsSchema
  # @private
  class Parser
    SCALAR_RULE = Rule.new(:scalar, { allow_nil: true }.freeze, nil, 0)
    private_constant :SCALAR_RULE

    def initialize(native: false)
      @native = native
    end

    def call(raw, rule, path = [])
      # A single selection uses the container's nil policy, including after coercion.
      empty_rule = rule.type == :one_or_many ? rule.children : rule
      raw = nil if !@native && empty_rule.options[:empty_string_to_nil] && empty_string?(raw)
      if NilClass === raw
        fail_at(path, :nil_not_allowed) unless rule.options[:allow_nil]
        return nil
      end
      raise ArgumentError, "uploaded files cannot be schema constants" if @native && uploaded_file?(raw)

      case rule.type
      when :object, :map
        parse_hash(raw, rule, path)
      when :hash
        data = hash_source(raw, path, :hash)
        fail_at(path, :empty_object) if data.empty? && rule.options[:reject_empty]
        free_value(data, path, 0)
      when :array
        parse_array(raw, rule, path)
      when :collection
        Array === raw ? parse_array(raw, rule, path) : parse_hash(raw, rule, path)
      when :one_or_many
        if Array === raw
          parse_array(raw, rule, path)
        else
          check_size(1, rule, path)
          call(raw, rule.children, path)
        end
      else
        result = leaf(raw, rule, path)
        owned(result)
      end
    end

    private
      def leaf(raw, rule, path)
        options, type = rule.options, rule.type
        coerce = !@native && options.fetch(:coerce, true)
        check_string(raw, type, options, path, coerce) if String === raw
        result = convert_leaf(raw, type, path, coerce)

        if options.key?(:in)
          domain = options[:in]
          member = Range === domain ? domain.cover?(result) : domain.key?(result)
          fail_at(path, :not_included) unless member
        end
        check_pattern(options[:format], result, path, :invalid_format) if options.key?(:format)
        result
      end

      def parse_hash(raw, rule, path)
        data = hash_source(raw, path, rule.type)
        check_size(data.size, rule, path) unless rule.type == :object
        index = index_hash(data, path)
        rule.type == :object ? object(index, rule, path) : map(index, rule, path)
      end

      def free_value(raw, path, depth)
        fail_at(path, :nesting_too_deep) if depth > MAX_DEPTH
        case raw
        when Hash, ActionController::Parameters
          index = index_hash(hash_source(raw, path, :hash), path)
          index.each_pair { |key, value| index[key] = free_value(value, path + [ key ], depth + 1) }
        when Array
          raw.each_with_index.map { |value, i| free_value(value, path + [ i ], depth + 1) }
        else
          call(raw, SCALAR_RULE, path)
        end
      end

      def parse_array(raw, rule, path)
        fail_at(path, :invalid_array) unless Array === raw
        drop_empty_strings = rule.options[:drop_empty_strings]
        size = drop_empty_strings ? raw.count { |item| !empty_string?(item) } : raw.size
        check_size(size, rule, path)
        raw.each_with_index.each_with_object([]) do |(item, index), result|
          if drop_empty_strings && empty_string?(item)
            raise ArgumentError, "array defaults cannot contain empty strings when drop_empty_strings is enabled" if @native
            next
          end
          # Keep source indices even when a hidden form value is removed.
          result << call(item, rule.children, path + [ index ])
        end
      end

      def empty_string?(value)
        String === value && value.empty?
      end

      def check_string(raw, type, options, path, coerce)
        # Bound byte lengths before scanning the string for encoding or syntax.
        if %i[integer float].include?(type) && coerce && raw.bytesize > 256
          fail_at(path, :"#{type}_too_long")
        end
        if type == :string
          fail_at(path, :value_too_short) if raw.bytesize < options.fetch(:min_bytes, 0)
          fail_at(path, :value_too_long) if options.key?(:max_bytes) && raw.bytesize > options[:max_bytes]
        end
        fail_at(path, :invalid_encoding) unless raw.valid_encoding?
      end

      def convert_leaf(raw, type, path, coerce)
        case type
        when :string
          fail_at(path, :invalid_string) unless String === raw
          raw
        when :integer
          convert_integer(raw, path, coerce)
        when :float
          convert_float(raw, path, coerce)
        when :boolean
          convert_boolean(raw, path, coerce)
        when :scalar
          valid = String === raw || Integer === raw || TrueClass === raw || FalseClass === raw ||
            (Float === raw && raw.finite?) || uploaded_file?(raw)
          fail_at(path, :invalid_scalar) unless valid
          raw
        when :uploaded_file
          fail_at(path, :invalid_uploaded_file) unless uploaded_file?(raw)
          raw
        else
          raise ArgumentError, "scalar value rule expected"
        end
      end

      def uploaded_file?(value)
        ActionDispatch::Http::UploadedFile === value || Rack::Test::UploadedFile === value
      end

      def convert_integer(raw, path, coerce)
        return raw if Integer === raw

        fail_at(path, :invalid_integer) unless coerce && String === raw
        fail_at(path, :invalid_encoding) unless raw.encoding.ascii_compatible?
        check_pattern(INTEGER_PATTERN, raw, path, :invalid_integer)
        Integer(raw, 10)
      end

      def convert_boolean(raw, path, coerce)
        return raw if TrueClass === raw || FalseClass === raw

        fail_at(path, :invalid_boolean) unless coerce && String === raw
        fail_at(path, :invalid_encoding) unless raw.encoding.ascii_compatible?
        BOOLEAN_TEXT.fetch(raw) { fail_at(path, :invalid_boolean) }
      end

      def convert_float(raw, path, coerce)
        result = if Float === raw
          raw
        elsif coerce && Integer === raw
          decimal_float(raw)
        elsif coerce && String === raw
          fail_at(path, :invalid_encoding) unless raw.encoding.ascii_compatible?
          check_pattern(FLOAT_PATTERN, raw, path, :invalid_float)
          decimal_float(raw)
        end
        fail_at(path, :invalid_float) unless result && result.finite?
        result
      end

      def decimal_float(raw)
        # BigDecimal bundled with Ruby 3.2 requires a digit after the decimal point.
        raw = raw.sub(/\.(?=[eE]|\z)/, ".0") if String === raw
        # Kernel.Float warns with the input on overflow. BigDecimal lets us
        # classify the result ourselves and restores its thread-local settings.
        BigDecimal.save_exception_mode do
          BigDecimal.mode(BigDecimal::EXCEPTION_ALL, false)
          BigDecimal(raw).to_f
        end
      end

      def hash_source(raw, path, type)
        if ActionController::Parameters === raw
          # Internal Rails boundary: public readers may replace nested input values.
          raw.__send__(:parameters)
        elsif Hash === raw
          raw
        else
          fail_at(path, :"invalid_#{type}")
        end
      end

      def index_hash(data, path)
        index = {}
        data.each_pair do |key, item|
          fail_at(path, :invalid_key) unless String === key || Symbol === key
          key = key.name if Symbol === key
          fail_at(path, :invalid_encoding) unless key.valid_encoding?
          fail_at(path + [ key ], :ambiguous_key) if index.key?(key)
          index[String.new(key)] = item
        end
        index
      end

      def object(index, rule, path)
        result = {}
        index.each_pair do |name, raw|
          field = rule.children[name]
          unless field
            fail_at(path + [ name ], :unknown_parameter) if @native || rule.options[:unknown] == :reject
            next
          end

          child_path = path + [ name ]
          result[name] = call(raw, field.rule, child_path)
        end
        rule.options[:required_fields].each do |name|
          fail_at(path + [ name ], :missing) unless index.key?(name)
        end
        # Defaults cannot turn an empty submission into an accepted update.
        fail_at(path, :empty_object) if result.empty? && rule.options[:reject_empty]
        rule.options[:defaults].each_pair do |name, default|
          result[name] = copy_default(default) unless index.key?(name)
        end
        result
      end

      # Defaults were validated at construction; copy their mutable descendants.
      def copy_default(value)
        case value
        when Hash
          value.transform_values { |child| copy_default(child) }
        when Array
          value.map { |child| copy_default(child) }
        else
          owned(value)
        end
      end

      def map(index, rule, path)
        # Active Record treats an outer id key as one record, not a row identifier.
        fail_at(path + [ "id" ], :invalid_map_key) if rule.type == :collection && index.key?("id")
        pattern = rule.options[:keys]
        # The normalized index belongs to this parse, so its values can be replaced.
        index.each_pair do |key, raw|
          child_path = path + [ key ]
          check_pattern(pattern, key, child_path, :invalid_map_key) if pattern
          index[key] = call(raw, rule.children, child_path)
        end
      end

      def check_size(count, rule, path)
        options = rule.options
        fail_at(path, :too_few_items) if count < options.fetch(:min_size, 0)
        fail_at(path, :too_many_items) if options.key?(:max_size) && count > options[:max_size]
      end

      def check_pattern(pattern, value, path, code)
        fail_at(path, code) unless pattern.match?(value)
      rescue Encoding::CompatibilityError
        fail_at(path, :invalid_encoding)
      rescue Regexp::TimeoutError
        fail_at(path, :pattern_timeout)
      end

      def owned(value)
        String === value ? String.new(value) : value
      end

      def fail_at(path, code)
        ParamsSchema.invalid(path, code)
      end
  end
end
