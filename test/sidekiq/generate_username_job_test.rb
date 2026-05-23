# frozen_string_literal: true

require "test_helper"

class GenerateUsernameJobTest < ActiveSupport::TestCase
  self.described_class = GenerateUsernameJob



  context_ GenerateUsernameJob do
  context_ "#perform" do
  context_ "username is present" do
  test "does not generate a new username" do
          user = create(:user, username: "foo")
          expect_any_instance_of(UsernameGeneratorService).not_to receive(:username)
          described_class.new.perform(user.id)
        end
      end

  context_ "username is blank" do
  test "generates a new username" do
          user = create(:user, username: nil)
          expect_any_instance_of(UsernameGeneratorService).to receive(:username).and_return("foo")
          described_class.new.perform(user.id)
          expect(user.reload.username).to eq("foo")
        end
      end
    end
  end
end
