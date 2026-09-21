# frozen_string_literal: true

require "spec_helper"

describe "Disabled form fields", type: :system, js: true do
  it "keeps saved affiliate details and disabled commissions readable" do
    seller = create(:named_seller)
    product = create(:product, user: seller)
    create(:product, user: seller)
    affiliate = create(:direct_affiliate, seller:, affiliate_user: create(:user, email: "affiliate@example.com"))
    create(:product_affiliate, affiliate:, product:, affiliate_basis_points: 1500)
    login_as seller

    visit edit_affiliate_path(affiliate.external_id)

    email = find_field("Email", with: "affiliate@example.com", disabled: true)
    commission = all(:field, "Commission", disabled: true).first
    group = commission.find(:xpath, "..")

    expect(email.evaluate_script("getComputedStyle(this).opacity")).to eq("1")
    expect(commission.evaluate_script("getComputedStyle(this).opacity")).to eq("1")
    expect(group.evaluate_script("getComputedStyle(this).opacity")).to eq("1")
    expect(commission.evaluate_script("getComputedStyle(this).backgroundColor")).to eq("rgba(0, 0, 0, 0)")
    expect(group.evaluate_script("getComputedStyle(this).backgroundColor")).not_to eq("rgba(0, 0, 0, 0)")
  end

  it "keeps enforced refund periods and fine print readable" do
    seller = create(:named_seller, refund_policy_enforced: true)
    seller.refund_policy.update!(max_refund_period_in_days: 30, fine_print: "Contact support within 30 days for a refund.")
    login_as seller

    visit settings_main_path

    period = find_field("Refund period", disabled: true)
    fine_print = find_field("Fine print", disabled: true)

    expect(period.value).to eq("30")
    expect(fine_print.value).to eq("Contact support within 30 days for a refund.")
    expect(period.evaluate_script("getComputedStyle(this).opacity")).to eq("1")
    expect(fine_print.evaluate_script("getComputedStyle(this).opacity")).to eq("1")
  end
end
