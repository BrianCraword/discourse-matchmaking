# frozen_string_literal: true

# name: discourse-matchmaking
# about: Christian matchmaking powered by Discourse AI — faith-based compatibility matching with AI-guided conversations
# version: 0.3.0
# authors: Brian Crawford
# url: https://github.com/BrianCrawford/discourse-matchmaking
# required_version: 2.7.0

enabled_site_setting :matchmaking_enabled

register_asset "stylesheets/matchmaking.scss"

module ::DiscourseMatchmaking
  PLUGIN_NAME = "discourse-matchmaking"
end

require_relative "lib/discourse_matchmaking/engine"

after_initialize do
  require_relative "app/models/matchmaking_profile"
  require_relative "app/models/matchmaking_match"
  require_relative "app/models/matchmaking_consent"
  require_relative "app/models/zip_code_location"
  require_relative "app/serializers/matchmaking_profile_serializer"
  require_relative "app/controllers/discourse_matchmaking/profiles_controller"
  require_relative "app/jobs/regular/recompute_compatibility_cache"
  require_relative "app/jobs/regular/seed_zip_code_locations"
  require_relative "app/jobs/regular/generate_profile_insight"
  require_relative "app/jobs/regular/evaluate_verification"

  # Seed ZIP code reference data on first boot if table is empty
  if SiteSetting.matchmaking_enabled && ActiveRecord::Base.connection.table_exists?(:zip_code_locations) && ZipCodeLocation.count == 0
    Jobs.enqueue(:seed_zip_code_locations)
  end

  Discourse::Application.routes.append do
    mount DiscourseMatchmaking::Engine, at: "/matchmaking"
  end

  require_relative "lib/discourse_matchmaking/scoring"

  if defined?(DiscourseAi::Agents::ToolRunner)
    require_relative "lib/discourse_matchmaking/tool_runner_extension"
    DiscourseAi::Agents::ToolRunner.prepend(DiscourseMatchmaking::ToolRunnerExtension)
  elsif defined?(DiscourseAi::Personas::ToolRunner)
    require_relative "lib/discourse_matchmaking/tool_runner_extension"
    DiscourseAi::Personas::ToolRunner.prepend(DiscourseMatchmaking::ToolRunnerExtension)
  end

  if defined?(DiscourseAi::Agents::Agent)
    require_relative "lib/discourse_matchmaking/persona_extension"
    DiscourseAi::Agents::Agent.prepend(DiscourseMatchmaking::PersonaExtension)
  elsif defined?(DiscourseAi::Personas::Persona)
    require_relative "lib/discourse_matchmaking/persona_extension"
    DiscourseAi::Personas::Persona.prepend(DiscourseMatchmaking::PersonaExtension)
  end
end
