# frozen_string_literal: true

require "spec_helper"

describe UtmLinkDrivenSale do
  describe "associations" do
    it { is_expected.to belong_to(:utm_link).optional(false) }
    it { is_expected.to belong_to(:utm_link_visit).optional(false) }
    it { is_expected.to belong_to(:purchase).optional(false) }
  end

  describe "validations" do
    context "purchase_id and utm_link_visit_id uniqueness" do
      subject(:sale) { build(:utm_link_driven_sale, utm_link: create(:utm_link)) }

      it { is_expected.to validate_uniqueness_of(:purchase_id).scoped_to(:utm_link_visit_id) }
    end
  end
end
