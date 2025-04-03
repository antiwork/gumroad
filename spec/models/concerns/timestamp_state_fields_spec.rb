# frozen_string_literal: true

require "spec_helper"

describe TimestampStateFields do
  class TestUser < ApplicationRecord
    self.table_name = "users"

    include TimestampStateFields
    timestamp_state_fields \
      :created,
      :confirmed,
      :banned,
      :deleted,
      default_state: :confirmed,
      states_excluded_from_default: %i[created]
  end

  let!(:user) do
    TestUser.create!(
      name: "Joe",
      email: "joe@example.com",
      recommendation_type: User::RecommendationType::OWN_PRODUCTS
    )
  end

  describe "class methods" do
    before { user.update_as_banned! }

    it "it filter records" do
      expect(TestUser.banned).to eq [user]
      expect(TestUser.not_banned).to eq []
    end
  end

  describe "instance methods" do
    it "returns boolean value when using predicate methods" do
      expect(user.created?).to be(true)
      expect(user.not_created?).to be(false)
    end

    it "updates record via update methods" do
      expect(user.banned?).to be(false)
      user.update_as_banned!
      expect(user.banned?).to be(true)
      user.update_as_not_banned!
      expect(user.banned?).to be(false)
    end

    it "reponds to state methods" do
      expect(user.created?).to be(true)
      expect(user.state_confirmed?).to be(true)
      expect(user.state).to eq(:confirmed)

      expect(user.banned?).to be(false)
      expect(user.deleted?).to be(false)

      user.update_as_banned!
      expect(user.state).to eq(:banned)
      expect(user.state_banned?).to be(true)
    end
  end
end
