# frozen_string_literal: true

module ChurnTestHelpers
  def create_active_subscription(product:, price:, created_at: 60.days.ago, deactivated_at: nil)
    subscription = create(:subscription,
                          link: product,
                          user: create(:user),
                          created_at: created_at,
                          deactivated_at: deactivated_at)
    payment_option = create(:payment_option, subscription: subscription, price: price)
    subscription.update!(last_payment_option: payment_option)
    subscription
  end

  def create_churned_subscription(product:, price:, created_at:, deactivated_at:)
    create_active_subscription(
      product: product,
      price: price,
      created_at: created_at,
      deactivated_at: deactivated_at
    )
  end

  def create_new_subscription(product:, price:, created_at:)
    create_active_subscription(
      product: product,
      price: price,
      created_at: created_at
    )
  end

  # Helper for system tests to verify churn metrics
  def expect_churn_metrics(churn_rate:, last_period_rate:, revenue_lost:, churned_users:)
    within_section("Churn rate") { expect(page).to have_text("#{churn_rate}%") }
    within_section("Last period churn rate") { expect(page).to have_text("#{last_period_rate}%") }
    within_section("Revenue lost") { expect(page).to have_text("$#{revenue_lost}") }
    within_section("Churned users") { expect(page).to have_text(churned_users.to_s) }
  end

  # Setup standard test scenario with known churn data
  # Returns hash with :active, :new, and :churned subscription arrays
  def setup_churn_scenario(monthly_product:, yearly_product:, monthly_price:, yearly_price:, base_date: "2023-12-01")
    # Create 2 active subscriptions (started before period)
    active_sub1 = create_active_subscription(
      product: monthly_product,
      price: monthly_price,
      created_at: "#{base_date} 12:00:00"
    )
    active_sub2 = create_active_subscription(
      product: monthly_product,
      price: monthly_price,
      created_at: "#{base_date} 12:00:00"
    )

    # Create 1 new subscription (started during period)
    new_sub = create_new_subscription(
      product: monthly_product,
      price: monthly_price,
      created_at: "2023-12-16 12:00:00"
    )

    # Create 2 churned subscriptions (1 monthly, 1 yearly)
    churned_sub1 = create_churned_subscription(
      product: monthly_product,
      price: monthly_price,
      created_at: "#{base_date} 12:00:00",
      deactivated_at: "2023-12-20 12:00:00"
    )
    churned_sub2 = create_churned_subscription(
      product: yearly_product,
      price: yearly_price,
      created_at: "#{base_date} 12:00:00",
      deactivated_at: "2023-12-25 12:00:00"
    )

    {
      active: [active_sub1, active_sub2],
      new: [new_sub],
      churned: [churned_sub1, churned_sub2]
    }
  end
end
