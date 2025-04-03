# frozen_string_literal: true

require "spec_helper"

describe SignupEvent do
  it "is an Event" do
    expect(build(:signup_event).is_a?(Event)).to eq(true)
  end
end
