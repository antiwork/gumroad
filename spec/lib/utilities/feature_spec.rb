# frozen_string_literal: true

RSpec.describe Feature do
  let(:user1) { create(:user) }
  let(:user2) { create(:user) }
  let(:feature_name) { :new_feature }

  describe "#activate" do
    it "activates the feature for everyone" do
      expect do
        described_class.activate(feature_name)
      end.to change { Flipper.enabled?(feature_name) }.from(false).to(true)
    end
  end

  describe "#activate_user" do
    it "activates the feature for the actor" do
      expect do
        described_class.activate_user(feature_name, user1)

        expect(Flipper.enabled?(feature_name)).to eq(false)
      end.to change { Flipper.enabled?(feature_name, user1) }.from(false).to(true)
    end
  end

  describe "#deactivate" do
    before { Flipper.enable(feature_name) }

    it "deactivates the feature for everyone" do
      expect do
        described_class.deactivate(feature_name)
      end.to change { Flipper.enabled?(feature_name, user1) }.from(true).to(false)
         .and change { Flipper.enabled?(feature_name, user2) }.from(true).to(false)
         .and change { Flipper.enabled?(feature_name) }.from(true).to(false)
    end
  end

  describe "#deactivate_user" do
    before { Flipper.enable_actor(feature_name, user1) }
    before { Flipper.enable_actor(feature_name, user2) }

    it "deactivates the feature for the actor" do
      expect do
        described_class.deactivate_user(feature_name, user1)

        expect(Flipper.enabled?(feature_name, user2)).to eq(true)
      end.to change { Flipper.enabled?(feature_name, user1) }.from(true).to(false)
    end
  end

  describe "#activate_percentage" do
    it "activates the feature for the specified percentage of actors" do
      expect do
        described_class.activate_percentage(feature_name, 100)
      end.to change { Flipper[feature_name].percentage_of_actors_value }.from(0).to(100)
    end
  end

  describe "#deactivate_percentage" do
    before { described_class.activate_percentage(feature_name, 100) }

    it "deactivates the percentage rollout" do
      expect do
        described_class.deactivate_percentage(feature_name)
      end.to change { Flipper[feature_name].percentage_of_actors_value }.from(100).to(0)
    end
  end

  describe "#active?" do
    context "when an actor is passed" do
      it "returns true if the feature is active for the actor" do
        Flipper.enable_actor(feature_name, user1)

        expect(described_class.active?(feature_name, user1)).to eq(true)
      end

      it "returns false if the feature is not active for the actor" do
        expect(described_class.active?(feature_name, user1)).to eq(false)
      end
    end

    context "when no actor is passed" do
      it "returns true if the feature is active for everyone" do
        Flipper.enable(feature_name)

        expect(described_class.active?(feature_name)).to eq(true)
      end

      it "returns false if the feature is not active for everyone" do
        expect(described_class.active?(feature_name)).to eq(false)
      end
    end
  end

  describe "#inactive?" do
    context "when an actor is passed" do
      it "returns false if the feature is active for the actor" do
        Flipper.enable_actor(feature_name, user1)

        expect(described_class.inactive?(feature_name, user1)).to eq(false)
      end

      it "returns true if the feature is not active for the actor" do
        expect(described_class.inactive?(feature_name, user1)).to eq(true)
      end
    end

    context "when no actor is passed" do
      it "returns false if the feature is active for everyone" do
        Flipper.enable(feature_name)

        expect(described_class.inactive?(feature_name)).to eq(false)
      end

      it "returns true if the feature is not active for everyone" do
        expect(described_class.inactive?(feature_name)).to eq(true)
      end
    end
  end
end
