# frozen_string_literal: true

module Jobs
  class GenerateProfileInsight < ::Jobs::Base
    sidekiq_options queue: "low"

    SYSTEM_PROMPT = <<~PROMPT
      You are a faith profile analyzer for a Christian matchmaking platform called Jesus Enough.
      You will receive a user's profile narrative fields and produce two outputs in a single JSON response.

      TASK 1 — FAITH TAGS (structured classification)
      Classify this profile into structured tags. Be accurate — do not inflate.
      A short testimony with genuine faith language gets tagged accurately.
      A long testimony with generic language does not get high strength scores just for length.
      If text is vague or lacks spiritual depth, reflect that honestly.

      For spiritual_posture: select ALL that clearly apply from this list:
      sanctification, salvation_atonement, surrender, identity_in_christ,
      scripture_devotion, prayer_life, worship, evangelism, community,
      covenant_marriage, family_values, service_heart, purpose_calling,
      character_virtue, joy_peace, spiritual_struggle

      For spiritual_posture_strength: assign 0.0-1.0 for each posture you selected:
      - 1.0 = central theme, multiple clear expressions
      - 0.7 = clearly present, mentioned meaningfully
      - 0.4 = hinted at or briefly mentioned

      For faith_maturity, select ONE:
      new_believer, growing, established, mature, in_crisis, rebuilding

      For ministry_season, select ONE:
      active, seeking, stepping_back, not_serving, called_but_waiting, hurt_withdrawn

      For relational_values, select all that apply from:
      covenant_marriage, equally_yoked, spiritual_leadership, shared_ministry,
      family_building, adventure_together, emotional_depth, intellectual_match,
      humor_connection, physical_active, simple_life, ambitious_together

      For partner_priorities, select the top 3 most prominent from:
      faith_depth, character, shared_ministry, theological_alignment,
      emotional_maturity, family_orientation, ambition, humor, adventure,
      intellectual_curiosity, physical_fitness, financial_stability,
      fun_lifestyle, companionship

      For partner_absence_flags: if the partner_description contains NO faith language,
      NO spiritual values, and focuses entirely on lifestyle or personality, include "faith_silent".
      If it's extremely vague and generic, include "vague_generic". Otherwise leave empty.

      For life_direction, select all that apply from:
      family_focused, ministry_calling, career_driven, missions_oriented,
      community_builder, scholar_learner, creative_artist, simple_content

      For struggle_indicators, include any that are present:
      church_hurt, faith_doubt, relationship_wound, loss_grief,
      spiritual_dryness, isolation, anger_at_god, rebuilding_trust
      Leave empty if none are indicated.

      TASK 2 — FAITH SUMMARY (narrative)
      Write a 2-4 sentence narrative summary of this person's faith profile.
      Third person. Warm but honest. Include:
      - Their central spiritual theme (what their faith is about)
      - Their faith maturity and current season
      - Their ministry posture
      - Any notable gaps or tensions (e.g., deep theology but faith-silent partner description)
      - What kind of partner they seem to be looking for

      Do NOT inflate. Do NOT add spiritual depth they did not express.
      Reflect what they actually wrote, at the depth they actually wrote it.
      If their writing is sparse, say so honestly — do not fabricate richness.

      WHEN ENRICHMENT NOTES ARE PROVIDED:
      You may receive "VERIFICATION CONVERSATION ENRICHMENT" — these are structured
      notes from a conversation where the user elaborated on their profile in their
      own words. These notes are organized by profile area and contain the user's
      actual language, direct quotes, and factual observations.

      These enrichment notes are HIGH-VALUE input. They contain the texture, specifics,
      and nuance that the form fields alone cannot capture. Use them to:
      - Produce more accurate posture classifications (the user's own words reveal
        what they actually prioritize, not just what they checked on a form)
      - Assign more confident strength scores (elaborated themes get higher strength)
      - Write a richer, more specific faith_summary that reflects who this person
        actually is — named churches, specific callings, real struggles, concrete goals
      - Detect postures that weren't visible in form text alone (e.g., a user whose
        form testimony is brief but who described a deep prayer life in conversation)

      Treat enrichment notes with the same Mirror Principle as the form data:
      reflect what the user actually said at the depth they actually said it.
      Do not inflate enrichment notes into grander spiritual language than the
      user themselves used.

      OUTPUT FORMAT:
      Respond with ONLY a valid JSON object. No markdown backticks, no preamble, no explanation.
      {
        "faith_tags": {
          "spiritual_posture": [...],
          "spiritual_posture_strength": {...},
          "faith_maturity": "...",
          "ministry_season": "...",
          "ministry_areas": [...],
          "relational_values": [...],
          "partner_priorities": [...],
          "partner_absence_flags": [...],
          "life_direction": [...],
          "struggle_indicators": [...],
          "key_themes": [...]
        },
        "faith_summary": "..."
      }
    PROMPT

    def execute(args)
      return unless SiteSetting.matchmaking_enabled

      profile = MatchmakingProfile.find_by(id: args[:profile_id])
      return unless profile

      # Skip if no narrative fields have content
      narratives = [profile.testimony, profile.life_goals,
                    profile.ministry_involvement, profile.partner_description]
      return if narratives.all?(&:blank?)

      llm = resolve_llm
      unless llm
        Rails.logger.warn(
          "[discourse-matchmaking] Cannot generate profile insight: " \
          "no LLM configured. Set matchmaking_insight_llm_model_id in admin settings."
        )
        return
      end

      # Build input — optionally enriched with verification conversation data
      user_message = build_user_message(profile)

      if args[:include_transcript] && args[:topic_id]
        # Prefer the structured enrichment summary over raw transcript
        enrichment = extract_enrichment_summary(profile)

        if enrichment.present?
          user_message += "\n\n" + build_enrichment_block(enrichment)
        else
          # Fallback to raw transcript if no enrichment summary exists
          transcript = extract_user_messages(args[:topic_id], profile.user_id)
          if transcript.present?
            user_message += "\n\nVERIFICATION CONVERSATION TRANSCRIPT (the user elaborated on their profile in their own words — use this to produce richer, more accurate classification):\n#{transcript}"
          end
        end
      end

      prompt = DiscourseAi::Completions::Prompt.new(SYSTEM_PROMPT)
      prompt.push(type: :user, content: user_message)

      begin
        response = llm.generate(prompt, user: Discourse.system_user)

        # Strip markdown fences if present
        cleaned = response.to_s.strip
        cleaned = cleaned.gsub(/\A```json\s*/i, "").gsub(/\A```\s*/i, "").gsub(/\s*```\z/, "").strip

        result = JSON.parse(cleaned)

        faith_tags = result["faith_tags"]
        faith_summary = result["faith_summary"]

        unless faith_tags.is_a?(Hash) && faith_summary.is_a?(String)
          Rails.logger.warn(
            "[discourse-matchmaking] LLM returned unexpected format for profile #{profile.id}"
          )
          return
        end

        # Validate that spiritual_posture contains only known values
        valid_postures = %w[
          sanctification salvation_atonement surrender identity_in_christ
          scripture_devotion prayer_life worship evangelism community
          covenant_marriage family_values service_heart purpose_calling
          character_virtue joy_peace spiritual_struggle
        ]
        if faith_tags["spiritual_posture"].is_a?(Array)
          faith_tags["spiritual_posture"] = faith_tags["spiritual_posture"].select { |p| valid_postures.include?(p.to_s) }
        end
        if faith_tags["spiritual_posture_strength"].is_a?(Hash)
          faith_tags["spiritual_posture_strength"] = faith_tags["spiritual_posture_strength"]
            .select { |k, _| valid_postures.include?(k.to_s) }
            .transform_values { |v| [[v.to_f, 0.0].max, 1.0].min }
        end

        profile.update_columns(
          faith_tags: faith_tags,
          faith_summary: faith_summary.truncate(2000),
          faith_insight_updated_at: Time.current,
        )

        Rails.logger.info(
          "[discourse-matchmaking] Generated faith insight for profile #{profile.id} " \
          "(#{faith_tags['spiritual_posture']&.size || 0} postures, " \
          "maturity: #{faith_tags['faith_maturity']}" \
          "#{args[:include_transcript] ? ', enriched with verification data' : ''})"
        )

      rescue JSON::ParserError => e
        Rails.logger.warn(
          "[discourse-matchmaking] Failed to parse LLM response for profile #{profile.id}: #{e.message}"
        )
      rescue => e
        Rails.logger.error(
          "[discourse-matchmaking] Error generating faith insight for profile #{profile.id}: #{e.message}"
        )
      end
    end

    private

    def build_user_message(profile)
      sections = []
      sections << "TESTIMONY:\n#{profile.testimony}" if profile.testimony.present?
      sections << "LIFE GOALS:\n#{profile.life_goals}" if profile.life_goals.present?
      sections << "MINISTRY INVOLVEMENT:\n#{profile.ministry_involvement}" if profile.ministry_involvement.present?
      sections << "PARTNER DESCRIPTION:\n#{profile.partner_description}" if profile.partner_description.present?

      # Include structured fields as context for more accurate classification
      context_parts = []
      context_parts << "Denomination: #{profile.denomination}" if profile.denomination.present?
      context_parts << "Church attendance: #{profile.church_attendance}" if profile.church_attendance.present?
      context_parts << "Relationship intention: #{profile.relationship_intention}" if profile.relationship_intention.present?
      context_parts << "Children preference: #{profile.children_preference}" if profile.children_preference.present?
      context_parts << "Bible engagement: #{profile.bible_engagement}" if profile.bible_engagement.present?

      if context_parts.any?
        sections << "STRUCTURED PROFILE DATA (for context, do not repeat — use to inform your classification):\n#{context_parts.join("\n")}"
      end

      sections.join("\n\n")
    end

    # Extract the structured enrichment summary from verification_data
    # This is the preferred source — organized by profile area with the user's own words
    def extract_enrichment_summary(profile)
      return nil unless profile.verification_data.is_a?(Hash)
      profile.verification_data["enrichment_summary"]
    end

    # Build a structured enrichment block from the enrichment summary hash
    def build_enrichment_block(enrichment)
      return "" unless enrichment.is_a?(Hash)

      sections = ["VERIFICATION CONVERSATION ENRICHMENT (structured notes from a conversation where the user elaborated on their profile — organized by area, in the user's own words):"]

      field_labels = {
        "testimony_enrichment" => "FAITH JOURNEY ELABORATION",
        "church_life_notes" => "CHURCH LIFE DETAILS",
        "bible_engagement_notes" => "SCRIPTURE ENGAGEMENT DETAILS",
        "theological_clarity" => "THEOLOGICAL VIEWS CLARIFICATION",
        "life_goals_enrichment" => "LIFE GOALS ELABORATION",
        "ministry_notes" => "MINISTRY DETAILS",
        "relationship_context" => "RELATIONSHIP INTENTION CONTEXT",
        "partner_enrichment" => "PARTNER DESCRIPTION ELABORATION",
        "lifestyle_and_interests_notes" => "LIFESTYLE AND INTERESTS NOTES",
        "notable_observations" => "OTHER OBSERVATIONS",
      }

      field_labels.each do |key, label|
        value = enrichment[key]
        next if value.blank?
        sections << "#{label}:\n#{value}"
      end

      sections.join("\n\n")
    end

    # Fallback: extract only the USER's messages from the verification conversation
    def extract_user_messages(topic_id, user_id)
      topic = Topic.find_by(id: topic_id)
      return nil unless topic

      user_posts = topic.posts
        .where(user_id: user_id)
        .order(:post_number)
        .pluck(:raw)

      return nil if user_posts.empty?

      user_posts.join("\n\n")
    end

    def resolve_llm
      model_id = SiteSetting.matchmaking_insight_llm_model_id rescue nil
      return nil if model_id.blank?

      llm_model = LlmModel.find_by(id: model_id.to_i)
      return nil unless llm_model

      DiscourseAi::Completions::Llm.proxy(llm_model)
    end
  end
end
