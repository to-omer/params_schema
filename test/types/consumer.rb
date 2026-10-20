# frozen_string_literal: true

# Shared consumer for static types, runtime signatures, and the installed gem.
require "params_schema"

schema = ActionController::Parameters.schema(name: :consumer, unknown: :reject, reject_empty: true) do |s|
  id = s.value(:integer, in: 1..)
  ids = s.value(:array, of: id, min_size: 1)
  s.param :owner_id, s.value(id), required: true
  s.param :enabled, :boolean, default: false
  s.param :label, :string, default: "new", max_bytes: 20
  s.param :weight, :float, default: 1.0, in: 0..10
  s.array :weights, of: s.value(:float, in: 0.0..1.0)
  s.param :expires_in, :integer, empty_string_to_nil: true, allow_nil: true
  s.array :selected_ids, of: :integer, drop_empty_strings: true
  s.object :filter, reject_empty: true do |filter|
    filter.param :query, :string
  end
  s.array :groups, of: ids
  s.map :groups_by_name, of: ids, keys: /\A[a-z]+\z/
  s.array :nullable_ids, of: s.value(:integer, allow_nil: true)
  s.array :nullable_array, of: :integer, allow_nil: true
  s.array :tags, of: :string, default: []
  s.param :counts, :map, of: :integer, default: ActionController::Parameters.new(visitors: 1)
  s.object(:settings, default: {}) { |o| o.param :page, :integer, default: 1 }
  s.param :seeds, ids, default: [ 1 ]
  s.param :attachment, :uploaded_file, allow_nil: true, default: nil
  row = s.value(:object, reject_empty: true) { |r| r.one_or_many :value, of: :string }
  s.collection :rows, of: row
  s.param :fallback_rows, :collection, of: row, default: []
  s.param :selection, :one_or_many, of: :integer, default: 1
  s.collection :updates do |r|
    r.param :ids, s.value(:one_or_many, of: id)
  end
  s.param :archived_rows, s.value(:collection, of: row), default: {}
  s.param :no_choice, :string, in: [], allow_nil: true, default: nil
  s.one_or_many :selected_values, of: :integer, drop_empty_strings: true
  s.param :filtered_values, :one_or_many, of: :integer, drop_empty_strings: true
  s.param :filtered_rule, s.value(:one_or_many, of: :integer, drop_empty_strings: true)
  s.param :native_flag, :boolean, coerce: false, empty_string_to_nil: true, allow_nil: true
  s.param :metadata, :hash, reject_empty: true, default: { source: { tags: [ "new" ] } }
  s.array :documents, of: :hash
  s.map :profiles, of: s.value(:hash, allow_nil: true, reject_empty: false)
end

input = ActionController::Parameters.new(
  owner_id: "42", filter: { query: "example" }, groups: [ [ "1", "2" ] ],
  groups_by_name: { editors: [ "3" ] }, nullable_ids: [ nil, "4" ], nullable_array: nil,
  rows: { "new_item" => { value: [ "", "tag" ] } }, updates: [ { ids: "2" } ], weights: [ "0.5" ],
  expires_in: "", selected_ids: [ "", "1" ], selected_values: [ "", "2" ],
  filtered_values: [ "", "3" ], filtered_rule: [ "", "4" ], native_flag: "",
  documents: [ { flags: [ true, "0" ] } ], profiles: { guest: nil }
)
result = input.parse(schema)
raise "unpermitted result" unless result.permitted?
raise "input was changed" if input.permitted? || input[:owner_id] != "42"
# @type var expected: Hash[String, untyped]
expected = {
  "owner_id" => 42, "enabled" => false, "label" => "new", "weight" => 1.0, "weights" => [ 0.5 ],
  "expires_in" => nil, "selected_ids" => [ 1 ],
  "filter" => { "query" => "example" }, "groups" => [ [ 1, 2 ] ],
  "groups_by_name" => { "editors" => [ 3 ] }, "nullable_ids" => [ nil, 4 ], "nullable_array" => nil,
  "tags" => [], "counts" => { "visitors" => 1 }, "settings" => { "page" => 1 }, "seeds" => [ 1 ], "attachment" => nil,
  "rows" => { "new_item" => { "value" => [ "", "tag" ] } }, "updates" => [ { "ids" => 2 } ],
  "fallback_rows" => [], "selection" => 1, "archived_rows" => {}, "no_choice" => nil,
  "selected_values" => [ 2 ], "filtered_values" => [ 3 ], "filtered_rule" => [ 4 ], "native_flag" => nil,
  "metadata" => { "source" => { "tags" => [ "new" ] } }, "documents" => [ { "flags" => [ true, "0" ] } ],
  "profiles" => { "guest" => nil }
}
raise "unexpected conversion" unless result.to_h == expected
raise "unexpected bang conversion" unless input.parse!(schema).to_h == expected

