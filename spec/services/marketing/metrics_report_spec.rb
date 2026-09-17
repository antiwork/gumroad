# frozen_string_literal: true

require "spec_helper"

describe Marketing::MetricsReport do
  let(:ends_at) { Time.utc(2026, 8, 1) }
  let(:starts_at) { ends_at - 90.days }
  let(:seller) { create(:user) }
  let(:control) { create(:user) }
  let(:product) { create(:product, user: seller) }

  def assign(user, holdout: false, bucket: "zero", at: starts_at - 1.day)
    create(:marketing_holdout_assignment, user:, marketing_holdout: holdout,
                                          prior_sales_bucket: bucket, marketing_holdout_assigned_at: at)
  end

  def report(cohort: "zero_sale", **options)
    described_class.new(window_start: starts_at, window_end: ends_at, cohort:, **options).call
  end

  def sale(user: seller, at: starts_at + 1.day, **attributes)
    create(:purchase, link: user == seller ? product : create(:product, user:), seller: user,
                      created_at: at, succeeded_at: at, **attributes)
  end

  def renewal(**attributes)
    subscription = create(:subscription, link: product)
    sale(at: starts_at - 10.days, email: attributes.fetch(:email, "renewal@example.com"), subscription:, is_original_subscription_purchase: true)
    sale(subscription:, is_original_subscription_purchase: false, **attributes)
  end

  def attribute_sale(purchase, at: purchase.created_at - 1.hour, user: seller)
    utm = create(:utm_link, seller: user)
    visit = create(:utm_link_visit, utm_link: utm, created_at: at)
    create(:utm_link_driven_sale, purchase:, utm_link: utm, utm_link_visit: visit)
  end

  def delivered_email(user:, email:, at:, suggested: false)
    purchase = sale(user:, email:, at: starts_at - 10.days)
    post = create(:seller_post, seller: user, published_at: at)
    post.update!(json_data: { described_class::SUGGESTED_EMAIL_KEY => "digest" }) if suggested
    create(:creator_contacting_customers_email_info, purchase:, installment: post,
                                                     delivered_at: at, sent_at: at, state: "delivered")
  end

  it "keeps frozen pre-window assignments and inactive creators in the intention-to-treat revenue denominator" do
    assignment = assign(seller)
    assign(control, holdout: true)
    before = Marketing::HoldoutAssignment.order(:id).map(&:attributes)
    sale(price_cents: 1000)
    expect(Marketing::Action.count).to eq(0)

    result = report

    expect(result[:net_revenue][:treatment]).to include(n: 1, amount_cents: 1000)
    expect(result[:net_revenue][:holdout]).to include(n: 1, amount_cents: 0)
    expect(Marketing::HoldoutAssignment.order(:id).map(&:attributes)).to eq(before)
    expect(assignment.reload.marketing_holdout).to eq(false)
  end

  it "nets partial refunds, excludes full refunds and unreversed chargebacks, and keeps subscription revenue" do
    assign(seller)
    purchase = sale(price_cents: 1000, stripe_partially_refunded: true)
    create(:refund, purchase:, amount_cents: 250)
    create(:refund, purchase:, amount_cents: 100, status: "failed", json_data: { balance_reversed_on_failure: true })
    sale(price_cents: 500, stripe_refunded: true)
    sale(price_cents: 700, chargeback_date: starts_at + 2.days)
    sale(price_cents: 900, purchase_state: "failed")
    sale(price_cents: 300, at: ends_at)
    renewal(price_cents: 200)

    expect(report[:net_revenue][:treatment]).to include(n: 1, amount_cents: 950)
  end

  it "splits both prior-sales strata from zero-sale assignments without consulting current sales" do
    assign(seller, bucket: "under_100")
    assign(control, holdout: true, bucket: "at_least_100")
    sale(price_cents: 400)
    expect(report[:net_revenue][:treatment][:n]).to eq(0)
    expect(report(cohort: "already_sells")[:net_revenue][:treatment]).to include(n: 1, amount_cents: 400)
    expect(report(cohort: "already_sells")[:net_revenue][:holdout][:n]).to eq(1)
  end

  it "reports immature assignments without giving them partial 90-day outcomes" do
    assign(seller, at: ends_at - 2.days)
    sale(price_cents: 500, at: ends_at - 1.day)
    result = report
    expect(result[:assigned_creators][:treatment]).to eq(1)
    expect(result[:net_revenue][:treatment]).to include(n: 0, amount_cents: nil)
    expect(result[:first_sale][:treatment][:n]).to eq(0)
  end

  it "counts one first sale per newly assigned creator despite multiple attribution rows" do
    assign(seller, at: starts_at)
    assign(control, holdout: true, at: starts_at)
    purchase = sale
    attribute_sale(purchase)
    attribute_sale(purchase, at: purchase.created_at - 2.hours)
    attribute_sale(sale(at: starts_at + 2.days))
    result = report[:first_sale]
    expect(result[:treatment]).to eq(n: 1, successes: 1, rate: 1.0)
    expect(result[:holdout]).to eq(n: 1, successes: 0, rate: 0.0)
    expect(result[:p_value]).to be_between(0, 1)
  end

  it "requires the first purchase, a nonfuture last click, and the seven-day conversion horizon" do
    assign(seller, at: starts_at)
    sale
    attribute_sale(sale(at: starts_at + 2.days))
    expect(report[:first_sale][:treatment][:successes]).to eq(0)
  end

  it "rejects clicks outside seven days and later clicks credited to another seller" do
    assign(seller, at: starts_at)
    purchase = sale
    attribute_sale(purchase, at: purchase.created_at - 8.days)
    attribute_sale(purchase, at: purchase.created_at + 1.hour)
    expect(report[:first_sale][:treatment][:successes]).to eq(0)
    attribute_sale(purchase)
    attribute_sale(purchase, at: purchase.created_at - 1.minute, user: control)
    expect(report[:first_sale][:treatment][:successes]).to eq(0)
  end

  it "counts prior buyers once without conditioning on an email, excluding refunds and auto-renewals" do
    assign(seller, bucket: "under_100")
    assign(control, holdout: true, bucket: "under_100")
    %w[repeat refund partial renewal inactive].each { |name| sale(email: "#{name}@example.com", at: starts_at - 2.days) }
    sale(user: control, email: "control@example.com", at: starts_at - 2.days)
    2.times { sale(email: "repeat@example.com") }
    sale(email: "refund@example.com", stripe_refunded: true)
    sale(email: "partial@example.com", stripe_partially_refunded: true)
    renewal(email: "renewal@example.com")
    sale(email: "new@example.com")
    result = report(cohort: "already_sells")[:repeat_purchase]
    expect(result[:treatment]).to eq(n: 5, successes: 1, rate: 0.2, email_linked_successes: 0)
    expect(result[:holdout]).to eq(n: 1, successes: 0, rate: 0.0, email_linked_successes: 0)
  end

  it "reports deduplicated delivered suggested and hand-written emails and flags deterioration" do
    assign(seller)
    assign(control, holdout: true)
    email = delivered_email(user: seller, email: "buyer@example.com", at: starts_at + 1.day, suggested: true)
    create(:creator_contacting_customers_email_info, purchase: email.purchase, installment: email.installment,
                                                     delivered_at: starts_at + 1.day, state: "delivered")
    delivered_email(user: control, email: "other@example.com", at: starts_at + 1.day, suggested: true)
    delivered_email(user: seller, email: "manual@example.com", at: starts_at + 1.day)
    create(:follower, user: seller, email: "buyer@example.com", confirmed_at: nil, deleted_at: starts_at + 2.days)
    safety = report(deterioration_threshold: 0.05)[:email_safety]
    expect(safety[:by_origin][:suggested][:treatment]).to eq(n: 1, successes: 1, rate: 1.0)
    expect(safety[:by_origin][:hand_written][:treatment]).to eq(n: 1, successes: 0, rate: 0.0)
    expect(safety).to include(deteriorated: true, blocks_rollout: true, complete: false)
    expect(report(deterioration_threshold: 1)[:email_safety][:deteriorated]).to eq(false)
  end

  it "does not infer historical complaint or delivered counts from current opt-out or sent state" do
    assign(seller)
    purchase = sale(can_contact: false, can_contact_reason: Purchase::CAN_CONTACT_REASON_SPAM_REPORT)
    post = create(:seller_post, seller:)
    create(:sent_post_email, post:, email: purchase.email)
    result = report
    expect(result[:email_safety][:complaints][:treatment]).to eq(n: nil, rate: nil, p_value: nil)
    expect(result[:email_safety][:by_origin][:hand_written][:treatment][:n]).to eq(0)
    expect(result[:blocks_rollout]).to eq(true)
  end

  it "attributes a deletion only to the most recent delivered email and ignores earlier opt-outs" do
    assign(seller)
    delivered_email(user: seller, email: "buyer@example.com", at: starts_at + 1.day, suggested: true)
    delivered_email(user: seller, email: "buyer@example.com", at: starts_at + 2.days)
    create(:follower, user: seller, email: "buyer@example.com", confirmed_at: nil, deleted_at: starts_at + 3.days)
    result = report[:email_safety][:by_origin]
    expect(result[:suggested][:treatment][:successes]).to eq(0)
    expect(result[:hand_written][:treatment][:successes]).to eq(1)
  end

  it "counts newly enabled workflow carts once and requires a retained same-cart purchase within the recovery horizon" do
    assign(seller)
    assign(control, holdout: true)
    workflow = create(:abandoned_cart_workflow, seller:, first_published_at: starts_at + 1.day)
    sent_at = starts_at + 2.days
    order = create(:order)
    cart = create(:cart, order:)
    order.purchases << sale(at: sent_at + 1.day)
    create(:sent_abandoned_cart_email, cart:, installment: workflow.installments.first, created_at: sent_at)
    second = create(:workflow_installment, workflow:, seller:)
    create(:sent_abandoned_cart_email, cart:, installment: second, created_at: sent_at + 1.day)
    missed = create(:cart, order: create(:order))
    missed.order.purchases << sale(at: sent_at + 8.days)
    create(:sent_abandoned_cart_email, cart: missed, installment: second, created_at: sent_at)
    immature = create(:cart)
    create(:sent_abandoned_cart_email, cart: immature, installment: second, created_at: ends_at - 1.day)
    result = report[:cart_recovery]
    expect(result[:treatment]).to eq(n: 2, successes: 1, rate: 0.5)
    expect(result[:holdout][:n]).to eq(0)
    expect(report(recovery_days: 10)[:cart_recovery][:treatment][:successes]).to eq(2)
  end

  it "deduplicates email-linked repeats across email_infos and sent_post_emails without dropping unexposed buyers" do
    assign(seller, bucket: "under_100")
    original = sale(email: "linked@example.com", at: starts_at - 2.days)
    sale(email: "unexposed@example.com", at: starts_at - 2.days)
    sale(email: "linked@example.com", at: starts_at + 3.days)
    sale(email: "unexposed@example.com", at: starts_at + 3.days)
    post = create(:seller_post, seller:)
    create(:creator_contacting_customers_email_info, purchase: original, installment: post, sent_at: starts_at + 1.day)
    create(:sent_post_email, post:, email: original.email, created_at: starts_at + 2.days)
    expect(report(cohort: "already_sells")[:repeat_purchase][:treatment]).to include(n: 2, successes: 2, email_linked_successes: 1)
  end

  it "does not attribute repeat purchases to a later send or another seller" do
    assign(seller, bucket: "under_100")
    original = sale(email: "buyer@example.com", at: starts_at - 2.days)
    sale(email: original.email)
    other_post = create(:seller_post, seller: control)
    create(:sent_post_email, post: other_post, email: original.email, created_at: starts_at)
    post = create(:seller_post, seller:)
    create(:creator_contacting_customers_email_info, purchase: original, installment: post, sent_at: starts_at + 5.days)
    expect(report(cohort: "already_sells")[:repeat_purchase][:treatment][:email_linked_successes]).to eq(0)
  end

  it "rejects refunded and eighth-day first sales" do
    assign(seller, at: starts_at)
    attribute_sale(sale(stripe_refunded: true))
    attribute_sale(sale(at: starts_at + 7.days))
    expect(report[:first_sale][:treatment][:successes]).to eq(0)
  end

  it "keeps existing workflows and pre-assignment workflows out of new-workflow recovery" do
    assign(seller)
    workflow = create(:abandoned_cart_workflow, seller:, first_published_at: starts_at - 2.days, published_at: starts_at + 1.day)
    cart = create(:cart)
    create(:sent_abandoned_cart_email, cart:, installment: workflow.installments.first, created_at: starts_at + 2.days)
    expect(report[:cart_recovery][:treatment][:n]).to eq(0)
  end

  it "does not recover refunded, renewal, other-seller, or unrelated-order purchases" do
    assign(seller)
    workflow = create(:abandoned_cart_workflow, seller:, first_published_at: starts_at)
    cart = create(:cart, order: create(:order))
    create(:sent_abandoned_cart_email, cart:, installment: workflow.installments.first, created_at: starts_at)
    cart.order.purchases << sale(stripe_refunded: true)
    cart.order.purchases << renewal
    cart.order.purchases << sale(user: control)
    sale
    expect(report[:cart_recovery][:treatment]).to eq(n: 1, successes: 0, rate: 0.0)
  end

  it "ignores undelivered sends and deletions before delivery" do
    assign(seller)
    info = delivered_email(user: seller, email: "buyer@example.com", at: starts_at + 2.days)
    create(:follower, user: seller, email: info.purchase.email, confirmed_at: nil, deleted_at: starts_at + 1.day)
    create(:creator_contacting_customers_email_info, purchase: info.purchase, installment: create(:seller_post, seller:), sent_at: starts_at)
    expect(report[:email_safety][:hand_written]).to be_nil
    expect(report[:email_safety][:by_origin][:hand_written][:treatment]).to eq(n: 1, successes: 0, rate: 0.0)
  end

  it "excludes future assignments and never writes or deletes assignment rows" do
    assign(seller, at: ends_at + 1.day)
    before = Marketing::HoldoutAssignment.order(:id).map(&:attributes)
    expect(report[:assigned_creators]).to eq(treatment: 0, holdout: 0)
    expect(Marketing::HoldoutAssignment.order(:id).map(&:attributes)).to eq(before)
  end

  it "rejects future, inverted, non-90-day windows and invalid configuration" do
    expect { described_class.new(window_start: starts_at, window_end: starts_at, cohort: "zero_sale") }.to raise_error(ArgumentError)
    expect { report(cohort: "unknown") }.to raise_error(ArgumentError)
    expect { report(recovery_days: 0) }.to raise_error(ArgumentError)
    expect { report(deterioration_threshold: Float::NAN) }.to raise_error(ArgumentError)
  end
end
