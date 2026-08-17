# frozen_string_literal: true

if Rails.env.staging? && ENV["BRANCH_DEPLOYMENT"] == "true"
  Rails.application.config.after_initialize do
    [Link, Balance, Purchase, Installment, ConfirmedFollowerEvent, ProductPageView].each do |model|
      model.index_name("branch-app-#{ENV['DATABASE_NAME']}__#{model.name.parameterize}")
      begin
        model.__elasticsearch__.create_index!
      rescue Elasticsearch::Transport::Transport::Errors::BadRequest => e
        # Shared staging ES can hit its shard cap; keep the preview booting.
        # Search-backed pages may error until shards are freed. Any other 400
        # (bad mapping etc.) is a real defect and must still abort boot.
        raise unless e.message.match?(/maximum (normal )?shards open/)
        Rails.logger.error("preview ES index #{model.index_name} not created: #{e.message}")
      end
    end
  end
end
