# frozen_string_literal: true

require "spec_helper"

describe "InstallmentScopes"  do
  before do
    @creator = create(:named_user, :with_avatar)
    @installment = create(:installment, call_to_action_text: "CTA", call_to_action_url: "https://www.example.com", seller: @creator)
  end

  describe ".shown_on_profile" do
    before do
      @installment1 = create(:installment, shown_on_profile: true, send_emails: false)
      @installment2 = create(:installment, shown_on_profile: true, send_emails: true)
      create(:installment)
    end

    it "returns installments shown on profile" do
      Installment.shown_on_profile.tap do |installments|
        expect(installments.count).to eq(2)
        expect(installments).to contain_exactly(@installment1, @installment2)
      end
    end
  end

  describe ".profile_only" do
    before do
      @installment = create(:installment, shown_on_profile: true, send_emails: false)
      create(:installment, shown_on_profile: false, send_emails: true)
    end

    it "returns installments shown only on profile" do
      Installment.profile_only.tap do |installments|
        expect(installments.count).to eq(1)
        expect(installments).to contain_exactly(@installment)
      end
    end
  end

  describe ".published" do
    let!(:published_installement) { create(:published_installment) }
    let!(:not_published_installement) { create(:installment) }

    it "returns published installments" do
      result = Installment.published
      expect(result).to include(published_installement)
      expect(result).to_not include(not_published_installement)
    end
  end

  describe ".not_published" do
    let!(:published_installement) { create(:published_installment) }
    let!(:not_published_installement) { create(:installment) }

    it "returns unpublished installments" do
      result = Installment.not_published
      expect(result).to include(not_published_installement)
      expect(result).to_not include(published_installement)
    end
  end

  describe ".scheduled" do
    let!(:published_installment) { create(:published_installment) }
    let!(:scheduled_installment) { create(:scheduled_installment) }
    let!(:drafts_installment) { create(:installment) }

    it "returns scheduled installments" do
      result = Installment.scheduled
      expect(result).to include(scheduled_installment)
      expect(result).to_not include(published_installment, drafts_installment)
    end
  end

  describe ".draft" do
    let!(:published_installment) { create(:published_installment) }
    let!(:scheduled_installment) { create(:scheduled_installment) }
    let!(:drafts_installment) { create(:installment) }

    it "returns draft installments" do
      result = Installment.draft
      expect(result).to include(drafts_installment)
      expect(result).to_not include(published_installment, scheduled_installment)
    end
  end
end
