# Params Schema

Params Schema validates and converts Rails request parameters. A schema defines
the accepted fields, types, defaults, and constraints. Parsing input with that
schema returns a new, permitted `ActionController::Parameters` instance.

## Why use it?

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

## Usage

```ruby
SEARCH_INPUT = ActionController::Parameters.schema do |schema|
  schema.param :page, :integer, default: 1, in: 1..100
  schema.param :archived, :boolean, default: false
end

params = ActionController::Parameters.new(page: "2", archived: "false", debug: "1")
output = params.parse(SEARCH_INPUT)
output.to_h
# => { "page" => 2, "archived" => false }
```

For comparison, `permit` keeps these values as strings:

```ruby
params.permit(:page, :archived).to_h
# => { "page" => "2", "archived" => "false" }
```

`parse` raises `ParamsSchema::InvalidParameters` on failure (HTTP 400 by default).

## Documentation

- [Field types and options](https://to-omer.github.io/params_schema/ParamsSchema/Builder.html): the complete schema declaration reference
- [Using schemas in Rails](https://to-omer.github.io/params_schema/file.integration.html): parameter helpers and nested input
- [Forms](https://to-omer.github.io/params_schema/file.forms.html): cleared fields, multiple selections, and nested model attributes
- [Handling errors](https://to-omer.github.io/params_schema/file.errors.html): responses, notifications, and gradual adoption
- [Request tests](https://to-omer.github.io/params_schema/file.test_support.html): verify endpoint behavior with RSpec or Minitest

See [Development](docs/development.md) for local setup, checks, and YARD builds.
