# frozen_string_literal: true

require "spec_helper"

describe GenerateUsernameJob do
  describe "#perform" do
    context "username is present" do
      it "does not generate a new username" do
        user = create(:user, username: "foo")
        expect_any_instance_of(UsernameGeneratorService).not_to receive(:username)
        described_class.new.perform(user.id)
      end
    end

    context "username is blank" do
      it "generates a new username" do
        user = create(:user, username: nil)
        expect_any_instance_of(UsernameGeneratorService).to receive(:username).and_return("foo")
        described_class.new.perform(user.id)
        expect(user.reload.username).to eq("foo")
      end

      it "leaves the default username when the generated one is blocked" do
        user = create(:user, username: nil)
        expect_any_instance_of(UsernameGeneratorService).to receive(:username).and_return("go88tv")
        described_class.new.perform(user.id)
        expect(user.reload.read_attribute(:username)).to be_nil
      end

      it "leaves the default username when a generated brand name relies on an unconfirmed address" do
        user = create(:unconfirmed_user, username: nil, email: "x@paypal.com")
        expect_any_instance_of(UsernameGeneratorService).to receive(:username).and_return("paypal")
        described_class.new.perform(user.id)
        expect(user.reload.read_attribute(:username)).to be_nil
      end

      it "keeps a generated brand name for a confirmed brand address" do
        user = create(:user, username: nil, email: "x@paypal.com")
        expect_any_instance_of(UsernameGeneratorService).to receive(:username).and_return("paypal")
        described_class.new.perform(user.id)
        expect(user.reload.username).to eq("paypal")
      end
    end
  end
end
