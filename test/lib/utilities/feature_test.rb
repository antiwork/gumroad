# frozen_string_literal: true

require "test_helper"

class FeatureTest < ActiveSupport::TestCase
  self.described_class = Feature


  context_ Feature do
    let(:user1) { create(:user) }
    let(:user2) { create(:user) }
    let(:feature_name) { :new_feature }

  context_ "#activate" do
  test "activates the feature for everyone" do
        expect do
          described_class.activate(feature_name)
        end.to change { Flipper.enabled?(feature_name) }.from(false).to(true)
      end
    end

  context_ "#activate_user" do
  test "activates the feature for the actor" do
        expect do
          described_class.activate_user(feature_name, user1)

          expect(Flipper.enabled?(feature_name)).to eq(false)
        end.to change { Flipper.enabled?(feature_name, user1) }.from(false).to(true)
      end
    end

  context_ "#deactivate" do
      before { Flipper.enable(feature_name) }

  test "deactivates the feature for everyone" do
        expect do
          described_class.deactivate(feature_name)
        end.to change { Flipper.enabled?(feature_name, user1) }.from(true).to(false)
           .and change { Flipper.enabled?(feature_name, user2) }.from(true).to(false)
           .and change { Flipper.enabled?(feature_name) }.from(true).to(false)
      end
    end

  context_ "#deactivate_user" do
      before { Flipper.enable_actor(feature_name, user1) }
      before { Flipper.enable_actor(feature_name, user2) }

  test "deactivates the feature for the actor" do
        expect do
          described_class.deactivate_user(feature_name, user1)

          expect(Flipper.enabled?(feature_name, user2)).to eq(true)
        end.to change { Flipper.enabled?(feature_name, user1) }.from(true).to(false)
      end
    end

  context_ "#activate_percentage" do
  test "activates the feature for the specified percentage of actors" do
        expect do
          described_class.activate_percentage(feature_name, 100)
        end.to change { Flipper[feature_name].percentage_of_actors_value }.from(0).to(100)
      end
    end

  context_ "#deactivate_percentage" do
      before { described_class.activate_percentage(feature_name, 100) }

  test "deactivates the percentage rollout" do
        expect do
          described_class.deactivate_percentage(feature_name)
        end.to change { Flipper[feature_name].percentage_of_actors_value }.from(100).to(0)
      end
    end

  context_ "#active?" do
  context_ "when an actor is passed" do
  test "returns true if the feature is active for the actor" do
          Flipper.enable_actor(feature_name, user1)

          expect(described_class.active?(feature_name, user1)).to eq(true)
        end

  test "returns false if the feature is not active for the actor" do
          expect(described_class.active?(feature_name, user1)).to eq(false)
        end
      end

  context_ "when no actor is passed" do
  test "returns true if the feature is active for everyone" do
          Flipper.enable(feature_name)

          expect(described_class.active?(feature_name)).to eq(true)
        end

  test "returns false if the feature is not active for everyone" do
          expect(described_class.active?(feature_name)).to eq(false)
        end
      end
    end

  context_ "#inactive?" do
  context_ "when an actor is passed" do
  test "returns false if the feature is active for the actor" do
          Flipper.enable_actor(feature_name, user1)

          expect(described_class.inactive?(feature_name, user1)).to eq(false)
        end

  test "returns true if the feature is not active for the actor" do
          expect(described_class.inactive?(feature_name, user1)).to eq(true)
        end
      end

  context_ "when no actor is passed" do
  test "returns false if the feature is active for everyone" do
          Flipper.enable(feature_name)

          expect(described_class.inactive?(feature_name)).to eq(false)
        end

  test "returns true if the feature is not active for everyone" do
          expect(described_class.inactive?(feature_name)).to eq(true)
        end
      end
    end
  end
end
