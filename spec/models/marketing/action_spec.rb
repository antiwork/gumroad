# frozen_string_literal: true

require "spec_helper"

describe Marketing::Action do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }

  describe "validations" do
    it "rejects copy longer than the room a 23-char link leaves in 280" do
      action = build(:marketing_action, copy: "a" * (described_class::MAX_COPY_LENGTH + 1))
      expect(action).not_to be_valid
      expect(build(:marketing_action, copy: "a" * described_class::MAX_COPY_LENGTH)).to be_valid
    end

    it "generates a unique idempotency key" do
      a = create(:marketing_action)
      expect(a.idempotency_key).to be_present
      expect(build(:marketing_action, idempotency_key: a.idempotency_key)).not_to be_valid
    end
  end

  describe "state machine" do
    let(:action) { create(:marketing_action, user: seller, link: product) }

    it "walks recommended → approved → queued → posted and stamps timestamps" do
      expect(action).to be_recommended
      action.approve!
      expect(action.approved_at).to be_present
      action.queue!
      action.mark_posted!
      expect(action).to be_posted
      expect(action.posted_at).to be_present
      expect(action).to be_terminal
    end

    it "lets an approved action be re-approved with edited copy but not a posted one" do
      action.approve!
      expect(action.approve).to be(true)
      action.queue!
      action.mark_posted!
      expect(action.approve).to be(false)
      expect(action.cancel).to be(false)
    end

    it "fails from approved or queued and cancels anything not yet claimed" do
      action.approve!
      expect(action.mark_failed).to be(true)
      other = create(:marketing_action, user: seller, link: product)
      expect(other.cancel).to be(true)
      expect(other.mark_failed).to be(false)
    end

    it "refuses to cancel an action the executor has claimed" do
      action.approve!
      action.queue!

      expect(action.cancel).to be(false)
      expect(action).to be_queued
    end

    it "stamps queued_at on queue and reopens the action when the connection cannot write" do
      action.approve!
      action.queue!
      expect(action.queued_at).to be_present

      expect(action.require_reconnect).to be(true)
      expect(action).to be_approved
      expect(action).not_to be_terminal
    end
  end

  describe ".find_or_create_open!" do
    it "reuses the open action for (user, link, channel) and creates a fresh one once it is terminal" do
      first = described_class.find_or_create_open!(user: seller, link: product, channel: "x") { |a| a.copy = "Hi" }
      again = described_class.find_or_create_open!(user: seller, link: product, channel: "x") { |a| a.copy = "Other" }
      expect(again).to eq(first)
      expect(again.copy).to eq("Hi")

      first.cancel!
      third = described_class.find_or_create_open!(user: seller, link: product, channel: "x") { |a| a.copy = "New" }
      expect(third).not_to eq(first)
      expect(described_class.open.where(link: product).count).to eq(1)
    end
  end

  describe "#approve_copy" do
    [nil, [], ["token"], { value: "token" }, "", " "].each do |token|
      it "requires a nonempty scalar confirmation token (#{token.inspect})" do
        action = create(:marketing_action, user: seller, link: product)
        original = action.attributes
        expect { action.approve_copy(confirmation_token: token, copy: "Changed") }.to raise_error(Marketing::Action::ConfirmationChanged)
        expect(action.reload.attributes).to eq(original)
      end
    end

    it "reloads a stale instance before freezing a claimed post" do
      action = create(:marketing_action, user: seller, link: product, copy: "Original")
      stale = described_class.find(action.id)
      action.approve!
      action.queue!

      expect(stale.approve_copy(confirmation_token: stale.confirmation_token, copy: "Changed")).to eq(:claimed)
      expect(action.reload.copy).to eq("Original")
      expect(action).to be_queued
    end

    it "reuses the idempotency key after repeated approvals" do
      action = create(:marketing_action, user: seller, link: product)
      key = action.api_idempotency_key
      2.times { expect(action.approve_copy(confirmation_token: action.confirmation_token)).to eq(:approved) }
      expect(action.reload.api_idempotency_key).to eq(key)
      expect(action.as_json[:idempotency_key]).not_to include(":")
    end

    it "returns a posted action without changing its copy or approval" do
      action = create(:marketing_action, user: seller, link: product)
      action.approve!
      action.queue!
      action.mark_posted!
      original = action.attributes
      expect(action.approve_copy(confirmation_token: action.confirmation_token, copy: "Changed")).to eq(:claimed)
      expect(action.reload.attributes).to eq(original)
    end
  end

  describe "#post_text" do
    it "appends the tagged short link after a blank line" do
      utm_link = create(:utm_link, seller:, target_resource_type: :product_page, target_resource_id: product.id)
      action = create(:marketing_action, user: seller, link: product, utm_link:, copy: "Hello")
      expect(action.post_text).to eq("Hello\n\n#{utm_link.short_url}")
    end
  end
end
