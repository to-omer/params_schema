<!--
# @title Rails controllers
-->

# Use schemas in Rails controllers

A schema defines the request data a controller accepts. `params.parse` validates
and converts that data, returning permitted parameters for the action to use:

```ruby
class SearchesController < ApplicationController
  def index
    render json: search_params
  end

  private
    def search_params
      params.parse do |schema|
        schema.param :page, :integer, default: 1, in: 1..100
        schema.param :archived, :boolean, default: false
      end
    end
end
```

| Request | HTTP status | JSON response or exception |
| --- | --- | --- |
| `GET /searches?page=2&archived=false` | 200 | `{"page":2,"archived":false}` |
| `GET /searches` | 200 | `{"page":1,"archived":false}` |
| `GET /searches?page=2abc` | 400 | `InvalidParameters`, code `:invalid_integer`, path `["page"]` |
| `GET /searches?page=101` | 400 | `InvalidParameters`, code `:not_included`, path `["page"]` |

See {ParamsSchema::Builder Field types and options} for the declaration API and
{file:docs/errors.md error handling} to customize failure responses.

## Create and update records

Define a reusable schema for the fields accepted by both actions:

```ruby
class UsersController < ApplicationController
  USER_INPUT = ActionController::Parameters.schema(name: :users) do |schema|
    schema.object :user, required: true, unknown: :reject do |user|
      user.param :name, :string, max_bytes: 100
      user.param :age, :integer, allow_nil: true, in: 0..150
      user.array :tags, of: :string, max_size: 10
    end
  end

  def create
    user = User.create!(user_params)
    render json: user, status: :created
  end

  def update
    user = User.find(params[:id])
    user.update!(user_params)
    render json: user
  end

  private
    def user_params
      params.parse(USER_INPUT).fetch(:user)
    end
end
```

The required `user` object must contain at least one declared field.
Empty objects are rejected before adding child defaults:

```ruby
begin
  UsersController::USER_INPUT.parse(user: {})
rescue ParamsSchema::InvalidParameters => error
  [error.code, error.path]
end
# => [:empty_object, ["user"]]
```

### Leave omitted fields unchanged

Keep update fields optional and without defaults to preserve attributes that
were not sent. Explicit `nil` and `[]` can clear a field when its rule accepts
that value:

```ruby
UsersController::USER_INPUT.parse(user: { name: "Ada", age: "27" }).to_h
# => { "user" => { "name" => "Ada", "age" => 27 } }

UsersController::USER_INPUT.parse(user: { name: "Grace" }).to_h
# => { "user" => { "name" => "Grace" } }

UsersController::USER_INPUT.parse(user: { age: nil, tags: [] }).to_h
# => { "user" => { "age" => nil, "tags" => [] } }
```

A default supplies a value whenever its key is missing, including during an
update. Use it when omission should assign that value, as with the search
parameters above.

### Reject undeclared fields

The root uses the default `unknown: :drop`, which removes fields such as
`controller`, `action`, and `authenticity_token` from the output. The nested
`unknown: :reject` catches undeclared fields inside `user`:

```ruby
begin
  UsersController::USER_INPUT.parse(user: { admin: true })
rescue ParamsSchema::InvalidParameters => error
  [error.code, error.path]
end
# => [:unknown_parameter, ["user", "admin"]]
```

### Choose fields for the current user

When the fields a user may change depend on their permissions, declare those
fields in the parameter helper. This example accepts `admin` only from an
authenticated administrator:

```ruby
def user_params
  params.parse do |schema|
    schema.object :user, required: true do |user|
      user.param :name, :string, max_bytes: 100
      user.param :admin, :boolean if current_user.admin?
    end
  end.fetch(:user)
end
```

With the default `unknown: :drop`, other users' `admin` input is omitted.
The required object must contain at least one field declared for the current user.

## Validate an array of objects

Consider an order request with an `items` array. Each item contains a product
code and a quantity. The block passed to `array` declares the fields required
in each item:

```ruby
BATCH_INPUT = ActionController::Parameters.schema do |schema|
  schema.array :items, required: true, min_size: 1, max_size: 20 do |item|
    item.param :product_code, :string, required: true, min_bytes: 1
    item.param :quantity, :integer, required: true, in: 1..10
  end
end

BATCH_INPUT.parse(items: [{ product_code: "A", quantity: "2" }]).to_h
# => { "items" => [{ "product_code" => "A", "quantity" => 2 }] }

begin
  BATCH_INPUT.parse(items: [{ product_code: "A", quantity: "2" }, { product_code: "B", quantity: "11" }])
rescue ParamsSchema::InvalidParameters => error
  [error.code, error.path]
end
# => [:not_included, ["items", 1, "quantity"]]

begin
  BATCH_INPUT.parse(items: { product_code: "A", quantity: "2" })
rescue ParamsSchema::InvalidParameters => error
  [error.code, error.path]
end
# => [:invalid_array, ["items"]]
```

For nested attributes passed to Active Record, see the
{file:docs/forms.md forms guide}.

## Validate a particular input source

`params` combines body, query, and routing parameters. To restrict validation to
one source, pass `request.query_parameters` for the query string or
`request.request_parameters` for the request body to `schema.parse`.

For example, this import reads IDs from the JSON body, even when the query
string contains an `ids` field:

```ruby
class ImportsController < ApplicationController
  BODY = ActionController::Parameters.schema do |schema|
    schema.array :ids, of: :integer, required: true
  end

  def create
    render json: import_params
  end

  private
    def import_params
      BODY.parse(request.request_parameters)
    end
end
```

For requests with `Content-Type: application/json`:

| Request | Body | HTTP status | JSON response or exception |
| --- | --- | --- | --- |
| `POST /imports?ids[]=99` | `{"ids":[1,2]}` | 200 | `{"ids":[1,2]}` |
| `POST /imports?ids[]=99` | `{}` | 400 | `InvalidParameters`, code `:missing`, path `["ids"]` |
