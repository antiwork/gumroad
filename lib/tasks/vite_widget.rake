# frozen_string_literal: true

namespace :vite do
  desc "Build the standalone widget bundles (vite.config.widget.ts) for both overlay and embed targets"
  task :build_widget do
    %w[gumroad gumroad-embed].each do |target|
      sh({ "WIDGET_TARGET" => target }, "npx vite build --config vite.config.widget.ts")
    end
  end
end

if Rake::Task.task_defined?("assets:precompile")
  Rake::Task["assets:precompile"].enhance(["vite:build_widget"])
end
