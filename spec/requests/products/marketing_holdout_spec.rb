# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Launch card holdout", type: :system, js: true do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }

  [false, true].each do |holdout|
    it "#{holdout ? 'hides' : 'shows'} the card for a #{holdout ? 'holdout' : 'treatment'} seller at full rollout" do
      create(:marketing_holdout_assignment, user: seller, marketing_holdout: holdout)
      Feature.activate_percentage(:auto_marketing, 100)
      Feature.activate_user(:auto_marketing, seller)
      login_as(seller)
      visit "#{edit_link_path(product.unique_permalink)}/share"

      expect(page).to have_button("Copy checkout URL")
      if holdout
        expect(page).not_to have_text("Share your launch")
        expect(Marketing::Action.where(user: seller).count).to eq(0)
      else
        expect(page).to have_text("Share your launch")
        expect(page).to have_text("Connect X")
        expect(Marketing::Action.where(user: seller).count).to eq(1)
      end
    end
  end
end
