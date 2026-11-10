# frozen_string_literal: true

# Refreshes purchase docs indexed before affiliate_credit_* fields were kept in sync.
# Resume a run with `after_id:` set to the last returned credit id.
class Onetime::ReindexAffiliateCreditPurchases
  BATCH_SIZE = 500

  def self.perform(after_id: 0, limit: BATCH_SIZE)
    credits = ApplicationRecord.connected_to(role: :reading) do
      AffiliateCredit.where("id > ?", after_id).order(:id).limit(limit).pluck(:id, :purchase_id)
    end

    credits.each do |_, purchase_id|
      ElasticsearchIndexerWorker.set(queue: "low").perform_async("index", "class_name" => "Purchase", "record_id" => purchase_id)
    end

    { enqueued: credits.size, last_credit_id: credits.last&.first }
  end
end
