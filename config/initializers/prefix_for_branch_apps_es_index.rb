# frozen_string_literal: true

if Rails.env.staging? && ENV["BRANCH_DEPLOYMENT"] == "true"
  Rails.application.config.after_initialize do
    [Link, Balance, Purchase, Installment, ConfirmedFollowerEvent, ProductPageView].each do |model|
      model.index_name("branch-app-#{ENV['DATABASE_NAME']}__#{model.name.parameterize}")
      begin
        model.__elasticsearch__.create_index!
      rescue Elasticsearch::Transport::Transport::Errors::BadRequest => e
        # Shared staging ES sits at a 1000-shard cap. A failed create used to
        # abort boot (js:export and puma), so Nomad crash-looped the preview
        # and GitHub still recorded a successful deploy. Search on this app
        # stays empty until shards are freed; the HTML app must still serve.
        Rails.logger.error("preview ES index #{model.index_name} not created: #{e.message}")
      end
    end
  end
end
