# frozen_string_literal: true

require "spec_helper"

describe Iffy::EventJob do
  describe "#perform" do
    let(:id) { 1 }
    let(:entity) { "Product" }

    context "when event is valid" do
      Iffy::EventJob::EVENTS.each do |event|
        it "calls the appropriate service for #{event}" do
          service_class = (
            case event
            when "user.banned"
              Iffy::User::BanService
            when "user.suspended"
              Iffy::User::SuspendService
            when "user.compliant"
              Iffy::User::MarkCompliantService
            when "record.flagged"
              entity == "Product" ? Iffy::Product::FlagService : Iffy::Post::FlagService
            when "record.compliant"
              entity == "Product" ? Iffy::Product::MarkCompliantService : Iffy::Post::MarkCompliantService
            end
          )

          service = double(perform: true)
          expect(service_class).to receive(:new).with(id).and_return(service)
          expect(service).to receive(:perform)

          described_class.new.perform(event, id, entity)
        end
      end
    end

    context "when event is invalid" do
      it "does not call any service" do
        expect(Iffy::User::BanService).not_to receive(:new)
        expect(Iffy::User::SuspendService).not_to receive(:new)
        expect(Iffy::User::MarkCompliantService).not_to receive(:new)
        expect(Iffy::Product::FlagService).not_to receive(:new)
        expect(Iffy::Product::MarkCompliantService).not_to receive(:new)
        expect(Iffy::Post::FlagService).not_to receive(:new)
        expect(Iffy::Post::MarkCompliantService).not_to receive(:new)

        described_class.new.perform("invalid.event", id, entity)
      end
    end

    context "when user is protected" do
      let(:event) { "record.flagged" }
      let(:protected_user) { { "protected" => true } }

      it "does not call FlagService for protected users" do
        expect(Iffy::Product::FlagService).not_to receive(:new)
        expect(Iffy::Post::FlagService).not_to receive(:new)

        described_class.new.perform(event, id, entity, protected_user)
      end

      it "calls FlagService for non-protected users" do
        non_protected_user = { "protected" => false }
        service = double(perform: true)

        expect(Iffy::Product::FlagService).to receive(:new).with(id).and_return(service)
        expect(service).to receive(:perform)

        described_class.new.perform(event, id, entity, non_protected_user)
      end
    end
  end
end
