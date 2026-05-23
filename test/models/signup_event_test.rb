# frozen_string_literal: true

require "test_helper"

class SignupEventTest < ActiveSupport::TestCase
  self.described_class = SignupEvent



  context_ SignupEvent do
  test "is an Event" do
      expect(build(:signup_event).is_a?(Event)).to eq(true)
    end
  end
end
