# frozen_string_literal: true

require "spec_helper"

describe Onetime::ResetFormerStoreThemeDefaults do
  # after_initialize fills a blank column with the current default, so read the stored values.
  def stored(profile)
    SellerProfile.where(id: profile.id).pick(:border_radius, :button_hover)
  end

  let!(:former_defaults) { create(:seller_profile, border_radius: "small", button_hover: "lift") }
  let!(:chosen_corners) { create(:seller_profile, border_radius: "large", button_hover: "lift") }
  let!(:chosen_hover) { create(:seller_profile, border_radius: "small", button_hover: "none") }
  let!(:untouched) { create(:seller_profile, border_radius: "none", button_hover: "none") }

  it "changes nothing on a dry run and reports what it would reset" do
    expect(described_class.process).to eq(border_radius: 2, button_hover: 2)

    expect(stored(former_defaults)).to eq(%w[small lift])
  end

  it "clears only the former defaults, so those stores follow the current ones" do
    expect(described_class.process(dry_run: false)).to eq(border_radius: 2, button_hover: 2)

    expect(stored(former_defaults)).to eq([nil, nil])
    expect(stored(chosen_corners)).to eq(["large", nil])
    expect(stored(chosen_hover)).to eq([nil, "none"])
    expect(stored(untouched)).to eq(%w[none none])
    expect(former_defaults.reload).to have_attributes(border_radius: "medium", button_hover: "none")
  end

  it "drops the compiled CSS of the stores it resets and keeps the others" do
    [former_defaults, untouched].each(&:custom_styles)

    described_class.process(dry_run: false)

    expect(Rails.cache.exist?(former_defaults.custom_style_cache_name)).to eq(false)
    expect(Rails.cache.exist?(untouched.custom_style_cache_name)).to eq(true)
    expect(former_defaults.reload.custom_styles).to include("--radius: 0.5rem;--button-hover-offset: 0rem")
  end

  it "has nothing left to reset on a second run" do
    described_class.process(dry_run: false)

    expect(described_class.process(dry_run: false)).to eq(border_radius: 0, button_hover: 0)
  end
end
