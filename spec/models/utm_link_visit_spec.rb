# frozen_string_literal: true

require "spec_helper"

describe UtmLinkVisit do
  describe "associations" do
    it { is_expected.to belong_to(:utm_link) }
    it { is_expected.to belong_to(:user).optional }
    it { is_expected.to have_many(:utm_link_driven_sales).dependent(:destroy) }
    it { is_expected.to have_many(:purchases).through(:utm_link_driven_sales) }
  end

  describe "validations" do
    it { is_expected.to be_versioned }

    it { is_expected.to validate_presence_of(:ip_address) }
    it { is_expected.to validate_presence_of(:browser_guid) }
  end
end
