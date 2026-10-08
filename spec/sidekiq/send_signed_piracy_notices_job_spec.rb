# frozen_string_literal: true

require "spec_helper"

describe SendSignedPiracyNoticesJob do
  let!(:signed) { create(:piracy_report, :signed) }
  let!(:awaiting) { create(:piracy_report, :awaiting_signature) }

  before do
    allow(PiracyReports::RecipientRegistry).to receive(:entries).and_return(
      "example.net" => PiracyReports::RecipientRegistry::Entry.new(name: "Example Net Inc.", email: "copyright@example.net", source_url: "https://dmca.copyright.gov/osp/example")
    )
  end

  it "sends every signed report while the sending flag is on, and nothing else" do
    Feature.activate(:piracy_reports_sending)

    described_class.new.perform

    expect(signed.reload.state).to eq("sent")
    expect(awaiting.reload.state).to eq("awaiting_signature")
  end

  it "sends nothing while the sending flag is off" do
    expect { described_class.new.perform }.not_to change { ActionMailer::Base.deliveries.count }
    expect(signed.reload.state).to eq("signed")
  end
end
