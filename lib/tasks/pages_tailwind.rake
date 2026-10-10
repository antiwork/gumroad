# frozen_string_literal: true

namespace :pages_tailwind do
  desc "Build the Tailwind CSS file used by AI-generated page iframes"
  task :build do
    # The production compile sets this after unpacking a cached build (docker/web/compile_assets.sh).
    next if ENV["PAGES_TAILWIND_RESTORED"] == "true"

    sh "npm run build:pages-tailwind"
  end
end

if Rake::Task.task_defined?("assets:precompile")
  Rake::Task["assets:precompile"].enhance(["pages_tailwind:build"])
end