inline = ActionController::Parameters.new(page: "2").parse(name: :page, unknown: :reject, reject_empty: true) do |s|
  s.param :page, :integer, in: 1..100
end
raise "unexpected inline result" unless inline.to_h == { "page" => 2 }
inline_bang = ActionController::Parameters.new(page: "2").parse!(name: :page, unknown: :reject, reject_empty: true) do |s|
  s.param :page, :integer, in: 1..100
end
raise "unexpected inline bang result" unless inline_bang.to_h == { "page" => 2 }

nullable = ActionController::Parameters.schema do |s|
  s.param :name, :string, empty_string_to_nil: true, allow_nil: true
  s.param :subscribed, :boolean, empty_string_to_nil: true, allow_nil: true
  s.param :reference, :scalar, empty_string_to_nil: true, allow_nil: true
  s.array :names, of: s.value(:string, empty_string_to_nil: true, allow_nil: true)
  s.array :subscriptions, of: s.value(:boolean, empty_string_to_nil: true, allow_nil: true)
  s.array :references, of: s.value(:scalar, empty_string_to_nil: true, allow_nil: true)
end
cleared = nullable.parse(name: "", subscribed: "", reference: "", names: [ "" ], subscriptions: [ "" ], references: [ "" ])
raise "empty values were not normalized" unless cleared.to_h == {
  "name" => nil, "subscribed" => nil, "reference" => nil,
  "names" => [ nil ], "subscriptions" => [ nil ], "references" => [ nil ]
}

begin
  schema.parse({ owner_id: "invalid" })
  raise "invalid input was accepted"
rescue ParamsSchema::InvalidParameters => error
  raise "unexpected error" unless error.code == :invalid_integer && error.path == [ "owner_id" ]
end

begin
  schema.parse!({ owner_id: "invalid" })
  raise "invalid input was accepted"
rescue ParamsSchema::UnexpectedParameters => error
  raise "unexpected bang error" unless error.code == :invalid_integer && error.path == [ "owner_id" ]
end

observed = schema.try_parse({ owner_id: "invalid" })
raise "invalid input succeeded" if observed.success?
observed_error = observed.error
raise "missing diagnostic" unless observed_error && observed_error.code == :invalid_integer
parsed = schema.try_parse({ owner_id: "42" })
raise "unexpected result" unless parsed.success? && parsed.value![:owner_id] == 42

# Type names may also come from a finite set in application configuration.
# @type var types: Array[:string | :integer]
types = [ :string, :integer ]
ActionController::Parameters.schema do |s|
  types.each_with_index do |type, index|
    s.value(type)
    s.value(type, allow_nil: true)
    s.param "field_#{index}", type
    s.param "nullable_#{index}", type, allow_nil: true
    s.array "items_#{index}", of: type
  end
end

require "params_schema/testing"

ParamsSchema::Testing.request_cases(path: [ :owner_id ], integer: 1..,
  required: true, allow_nil: false).each do |sample|
  parameters = sample.params(owner_id: 42)
  raise "missing case description" if sample.description.empty?
  raise "wrong path" unless sample.path == [ "owner_id" ]
  if sample.omitted?
    raise "field was not omitted" if parameters.key?(:owner_id)
  else
    raise "wrong input value" unless parameters.fetch(:owner_id) == sample.value
  end
  raise "wrong validity" unless sample.valid? == sample.error_code.nil?
end

ParamsSchema::Testing.request_cases(path: [ :order, :ids, 1 ], integer: 1..100,
  cases: [ { value: {}, error_code: :invalid_integer } ]).each do |sample|
  parameters = sample.params(order: { ids: [ 1, 2 ] })
  raise "wrong array element" unless parameters.dig(:order, :ids, 1) == sample.value
end

puts "Params Schema #{ParamsSchema::VERSION}: consumer checks passed"
