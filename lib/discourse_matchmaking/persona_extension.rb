# frozen_string_literal: true

module DiscourseMatchmaking
  module PersonaExtension
    def craft_prompt(context, llm: nil)
      if SiteSetting.matchmaking_enabled && context.user.present?
        # Detect if this is the Verification Companion — it gets special handling
        is_verification_persona = detect_persona(
          (SiteSetting.respond_to?(:matchmaking_verification_persona_user_id) ? SiteSetting.matchmaking_verification_persona_user_id : nil),
          "verification companion for Jesus Enough"
        )

        if is_verification_persona
          inject_verification_context(context)
        else
          # All other personas (Logos_bot, InsightAI, future personas) get profile awareness
          inject_matchmaking_context(context)
        end
      end

      super(context, llm: llm)
    end

    private

    def detect_persona(setting_user_id, system_prompt_marker)
      if setting_user_id.present? && self.class.respond_to?(:user_id) && self.class.user_id.to_s == setting_user_id.to_s
        return true
      end

      # Fallback: check system prompt for marker text
      if respond_to?(:system_prompt) && system_prompt.to_s.include?(system_prompt_marker)
        return true
      end

      false
    end

    def inject_matchmaking_context(context)
      profile = MatchmakingProfile.find_by(user_id: context.user.id)
      consent_ok = MatchmakingConsent.fully_consented?(context.user.id)

      matchmaking_block = build_matchmaking_context(context.user, profile, consent_ok)

      if matchmaking_block.present?
        if context.custom_instructions.present?
          context.custom_instructions = context.custom_instructions + matchmaking_block
        else
          context.custom_instructions = matchmaking_block
        end
      end
    end

    def inject_verification_context(context)
      profile = MatchmakingProfile.find_by(user_id: context.user.id)

      verification_block = build_verification_context(context.user, profile)

      if verification_block.present?
        if context.custom_instructions.present?
          context.custom_instructions = context.custom_instructions + verification_block
        else
          context.custom_instructions = verification_block
        end
      end
    end

    def build_matchmaking_context(user, profile, consent_ok)
      parts = []
      parts << "\n## Matchmaking Context — #{user.name || user.username}"

      unless consent_ok
        parts << "This user has NOT yet completed the matchmaking consent process. Before searching for matches, guide them to complete their profile at their User Preferences page. Do not attempt to search until they have a profile."
        return parts.join("\n")
      end

      if profile.nil?
        parts << "This user has consented to matchmaking but has NOT yet created a profile. Encourage them to fill out their profile in User Preferences before you can search for matches."
        return parts.join("\n")
      end

      parts << "This user has an active matchmaking profile (#{profile.completion_percentage}% complete)."

      unless profile.meets_minimum_completion?
        parts << "WARNING: Their profile does not meet the minimum completion threshold for searching. Encourage them to complete more fields before searching."
      end

      parts << ""
      parts << "**Their Profile Summary:**"
      parts << "- #{profile.gender&.capitalize}, looking for #{profile.seeking_gender}"
      parts << "- Age: #{profile.age}, seeking ages #{profile.age_min_preference}-#{profile.age_max_preference}"
      parts << "- Location: #{[profile.city, profile.state, profile.country].compact.join(', ')} (flexibility: #{profile.location_flexibility})"
      parts << "- Denomination: #{profile.denomination} (importance: #{profile.denomination_importance})"
      parts << "- Church attendance: #{profile.church_attendance}"
      parts << "- Relationship intention: #{profile.relationship_intention}"
      parts << "- Children preference: #{profile.children_preference}"

      if profile.theological_views.present? && profile.theological_views.any?
        tv = profile.theological_views
        parts << "- Theological views: #{tv.map { |k, v| "#{k}: #{v}" }.join(', ')}"
      end

      parts << "- Testimony: #{profile.testimony}" if profile.testimony.present?
      parts << "- Life goals: #{profile.life_goals}" if profile.life_goals.present?
      parts << "- Ministry: #{profile.ministry_involvement}" if profile.ministry_involvement.present?
      parts << "- Looking for: #{profile.partner_description}" if profile.partner_description.present?
      parts << "- Interests: #{profile.interests.join(', ')}" if profile.interests.present? && profile.interests.any?

      if profile.faith_summary.present?
        parts << ""
        parts << "**Faith Summary (AI-generated):** #{profile.faith_summary}"
      end

      parts << ""
      parts << "- Verification status: #{profile.verification_status}"

      previous_searches = MatchmakingMatch.where(searcher_id: user.id).select(:created_at).distinct.count
      parts << "- Previous searches: #{previous_searches}"

      parts << ""
      parts << "Use this context to greet them by name and acknowledge what you already know. Ask if they want to search with these preferences or update anything first."

      parts.join("\n")
    end

    def build_verification_context(user, profile)
      parts = []
      parts << "\n## Verification Context — #{user.name || user.username}"

      if profile.nil?
        parts << "STATUS: NO PROFILE"
        parts << "This user has NOT yet created a matchmaking profile."
        parts << "Direct them to User Preferences to toggle on the matchmaking feature, accept the consent, and fill out their profile."
        parts << "Say something like: \"Welcome to Jesus Enough! Before we can chat about your faith journey, you'll need to set up your profile. Head to your User Preferences, toggle on the matchmaking feature, and fill out the form. Come back to me when you're done — I'll be right here.\""
        return parts.join("\n")
      end

      parts << "STATUS: #{profile.verification_status.upcase}"

      case profile.verification_status
      when "verified"
        parts << "This user is already verified. They have full platform access."
        parts << "You can have a friendly conversation, but no verification interview is needed."
        parts << "If they want to revisit their beliefs or update their profile understanding, you can help with that as a faith reflection companion."
        return parts.join("\n")
      when "flagged"
        parts << "This user's profile has been flagged for admin review. Their previous interview is being reviewed."
        parts << "Be warm and let them know their profile is under review. Do not conduct a new interview."
        return parts.join("\n")
      when "rejected"
        parts << "This user's profile has been rejected by an admin."
        parts << "Let them know their account is under review and suggest they contact the community admins if they have questions."
        return parts.join("\n")
      end

      # unverified or pending_interview — conduct the interview
      parts << "PROFILE COMPLETION: #{profile.completion_percentage}%"

      unless profile.meets_minimum_completion?
        parts << "WARNING: Profile is below minimum completion (#{profile.completion_percentage}%). Direct them to complete more fields before the interview."
        parts << "Say: \"I see you've started your profile, but it's not quite complete enough for us to have a meaningful conversation about it. Head back to your User Preferences and fill in a few more fields — especially your testimony and what you're looking for in a partner. Then come back and we'll talk!\""
        return parts.join("\n")
      end

      parts << ""
      parts << "READY FOR INTERVIEW. Below is the user's complete profile data. Use this to ask specific, profile-grounded follow-up questions."
      parts << ""
      parts << "**Profile Data:**"
      parts << "- Name: #{user.name || user.username}"
      parts << "- Gender: #{profile.gender&.capitalize}"
      parts << "- Age: #{profile.age}"
      parts << "- Location: #{[profile.city, profile.state, profile.country].compact.join(', ')}"
      parts << "- Denomination: #{profile.denomination} (importance: #{profile.denomination_importance})"
      parts << "- Church attendance: #{profile.church_attendance}"
      parts << "- Bible engagement: #{profile.bible_engagement}"
      parts << "- Baptism status: #{profile.baptism_status}"

      if profile.theological_views.present? && profile.theological_views.any?
        tv = profile.theological_views
        parts << "- Theological views: #{tv.map { |k, v| "#{k}: #{v}" }.join(', ')}"
      end

      parts << "- Relationship intention: #{profile.relationship_intention}"
      parts << "- Children preference: #{profile.children_preference}"
      parts << "- Interests: #{(profile.interests || []).join(', ')}"
      parts << "- Lifestyle: #{(profile.lifestyle || []).join(', ')}"

      parts << ""
      parts << "**Narrative Fields (the user's own words — these are your interview material):**"
      parts << "TESTIMONY: \"#{profile.testimony}\"" if profile.testimony.present?
      parts << "LIFE GOALS: \"#{profile.life_goals}\"" if profile.life_goals.present?
      parts << "MINISTRY INVOLVEMENT: \"#{profile.ministry_involvement}\"" if profile.ministry_involvement.present?
      parts << "PARTNER DESCRIPTION: \"#{profile.partner_description}\"" if profile.partner_description.present?

      parts << ""
      parts << "Begin the interview. Follow your prompt instructions for conversation flow. When the interview feels complete (5-8 exchanges), call verification.complete() to submit."

      parts.join("\n")
    end
  end
end
