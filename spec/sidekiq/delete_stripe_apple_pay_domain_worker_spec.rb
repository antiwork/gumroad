# frozen_string_literal: true

describe DeleteStripeApplePayDomainWorker, :vcr do
  describe "#perform" do
    before do
      @user = create(:user)
      @domain = "sampleusername.gumroad.dev"
    end

    it "deletes StripeApplePayDomain record when record exists on Stripe" do
      response = Stripe::ApplePayDomain.create(domain_name: @domain)
      StripeApplePayDomain.create!(user_id: @user.id, domain: @domain, stripe_id: response.id)
      described_class.new.perform(@user.id, @domain)
      expect(StripeApplePayDomain.count).to eq(0)
    end

    it "deletes StripeApplePayDomain record when record doesn't exist on Stripe" do
      StripeApplePayDomain.create!(user_id: @user.id, domain: @domain, stripe_id: "random_stripe_id")
      described_class.new.perform(@user.id, @domain)
      expect(StripeApplePayDomain.count).to eq(0)
    end
  end
end
