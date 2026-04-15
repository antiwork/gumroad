# Common Production Debugging Queries

## User Lookup

```ruby
# By ID
user = User.find(123)
puts user.attributes.to_json

# By email
user = User.find_by(email: "user@example.com")
puts [user.id, user.name, user.email, user.created_at].inspect

# By custom domain
cd = CustomDomain.find_by(domain: "example.com")
puts cd&.user_id
```

## Purchase Investigation

```ruby
# By ID
p = Purchase.find(123)
puts p.attributes.to_json

# Recent purchases for a product
Product.find(123).purchases.successful.order(created_at: :desc).limit(10).pluck(:id, :email, :price_cents, :created_at)

# Purchase with charge details
p = Purchase.find(123)
puts({ purchase: p.attributes, charge: p.charge&.attributes }.to_json)
```

## Product Queries

```ruby
# By permalink
product = Link.find_by(unique_permalink: "abcde")
puts product.attributes.to_json

# Products for a user
User.find(123).products.alive.pluck(:id, :name, :price_cents, :created_at)
```

## Financial / Balance

```ruby
# User balance
user = User.find(123)
puts({ balance_cents: user.unpaid_balance_cents, currency: user.currency_type }.to_json)

# Recent payouts
User.find(123).payments.order(created_at: :desc).limit(5).pluck(:id, :amount_cents, :state, :created_at)
```

## Subscription / Installment

```ruby
# Active subscriptions for a product
Installment.where(link_id: 123, alive: true).limit(10).pluck(:id, :email, :status, :created_at)

# Subscription details
sub = Installment.find(123)
puts sub.attributes.to_json
```

## Dispute / Chargeback

```ruby
Dispute.where(purchase_id: 123).pluck(:id, :reason, :status, :created_at)
```

## Feature Flags (Flipper)

```ruby
# Check if feature is enabled for user
puts Flipper.enabled?(:feature_name, User.find(123))

# List enabled features for user
user = User.find(123)
Flipper.features.select { |f| f.enabled?(user) }.map(&:name)
```

## Sidekiq Jobs

```ruby
# Check queue sizes
Sidekiq::Queue.all.map { |q| [q.name, q.size] }

# Check retries
puts Sidekiq::RetrySet.new.size
```

## DevTools Utilities

Available in `lib/utilities/dev_tools.rb`:

```ruby
DevTools.reindex_all_for_user(user_id)           # Reindex ES data for user
DevTools.reimport_follower_events_for_user!(user) # Reimport follower analytics
```

## Safety Patterns

```ruby
# Always limit result sets
Model.where(...).limit(20)

# Use pluck for lightweight queries (avoids instantiating AR objects)
Model.where(...).pluck(:id, :name, :created_at)

# Wrap slow queries with timeout
WithMaxExecutionTime.timeout_queries(seconds: 30) { <query> }

# Use .explain to check query plans before running heavy queries
puts Model.where(...).explain
```
