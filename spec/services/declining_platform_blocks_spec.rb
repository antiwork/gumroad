# frozen_string_literal: true

require "spec_helper"

describe DecliningPlatformBlocks do
  let(:clean_request_ip) { "192.0.2.50" }
  let(:seller) do
    create(:user, current_sign_in_ip: "198.51.100.1", last_sign_in_ip: "198.51.100.2", account_created_ip: "198.51.100.3")
  end
  let(:product) { create(:product, user: seller) }
  let(:buyer) do
    create(:user, email: "held-buyer@example.com",
                  current_sign_in_ip: "203.0.113.10", last_sign_in_ip: "203.0.113.11", account_created_ip: "203.0.113.12")
  end

  def ip_failure(**attrs)
    create(:purchase, link: product, email: "typed-at-checkout@example.com", ip_address: clean_request_ip,
                      purchase_state: "failed", error_code: PurchaseErrorCode::BLOCKED_IP_ADDRESS, **attrs)
  end

  def block_value(value, object_type: :ip_address)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[object_type], object_value: value, expires_in: 6.months)
  end

  # Runs the real checkout IP check on a fresh copy of the row, so each fixture proves the block it
  # reports is one checkout enforces — and that checkout itself is unchanged.
  def checkout_declines?(purchase)
    attempt = Purchase.find(purchase.id)
    attempt.error_code = nil
    attempt.send(:check_for_past_fraudulent_ips)
    attempt.error_code == PurchaseErrorCode::BLOCKED_IP_ADDRESS
  end

  def query_count(failures)
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { described_class.new(failures).call }
    count
  end

  def declining_block(purchase)
    described_class.new([Purchase.find(purchase.id)]).call[purchase.id]
  end

  describe "account IPs behind a clean request IP" do
    %i[current_sign_in_ip last_sign_in_ip account_created_ip].each do |column|
      it "resolves a block on the buyer's #{column}" do
        failure = ip_failure(purchaser: buyer)
        block = block_value(buyer.public_send(column))

        expect(checkout_declines?(failure)).to be(true)
        expect(declining_block(failure)).to eq(block)
      end
    end

    it "resolves the account behind the checkout email" do
      failure = ip_failure(email: buyer.email)
      block = block_value(buyer.last_sign_in_ip)

      expect(checkout_declines?(failure)).to be(true)
      expect(declining_block(failure)).to eq(block)
    end

    it "resolves the account behind the PayPal email" do
      failure = ip_failure(charge_processor_id: PaypalChargeProcessor.charge_processor_id, card_visual: buyer.email)
      block = block_value(buyer.last_sign_in_ip)

      expect(checkout_declines?(failure)).to be(true)
      expect(declining_block(failure)).to eq(block)
    end

    it "resolves the account behind the gifter email" do
      failure = ip_failure(is_gift_sender_purchase: true)
      create(:gift, link: product, gifter_purchase: failure, gifter_email: buyer.email)
      block = block_value(buyer.last_sign_in_ip)

      expect(checkout_declines?(failure)).to be(true)
      expect(declining_block(failure)).to eq(block)
    end

    it "resolves an account IP stored under an unexpected object_type, as checkout matches by value" do
      failure = ip_failure(purchaser: buyer)
      block = block_value(buyer.current_sign_in_ip, object_type: :browser_guid)

      expect(checkout_declines?(failure)).to be(true)
      expect(declining_block(failure)).to eq(block)
    end

    it "ignores an expired account IP block" do
      failure = ip_failure(purchaser: buyer)
      block_value(buyer.current_sign_in_ip).update!(expires_at: 1.minute.ago)

      expect(checkout_declines?(failure)).to be(false)
      expect(declining_block(failure)).to be_nil
    end

    it "reports the earliest of several blocks holding the row" do
      failure = ip_failure(purchaser: buyer)
      newer = block_value(buyer.current_sign_in_ip)
      older = block_value(buyer.account_created_ip)
      older.update!(blocked_at: 2.months.ago)

      expect(declining_block(failure)).to eq(older)
      expect(newer.reload.blocked_at).to be_present
    end
  end

  describe "seller IPs" do
    it "does not report a block on the seller's IP alone, which checkout does not decline the buyer on" do
      failure = ip_failure(purchaser: buyer)
      block_value(seller.current_sign_in_ip)

      expect(checkout_declines?(failure)).to be(false)
      expect(declining_block(failure)).to be_nil
    end

    it "reports a block on an address the buyer's account shares with the seller" do
      buyer.update!(last_sign_in_ip: seller.current_sign_in_ip)
      failure = ip_failure(purchaser: buyer)
      block = block_value(seller.current_sign_in_ip)

      expect(checkout_declines?(failure)).to be(true)
      expect(declining_block(failure)).to eq(block)
    end
  end

  it "still resolves a block on the request IP itself" do
    failure = ip_failure(ip_address: "192.0.2.99")
    block = block_value("192.0.2.99")

    expect(declining_block(failure)).to eq(block)
  end

  it "resolves a whole batch in a fixed number of queries" do
    build_failures = lambda do |n|
      n.times.map do |index|
        account = create(:user, last_sign_in_ip: "203.0.113.#{100 + index}")
        failure = ip_failure(purchaser: account, is_gift_sender_purchase: true)
        create(:gift, link: product, gifter_purchase: failure, gifter_email: account.email)
        block_value(account.last_sign_in_ip)
        failure.id
      end
    end

    one = build_failures.call(1)
    many = build_failures.call(4)

    expect(described_class.new(Purchase.where(id: many).to_a).call.size).to eq(4)
    expect(query_count(Purchase.where(id: many).to_a)).to eq(query_count(Purchase.where(id: one).to_a))
  end
end
