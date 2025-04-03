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
    end
  end
end
