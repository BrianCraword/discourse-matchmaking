# frozen_string_literal: true

module Jobs
  class EvaluateVerification < ::Jobs::Base
    sidekiq_options queue: "low"

    EVALUATOR_PROMPT = <<~PROMPT
      You are a verification evaluator for Jesus Enough, a Christian community platform.
      You will receive a user's matchmaking profile (form data they submitted) and the
      transcript of a conversation where a companion persona asked them to elaborate on
      what they wrote. Your job is to assess whether this person's profile appears to
      represent a genuine, lived faith experience.

      You are NOT judging the quality of their faith, the sophistication of their theology,
      or their English proficiency. You are assessing INTERNAL CONSISTENCY — does the
      conversation match the profile? Can this person elaborate on what they wrote with
      specific, coherent details that indicate real experience?

      EVALUATION DIMENSIONS:

      1. COHERENCE (0.0–1.0)
      Do their conversational answers align with what they wrote in the form?
      - 0.9-1.0: Strong alignment, conversation reinforces and expands the profile naturally
      - 0.6-0.8: Mostly aligned, minor inconsistencies that are normal human imprecision
      - 0.3-0.5: Notable misalignments between profile claims and conversational elaboration
      - 0.0-0.2: Major contradictions — conversation contradicts profile on key points

      2. DEPTH (0.0–1.0)
      Can they elaborate with specific, textured details?
      - 0.9-1.0: Rich details — names, places, specific moments, emotions, struggles
      - 0.6-0.8: Moderate detail — some specifics, generally engaged responses
      - 0.3-0.5: Surface level — short answers, few specifics, mostly generic language
      - 0.0-0.2: No depth — one-word or one-sentence answers, deflects follow-ups

      3. THEOLOGICAL_CONSISTENCY (0.0–1.0)
      Do their profile selections match their conversational descriptions?
      - 1.0: Selections perfectly match how they describe their beliefs in conversation
      - 0.7: Minor mismatches that suggest terminology confusion (not deception)
      - 0.4: Selections don't match descriptions — may not understand what they selected
      - 0.1: Selections clearly contradict their conversational descriptions

      4. ENGAGEMENT_QUALITY (0.0–1.0)
      Did they engage substantively with the conversation?
      - 0.9-1.0: Fully engaged, offered details without being prompted, asked questions
      - 0.6-0.8: Cooperative, answered questions with reasonable effort
      - 0.3-0.5: Minimal engagement, short answers, seemed uninterested or rushed
      - 0.0-0.2: Disengaged, refused to answer, tried to skip the conversation

      5. INTERVIEW_COMPLETENESS (0.0-1.0)
      Did the interview cover sufficient ground?
      - 0.9-1.0: Multiple profile areas explored (faith story, beliefs, life direction, partnership)
      - 0.6-0.8: Most key areas covered, minor gaps
      - 0.3-0.5: Only 1-2 areas covered, significant gaps
      - 0.0-0.2: Interview was cut short or barely started

      6. LANGUAGE_CONSISTENCY (flag)
      Does the linguistic register of the conversation match the profile text?
      This is NOT about English proficiency. A non-native speaker who writes and converses
      in the same non-native English is CONSISTENT. A profile in fluent American English
      paired with fundamentally different grammar/vocabulary is a flag.
      Set to true ONLY if there is a clear mismatch suggesting different authors.

      7. AI_GENERATION_INDICATORS (flag)
      Are the conversational responses suspiciously polished, uniform in register,
      or lacking natural typing patterns? Uniformly perfect grammar, suspiciously
      comprehensive answers, and lack of any natural imprecision ARE flags.
      Being articulate is NOT a flag.

      IMPORTANT CALIBRATION NOTES:
      - Err toward APPROVAL. Genuine believers who are nervous, inarticulate, or
        non-native English speakers should not be penalized.
      - A sparse but coherent conversation is better than a rich but inconsistent one.
      - Simple faith expressed authentically scores HIGHER than sophisticated faith
        expressed generically.
      - "I just love Jesus and go to my church on Sundays" with a named church and
        a specific pastor is MORE credible than "I am deeply passionate about
        Christocentric sanctification" without any concrete details.
      - Someone who says "I don't really know what cessationist means, I just
        picked something" is being HONEST, not suspicious.
      - If the interview is incomplete (few exchanges, limited coverage), score
        interview_completeness low but do NOT penalize the user's other scores
        for what the companion failed to ask. The user can only answer questions
        they were asked.

      OUTPUT FORMAT:
      Respond with ONLY a valid JSON object. No markdown, no preamble, no explanation.
      {
        "coherence": 0.0,
        "depth": 0.0,
        "theological_consistency": 0.0,
        "engagement_quality": 0.0,
        "interview_completeness": 0.0,
        "language_consistency_flag": false,
        "ai_generation_flag": false,
        "confidence_score": 0.0,
        "flags": [],
        "recommendation": "approve|review|reset|reject",
        "recommendation_reason": "1-2 sentence plain-language explanation of why this recommendation was made. Written for an admin who needs to make a quick decision.",
        "key_concerns": ["List of specific concerns, if any. Each should be a concrete observation, not a score label."],
        "summary": "2-3 sentence assessment summary for admin review."
      }

      For confidence_score, compute:
        base = coherence * 0.25 + depth * 0.20 + theological_consistency * 0.15 + engagement_quality * 0.20 + interview_completeness * 0.20
        if language_consistency_flag: base -= 0.15
        if ai_generation_flag: base -= 0.10
        confidence_score = max(0.0, min(1.0, base))

      For recommendation:
        - "approve": confidence >= 0.70 and no critical flags
        - "reset": interview_completeness < 0.50 (interview was too short — user needs a new interview, not rejection)
        - "review": confidence 0.40-0.69, or mixed signals that need human judgment
        - "reject": confidence < 0.40 with clear deception indicators (major_contradictions, off_platform_redirect)

      IMPORTANT: If the interview was cut short (interview_completeness < 0.50), ALWAYS recommend
      "reset" rather than "reject". An incomplete interview is not the user's fault — the
      companion ended too early. The user deserves a full interview before any negative action.

      For recommendation_reason, write as if briefing a busy admin:
        GOOD: "Profile testimony says 'Born and Baptized' with no details. Interview covered only one exchange before being cut short. User mentioned Irish Catholic upbringing with sacraments but conversation ended before beliefs, values, or partnership could be explored. Recommend reset for a complete interview."
        BAD: "Low scores across multiple dimensions."

      For key_concerns, list specific observations:
        GOOD: ["Testimony is one sentence with no personal narrative", "Interview ended after 1 exchange — most profile areas unexplored", "Partner description mentions no faith-related qualities"]
        BAD: ["Low depth score", "Generic responses"]

      For flags, include any applicable strings from:
        "language_mismatch", "ai_generated_responses", "rushed_completion",
        "incomplete_interview", "major_contradictions", "no_church_details",
        "deflects_followups", "profile_form_mismatch", "generic_responses",
        "off_platform_redirect", "no_faith_language_in_partner_description",
        "faith_as_cultural_identity_only"

      Include "incomplete_interview" if fewer than 4 substantive exchanges occurred.
      Include "faith_as_cultural_identity_only" if the user describes faith purely as
      cultural heritage (born into it, family tradition) with no personal conviction,
      relationship with God, or spiritual practice beyond attendance.
    PROMPT

    def execute(args)
      return unless SiteSetting.matchmaking_enabled

      profile = MatchmakingProfile.find_by(id: args[:profile_id])
      return unless profile
      return if profile.verified? # Already verified, don't re-evaluate

      topic_id = args[:topic_id] || profile.verification_conversation_topic_id
      return unless topic_id

      # Pull the conversation transcript
      transcript = build_transcript(topic_id, profile.user_id)
      return if transcript.blank?

      llm = resolve_llm
      unless llm
        Rails.logger.warn(
          "[discourse-matchmaking] Cannot evaluate verification: " \
          "no LLM configured. Set matchmaking_verification_llm_model_id in admin settings."
        )
        return
      end

      user_message = build_evaluator_input(profile, transcript)

      prompt = DiscourseAi::Completions::Prompt.new(EVALUATOR_PROMPT)
      prompt.push(type: :user, content: user_message)

      begin
        response = llm.generate(prompt, user: Discourse.system_user)

        cleaned = response.to_s.strip
        cleaned = cleaned.gsub(/\A```json\s*/i, "").gsub(/\A```\s*/i, "").gsub(/\s*```\z/, "").strip

        result = JSON.parse(cleaned)

        unless result["confidence_score"].is_a?(Numeric)
          Rails.logger.warn(
            "[discourse-matchmaking] Evaluator returned unexpected format for profile #{profile.id}"
          )
          return
        end

        # Clamp confidence score
        confidence = [[result["confidence_score"].to_f, 0.0].max, 1.0].min

        assessment_data = {
          confidence_score: confidence,
          coherence: result["coherence"]&.to_f,
          depth: result["depth"]&.to_f,
          theological_consistency: result["theological_consistency"]&.to_f,
          engagement_quality: result["engagement_quality"]&.to_f,
          interview_completeness: result["interview_completeness"]&.to_f,
          language_consistency_flag: result["language_consistency_flag"] == true,
          ai_generation_flag: result["ai_generation_flag"] == true,
          flags: Array(result["flags"]),
          recommendation: result["recommendation"].to_s,
          recommendation_reason: result["recommendation_reason"].to_s.truncate(500),
          key_concerns: Array(result["key_concerns"]),
          summary: result["summary"].to_s.truncate(1000),
          assessed_at: Time.current.iso8601,
          topic_id: topic_id,
          # Store profile excerpts for admin review without needing DB lookup
          profile_excerpts: {
            testimony: profile.testimony.to_s.truncate(300),
            life_goals: profile.life_goals.to_s.truncate(300),
            partner_description: profile.partner_description.to_s.truncate(300),
            ministry_involvement: profile.ministry_involvement.to_s.truncate(300),
            denomination: profile.denomination,
            church_attendance: profile.church_attendance,
          },
        }

        # Store the assessment
        profile.update_columns(
          verification_data: assessment_data,
          verification_conversation_topic_id: topic_id,
        )

        # Decision
        threshold = SiteSetting.respond_to?(:matchmaking_verification_auto_threshold) ?
          SiteSetting.matchmaking_verification_auto_threshold.to_f : 0.70

        if confidence >= threshold && result["recommendation"] != "reset"
          profile.verify!("auto")
          notify_user_verified(profile)
          Rails.logger.info(
            "[discourse-matchmaking] Auto-verified profile #{profile.id} " \
            "(confidence: #{confidence.round(3)})"
          )
        else
          profile.flag_for_review!(assessment_data)
          notify_admin_flagged(profile, assessment_data)
          notify_user_under_review(profile)
          Rails.logger.info(
            "[discourse-matchmaking] Flagged profile #{profile.id} for review " \
            "(confidence: #{confidence.round(3)}, recommendation: #{result['recommendation']}, " \
            "flags: #{assessment_data[:flags].join(', ')})"
          )
        end

        # Re-run faith insight generation with enriched transcript
        Jobs.enqueue(:generate_profile_insight,
          profile_id: profile.id,
          include_transcript: true,
          topic_id: topic_id,
        )

      rescue JSON::ParserError => e
        Rails.logger.warn(
          "[discourse-matchmaking] Failed to parse evaluator response for profile #{profile.id}: #{e.message}"
        )
      rescue => e
        Rails.logger.error(
          "[discourse-matchmaking] Error evaluating verification for profile #{profile.id}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
        )
      end
    end

    private

    def build_transcript(topic_id, user_id)
      topic = Topic.find_by(id: topic_id)
      return nil unless topic

      posts = topic.posts.order(:post_number)
      lines = []

      posts.each do |post|
        speaker = post.user_id == user_id ? "USER" : "COMPANION"
        lines << "#{speaker}: #{post.raw}"
      end

      lines.join("\n\n")
    end

    def build_evaluator_input(profile, transcript)
      sections = []

      sections << "=== PROFILE FORM DATA (what the user submitted) ==="
      sections << "Denomination: #{profile.denomination}" if profile.denomination.present?
      sections << "Denomination importance: #{profile.denomination_importance}" if profile.denomination_importance.present?
      sections << "Church attendance: #{profile.church_attendance}" if profile.church_attendance.present?
      sections << "Bible engagement: #{profile.bible_engagement}" if profile.bible_engagement.present?
      sections << "Baptism status: #{profile.baptism_status}" if profile.baptism_status.present?
      sections << "Relationship intention: #{profile.relationship_intention}" if profile.relationship_intention.present?
      sections << "Children preference: #{profile.children_preference}" if profile.children_preference.present?

      tv = profile.theological_views || {}
      if tv.any?
        sections << "Theological views: #{tv.map { |k, v| "#{k}: #{v}" }.join(', ')}"
      end

      sections << "\nTestimony: #{profile.testimony}" if profile.testimony.present?
      sections << "Life goals: #{profile.life_goals}" if profile.life_goals.present?
      sections << "Ministry involvement: #{profile.ministry_involvement}" if profile.ministry_involvement.present?
      sections << "Partner description: #{profile.partner_description}" if profile.partner_description.present?
      sections << "Interests: #{(profile.interests || []).join(', ')}" if profile.interests.present?

      sections << "\n=== CONVERSATION TRANSCRIPT ==="
      sections << transcript

      sections.join("\n")
    end

    def notify_user_verified(profile)
      body = <<~MSG.strip
        Welcome to Jesus Enough! Your profile has been verified and you now have full access to the community.

        You can:
        - Post and reply in the forums
        - Send messages to other members
        - Talk to **Logos_bot** on the [AI conversations page](#{Discourse.base_url}/discourse-ai/ai-bot/conversations) to start finding faith-compatible matches

        We're glad you're here!
      MSG

      PostCreator.new(
        Discourse.system_user,
        title: "Welcome to Jesus Enough — You're Verified!",
        raw: body,
        archetype: Archetype.private_message,
        target_usernames: profile.user.username,
        skip_validations: true,
      ).create
    rescue => e
      Rails.logger.warn("[discourse-matchmaking] Failed to send verification notification to #{profile.user.username}: #{e.message}")
    end

    def notify_user_under_review(profile)
      body = <<~MSG.strip
        Thanks for completing your profile interview! Your account is being reviewed by our team — you'll hear from us within 24 hours.

        In the meantime, feel free to browse the community.
      MSG

      PostCreator.new(
        Discourse.system_user,
        title: "Your Profile Is Being Reviewed",
        raw: body,
        archetype: Archetype.private_message,
        target_usernames: profile.user.username,
        skip_validations: true,
      ).create
    rescue => e
      Rails.logger.warn("[discourse-matchmaking] Failed to send review notification to #{profile.user.username}: #{e.message}")
    end

    def notify_admin_flagged(profile, assessment_data)
      admin_users = User.staff.where(admin: true).limit(5)
      return if admin_users.empty?

      confidence = assessment_data[:confidence_score]&.round(3)
      recommendation = assessment_data[:recommendation] || "review"
      recommendation_reason = assessment_data[:recommendation_reason] || "No reason provided."
      flags = assessment_data[:flags]&.join(", ") || "none"
      summary = assessment_data[:summary] || "No summary available."
      key_concerns = assessment_data[:key_concerns] || []
      topic_url = "#{Discourse.base_url}/t/#{assessment_data[:topic_id]}" if assessment_data[:topic_id]
      excerpts = assessment_data[:profile_excerpts] || {}

      # Determine the recommended action label and explanation
      action_label = case recommendation
                     when "approve" then "APPROVE — Evaluator thinks this user should pass"
                     when "reset" then "RESET — Interview was incomplete, user deserves a full interview"
                     when "reject" then "REJECT — Evaluator found clear deception indicators"
                     else "REVIEW — Mixed signals, needs human judgment"
                     end

      concerns_text = if key_concerns.any?
        key_concerns.map { |c| "- #{c}" }.join("\n")
      else
        "- None identified"
      end

      body = <<~MSG
        ## Verification Review Required

        **User**: #{profile.user.username} (#{profile.user.name || "no display name"})
        **Confidence**: #{confidence} / 1.0
        **Recommendation**: #{action_label}

        ---

        ### Why This Was Flagged

        #{recommendation_reason}

        ### Key Concerns

        #{concerns_text}

        ---

        ### What the User Wrote (Profile Excerpts)

        **Testimony**: #{excerpts[:testimony].presence || "(empty)"}

        **Life Goals**: #{excerpts[:life_goals].presence || "(empty)"}

        **Partner Description**: #{excerpts[:partner_description].presence || "(empty)"}

        **Ministry**: #{excerpts[:ministry_involvement].presence || "(empty)"}

        **Denomination**: #{excerpts[:denomination] || "not set"} | **Attendance**: #{excerpts[:church_attendance] || "not set"}

        ---

        ### Evaluator Assessment

        #{summary}

        **Scores**: Coherence #{assessment_data[:coherence]&.round(2)} · Depth #{assessment_data[:depth]&.round(2)} · Theology #{assessment_data[:theological_consistency]&.round(2)} · Engagement #{assessment_data[:engagement_quality]&.round(2)} · Interview completeness #{assessment_data[:interview_completeness]&.round(2)}

        **Flags**: #{flags}

        ---

        ### Conversation Transcript

        #{topic_url || "Topic ID not available"} — Read the full conversation before deciding.

        ---

        ### Actions

        **To approve** (verify and promote to TL1):
        ```
        p = MatchmakingProfile.find_by(user_id: #{profile.user_id})
        p.verify!("admin")
        ```

        **To reset** (send back for a new interview):
        ```
        p = MatchmakingProfile.find_by(user_id: #{profile.user_id})
        p.reset_verification!
        ```

        **To reject**:
        ```
        p = MatchmakingProfile.find_by(user_id: #{profile.user_id})
        p.reject!("admin")
        ```
      MSG

      # Send as a staff PM
      admin_users.each do |admin|
        begin
          PostCreator.new(
            Discourse.system_user,
            title: "[Verification] #{profile.user.username} — #{recommendation.upcase} recommended (#{confidence})",
            raw: body,
            archetype: Archetype.private_message,
            target_usernames: admin.username,
            skip_validations: true,
          ).create
        rescue => e
          Rails.logger.warn("[discourse-matchmaking] Failed to notify admin #{admin.username}: #{e.message}")
        end
      end
    end

    def resolve_llm
      # Use the dedicated verification LLM if set, otherwise fall back to insight LLM
      model_id = SiteSetting.respond_to?(:matchmaking_verification_llm_model_id) ?
        SiteSetting.matchmaking_verification_llm_model_id : nil
      model_id = SiteSetting.matchmaking_insight_llm_model_id if model_id.blank?
      return nil if model_id.blank?

      llm_model = LlmModel.find_by(id: model_id.to_i)
      return nil unless llm_model

      DiscourseAi::Completions::Llm.proxy(llm_model)
    end
  end
end
