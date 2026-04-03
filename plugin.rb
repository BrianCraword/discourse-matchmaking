# frozen_string_literal: true

# name: discourse-matchmaking
# about: Christian matchmaking powered by Discourse AI — faith-based compatibility matching with AI-guided conversations
# version: 0.3.1
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

  # Add new users to pending_verification group at registration
  # so they can access the Verification Companion before creating a profile
  on(:user_created) do |user|
    if SiteSetting.matchmaking_enabled &&
       SiteSetting.respond_to?(:matchmaking_verification_enabled) &&
       SiteSetting.matchmaking_verification_enabled
      group = Group.find_by(name: MatchmakingProfile::VERIFICATION_GROUP_NAME)
      if group
        group.add(user)
        Rails.logger.info("[discourse-matchmaking] Added new user #{user.username} (id: #{user.id}) to #{MatchmakingProfile::VERIFICATION_GROUP_NAME}")
      end
    end
  rescue => e
    Rails.logger.warn("[discourse-matchmaking] Failed to add new user to pending_verification: #{e.message}")
  end

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
