# frozen_string_literal: true

require "spec_helper"

describe YearlyStat do
  describe "associations" do
    it { is_expected.to belong_to(:user) }
  end
end
