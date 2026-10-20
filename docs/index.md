<!--
# @title Getting started
-->

# Request validation with Params Schema

Params Schema validates and converts Rails request parameters. A schema defines
the accepted fields, types, defaults, and constraints. Parsing input with that
schema returns a new, permitted `ActionController::Parameters` instance.

Strong Parameters selects fields for mass assignment and checks the shape of
nested input. Params Schema adds value conversion and validation to that step,
so controllers can use validated request data without repeating conversion
and validation code.

Params Schema does not replace Active Model or Active Record validations,
which check model data and business rules.

## Installation

Requires Ruby 3.2+ and Action Pack 8.0 or 8.1. Add a local checkout to the
application's Gemfile:

```ruby
gem "params_schema", path: "../params_schema"
```

With Rails 8.0, also add `gem "json", "~> 2.0"` to the Gemfile.
Active Support 8.0 passes options that JSON 3 rejects.

Then run `bundle install`. Rails loads the gem automatically; standalone scripts
use `require "params_schema"`.

## Parse request parameters

```ruby
require "params_schema"

query = ActionController::Parameters.schema do |schema|
  schema.param :page, :integer, default: 1, in: 1..100
  schema.param :archived, :boolean, default: false
end

params = ActionController::Parameters.new(page: "2", archived: "false", debug: "1")
output = params.parse(query)
output.to_h
# => { "page" => 2, "archived" => false }

output.permitted?
# => true
```

For comparison, `permit` keeps these values as strings:

```ruby
params.permit(:page, :archived).to_h
# => { "page" => "2", "archived" => "false" }
```

Defaults supply values for omitted fields:

```ruby
query.parse({}).to_h
# => { "page" => 1, "archived" => false }
```

Invalid input raises {ParamsSchema::InvalidParameters} (HTTP 400 by default).
The error identifies the failure's kind and location:

```ruby
begin
  query.parse(page: "2abc")
rescue ParamsSchema::InvalidParameters => error
  [error.code, error.path]
end
# => [:invalid_integer, ["page"]]
```

## Guides and reference

| Task | Reference |
| --- | --- |
| Apply schemas in controllers and validate nested input | {file:docs/integration.md Rails controllers} |
| Handle empty form controls and nested model attributes | {file:docs/forms.md Forms and nested attributes} |
| Set error responses, report failures, and adopt gradually | {file:docs/errors.md Errors and gradual adoption} |
| Test an endpoint's response and saved data | {file:docs/test_support.md Request tests} |

The API reference covers {ParamsSchema::Builder field types and options},
{ActionController::Parameters.schema schema construction},
{ParamsSchema::Schema parsing}, and {ParamsSchema::InvalidParameters error codes and paths}.
