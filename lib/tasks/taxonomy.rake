# frozen_string_literal: true

namespace :taxonomy do
  desc "Apply the taxonomy tree and its attribute definitions to the current environment (idempotent)"
  task seed: :environment do
    puts "Created #{Onetime::SeedTaxonomies.process} taxonomy row(s)"
  end
end
