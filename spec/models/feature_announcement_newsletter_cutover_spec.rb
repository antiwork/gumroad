# frozen_string_literal: true

require "spec_helper"

describe FeatureAnnouncementNewsletterCutover do
  describe ".retired_for?" do
    let(:seller) { create(:user) }
    let!(:cutover) { described_class.create!(seller:, state: "migrated", cutoff_at: 1.day.ago) }

    it "reads on the primary even when called from a replica block" do
      roles = []
      current_role = nil
      allow(ApplicationRecord).to receive(:connected_to).and_wrap_original do |_method, **options, &block|
        previous = current_role
        current_role = options[:role]
        block.call
      ensure
        current_role = previous
      end
      callback = ->(*, payload) { roles << current_role if payload[:sql].include?("feature_announcement_newsletter_cutovers") }

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        ApplicationRecord.connected_to(role: :reading) { described_class.retired_for?(seller.id) }
      end

      expect(roles).to eq([:writing])
    end

    it "isn't answered from the query cache" do
      ApplicationRecord.cache do
        expect(described_class.retired_for?(seller.id)).to be(false)
        # A raw write leaves Active Record's query cache in place, as a commit from another process would.
        ApplicationRecord.connection.raw_connection.query("UPDATE feature_announcement_newsletter_cutovers SET state = 'retired' WHERE id = #{cutover.id}")

        expect(described_class.retired_for?(seller.id)).to be(true)
      end
    end
  end
end
