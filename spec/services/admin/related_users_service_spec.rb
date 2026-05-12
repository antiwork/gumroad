# frozen_string_literal: true

require "spec_helper"

describe Admin::RelatedUsersService do
  def credit_card_with_fingerprint(fingerprint)
    CreditCard.create!(
      stripe_fingerprint: fingerprint,
      visual: "**** **** **** 4242",
      card_type: CardType::VISA,
      stripe_customer_id: "cus_#{SecureRandom.hex(6)}",
      expiry_month: 12,
      expiry_year: 2030,
      charge_processor_id: StripeChargeProcessor.charge_processor_id
    )
  end

  def related_user_payload(result, user)
    result.related_users.find { _1[:id] == user.external_id }
  end

  it "returns users sharing any target IP with the matching columns" do
    target = create(:user, account_created_ip: nil, current_sign_in_ip: "1.2.3.4", last_sign_in_ip: nil, payment_address: nil)
    created_ip_match = create(:user, account_created_ip: "1.2.3.4", current_sign_in_ip: nil, last_sign_in_ip: nil, payment_address: nil)
    last_ip_match = create(:user, account_created_ip: nil, current_sign_in_ip: nil, last_sign_in_ip: "1.2.3.4", payment_address: nil)
    create(:user, account_created_ip: nil, current_sign_in_ip: nil, last_sign_in_ip: "5.6.7.8", payment_address: nil)

    result = described_class.new(target, signals: ["ip"]).call

    expect(result.signals_evaluated).to eq(["ip"])
    expect(result.related_users.map { _1[:id] }).to contain_exactly(created_ip_match.external_id, last_ip_match.external_id)
    expect(related_user_payload(result, created_ip_match)[:relations]).to contain_exactly(
      signal: "ip",
      shared_value: "1.2.3.4",
      via: ["account_created_ip", "current_sign_in_ip"]
    )
    expect(related_user_payload(result, last_ip_match)[:relations]).to contain_exactly(
      signal: "ip",
      shared_value: "1.2.3.4",
      via: ["current_sign_in_ip", "last_sign_in_ip"]
    )
  end

  it "aggregates IP via columns for a related user matching the same shared value multiple ways" do
    target = create(:user, account_created_ip: "1.2.3.4", current_sign_in_ip: nil, last_sign_in_ip: nil, payment_address: nil)
    related = create(:user, account_created_ip: "1.2.3.4", current_sign_in_ip: "1.2.3.4", last_sign_in_ip: nil, payment_address: nil)

    result = described_class.new(target, signals: ["ip"]).call

    expect(related_user_payload(result, related)[:relations]).to contain_exactly(
      signal: "ip",
      shared_value: "1.2.3.4",
      via: ["account_created_ip", "current_sign_in_ip"]
    )
  end

  it "returns users sharing the target payment address" do
    target = create(:user, payment_address: "shared-payment@example.com")
    related = create(:user, payment_address: "shared-payment@example.com")
    create(:user, payment_address: "other-payment@example.com")

    result = described_class.new(target, signals: ["payment_address"]).call

    expect(result.signals_evaluated).to eq(["payment_address"])
    expect(result.related_users.map { _1[:id] }).to eq([related.external_id])
    expect(result.related_users.first[:relations]).to eq([
                                                           {
                                                             signal: "payment_address",
                                                             shared_value: "shared-payment@example.com",
                                                           }
                                                         ])
  end

  it "skips payment address when the target has no payment address" do
    target = create(:user, payment_address: nil)
    create(:user, payment_address: nil)

    result = described_class.new(target, signals: ["payment_address"]).call

    expect(result.signals_evaluated).to eq([])
    expect(result.related_users).to eq([])
    expect(result.truncated).to eq("payment_address" => false)
  end

  it "returns users sharing the target card fingerprint without exposing the fingerprint value" do
    target = create(:user, payment_address: nil, credit_card: credit_card_with_fingerprint("fp_shared"))
    first_related = create(:user, payment_address: nil, credit_card: credit_card_with_fingerprint("fp_shared"))
    second_related = create(:user, payment_address: nil, credit_card: credit_card_with_fingerprint("fp_shared"))
    create(:user, payment_address: nil, credit_card: credit_card_with_fingerprint("fp_other"))

    result = described_class.new(target, signals: ["card_fingerprint"]).call

    expect(result.signals_evaluated).to eq(["card_fingerprint"])
    expect(result.related_users.map { _1[:id] }).to contain_exactly(first_related.external_id, second_related.external_id)
    expect(result.related_users.flat_map { _1[:relations] }).to all(eq(signal: "card_fingerprint", shared_value: nil))
  end

  it "skips card fingerprint when the target has no credit card" do
    target = create(:user, payment_address: nil, credit_card: nil)

    result = described_class.new(target, signals: ["card_fingerprint"]).call

    expect(result.signals_evaluated).to eq([])
    expect(result.related_users).to eq([])
    expect(result.truncated).to eq("card_fingerprint" => false)
  end

  it "deduplicates by user and ranks users matching more distinct signals first" do
    target = create(:user, account_created_ip: "1.2.3.4", current_sign_in_ip: nil, last_sign_in_ip: nil, payment_address: "shared@example.com")
    multi_signal = create(:user, account_created_ip: "1.2.3.4", current_sign_in_ip: nil, last_sign_in_ip: nil, payment_address: "shared@example.com", updated_at: 2.days.ago)
    single_signal = create(:user, account_created_ip: "1.2.3.4", current_sign_in_ip: nil, last_sign_in_ip: nil, payment_address: "other@example.com", updated_at: 1.hour.ago)

    result = described_class.new(target, signals: %w[ip payment_address]).call

    expect(result.related_users.map { _1[:id] }).to eq([multi_signal.external_id, single_signal.external_id])
    expect(result.related_users.first[:relations].map { _1[:signal] }).to contain_exactly("ip", "payment_address")
  end

  it "caps the IP signal to the most recently updated matches and reports truncation" do
    target = create(:user, account_created_ip: "1.2.3.4", current_sign_in_ip: nil, last_sign_in_ip: nil, payment_address: nil)
    oldest = create(:user, account_created_ip: "1.2.3.4", current_sign_in_ip: nil, last_sign_in_ip: nil, payment_address: nil, updated_at: 3.days.ago)
    middle = create(:user, account_created_ip: "1.2.3.4", current_sign_in_ip: nil, last_sign_in_ip: nil, payment_address: nil, updated_at: 2.days.ago)
    newest = create(:user, account_created_ip: "1.2.3.4", current_sign_in_ip: nil, last_sign_in_ip: nil, payment_address: nil, updated_at: 1.day.ago)

    result = described_class.new(target, signals: ["ip"], limit: 2).call

    expect(result.related_users.map { _1[:id] }).to eq([newest.external_id, middle.external_id])
    expect(result.related_users.map { _1[:id] }).not_to include(oldest.external_id)
    expect(result.truncated).to eq("ip" => true)
  end

  it "caps the payment address signal to the most recently updated matches" do
    target = create(:user, payment_address: "shared-payment@example.com")
    oldest = create(:user, payment_address: "shared-payment@example.com", updated_at: 3.days.ago)
    middle = create(:user, payment_address: "shared-payment@example.com", updated_at: 2.days.ago)
    newest = create(:user, payment_address: "shared-payment@example.com", updated_at: 1.day.ago)

    result = described_class.new(target, signals: ["payment_address"], limit: 2).call

    expect(result.related_users.map { _1[:id] }).to eq([newest.external_id, middle.external_id])
    expect(result.related_users.map { _1[:id] }).not_to include(oldest.external_id)
    expect(result.truncated).to eq("payment_address" => true)
  end

  it "caps the card fingerprint signal to the most recently updated matches" do
    target = create(:user, payment_address: nil, credit_card: credit_card_with_fingerprint("fp_shared"))
    oldest = create(:user, payment_address: nil, credit_card: credit_card_with_fingerprint("fp_shared"), updated_at: 3.days.ago)
    middle = create(:user, payment_address: nil, credit_card: credit_card_with_fingerprint("fp_shared"), updated_at: 2.days.ago)
    newest = create(:user, payment_address: nil, credit_card: credit_card_with_fingerprint("fp_shared"), updated_at: 1.day.ago)

    result = described_class.new(target, signals: ["card_fingerprint"], limit: 2).call

    expect(result.related_users.map { _1[:id] }).to eq([newest.external_id, middle.external_id])
    expect(result.related_users.map { _1[:id] }).not_to include(oldest.external_id)
    expect(result.truncated).to eq("card_fingerprint" => true)
  end

  it "excludes the target user from related users" do
    target = create(:user, account_created_ip: "1.2.3.4", current_sign_in_ip: nil, last_sign_in_ip: nil, payment_address: "shared@example.com", credit_card: credit_card_with_fingerprint("fp_shared"))

    result = described_class.new(target).call

    expect(result.related_users).to eq([])
  end

  it "includes soft-deleted related users with deletion state exposed" do
    target = create(:user, account_created_ip: "1.2.3.4", current_sign_in_ip: nil, last_sign_in_ip: nil, payment_address: nil)
    deleted = create(:user, :deleted, account_created_ip: "1.2.3.4", current_sign_in_ip: nil, last_sign_in_ip: nil, payment_address: nil)

    result = described_class.new(target, signals: ["ip"]).call

    expect(related_user_payload(result, deleted)).to include(
      id: deleted.external_id,
      deleted_at: deleted.deleted_at.as_json
    )
  end

  it "returns empty results when the target has no related signal values" do
    target = create(:user, account_created_ip: nil, current_sign_in_ip: nil, last_sign_in_ip: nil, payment_address: nil, credit_card: nil)

    result = described_class.new(target).call

    expect(result.signals_evaluated).to eq([])
    expect(result.related_users).to eq([])
    expect(result.truncated).to eq(
      "ip" => false,
      "payment_address" => false,
      "card_fingerprint" => false
    )
  end
end
