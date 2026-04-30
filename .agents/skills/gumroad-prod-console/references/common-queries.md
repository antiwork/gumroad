# Common production debugging queries

Gumroad-specific scopes, associations, and helpers. Generic ActiveRecord patterns (basic finders, JSON output) are assumed.

## User

```ruby
user = User.find_by(email: "buyer@example.com")
user.unpaid_balance_cents    # balance available for payout
user.currency_type           # e.g. "usd"
user.products.alive          # products not deleted
user.payments.order(created_at: :desc).limit(5).pluck(:id, :amount_cents, :state, :created_at)
```

## Purchase

```ruby
Purchase.find_by_external_id(ext_id)
Link.find(123).purchases.successful.order(created_at: :desc).limit(10).pluck(:id, :email, :price_cents, :created_at)

p = Purchase.find(123)
puts({ purchase: p.attributes, charge: p.charge&.attributes }.to_json)
```

## Product (`Link`)

```ruby
Link.find_by(unique_permalink: "abcde")
Link.where(user_id: 123).alive
```

## Subscription (`Installment`)

```ruby
Installment.where(link_id: 123, alive: true).limit(10).pluck(:id, :email, :status, :created_at)
```

## Custom domain

```ruby
CustomDomain.find_by(domain: "example.com")&.user
```

## Sidekiq

```ruby
Sidekiq::Queue.all.map { |q| [q.name, q.size] }
Sidekiq::RetrySet.new.size
```

## Flipper

```ruby
Flipper.enabled?(:feature_name, User.find(123))
user = User.find(123)
Flipper.features.select { |f| f.enabled?(user) }.map(&:name)
```

## Slow queries

```ruby
WithMaxExecutionTime.timeout_queries(seconds: 30) { ... }
```
