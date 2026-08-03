# frozen_string_literal: true

namespace :taxonomy do
  desc "Apply the taxonomy tree and its attribute definitions to the current environment (idempotent)"
  task seed: :environment do
    begin
      puts "Created #{Onetime::SeedTaxonomies.process} taxonomy row(s)"
    rescue StandardError => e
      # The deploy script runs this non-fatally so a failure cannot hold the migration lock, which
      # means the shell discards the exit status — this report is the only thing that tells anyone
      # the tree is stale. Report before exiting: Sentry's at_exit flush runs on the abort.
      ErrorNotifier.notify(e, exclude_request_context: true, task: "taxonomy:seed")
      abort "taxonomy:seed failed: #{e.class}: #{e.message}"
    end
  end
end
