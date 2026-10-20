<!--
# @title Errors and gradual adoption
-->

# Handle validation failures

`parse` raises {ParamsSchema::InvalidParameters} for invalid input. Rails returns
HTTP 400 by default. Use the exception's `code` and `path` to identify the failure.

## Set a shared error response

Register `ParamsSchema::InvalidParameters` with `rescue_from` to use your
application's error response. Put the handler in `ApplicationController` to
share it across inheriting controllers:

```ruby
class ApplicationController < ActionController::Base
  rescue_from ParamsSchema::InvalidParameters do |error|
    render json: { error: error.code }, status: :bad_request
  end
end
```

### Add a translated message

To include a localized message, translate the error code in the handler.
Here, `request_locale` is the application's method for choosing a supported locale:

```ruby
rescue_from ParamsSchema::InvalidParameters do |error|
  message = I18n.t(error.code, scope: "params_schema.errors",
    locale: request_locale, default: :invalid)
  render json: { error: error.code, message: message }, status: :bad_request
end
```

Add translations to the application's locale files. The `invalid` entry
provides a fallback for codes without a specific translation:

```yaml
en:
  params_schema:
    errors:
      invalid: "Invalid request parameters."
      missing: "A required parameter is missing."
      invalid_integer: "An integer is required."
ja:
  params_schema:
    errors:
      invalid: "リクエストのパラメータが不正です。"
      missing: "必須パラメータがありません。"
      invalid_integer: "整数を指定してください。"
```

## Report failures across the application

Subscribe to `invalid.params_schema` once in an initializer:

```ruby
ActiveSupport::Notifications.subscribe("invalid.params_schema") do |event|
  Rails.logger.warn(
    "Invalid parameters: schema=#{event.payload[:schema]} code=#{event.payload[:code]}"
  )
end
```

Each failed parse publishes one event. The payload contains `schema`, the
schema's `name:` as a string (or nil), and `code`, the first validation error's
symbol. Subscriber exceptions propagate to the caller.

## Adopt a schema gradually

`try_parse` returns a validation result instead of raising on invalid input.
Call it before the endpoint's existing parameter handling. This example uses
`USER_INPUT` from the {file:docs/integration.md controller guide}:

```ruby
def user_params
  USER_INPUT.try_parse(params)
  params.expect(user: [:name, :age, tags: []])
end
```

`try_parse` reports validation failures through the same notification. The
existing `expect` expression still supplies the values used by the endpoint.

Before switching to the schema's output, compare accepted input, saved data,
error responses, and side effects in request tests. When the schema's rules
match the endpoint's intended behavior, use `parse` in the parameter helper:

```ruby
def user_params
  params.parse(USER_INPUT).fetch(:user)
end
```

The schema validates the required `user` object and its fields; `fetch` selects
the validated attributes. Configure its failure response with the handler above.

See the {file:docs/test_support.md request-test guide} for testing during gradual adoption.

## Treat an invalid request as an application bug

For a controlled client whose invalid requests indicate a bug, use
`params.parse!(USER_INPUT).fetch(:user)`. It raises
{ParamsSchema::UnexpectedParameters}, which produces HTTP 500 by default and
is separate from the `InvalidParameters` handler above. Validation and
failure notifications are the same as for `parse`.
