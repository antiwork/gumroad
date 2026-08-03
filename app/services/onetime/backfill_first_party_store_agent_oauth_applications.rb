# frozen_string_literal: true

class Onetime::BackfillFirstPartyStoreAgentOauthApplications
  BATCH_SIZE = 1_000

  def self.process(dry_run: true, batch_size: BATCH_SIZE)
    new(dry_run:, batch_size:).process
  end

  def initialize(dry_run: true, batch_size: BATCH_SIZE)
    @dry_run = dry_run
    @batch_size = batch_size
    @stats = Hash.new(0)
  end

  def process
    candidates.in_batches(of: batch_size) do |batch|
      unflagged_batch = batch.where(is_first_party_agent_app: false)
      matched_count = batch.count
      unflagged_count = unflagged_batch.count

      stats[:matched_count] += matched_count
      if dry_run
        stats[:would_flag_count] += unflagged_count
      else
        ReplicaLagWatcher.watch
        stats[:flagged_count] += unflagged_batch.update_all(is_first_party_agent_app: true, updated_at: Time.current)
      end

      Rails.logger.info(
        "[#{self.class.name}] matched=#{stats[:matched_count]} #{dry_run ? 'would_flag' : 'flagged'}=#{dry_run ? stats[:would_flag_count] : stats[:flagged_count]}"
      )
    end

    stats[:dry_run] = dry_run
    Rails.logger.info("[#{self.class.name}] #{stats.to_h}")
    stats
  end

  private
    attr_reader :batch_size, :dry_run, :stats

    def candidates
      OauthApplication.where(
        name: Ai::StoreAgentApiClient::AGENT_APP_NAME,
        owner_type: "User",
        redirect_uri: Ai::StoreAgentApiClient::AGENT_APP_REDIRECT_URI,
        scopes: Ai::StoreAgentApiClient::AGENT_APP_SCOPES,
      )
    end
end
