# frozen_string_literal: true

require "spec_helper"

describe PostEmailPersonalization do
  describe ".resolve" do
    it "uses the purchase's full name, first token only" do
      purchase = build(:purchase, full_name: "Jordi  Bruin")
      expect(described_class.resolve({ purchase: })).to eq("Jordi")
    end

    it "falls back to the carried purchaser name when the purchase is a bare id stub" do
      # This is what SendPostBlastEmailsJob actually hands the API services.
      expect(described_class.resolve({ purchase: Purchase.new(id: 1), purchaser_name: "Sahil Lavingia" })).to eq("Sahil")
    end

    it "is nil for a follower, who has no name anywhere" do
      expect(described_class.resolve({ follower: Follower.new(id: 1) })).to be_nil
    end

    it "is nil rather than blank for a whitespace-only name" do
      expect(described_class.resolve({ purchaser_name: "   " })).to be_nil
    end
  end

  describe ".apply" do
    it "substitutes the name" do
      expect(described_class.apply("Hi {{first_name}},", "Jordi")).to eq("Hi Jordi,")
    end

    it "never renders empty — a bare token falls back to the built-in default" do
      expect(described_class.apply("Hi {{first_name}},", nil)).to eq("Hi there,")
    end

    it "prefers the seller's own default over the built-in one" do
      expect(described_class.apply("Hi {{first_name|friend}},", nil)).to eq("Hi friend,")
    end

    it "ignores the seller default when a real name exists" do
      expect(described_class.apply("Hi {{first_name|friend}},", "Jordi")).to eq("Hi Jordi,")
    end

    it "handles several tokens with different defaults in one post" do
      expect(described_class.apply("{{first_name}} / {{first_name|pal}}", nil)).to eq("there / pal")
    end

    it "tolerates whitespace inside the braces" do
      expect(described_class.apply("Hi {{ first_name }},", "Jordi")).to eq("Hi Jordi,")
    end
  end

  describe ".substitutions" do
    it "emits one key per distinct spelling, since SendGrid matches keys exactly" do
      expect(described_class.substitutions("{{first_name}} {{first_name|pal}}", nil))
        .to eq("{{first_name}}" => "there", "{{first_name|pal}}" => "pal")
    end

    it "maps every spelling to the real name when one is known" do
      expect(described_class.substitutions("{{first_name}} {{first_name|pal}}", "Jordi"))
        .to eq("{{first_name}}" => "Jordi", "{{first_name|pal}}" => "Jordi")
    end

    it "is empty when the post uses no token" do
      expect(described_class.substitutions("Hello everyone", "Jordi")).to eq({})
    end
  end

  # The two provider services derive their substitution sets independently; a one-sided change
  # personalizes only the half of a blast that happened to route through that provider.
  it "keeps both provider services on the same resolver" do
    expect(File.read(Rails.root.join("app/services/post_resend_api.rb"))).to include("PostEmailPersonalization")
    expect(File.read(Rails.root.join("app/services/post_sendgrid_api.rb"))).to include("PostEmailPersonalization")
  end
end
