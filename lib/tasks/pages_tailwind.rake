# frozen_string_literal: true

namespace :pages_tailwind do
  desc "Build the Tailwind CSS file used by AI-generated page iframes"
  task :build do
    sh "npm run build:pages-tailwind"
  end
end

if Rake::Task.task_defined?("assets:precompile")
  Rake::Task["assets:precompile"].enhance(["pages_tailwind:build"])
end
