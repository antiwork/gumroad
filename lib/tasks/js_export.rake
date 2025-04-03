# typed: strict
# frozen_string_literal: true

extend Rake::DSL

namespace :js do
  desc "Generate JavaScript translations, icons and routes"
  task export: :environment do
    routes_dir = Rails.root.join("app", "javascript", "utils")

    JsRoutes.generate!(routes_dir.join("routes.js"))
    JsRoutes.definitions!(routes_dir.join("routes.d.ts"))

    json_schema_source_dir = "lib/json_schemas"
    json_schema_target_dir = "app/javascript/json_schemas"
    FileUtils.mkdir_p(json_schema_target_dir)
    Dir.foreach(json_schema_source_dir) do |filename|
      next unless filename.end_with? ".json"
      schema = File.read("#{json_schema_source_dir}/#{filename}")
      File.write("#{json_schema_target_dir}/#{filename[0..-6]}.ts", "export default #{schema.strip} as const")
    end
  end
end
