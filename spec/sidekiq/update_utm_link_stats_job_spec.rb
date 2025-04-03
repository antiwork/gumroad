# frozen_string_literal: true

describe UpdateUtmLinkStatsJob do
  describe "#perform" do
    let(:utm_link) { create(:utm_link) }
    let!(:utm_link_visit1) { create(:utm_link_visit, utm_link:, browser_guid: "abc123") }
    let!(:utm_link_visit2) { create(:utm_link_visit, utm_link:, browser_guid: "def456") }
    let!(:utm_link_visit3) { create(:utm_link_visit, utm_link:, browser_guid: "abc123") }

    it "updates the utm_link's stats" do
      described_class.new.perform(utm_link.id)

      expect(utm_link.reload.total_clicks).to eq(3)
      expect(utm_link.unique_clicks).to eq(2)
    end
  end
end
