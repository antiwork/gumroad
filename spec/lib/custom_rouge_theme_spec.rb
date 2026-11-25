# frozen_string_literal: true

require "spec_helper"

describe CustomRougeTheme do
  let(:theme) { described_class.mode(:light) }

  # Code in an email is 14px regular text, so each token needs WCAG AA's 4.5:1 on the block.
  it "keeps every token colour readable on the code block surface" do
    surface = theme.palette(:bg0)
    ratios = theme.styles.keys.filter_map do |token|
      color = theme.get_style(token).fg
      [token.qualname, ContrastColor.ratio_between(color, surface).round(2)] if color
    end.to_h

    expect(ratios).not_to be_empty
    expect(ratios.select { |_, ratio| ratio < ContrastColor::WCAG_AA_NORMAL_TEXT }).to eq({})
  end
end
