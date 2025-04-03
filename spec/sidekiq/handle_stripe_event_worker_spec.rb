# frozen_string_literal: true

describe HandleStripeEventWorker do
  describe "perform" do
    describe "stripe_connect_account_id is not provided" do
      it "calls the StripeEventHandler" do
        id = rand(10_000).to_s
        expect_any_instance_of(StripeEventHandler).to receive(:handle_stripe_event)
        expect(StripeEventHandler).to receive(:new).with({ id:, type: "deauthorized" }).and_call_original
        described_class.new.perform(id:, type: "deauthorized")
      end
    end

    describe "stripe_connect_account_id is provided" do
      it "calls the StripeEventHandler" do
        id = rand(10_000).to_s
        expect_any_instance_of(StripeEventHandler).to receive(:handle_stripe_event)
        expect(StripeEventHandler).to receive(:new).with({ id:, user_id: "acct_1234", type: "deauthorized" }).and_call_original
        described_class.new.perform(id:, user_id: "acct_1234", type: "deauthorized")
      end
    end
  end
end
