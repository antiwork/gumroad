# frozen_string_literal: true

require "spec_helper"

describe Iffy::Profile::IngestJob do
  describe "#perform" do
    let(:user) { create(:user) }

    it "invokes the ingest service with the correct user" do
      expect(Iffy::Profile::IngestService).to receive(:new).with(user).and_call_original
      expect_any_instance_of(Iffy::Profile::IngestService).to receive(:perform)

      Iffy::Profile::IngestJob.new.perform(user.id)
    end
  end
end
