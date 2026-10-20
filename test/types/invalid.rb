# frozen_string_literal: true

# These deliberate API misuses must produce the recorded Steep diagnostics.
ActionController::Parameters.schema

schema = ActionController::Parameters.schema { |s| s.param :id, :integer }
ActionController::Parameters.new.parse(schema) { |s| s.param :id, :integer }

ActionController::Parameters.schema do |s|
  s.array :ids, of: Object.new
end

schema.parse({ id: "1" }).upcase
schema.parse({ id: "1" }) { |s| s.param :id, :integer }
