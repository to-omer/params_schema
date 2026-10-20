# frozen_string_literal: true

module ParamsSchema
  # Declares fields, types, and constraints inside a schema block.
  #
  # {ActionController::Parameters.schema} and container blocks yield a builder.
  #
  # ## Types and conversion
  #
  # Primitive types are :string, :integer, :float, :boolean, :scalar, and :uploaded_file.
  #
  # | Type | Accepted non-nil values |
  # | --- | --- |
  # | :string | Validly encoded strings; output is a new ordinary String |
  # | :integer | Integers; with coerce: true, decimal strings of at most 256 bytes matching the syntax below |
  # | :float | Finite floats; with coerce: true, integers and decimal strings of at most 256 bytes |
  # | :boolean | true and false; with coerce: true, "true", "false", "1", and "0" |
  # | :scalar | Validly encoded strings, integers, finite floats, true, false, and uploaded files |
  # | :uploaded_file | ActionDispatch::Http::UploadedFile or Rack::Test::UploadedFile |
  # | :hash | A Hash or Parameters containing nested hashes, arrays, scalar values, and nil |
  # | :object | A Hash or Parameters with fixed declared fields |
  # | :array | An Array whose elements share one rule |
  # | :map | A Hash or Parameters whose values share one rule |
  # | :collection | An Array or Hash/Parameters of objects, preserving its shape |
  # | :one_or_many | One primitive value or an Array of values with the same rule |
  #
  # With the default `coerce: true`, numeric and boolean types also accept the
  # string forms described above. These strings must have a valid ASCII-compatible
  # encoding. `coerce: false` accepts only Integer values for :integer, finite
  # Float values for :float, and true/false for :boolean.
  #
  # Integer strings must match `\A[+-]?[0-9]+\z` and be at most 256 bytes,
  # including the sign. Signs and leading zeroes are allowed; whitespace,
  # separators, and suffixes are rejected.
  # Float strings allow a sign, a decimal point, and an exponent: `"1.25"`,
  # `".5"`, and `"1e2"` become 1.25, 0.5, and 100.0. Whitespace, underscores,
  # hexadecimal notation, NaN, infinity, and overflow are rejected. Conversion
  # uses Ruby's Float precision; use strings when the application needs exact decimals.
  #
  # `:hash` accepts any field names within that value and preserves scalar values
  # without conversion. Contents may nest up to 32 levels below the hash itself,
  # counting each hash value or array element as one level.
  #
  # ## Options by type
  #
  # Every type accepts `allow_nil:`. Other supported options are:
  #
  # | Type | Options |
  # | --- | --- |
  # | :string | in, empty_string_to_nil, min_bytes, max_bytes, format, multiline |
  # | :integer, :float | in, coerce, empty_string_to_nil |
  # | :boolean | in, coerce, empty_string_to_nil |
  # | :scalar | in, empty_string_to_nil |
  # | :uploaded_file | allow_nil only |
  # | :hash | reject_empty |
  # | :object | unknown, reject_empty; requires a block |
  # | :array | of, min_size, max_size, drop_empty_strings; an object block can replace of and also accepts unknown |
  # | :map | of, min_size, max_size, keys, multiline; an object block can replace of and also accepts unknown |
  # | :collection | of (object rule), min_size, max_size; an object block can replace of and also accepts unknown |
  # | :one_or_many | of (primitive type/rule), min_size, max_size, drop_empty_strings |
  #
  # For array, map, and collection object blocks, `unknown:` controls undeclared fields
  # within each object. With `of:`, put this option on the object value rule.
  #
  # ### Nil and empty strings
  #
  # `allow_nil: true` accepts nil before checking the type or other constraints.
  # `empty_string_to_nil: true` converts exactly `""` to nil before value validation;
  # `allow_nil:` then decides whether to accept it. It is available for string,
  # integer, float, boolean, and scalar. For integer, float, and boolean, it also
  # applies with `coerce: false`; other non-nil values must already have the declared type.
  #
  # ### Allowed values
  #
  # `in:` checks the converted value. Array members must already have the
  # declared output type: `in: [1, 2]` for integers. Membership uses `eql?`.
  # Numeric ranges use `cover?`; beginless, endless, and exclusive ranges work.
  # Integer ranges require integer bounds; float ranges accept integer or finite float bounds.
  # Nil is controlled by `allow_nil:`, independently of `in:`. Uploaded files
  # cannot be enumeration members.
  #
  # ### Length and size
  #
  # Length and size bounds are nonnegative integers, with the minimum no
  # greater than the maximum. Minimums default to zero; omitted maximums
  # impose no upper bound. String lengths count bytes, not characters.
  #
  # ## Regular expressions
  #
  # `format:` and `keys:` patterns preserve their source, flags, and encoding.
  # Patterns starting with `^` or ending with an unescaped `$` require
  # `multiline: true`. This option allows line anchors and preserves the
  # regexp's flags. Use `\A` and `\z` for whole-string patterns.
  #
  # When the schema is built, each pattern uses its instance timeout if set,
  # or `Regexp.timeout` otherwise. A positive timeout is capped at 50 ms;
  # an unlimited timeout becomes 50 ms.
  # The schema keeps this setting even if the global timeout later changes.
  # Numeric syntax patterns use the current `Regexp.timeout`.
  # On a pattern timeout, {Schema#parse} raises {InvalidParameters}
  # with code `pattern_timeout`.
  #
  # ## Schema definitions
  #
  # Field names must be strings or symbols; symbols normalize to strings.
  # Duplicate normalized names and unsupported option combinations raise
  # ArgumentError when the schema is built. Definitions may nest up to 32 levels
  # below the root, counting each array element or map value as one level.
  #
  class Builder
    # @private
    OPTIONS = {
      string: %i[allow_nil in empty_string_to_nil min_bytes max_bytes format multiline],
      integer: %i[allow_nil in coerce empty_string_to_nil],
      float: %i[allow_nil in coerce empty_string_to_nil],
      boolean: %i[allow_nil in coerce empty_string_to_nil],
      scalar: %i[allow_nil in empty_string_to_nil],
      uploaded_file: %i[allow_nil],
      hash: %i[allow_nil reject_empty],
      object: %i[allow_nil unknown reject_empty],
      array: %i[allow_nil min_size max_size of unknown drop_empty_strings],
      map: %i[allow_nil min_size max_size of unknown keys multiline],
      collection: %i[allow_nil min_size max_size of unknown],
      one_or_many: %i[allow_nil min_size max_size of drop_empty_strings]
    }.transform_values(&:freeze).freeze

    # @private
    def initialize
      @fields = {}
    end

    # Defines a value rule to reuse in fields and containers.
    #
    # Pass the rule to {#param} or as a container's `of:` option:
    #
    # ```ruby
    # ActionController::Parameters.schema do |schema|
    #   id = schema.value(:integer, in: 1..)
    #   schema.param :owner_id, id, required: true
    #   schema.array :ids, of: id, max_size: 100
    # end
    # ```
    #
    # @param type [Symbol, Object] a supported type, or a previously built
    #   value rule; reused rules accept neither extra options nor a block
    # @param options [Hash] options supported by the selected type
    # @option options [Boolean] :allow_nil (false) when true, accept nil and skip remaining checks for that value
    # @option options [Array, Range] :in allowed values after conversion; an array
    #   for string, integer, float, boolean, or scalar, or a numeric range with
    #   at least one bound. An empty array rejects every non-nil value
    # @option options [Boolean] :coerce (true) accept the documented numeric and
    #   boolean string forms, and integers for float; false requires the output type
    # @option options [Boolean] :empty_string_to_nil (false) convert exactly "" to nil for string, integer,
    #   float, boolean, or scalar before value validation; obeys allow_nil and
    #   applies independently of coerce. Defaults are not converted
    # @option options [Integer] :min_bytes (0) minimum string bytesize
    # @option options [Integer] :max_bytes maximum string bytesize
    # @option options [Regexp] :format string pattern
    # @option options [Boolean] :multiline (false) allow line anchors in
    #   format or keys; requires one of those patterns
    # @option options [:drop, :reject] :unknown (:drop) omit undeclared object
    #   fields from the output, or reject them with :unknown_parameter
    # @option options [Boolean] :reject_empty when true, reject an object with no
    #   supplied declared fields, or a :hash with no entries, using :empty_object.
    #   Defaults to true for required object/hash fields, false otherwise.
    #   Object fields are checked before adding child defaults. See {#object}
    # @option options [Symbol, Object] :of element/value rule; collection requires
    #   an object rule, one_or_many a primitive type/rule. Array, map, and collection
    #   also accept an object block instead of of:
    # @option options [Integer] :min_size (0) minimum element/entry count;
    #   one_or_many counts a non-nil single value as one
    # @option options [Integer] :max_size maximum element/entry count
    # @option options [Boolean] :drop_empty_strings (false) remove empty strings from
    #   an array before size and element validation; error paths keep input indices
    # @option options [Regexp] :keys pattern for every normalized map key
    # @yield [object] declares fields for an object or for object elements/values
    # @yieldparam object [ParamsSchema::Builder] the nested declaration DSL
    # @return [Object] a value rule for {#param} or the `of:` option
    # @raise [ArgumentError] for unsupported types/options, missing or conflicting
    #   blocks, invalid constants, invalid length/size bounds, or excessive depth
    # @example Reuse an array rule in nested containers
    #   groups = ActionController::Parameters.schema do |s|
    #     id = s.value(:integer, in: 1..)
    #     ids = s.value(:array, of: id, min_size: 1)
    #     s.array :groups, of: ids
    #     s.map :groups_by_name, of: ids, keys: /\A[a-z]+\z/
    #   end
    #   groups.parse(groups: [ [ "1", "2" ] ], groups_by_name: { editors: [ "3" ] }).to_h
    #   # => { "groups" => [ [ 1, 2 ] ], "groups_by_name" => { "editors" => [ 3 ] } }
    def value(type, **options, &block)
      if Rule === type
        raise ArgumentError, "put value options in the value rule" unless options.empty? && !block
        return type
      end
      allowed = OPTIONS[type]
      raise ArgumentError, "unknown value type" unless allowed
      check_options(options, allowed)
      children = build_children(type, options, &block)
      compile_pattern!(type, options)
      options[:in] = enumeration(type, options[:in]) if options.key?(:in)

      Rule.new(type, options.freeze, children, rule_depth(type, children))
    end

    # Declares a named field using a type or reusable value rule.
    #
    # `required: true` requires the key to exist. For an object or :hash rule, it also defaults
    # `reject_empty` to true unless that rule explicitly sets it to false.
    # Other types keep their own value constraints; false, empty strings, and empty
    # arrays count as present.
    # Defaults apply only when the key is missing. A present value, including nil
    # or an empty container, is processed by the value rule rather than replaced
    # by a default.
    #
    # | Field definition | Missing key | Explicit nil |
    # | --- | --- | --- |
    # | Optional, without a default | Omitted from output | Accepted only with allow_nil: true |
    # | Optional, with a default | Default value | Accepted only with allow_nil: true |
    # | required: true | :missing error | Accepted only with allow_nil: true |
    #
    # A default must satisfy the value rule without coercion. Use a Hash or
    # Parameters for object, map, or hash defaults, and an Array for array defaults.
    # Collection defaults accept either form; one_or_many defaults accept a
    # primitive value or Array. Each keeps the supplied shape.
    # Defaults are checked when the schema is built and copied for each parse,
    # including nested strings and containers.
    #
    # Object defaults reject undeclared keys and apply child defaults.
    # With `reject_empty: true`, an object default must supply a
    # declared field before child defaults are added.
    # Use `default: nil` with `allow_nil: true` to produce nil for
    # a missing field. Uploaded file objects cannot appear in defaults.
    #
    # Pass a primitive type, :hash, a container type with `of:`, or a rule from {#value}.
    # For object fields, use {#object} or pass an object rule built with a block.
    # For :hash, `reject_empty` checks the whole field; nested empty hashes are accepted.
    #
    # @param name [String, Symbol] a validly encoded field name
    # @param type [Symbol, Object] a primitive type, :hash, a container type with `of:`, or a
    #   rule returned by {#value}
    # @param required [Boolean] false makes the field optional; true requires the key
    # @param default [Object] value for a missing field, already satisfying the
    #   declared types and constraints; cannot be combined with required: true
    #   or contain uploaded file objects
    # @param options [Hash] value options from {#value} when passing a type name;
    #   place these on the rule itself when passing a reusable rule
    # @return [nil]
    # @raise [ArgumentError] for invalid definitions, defaults, or any block
    # @example Distinguish missing fields from explicit nil
    #   labels = ActionController::Parameters.schema do |s|
    #     s.param :label, :string, default: "new", allow_nil: true, max_bytes: 20
    #   end
    #   labels.parse({}).to_h           # => { "label" => "new" }
    #   labels.parse(label: nil).to_h   # => { "label" => nil }
    # @example Accept metadata with application-defined keys and structure
    #   input = ActionController::Parameters.schema do |s|
    #     s.param :metadata, :hash
    #   end
    #   input.parse(metadata: { crm: { tags: ["new"], score: "3" } }).to_h
    #   # => { "metadata" => { "crm" => { "tags" => ["new"], "score" => "3" } } }
    def param(name, type, required: false, default: UNSET, **options, &block)
      raise ArgumentError, "param does not accept a block" if block
      rule = value(type, **options)
      add(name, rule, required, default)
    end

    # Declares a named object with fixed child fields.
    #
    # Accepts a Hash or Parameters and validates its declared children.
    # `required: true` requires the object's key and defaults `reject_empty` to true.
    # `reject_empty: true` rejects an object with no supplied declared fields,
    # after filtering unknown keys and before adding child defaults.
    # Missing required children are reported before the empty-object check.
    # A supplied field with an accepted nil, false, or empty container makes the
    # object nonempty. Set `reject_empty: false` to allow an empty required object.
    # Each nested object applies its own empty-object policy.
    # Without its own default, a missing optional object stays absent even when
    # its children have defaults.
    #
    # @param name [String, Symbol] the field name
    # @param required [Boolean] false makes the object optional; true requires its key
    #   and defaults reject_empty to true
    # @param default [Hash, ActionController::Parameters, nil] value for an omitted
    #   object; must satisfy its fields and constraints; see {#param}
    # @param options [Hash] object options
    # @option options [Boolean] :allow_nil (false) accept nil for the object itself
    # @option options [:drop, :reject] :unknown (:drop) omit undeclared children
    #   from output, or reject them with :unknown_parameter
    # @option options [Boolean] :reject_empty when true, reject an object with no
    #   supplied declared fields using error code :empty_object; defaults to required
    # @yield [object] declares the child fields; a block is required
    # @yieldparam object [ParamsSchema::Builder] the nested declaration DSL
    # @return [nil]
    # @raise [ArgumentError] for invalid definitions or a missing block
    # @example Validate a fixed set of nested fields
    #   search = ActionController::Parameters.schema do |s|
    #     s.object :filter, reject_empty: true, unknown: :reject do |filter|
    #       filter.param :query, :string, max_bytes: 100
    #       filter.param :archived, :boolean, default: false
    #     end
    #   end
    #   search.parse(filter: { query: "example" }).to_h
    #   # => { "filter" => { "query" => "example", "archived" => false } }
    #   error = search.try_parse(filter: {}).error
    #   [error.code, error.path] # => [:empty_object, ["filter"]]
    def object(name, required: false, default: UNSET, **options, &block)
      add(name, value(:object, **options, &block), required, default)
    end

    # Declares an array whose elements all satisfy one rule.
    #
    # Accepts an Array and retains its element order. Invalid elements
    # fail the parse at the element's path. Element nil handling belongs
    # to the `of:` rule, independently of `allow_nil` on the array itself.
    # Use `default: []` to produce an empty array when the field is omitted.
    # Defaults must satisfy the array's size and element rules without coercion.
    #
    # `drop_empty_strings: true` removes exactly the empty string, as submitted by a
    # multi-select's hidden control. Size bounds count the remaining elements.
    # Nil, false, zero, and whitespace strings remain subject to the element rule.
    # Error paths use indices from the input passed to `parse`, before removal.
    # Array defaults must already be free of empty strings when this option is enabled.
    #
    # @param name [String, Symbol] the field name
    # @param required [Boolean] false makes the array optional; true requires its key
    # @param default [Array, nil] value for an omitted array; see {#param} for
    #   validation and copying
    # @param options [Hash] array options
    # @option options [Boolean] :allow_nil (false) accept nil for the array itself
    # @option options [Integer] :min_size (0) minimum number of elements
    # @option options [Integer] :max_size maximum number of elements; omitted means unbounded
    # @option options [Boolean] :drop_empty_strings (false) remove empty string elements
    #   before validating size and values
    # @option options [Symbol, Object] :of element type or value rule; required
    #   when no block is supplied, and cannot be combined with a block
    # @option options [:drop, :reject] :unknown (:drop) omit or reject undeclared
    #   fields in object elements; available only with a block
    # @yield [element] declares object elements; supply either a block or of:
    # @yieldparam element [ParamsSchema::Builder] the element's declaration DSL
    # @return [nil]
    # @raise [ArgumentError] for invalid definitions or conflicting/missing element rules
    # @example Allow nil elements independently from a nil array
    #   lists = ActionController::Parameters.schema do |s|
    #     s.array :ids, of: s.value(:integer, allow_nil: true)
    #     s.array :optional_ids, of: :integer, allow_nil: true
    #   end
    #   lists.parse(ids: [ nil, "4" ], optional_ids: nil).to_h
    #   # => { "ids" => [ nil, 4 ], "optional_ids" => nil }
    def array(name, required: false, default: UNSET, **options, &block)
      add(name, value(:array, **options, &block), required, default)
    end

    # Declares a map with dynamic keys and one rule shared by all values.
    #
    # Accepts a Hash or Parameters. String and symbol keys normalize to strings.
    # Keys such as "02" and "2" remain distinct; entry order and count are preserved.
    # Every key must match `keys:` when supplied; every value must satisfy its rule.
    # Nil handling for map values belongs to `of:`, independently of `allow_nil`
    # on the map itself.
    #
    # @param name [String, Symbol] the field name
    # @param required [Boolean] false makes the map optional; true requires its key
    # @param default [Hash, ActionController::Parameters, nil] value for an omitted
    #   map; must satisfy the key, size, and value rules; see {#param}
    # @param options [Hash] map options
    # @option options [Boolean] :allow_nil (false) accept nil for the map itself
    # @option options [Integer] :min_size (0) minimum number of entries
    # @option options [Integer] :max_size maximum number of entries; omitted means unbounded
    # @option options [Symbol, Object] :of value type or reusable value rule; required
    #   when no block is supplied, and cannot be combined with a block
    # @option options [:drop, :reject] :unknown (:drop) omit or reject undeclared
    #   fields in object values; available only with a block
    # @option options [Regexp] :keys pattern for each normalized key; omitted means
    #   any valid string or symbol key is accepted
    # @option options [Boolean] :multiline (false) allow line anchors in keys:;
    #   requires keys:
    # @yield [value] declares object values; supply either a block or of:
    # @yieldparam value [ParamsSchema::Builder] the value's declaration DSL
    # @return [nil]
    # @raise [ArgumentError] for invalid definitions or conflicting/missing value rules
    # @see Builder Types, constraints, and pattern timeouts
    # @example Preserve numbered keys while validating each object
    #   rows = ActionController::Parameters.schema do |s|
    #     s.map :rows, keys: /\A[0-9]+\z/, max_size: 100 do |row|
    #       row.param :name, :string, required: true
    #     end
    #   end
    #   rows.parse(rows: { "02" => { name: "Ada" } }).to_h
    #   # => { "rows" => { "02" => { "name" => "Ada" } } }
    def map(name, required: false, default: UNSET, **options, &block)
      add(name, value(:map, **options, &block), required, default)
    end

    # Declares object rows supplied as an Array or a Hash/Parameters.
    #
    # Output keeps the input's form, order, and row count. Row keys must be strings
    # or symbols and normalize to strings. Names such as "02" and "new_item" are preserved.
    #
    # The outer key "id" is rejected with :invalid_map_key because Active Record interprets that Hash
    # as a single record's attributes. Row objects can declare their own id field.
    #
    # Every row is validated. Errors retain the original string key or zero-based
    # array index in their path.
    # Nil rows follow the object rule's allow_nil setting; a block declares
    # non-nullable rows. The collection's allow_nil setting controls the whole field.
    #
    # @param name [String, Symbol] the field name
    # @param required [Boolean] false makes the field optional; true requires its key
    # @param default [Array, Hash, ActionController::Parameters, nil] value for an
    #   omitted collection; must satisfy its rules without coercion; see {#param}
    # @param options [Hash] collection options
    # @option options [Boolean] :allow_nil (false) accept nil for the collection itself
    # @option options [Integer] :min_size (0) minimum number of rows, in either form
    # @option options [Integer] :max_size maximum number of rows; omitted means unbounded
    # @option options [Object] :of an object rule from value(:object);
    #   supply this option or an object block, never both
    # @option options [:drop, :reject] :unknown (:drop) omit or reject undeclared
    #   fields within rows; available only with a block
    # @yield [row] declares each object's fields
    # @yieldparam row [ParamsSchema::Builder] the row's declaration DSL
    # @return [nil]
    # @raise [ArgumentError] for invalid definitions or a non-object rule
    # @see file:docs/forms.md Nested attributes for Active Record
    # @example Preserve numbered form rows and JSON arrays
    #   input = ActionController::Parameters.schema do |s|
    #     s.collection :items_attributes do |item|
    #       item.param :id, :scalar
    #       item.param :_destroy, :scalar
    #     end
    #   end
    #   input.parse(items_attributes: { "02" => { id: "7", _destroy: "1" } }).to_h
    #   # => { "items_attributes" => { "02" => { "id" => "7", "_destroy" => "1" } } }
    #   input.parse(items_attributes: [ { id: "7", _destroy: "1" } ]).to_h
    #   # => { "items_attributes" => [ { "id" => "7", "_destroy" => "1" } ] }
    def collection(name, required: false, default: UNSET, **options, &block)
      add(name, value(:collection, **options, &block), required, default)
    end

    # Declares a primitive value accepted singly or as an Array.
    #
    # The element rule must use :string, :integer, :float, :boolean, :scalar,
    # or :uploaded_file.
    #
    # The same rule validates the single value or each array element. Output keeps
    # that shape: "2" becomes 2 with of: :integer, while ["2"] becomes [2].
    # Size bounds count a non-nil single value as one and an Array by its length.
    # An empty array is accepted when min_size is zero. `drop_empty_strings: true`
    # removes empty strings from an Array before validation, preserving input
    # indices in errors. `drop_empty_strings:` does not affect single values;
    # the `of:` rule still applies.
    #
    # `allow_nil:` controls nil for the whole field. Nil inside an Array is
    # controlled by the `of:` rule, independently of the field's setting.
    # This also applies when the element rule uses `empty_string_to_nil: true`:
    # a single empty string follows the field's nil policy; empty strings left
    # in the Array follow the element's nil policy.
    #
    # @param name [String, Symbol] the field name
    # @param required [Boolean] false makes the field optional; true requires its key
    # @param default [Object] value for an omitted field, satisfying the rules
    #   without coercion; see {#param}
    # @param options [Hash] value/array options
    # @option options [Symbol, Object] :of required primitive type or primitive value rule
    # @option options [Boolean] :allow_nil (false) accept nil for the whole field
    # @option options [Integer] :min_size (0) minimum number of values
    # @option options [Integer] :max_size maximum number of values; omitted means unbounded
    # @option options [Boolean] :drop_empty_strings (false) remove empty strings from
    #   array input before validating size and values
    # @return [nil]
    # @raise [ArgumentError] for a block, a non-primitive rule, or invalid options
    # @example Accept one label or an array of labels
    #   input = ActionController::Parameters.schema do |s|
    #     s.one_or_many :selection, of: :string
    #   end
    #   input.parse(selection: "red").to_h # => { "selection" => "red" }
    #   input.parse(selection: ["red", "blue"]).to_h # => { "selection" => ["red", "blue"] }
    def one_or_many(name, required: false, default: UNSET, **options, &block)
      add(name, value(:one_or_many, **options, &block), required, default)
    end

    protected
      # @private
      attr_reader :fields

    private
      # @private
      def build_children(type, options, &block)
        case type
        when :object
          raise ArgumentError, "object requires a block" unless block
          builder = self.class.new
          block.call(builder)
          fields = builder.fields.freeze
          # Missing optional fields need no work, even in a large sparse schema.
          options[:required_fields] = fields.select { |_, field| field.required }.keys.freeze
          options[:defaults] = fields.reject { |_, field| field.default.equal?(UNSET) }.transform_values(&:default).freeze
          fields
        when :array, :map
          build_element(options, &block)
        when :collection
          child = build_element(options, &block)
          raise ArgumentError, "collection requires an object rule" unless child.type == :object
          child
        when :one_or_many
          raise ArgumentError, "one_or_many does not accept a block" if block
          child = build_element(options)
          unless %i[string integer float boolean scalar uploaded_file].include?(child.type)
            raise ArgumentError, "one_or_many requires a primitive rule"
          end
          child
        else
          raise ArgumentError, "value does not accept a block" if block
          nil
        end
      end

      # @private
      def build_element(options, &block)
        raise ArgumentError, "choose of: or an object block" unless options.key?(:of) ^ !!block
        if block
          value(:object, unknown: options.delete(:unknown) { :drop }, &block)
        else
          raise ArgumentError, "unknown: requires an object block" if options.key?(:unknown)
          value(options.delete(:of))
        end
      end

      # @private
      def compile_pattern!(type, options)
        key = type == :map ? :keys : :format
        if options.key?(:multiline) && !options.key?(key)
          raise ArgumentError, "multiline: requires a regular expression"
        end
        options[key] = pattern(options[key], options.delete(:multiline) { false }) if options.key?(key)
      end

      # @private
      def enumeration(type, domain)
        if Range === domain
          validate_range(type, domain)
          Range.new(domain.begin, domain.end, domain.exclude_end?)
        elsif Array === domain
          native_rule = Rule.new(type, {}.freeze, nil, 0)
          # Hash membership preserves eql? and avoids a scan for every element.
          domain.to_h { |v| [ constant(native_rule, v), true ] }.freeze
        else
          raise ArgumentError, "in: requires an array or a numeric range"
        end
      end

      # @private
      def validate_range(type, domain)
        endpoints = [ domain.begin, domain.end ].compact
        valid = case type
        when :integer then endpoints.all? { |v| Integer === v }
        when :float then endpoints.all? { |v| Integer === v || (Float === v && v.finite?) }
        else false
        end
        raise ArgumentError, "range bounds must match the numeric type" unless valid && !endpoints.empty?
      end

      # @private
      def rule_depth(type, children)
        depth = case type
        when :object then children.empty? ? 0 : 1 + children.values.map { |field| field.rule.depth }.max
        when :array, :map, :collection, :one_or_many then 1 + children.depth
        else 0
        end
        raise ArgumentError, "schema nesting exceeds #{MAX_DEPTH}" if depth > MAX_DEPTH
        depth
      end

      # @private
      def add(name, rule, required, default)
        unless TrueClass === required || FalseClass === required
          raise ArgumentError, "required must be true or false"
        end
        unless String === name || Symbol === name
          raise ArgumentError, "parameter name must be a String or Symbol"
        end
        name = String.new(Symbol === name ? name.name : name)
        raise ArgumentError, "invalid name encoding" unless name.valid_encoding?
        raise ArgumentError, "duplicate parameter declaration" if @fields.key?(name)
        if required && %i[object hash].include?(rule.type) && !rule.options.key?(:reject_empty)
          rule = rule.with(options: rule.options.merge(reject_empty: true).freeze)
        end
        unless default.equal?(UNSET)
          raise ArgumentError, "default requires an optional parameter" if required
          default = constant(rule, default)
        end
        @fields[name.freeze] = Field.new(rule, required, default)
        nil
      end

      # @private
      def check_options(options, allowed)
        extra = options.keys - allowed
        raise ArgumentError, "unsupported options: #{extra.join(', ')}" unless extra.empty?
        options.each do |key, v|
          case key
          when :allow_nil, :reject_empty, :coerce, :multiline, :drop_empty_strings, :empty_string_to_nil
            raise ArgumentError, "#{key} must be true or false" unless TrueClass === v || FalseClass === v
          when :min_bytes, :max_bytes, :min_size, :max_size
            raise ArgumentError, "#{key} must be a nonnegative integer" unless Integer === v && v >= 0
          when :unknown
            raise ArgumentError, "unknown must be :drop or :reject" unless %i[drop reject].include?(v)
          end
        end
        [ [ :min_bytes, :max_bytes ], [ :min_size, :max_size ] ].each do |low, high|
          if options.key?(low) && options.key?(high) && options[low] > options[high]
            raise ArgumentError, "#{low} exceeds #{high}"
          end
        end
      end

      # @private
      def pattern(regexp, multiline)
        raise ArgumentError, "Regexp expected" unless Regexp === regexp
        source = regexp.source
        # Inspect anchors without changing the pattern's matching encoding.
        source = source.encode(Encoding::UTF_8) unless source.encoding.ascii_compatible?
        if !multiline && (source.start_with?("^") || source.match?(/(?<!\\)(?:\\\\)*\$\z/))
          raise ArgumentError, 'use \\A and \\z, or explicitly set multiline: true'
        end
        # An instance timeout takes precedence over the global timeout in Ruby.
        timeout = regexp.timeout || Regexp.timeout
        timeout = PATTERN_TIMEOUT unless timeout && timeout.positive?
        Regexp.new(regexp, timeout: [ timeout, PATTERN_TIMEOUT ].min).freeze
      end

      # @private
      def constant(rule, raw)
        freeze_constant(Parser.new(native: true).call(raw, rule))
      rescue ParamsSchema::InvalidParameters => error
        raise ArgumentError, "invalid constant: #{error.code}", cause: nil
      end

      # @private
      def freeze_constant(value)
        case value
        when Hash then value.each_value { |child| freeze_constant(child) }
        when Array then value.each { |child| freeze_constant(child) }
        end
        value.freeze
      end
  end
end
