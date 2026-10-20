<!--
# @title Forms and nested attributes
-->

# Handle form inputs

Most form values arrive as strings. Choose each field's
{ParamsSchema::Builder type and options} to control how these values are parsed.
Use `:scalar` when the model should perform the conversion, for example for an
Active Record boolean attribute that accepts `"off"` as false. Use `:boolean`
when the controller needs a validated true or false value.

## Handle cleared form fields

A cleared text or number field submits an empty string. To receive nil instead,
combine `empty_string_to_nil: true` with `allow_nil: true`. This works with `:string`, `:integer`,
`:float`, `:boolean`, and `:scalar`:

```ruby
FORM_INPUT = ActionController::Parameters.schema do |schema|
  schema.param :name, :string, allow_nil: true, empty_string_to_nil: true
  schema.param :age, :integer, allow_nil: true, empty_string_to_nil: true, in: 0..150
  schema.param :subscribed, :boolean, allow_nil: true, empty_string_to_nil: true
end

FORM_INPUT.parse(name: "", age: "", subscribed: "").to_h
# => { "name" => nil, "age" => nil, "subscribed" => nil }

FORM_INPUT.parse(name: " ", subscribed: "0").to_h
# => { "name" => " ", "subscribed" => false }

FORM_INPUT.parse({}).to_h
# => {}
```

## Submit multiple selections

Rails adds a hidden empty value to multiple-selection controls so that clearing
all selections still submits the field. `drop_empty_strings: true` removes that value
before validating the selected values and their count:

```ruby
TAGS_INPUT = ActionController::Parameters.schema do |schema|
  schema.array :tag_ids, of: :integer, drop_empty_strings: true, max_size: 2
end

TAGS_INPUT.parse(tag_ids: ["", "1", "2"]).to_h
# => { "tag_ids" => [1, 2] }
TAGS_INPUT.parse(tag_ids: [""]).to_h
# => { "tag_ids" => [] }

begin
  TAGS_INPUT.parse(tag_ids: ["", "1", "wrong"])
rescue ParamsSchema::InvalidParameters => error
  [error.code, error.path]
end
# => [:invalid_integer, ["tag_ids", 2]]
```

The error path keeps the index from the input passed to `parse`, before empty
strings are removed.
Use {ParamsSchema::Builder#one_or_many} when an endpoint accepts either a single
selection or an array. Single values remain single values; arrays remain arrays.

## Pass nested attributes to a model

For a model using `accepts_nested_attributes_for`, `collection` accepts both
a Hash of rows and an Array of objects. Use `:scalar` to preserve submitted
values for Active Record's `reject_if` and `_destroy` handling:

```ruby
ORDER_INPUT = ActionController::Parameters.schema do |schema|
  schema.object :order, required: true do |order|
    order.collection :items_attributes do |item|
      item.param :id, :scalar
      item.param :product_code, :scalar
      item.param :quantity, :scalar
      item.param :_destroy, :scalar
    end
  end
end

def order_params
  params.parse(ORDER_INPUT).fetch(:order)
end
```

Pass the result to `order.update!(order_params)`. Omitted fields remain absent,
so the same schema supports partial updates. Hash row keys can be strings or
symbols and are returned as strings: `"02"` stays `"02"`, and `:new_item` becomes
`"new_item"`. The outer key `"id"` is reserved; put record IDs inside each row.

For a model configured with `allow_destroy: true`, the supplied ID and `_destroy`
value let Active Record delete an existing item:

```ruby
rows = { "02" => { id: "7", quantity: "", _destroy: "1" } }
ORDER_INPUT.parse(order: { items_attributes: rows }).fetch(:order).to_h
# => { "items_attributes" => { "02" => { "id" => "7", "quantity" => "", "_destroy" => "1" } } }
```

Schema rules run before Active Record decides which rows to save or delete.
Here, `:scalar` lets the empty quantity reach Active Record along with the
deletion flag; an `:integer` rule would reject it first. Put constraints on
saved items, such as a positive quantity, in the model's validations.

## Update file attachments

An Active Storage form can submit existing attachments' signed IDs alongside
new uploaded files. Use `:scalar` for this mixture and `drop_empty_strings: true`
to remove the file field's hidden empty value:

```ruby
PHOTOS_INPUT = ActionController::Parameters.schema do |schema|
  schema.array :images, of: :scalar, drop_empty_strings: true
end
```

Here, `signed_id` is an existing blob's signed ID and `upload` is a newly
uploaded file:

```ruby
PHOTOS_INPUT.parse(images: ["", signed_id, upload])[:images]
# => [signed_id, upload]

PHOTOS_INPUT.parse(images: [""]).to_h
# => { "images" => [] }

PHOTOS_INPUT.parse({}).to_h
# => {}
```

Pass the result to a model's `update!` to replace its attachments with the
submitted list. An empty list clears attachments; an omitted field leaves them
unchanged. Active Storage resolves the signed IDs. Use `:uploaded_file` when a
field accepts only new uploads.

For a single attachment declared with `has_one_attached :avatar`, use `:scalar`
to accept an upload or signed ID. Use `allow_nil: true` to accept an explicit nil
for removal:

```ruby
AVATAR_INPUT = ActionController::Parameters.schema do |schema|
  schema.param :avatar, :scalar, allow_nil: true
end

AVATAR_INPUT.parse(avatar: nil).to_h
# => { "avatar" => nil }
AVATAR_INPUT.parse({}).to_h
# => {}
```

When passed to `user.update!`, `avatar: nil` removes the attachment and an omitted
`avatar` leaves it unchanged. Active Storage manages the
[removal of stored files](https://guides.rubyonrails.org/active_storage_overview.html#removing-files).

## Submit dates from select controls

Rails' `date_select :birth_date` sends separate year, month, and day keys.
Use `:string` for each component's value so Active Record can assemble the date:

```ruby
DATE_INPUT = ActionController::Parameters.schema do |schema|
  schema.param :"birth_date(1i)", :string
  schema.param :"birth_date(2i)", :string
  schema.param :"birth_date(3i)", :string
end

DATE_INPUT.parse("birth_date(1i)" => "2026", "birth_date(2i)" => "10", "birth_date(3i)" => "19").to_h
# => { "birth_date(1i)" => "2026", "birth_date(2i)" => "10", "birth_date(3i)" => "19" }
```

Pass these parameters to a model with a `birth_date` attribute. Keep cleared
components as empty strings; Active Record interprets an entirely empty date
as nil. For `time_select` and `datetime_select`, use `:string` for every
component generated by the helper, including hidden date components.
