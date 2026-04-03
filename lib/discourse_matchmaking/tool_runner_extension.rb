# frozen_string_literal: true

module DiscourseMatchmaking
  module ToolRunnerExtension
    MATCHMAKING_JS = <<~JS
      const matchmaking = {
        search: function(params) {
          const result = _matchmaking_search(typeof params === 'object' ? JSON.stringify(params) : String(params));
          return typeof result === 'string' ? JSON.parse(result) : result;
        },
        getMyProfile: function() {
          const result = _matchmaking_get_profile();
          return typeof result === 'string' ? JSON.parse(result) : result;
        },
        introduce: function(candidateLabel) {
          const result = _matchmaking_introduce(String(candidateLabel));
          return typeof result === 'string' ? JSON.parse(result) : result;
        }
      };
    JS

    VERIFICATION_JS = <<~JS
      const verification = {
        complete: function(enrichmentSummary) {
          const summaryStr = enrichmentSummary ?
            (typeof enrichmentSummary === 'object' ? JSON.stringify(enrichmentSummary) : String(enrichmentSummary)) :
            null;
          const result = _verification_complete(summaryStr);
          return typeof result === 'string' ? JSON.parse(result) : result;
        }
      };
    JS

    def mini_racer_context
      @mini_racer_context ||=
        begin
          ctx = super
          if SiteSetting.matchmaking_enabled
            attach_matchmaking(ctx)
            attach_verification(ctx)
          end
          ctx
        end
    end

    def framework_script
      if SiteSetting.matchmaking_enabled
        super + "\n" + MATCHMAKING_JS + "\n" + VERIFICATION_JS
      else
        super
      end
    end

    private

    def attach_verification(mini_racer_context)
      mini_racer_context.attach(
        "_verification_complete",
        ->(enrichment_summary_json) do
          in_attached_function do
            user_id = @context.user&.id
            return JSON.generate({ error: "No user context" }) unless user_id
            return JSON.generate({ error: "Matchmaking not enabled" }) unless SiteSetting.matchmaking_enabled

            profile = MatchmakingProfile.find_by(user_id: user_id)
            return JSON.generate({
              error: "no_profile",
              message: "No matchmaking profile found. The user needs to complete their profile first.",
            }) unless profile

            unless profile.needs_verification?
              return JSON.generate({
                status: "already_processed",
                verification_status: profile.verification_status,
                message: "This profile has already been processed.",
              })
            end

            # Get the topic ID from the conversation context.
            topic_id = nil

            if @context.respond_to?(:topic_id) && @context.topic_id.present?
              topic_id = @context.topic_id
            elsif @context.respond_to?(:post) && @context.post.respond_to?(:topic_id)
              topic_id = @context.post.topic_id
            elsif instance_variable_defined?(:@post) && @post.respond_to?(:topic_id)
              topic_id = @post.topic_id
            end

            # Fallback: find the most recent AI conversation topic for this user
            if topic_id.nil?
              recent_topic = Topic
                .joins(:posts)
                .where(archetype: Archetype.default)
                .where(posts: { user_id: user_id })
                .where("topics.title LIKE '%' OR topics.id > 0")
                .order("topics.updated_at DESC")
                .first
              topic_id = recent_topic&.id
            end

            unless topic_id
              return JSON.generate({
                error: "no_topic",
                message: "Could not determine the conversation topic. Please try again.",
              })
            end

            # Parse and store the enrichment summary if provided
            enrichment_data = nil
            if enrichment_summary_json.present? && enrichment_summary_json != "null"
              begin
                enrichment_data = JSON.parse(enrichment_summary_json)
              rescue JSON::ParserError => e
                Rails.logger.warn(
                  "[discourse-matchmaking] Failed to parse enrichment summary for user #{user_id}: #{e.message}"
                )
                # Continue without enrichment — the conversation transcript is still available
              end
            end

            # Build verification_data with enrichment summary included
            verification_data = profile.verification_data || {}
            verification_data = verification_data.merge("enrichment_summary" => enrichment_data) if enrichment_data

            # Update profile status and store conversation reference + enrichment
            profile.update_columns(
              verification_status: "pending_interview",
              verification_conversation_topic_id: topic_id,
              verification_data: verification_data,
            )

            # Enqueue the evaluator background job
            Jobs.enqueue(:evaluate_verification,
              profile_id: profile.id,
              topic_id: topic_id,
            )

            JSON.generate({
              status: "submitted",
              message: "Your profile interview has been submitted for review. You'll hear from us shortly!",
            })
          end
        end,
      )
    end

    def attach_matchmaking(mini_racer_context)
      @matchmaking_last_results = {}

      mini_racer_context.attach(
        "_matchmaking_search",
        ->(params_json) do
          in_attached_function do
            user_id = @context.user&.id
            return JSON.generate({ error: "No user context" }) unless user_id
            return JSON.generate({ error: "Matchmaking not enabled" }) unless SiteSetting.matchmaking_enabled

            searcher = MatchmakingProfile.find_by(user_id: user_id)
            return JSON.generate({ error: "no_profile", message: "You need to create a matchmaking profile first. Visit your User Preferences to get started." }) unless searcher

            unless MatchmakingConsent.fully_consented?(user_id)
              return JSON.generate({ error: "no_consent", message: "You need to complete the matchmaking consent process first." })
            end

            unless searcher.meets_minimum_completion?
              return JSON.generate({
                error: "incomplete_profile",
                message: "Your profile is #{searcher.completion_percentage}% complete. Please fill in more fields to reach the minimum threshold before searching.",
                completion: searcher.completion_percentage,
              })
            end

            overrides = {}
            begin
              overrides = JSON.parse(params_json) if params_json.present? && params_json != "undefined"
            rescue JSON::ParserError
            end

            max_results = SiteSetting.matchmaking_max_results_per_search rescue 25

            # Run the matching pipeline
            candidates = DiscourseMatchmaking::Scoring.hard_filter(searcher).includes(:user).to_a

            searcher.update_column(:last_search_at, Time.current)

            if candidates.empty?
              return JSON.generate({
                status: "no_matches",
                message: "No compatible profiles found with your current preferences. This could mean the community is still growing, or you might try adjusting your preferences.",
                searcher_summary: {
                  denomination: searcher.denomination,
                  location: "#{searcher.state}, #{searcher.country}",
                  age_range: "#{searcher.age_min_preference}-#{searcher.age_max_preference}",
                  seeking: searcher.seeking_gender,
                },
              })
            end

            # Score, sort, and take top N
            scored = candidates.map do |c|
              result = DiscourseMatchmaking::Scoring.score_candidate(searcher, c)
              { profile: c, score: result[:total], breakdown: result[:breakdown], flags: result[:flags] }
            end
            scored.sort_by! { |s| -s[:score] }
            top = scored.first(max_results)

            # Build LLM results AND store candidate label → user_id mapping
            @matchmaking_last_results = {}
            llm_results = top.each_with_index.map do |entry, idx|
              label = ("A".ord + idx).chr
              @matchmaking_last_results[label] = entry[:profile].user_id

              hash = entry[:profile].to_llm_hash(
                candidate_label: label,
                score: entry[:score],
                score_breakdown: entry[:breakdown],
              )

              # Add dealbreaker flags for pastoral presentation
              hash[:compatibility_flags] = entry[:flags] if entry[:flags]&.any?

              # Add distance if available
              distance = DiscourseMatchmaking::Scoring.send(:compute_distance, searcher, entry[:profile])
              hash[:distance_miles] = distance if distance

              hash
            end

            shown_to_user = SiteSetting.matchmaking_results_shown_to_user rescue 5
            JSON.generate({
              status: "ok",
              total_candidates_scored: llm_results.size,
              showing_top: [llm_results.size, shown_to_user].min,
              note_to_persona: "Present the top #{shown_to_user} matches with warm, specific explanations. Lead with faith alignment, then values, then practical compatibility. Do NOT reveal numeric scores. Use first names only. If the user wants to connect with someone, call matchmaking.introduce with their candidate label (A, B, C, etc.). If a candidate has compatibility_flags, address them honestly but pastorally — these are conversation starters, not disqualifiers. If distance_miles is provided, mention approximate distance naturally.",
              candidates: llm_results,
            })
          end
        end,
      )

      mini_racer_context.attach(
        "_matchmaking_get_profile",
        ->() do
          in_attached_function do
            user_id = @context.user&.id
            return JSON.generate(nil) unless user_id
            return JSON.generate({ error: "Matchmaking not enabled" }) unless SiteSetting.matchmaking_enabled

            profile = MatchmakingProfile.find_by(user_id: user_id)
            return JSON.generate(nil) unless profile

            # Include verification status in the profile response
            result = profile.to_llm_hash
            result[:verification_status] = profile.verification_status
            JSON.generate(result)
          end
        end,
      )

      mini_racer_context.attach(
        "_matchmaking_introduce",
        ->(candidate_label) do
          in_attached_function do
            user_id = @context.user&.id
            return JSON.generate({ error: "No user context" }) unless user_id
            return JSON.generate({ error: "Matchmaking not enabled" }) unless SiteSetting.matchmaking_enabled

            candidate_user_id = @matchmaking_last_results[candidate_label.to_s.strip.upcase]

            unless candidate_user_id
              candidate_profile = MatchmakingProfile
                .searchable
                .joins(:user)
                .where("LOWER(SPLIT_PART(users.name, ' ', 1)) = ?", candidate_label.to_s.strip.downcase)
                .first

              if candidate_profile
                candidate_user_id = candidate_profile.user_id
              else
                return JSON.generate({
                  error: "candidate_not_found",
                  message: "I couldn't find that person in the recent search results. Could you run a new search first?",
                })
              end
            end

            searcher = User.find_by(id: user_id)
            candidate = User.find_by(id: candidate_user_id)

            return JSON.generate({ error: "user_not_found" }) unless searcher && candidate

            existing_match = MatchmakingMatch.find_by(searcher_id: user_id, candidate_id: candidate_user_id, status: "introduced")
            if existing_match
              return JSON.generate({
                status: "already_introduced",
                message: "You've already been introduced to #{candidate.name&.split(' ')&.first || candidate.username}. Check your messages to continue your conversation.",
              })
            end

            bot_user_id = SiteSetting.matchmaking_persona_user_id.to_i
            bot_user = User.find_by(id: bot_user_id)
            return JSON.generate({ error: "bot_user_not_found" }) unless bot_user

            searcher_first = searcher.name&.split(" ")&.first || searcher.username
            candidate_first = candidate.name&.split(" ")&.first || candidate.username

            searcher_profile = MatchmakingProfile.find_by(user_id: user_id)
            candidate_profile = MatchmakingProfile.find_by(user_id: candidate_user_id)

            shared = []
            if searcher_profile && candidate_profile
              s_interests = Array(searcher_profile.interests)
              c_interests = Array(candidate_profile.interests)
              common = (s_interests & c_interests).first(3).map { |i| i.to_s.gsub("_", " ") }
              shared = common if common.any?
            end

            shared_text = shared.any? ? " You share some common interests — #{shared.join(', ')}." : ""

            intro_message = <<~MSG.strip
              Hi #{candidate_first} and #{searcher_first}! 👋

              I thought you two might enjoy getting to know each other. You're both part of the Jesus Enough community, and based on your profiles, you share some meaningful faith and values alignment.#{shared_text}

              This is a simple introduction — no pressure, no expectations. Take your time getting to know each other at your own pace.

              I'll leave you to it. Blessings to you both!
            MSG

            begin
              creator = PostCreator.new(
                bot_user,
                title: "Introduction — #{searcher_first} & #{candidate_first}",
                raw: intro_message,
                archetype: Archetype.private_message,
                target_usernames: "#{searcher.username},#{candidate.username}",
                skip_validations: true,
              )

              post = creator.create

              if creator.errors.present?
                return JSON.generate({
                  error: "pm_creation_failed",
                  message: "I wasn't able to create the introduction. Please try again.",
                  details: creator.errors.full_messages.join(", "),
                })
              end

              MatchmakingMatch.find_or_create_by(searcher_id: user_id, candidate_id: candidate_user_id) do |m|
                m.status = "introduced"
                m.ai_explanation = "Introduction created via matchmaking persona"
              end

              topic_url = "#{Discourse.base_url}/t/#{post.topic.slug}/#{post.topic.id}"

              JSON.generate({
                status: "introduced",
                message: "I've created a private conversation between you and #{candidate_first}. You'll find it in your messages.",
                topic_url: topic_url,
                candidate_name: candidate_first,
              })

            rescue => e
              JSON.generate({
                error: "pm_creation_error",
                message: "Something went wrong creating the introduction: #{e.message}",
              })
            end
          end
        end,
      )
    end
  end
end
