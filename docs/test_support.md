<!--
# @title Request tests
-->

# Test an endpoint's parameter handling

Use ordinary request specs to check the endpoint's response and saved data
against its requirements.
The optional `params_schema/testing` helper generates boundary, omission, and
nil cases from the requirements you specify.

## Write RSpec request specs

This example assumes `POST /users` returns the saved user with HTTP 201.
Invalid input returns HTTP 400 with an `error` code, as in the
{file:docs/errors.md error-handling guide}. It uses `USER_INPUT` from the
{file:docs/integration.md controller guide}; an omitted or null age is saved as nil.

```ruby
require "rails_helper"

RSpec.describe "POST /users", type: :request do
  subject(:perform_request) { post users_path, params: request_params, as: :json }

  let(:valid_params) { { user: { name: "Ada", age: "27" } } }
  let(:request_params) { valid_params }

  it "creates and returns the requested user", :aggregate_failures do
    expect { perform_request }.to change(User, :count).by(1)
    expect(User.last).to have_attributes(name: "Ada", age: 27)
    expect(response.status).to eq(201)
    expect(response.parsed_body).to include("name" => "Ada", "age" => 27)
  end

  context "with a malformed age" do
    let(:request_params) { { user: { name: "Ada", age: "27abc" } } }

    it "rejects the request without creating a user", :aggregate_failures do
      expect { perform_request }.not_to change(User, :count)
      expect(response.status).to eq(400)
      expect(response.parsed_body).to include("error" => "invalid_integer")
    end
  end
end
```

## Add boundary cases

Load `params_schema/testing` in the spec file. Add the following inside the
`RSpec.describe` block above, using its `valid_params` and request subject:

```ruby
  cases = ParamsSchema::Testing.request_cases(
    path: [:user, :age], integer: 0..150, required: false, allow_nil: true
  )

  cases.each do |sample|
    context sample.description do
      let(:request_params) { sample.params(valid_params) }

      it "handles the requested age", :aggregate_failures do
        if sample.valid?
          expect { perform_request }.to change(User, :count).by(1)
          age = sample.omitted? ? nil : sample.value
          expect(User.last).to have_attributes(name: "Ada", age: age)
          expect(response.status).to eq(201)
          expect(response.parsed_body).to include("name" => "Ada", "age" => age)
        else
          expect { perform_request }.not_to change(User, :count)
          expect(response.status).to eq(400)
          expect(response.parsed_body).to include("error" => sample.error_code.to_s)
        end
      end
    end
  end
```

Each variation runs as a separate example. Failure descriptions identify the input:
`["user", "age"]: outside range 151 (not_included)`.

## Vary nested input

A path contains field names and zero-based array indexes:

| Target | Path |
| --- | --- |
| Quantity in the second item | `[:order, :items, 1, :quantity]` |
| The items array | `[:order, :items]` |
| The second tag ID | `[:order, :tag_ids, 1]` |
| Quantity under the map key `"02"` | `[:order, :items_attributes, "02", :quantity]` |

For example, generate quantity boundaries and omission/nil cases:

```ruby
cases = ParamsSchema::Testing.request_cases(
  path: [:order, :items, 1, :quantity],
  integer: 1..10, required: true, allow_nil: false
)
baseline = {
  order: { items: [{ product_code: "A", quantity: 2 }, { product_code: "B", quantity: 3 }] }
}
cases.first.params(baseline)
# => { order: { items: [{ product_code: "A", quantity: 2 }, { product_code: "B", quantity: 1 }] } }
```

The baseline must contain the selected field and its parent containers.
Each case copies the baseline and changes only the selected value.

For an endpoint that requires a nonempty `items` array, add explicit cases
for the array's shape and minimum length:

```ruby
ParamsSchema::Testing.request_cases(path: [:order, :items], cases: [
  { value: { product_code: "A", quantity: 2 }, error_code: :invalid_array },
  { value: [], error_code: :too_few_items }
])
```

See {ParamsSchema::Testing.request_cases} for all options, including string
representations of integer boundaries.

## Test notifications during gradual adoption

After adding `try_parse` before an endpoint's existing parameter handling, as in
{file:docs/errors.md gradual adoption}, check that validation failures emit a
notification and the endpoint keeps its existing response. This example uses an
endpoint that accepts age 151 and a proposed schema that rejects it:

```ruby
it "reports an out-of-range age and preserves the existing response", :aggregate_failures do
  events = []
  capture = ->(event) { events << event.payload }

  ActiveSupport::Notifications.subscribed(capture, "invalid.params_schema") do
    expect do
      post users_path, params: { user: { name: "Ada", age: "151" } }, as: :json
    end.to change(User, :count).by(1)
  end

  expect(events).to eq([{ schema: "users", code: :not_included }])
  expect(response.status).to eq(201)
  expect(response.parsed_body).to include("name" => "Ada", "age" => 151)
  expect(User.last).to have_attributes(name: "Ada", age: 151)
end
```

## Use Minitest

In an `ActionDispatch::IntegrationTest`, iterate over the same cases and define
`test sample.description do ... end` for each one. Send
`sample.params(baseline)` with the normal request helper, then assert the
response and application state.

## Test Rails' default error responses

If the application uses Rails' default exception response, set
`config.action_dispatch.show_exceptions = :rescuable` in the test environment
to assert HTTP 400 for `parse`. With `:none`, assert the raised exception.
For `parse!`, assert `ParamsSchema::UnexpectedParameters`. To test its default
HTTP 500 response, use `:all`.
