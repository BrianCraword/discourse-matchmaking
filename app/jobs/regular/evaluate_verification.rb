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

      5. LANGUAGE_CONSISTENCY (flag)
      Does the linguistic register of the conversation match the profile text?
      This is NOT about English proficiency. A non-native speaker who writes their profile
      in non-native English and converses in the same non-native English is CONSISTENT.
      A profile written in fluent American English paired with conversation that uses
      fundamentally different grammar, idioms, or vocabulary level is a flag.
      Set to true ONLY if there is a clear mismatch between profile writing style and
      conversational writing style that suggests different authors.

      6. AI_GENERATION_INDICATORS (flag)
      Are the conversational responses suspiciously polished, uniform in register,
      or lacking natural typing patterns? Do they sound scripted or generated?
      Set to true ONLY if there are strong indicators. Some people are naturally
      articulate — being well-spoken is not a flag. Uniformly perfect grammar,
      suspiciously comprehensive answers to every question, and lack of any
      hesitation or natural imprecision ARE flags.

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

      OUTPUT FORMAT:
      Respond with ONLY a valid JSON object. No markdown, no preamble, no explanation.
      {
        "coherence": 0.0,
        "depth": 0.0,
        "theological_consistency": 0.0,
        "engagement_quality": 0.0,
        "language_consistency_flag": false,
        "ai_generation_flag": false,
        "confidence_score": 0.0,
        "flags": [],
        "summary": "2-3 sentence assessment summary for admin review."
      }

      For confidence_score, compute:
        base = coherence * 0.30 + depth * 0.25 + theological_consistency * 0.20 + engagement_quality * 0.25
        if language_consistency_flag: base -= 0.15
        if ai_generation_flag: base -= 0.10
        confidence_score = max(0.0, min(1.0, base))

      For flags, include any applicable strings from:
        "language_mismatch", "ai_generated_responses", "rushed_completion",
        "major_contradictions", "no_church_details", "deflects_followups",
        "profile_form_mismatch", "generic_responses", "off_platform_redirect"

      Include "off_platform_redirect" if the user attempts to move the conversation
      off the platform, asks for contact information, or suggests meeting elsewhere
      during the verification interview.
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
          language_consistency_flag: result["language_consistency_flag"] == true,
          ai_generation_flag: result["ai_generation_flag"] == true,
          flags: Array(result["flags"]),
          summary: result["summary"].to_s.truncate(1000),
          assessed_at: Time.current.iso8601,
          topic_id: topic_id,
        }

        # Store the assessment
        profile.update_columns(
          verification_data: assessment_data,
          verification_conversation_topic_id: topic_id,
        )

        # Decision
        threshold = SiteSetting.respond_to?(:matchmaking_verification_auto_threshold) ?
          SiteSetting.matchmaking_verification_auto_threshold.to_f : 0.70

        if confidence >= threshold
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
            "(confidence: #{confidence.round(3)}, flags: #{assessment_data[:flags].join(', ')})"
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
      flags = assessment_data[:flags]&.join(", ") || "none"
      summary = assessment_data[:summary] || "No summary available."
      topic_url = "#{Discourse.base_url}/t/#{assessment_data[:topic_id]}" if assessment_data[:topic_id]

      body = <<~MSG
        A new user's verification interview has been flagged for review.

        **User**: #{profile.user.username} (#{profile.user.name || "no display name"})
        **Confidence Score**: #{confidence}
        **Flags**: #{flags}

        **Evaluator Summary**: #{summary}

        **Scores**:
        - Coherence: #{assessment_data[:coherence]&.round(3)}
        - Depth: #{assessment_data[:depth]&.round(3)}
        - Theological consistency: #{assessment_data[:theological_consistency]&.round(3)}
        - Engagement quality: #{assessment_data[:engagement_quality]&.round(3)}
        - Language mismatch flag: #{assessment_data[:language_consistency_flag]}
        - AI generation flag: #{assessment_data[:ai_generation_flag]}

        **Conversation transcript**: #{topic_url || "Topic ID not available"}

        **To approve**: Run in Rails console:
        ```
        p = MatchmakingProfile.find_by(user_id: #{profile.user_id})
        p.verify!("admin")
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
            title: "[Verification Review] #{profile.user.username} — confidence #{confidence}",
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
