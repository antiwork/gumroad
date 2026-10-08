# frozen_string_literal: true

require "spec_helper"

describe SendSignedPiracyNoticesJob do
  let!(:signed) { create(:piracy_report, :signed, recipient_email: "copyright@example.com") }
  let!(:awaiting) { create(:piracy_report, :awaiting_signature) }

  before do
    allow(PiracyReports::RecipientRegistry).to receive(:entries).and_return(
      "example.net" => PiracyReports::RecipientRegistry::Entry.new(name: "Example Net Inc.", email: "copyright@example.com", source_url: "https://dmca.copyright.gov/osp/example")
    )
  end

  it "sends every signed report while the sending flag is on, and nothing else" do
    Feature.activate(:piracy_reports_sending)

    described_class.new.perform

    expect(signed.reload.state).to eq("sent")
    expect(awaiting.reload.state).to eq("awaiting_signature")
  end

  it "keeps sending the remaining reports when one raises" do
    Feature.activate(:piracy_reports_sending)
    later = create(:piracy_report, :signed, recipient_email: "copyright@example.com", product: create(:product, user: signed.seller), url: "https://example.net/other")
    allow(ErrorNotifier).to receive(:notify)
    allow_any_instance_of(PiracyReport).to receive(:send_notice!).and_wrap_original do |original, *args|
      raise ActiveRecord::RecordInvalid, original.receiver if original.receiver.id == signed.id

      original.call(*args)
    end

    expect { described_class.new.perform }.not_to raise_error

    expect(signed.reload.state).to eq("signed")
    expect(later.reload.state).to eq("sent")
    expect(ErrorNotifier).to have_received(:notify).with(an_instance_of(ActiveRecord::RecordInvalid), context: { piracy_report_id: signed.id })
  end

  it "sends nothing while the sending flag is off" do
    expect { described_class.new.perform }.not_to change { ActionMailer::Base.deliveries.count }
    expect(signed.reload.state).to eq("signed")
  end
end
