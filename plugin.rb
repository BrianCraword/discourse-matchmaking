# frozen_string_literal: true

# name: discourse-matchmaking
# about: Christian matchmaking powered by Victorious Christians AI — faith-based compatibility matching with AI-guided conversations
# version: 0.4.1
# authors: Brian Crawford
# url: https://github.com/BrianCrawford/discourse-matchmaking
# required_version: 2.7.0

enabled_site_setting :matchmaking_enabled

register_asset "stylesheets/matchmaking.scss"

# Register admin page for Verification Queue
add_admin_route "matchmaking.admin.title", "matchmaking"

Discourse::Application.routes.append do
  get "/admin/plugins/matchmaking" => "admin/plugins#index",
      constraints: StaffConstraint.new
  get "/admin/plugins/matchmaking/verification-queue" => "admin/plugins#index",
      constraints: StaffConstraint.new
end

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

  # ── Public Faith Profile on User Profile Page ──────────────────────
  # Attaches curated matchmaking profile data to the UserSerializer so
  # the faith card component can display it on /u/username without an
  # extra API call. Returns nil (no card) for non-participants, unverified
  # profiles, or when viewed by TL0 users.
  add_to_serializer(:user, :matchmaking_public_profile) do
    return nil unless SiteSetting.matchmaking_enabled

    # Only show faith cards to TL1+ viewers (verified members)
    return nil unless scope.user && scope.user.trust_level >= 1

    profile = MatchmakingProfile.find_by(user_id: object.id)
    return nil unless profile
    return nil unless profile.verification_status == "verified"
    return nil unless profile.active? && profile.visible?
    return nil unless MatchmakingConsent.has_active_consent?(object.id, "ai_matching")

    {
      denomination: profile.denomination,
      church_attendance: profile.church_attendance,
      bible_engagement: profile.bible_engagement,
      testimony_excerpt: profile.testimony&.truncate(250),
      faith_summary: profile.faith_summary,
      theological_views: profile.theological_views,
      interests: profile.interests,
      relationship_intention: profile.relationship_intention,
      state: profile.state,
      country: profile.country,
      verification_status: profile.verification_status,
    }
  end

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
