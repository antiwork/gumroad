module StripeSignup
  def self.disabled?
    ENV["DISABLE_STRIPE_SIGNUP"] == "true"
  end
end
