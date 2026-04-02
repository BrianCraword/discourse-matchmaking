# frozen_string_literal: true

module DiscourseMatchmaking
  class Scoring
    # ── Weight Configuration ──────────────────────────────────────────────
    # When faith_tags are available (LLM-processed profiles), narrative
    # scoring uses tag comparison. When unavailable, falls back to simple
    # keyword overlap.
    #
    # Faith-related scoring: ~67%
    # Practical scoring: ~33%
    DEFAULT_WEIGHTS = {
      denomination: 0.10,
      theology: 0.12,
      faith_alignment: 0.25,     # spiritual posture overlap from faith_tags
      partner_fit: 0.15,         # cross-match: does candidate match what searcher wants?
      location: 0.10,
      age: 0.08,
      attendance: 0.07,
      maturity_season: 0.05,     # faith maturity + ministry season compatibility
      interests: 0.05,
      relational_values: 0.03,   # relational values overlap from faith_tags
    }.freeze

    # ── Denomination Families & Matrix ────────────────────────────────────

    DENOMINATION_FAMILIES = {
      "reformed" => :reformed,
      "presbyterian" => :reformed,
      "baptist" => :evangelical,
      "non_denominational" => :evangelical,
      "church_of_christ" => :evangelical,
      "catholic" => :catholic,
      "orthodox" => :orthodox,
      "pentecostal" => :charismatic,
      "adventist" => :charismatic,
      "methodist" => :mainline,
      "lutheran" => :mainline,
      "anglican" => :mainline,
      "other" => :mainline,
    }.freeze

    DEFAULT_FAMILY_MATRIX = {
      reformed:    { reformed: 1.0, evangelical: 0.75, catholic: 0.3,  orthodox: 0.35, charismatic: 0.5,  mainline: 0.4  },
      evangelical: { reformed: 0.75, evangelical: 1.0, catholic: 0.35, orthodox: 0.3,  charismatic: 0.7,  mainline: 0.5  },
      catholic:    { reformed: 0.3,  evangelical: 0.35, catholic: 1.0, orthodox: 0.8,  charismatic: 0.25, mainline: 0.4  },
      orthodox:    { reformed: 0.35, evangelical: 0.3, catholic: 0.8,  orthodox: 1.0,  charismatic: 0.2,  mainline: 0.35 },
      charismatic: { reformed: 0.5,  evangelical: 0.7, catholic: 0.25, orthodox: 0.2,  charismatic: 1.0,  mainline: 0.45 },
      mainline:    { reformed: 0.4,  evangelical: 0.5, catholic: 0.4,  orthodox: 0.35, charismatic: 0.45, mainline: 1.0  },
    }.freeze

    ATTENDANCE_LEVELS = %w[multiple_weekly weekly bi_weekly monthly occasional].freeze
    BIBLE_ENGAGEMENT_LEVELS = %w[daily several_weekly weekly occasional].freeze

    # ── Theological Adjacency ─────────────────────────────────────────────

    THEOLOGICAL_ADJACENCY = {
      "spiritual_gifts" => {
        "continuationist" => { "continuationist" => 1.0, "open_but_cautious" => 0.7, "cessationist" => 0.2 },
        "cessationist" => { "cessationist" => 1.0, "open_but_cautious" => 0.6, "continuationist" => 0.2 },
        "open_but_cautious" => { "open_but_cautious" => 1.0, "continuationist" => 0.7, "cessationist" => 0.6 },
      },
      "creation" => {
        "young_earth" => { "young_earth" => 1.0, "old_earth" => 0.5, "theistic_evolution" => 0.2, "undecided" => 0.7 },
        "old_earth" => { "old_earth" => 1.0, "young_earth" => 0.5, "theistic_evolution" => 0.6, "undecided" => 0.7 },
        "theistic_evolution" => { "theistic_evolution" => 1.0, "old_earth" => 0.6, "young_earth" => 0.2, "undecided" => 0.7 },
        "undecided" => { "undecided" => 1.0, "young_earth" => 0.7, "old_earth" => 0.7, "theistic_evolution" => 0.7 },
      },
      "gender_roles" => {
        "complementarian" => { "complementarian" => 1.0, "somewhere_between" => 0.6, "egalitarian" => 0.3 },
        "egalitarian" => { "egalitarian" => 1.0, "somewhere_between" => 0.6, "complementarian" => 0.3 },
        "somewhere_between" => { "somewhere_between" => 1.0, "complementarian" => 0.6, "egalitarian" => 0.6 },
      },
      "end_times" => {
        "premillennial" => { "premillennial" => 1.0, "amillennial" => 0.6, "postmillennial" => 0.5, "pan_millennial" => 0.8 },
        "amillennial" => { "amillennial" => 1.0, "premillennial" => 0.6, "postmillennial" => 0.6, "pan_millennial" => 0.8 },
        "postmillennial" => { "postmillennial" => 1.0, "premillennial" => 0.5, "amillennial" => 0.6, "pan_millennial" => 0.8 },
        "pan_millennial" => { "pan_millennial" => 1.0, "premillennial" => 0.8, "amillennial" => 0.8, "postmillennial" => 0.8 },
      },
      "salvation_security" => {
        "eternal_security" => { "eternal_security" => 1.0, "conditional" => 0.3, "undecided" => 0.7 },
        "conditional" => { "conditional" => 1.0, "eternal_security" => 0.3, "undecided" => 0.7 },
        "undecided" => { "undecided" => 1.0, "eternal_security" => 0.7, "conditional" => 0.7 },
      },
    }.freeze

    # ── Spiritual posture affinity (used in tag-based scoring) ────────────
    # When two profiles activate different but related postures, partial
    # credit is awarded. E.g., sanctification ↔ identity_in_christ = 0.75.
    POSTURE_AFFINITY = {
      Set["sanctification", "identity_in_christ"] => 0.75,
      Set["sanctification", "surrender"] => 0.70,
      Set["sanctification", "salvation_atonement"] => 0.50,
      Set["sanctification", "character_virtue"] => 0.40,
      Set["surrender", "identity_in_christ"] => 0.60,
      Set["surrender", "prayer_life"] => 0.40,
      Set["surrender", "purpose_calling"] => 0.35,
      Set["salvation_atonement", "identity_in_christ"] => 0.65,
      Set["salvation_atonement", "surrender"] => 0.45,
      Set["salvation_atonement", "worship"] => 0.40,
      Set["salvation_atonement", "evangelism"] => 0.50,
      Set["identity_in_christ", "covenant_marriage"] => 0.35,
      Set["identity_in_christ", "character_virtue"] => 0.35,
      Set["scripture_devotion", "prayer_life"] => 0.40,
      Set["scripture_devotion", "community"] => 0.30,
      Set["worship", "prayer_life"] => 0.45,
      Set["worship", "joy_peace"] => 0.35,
      Set["evangelism", "service_heart"] => 0.50,
      Set["evangelism", "purpose_calling"] => 0.45,
      Set["community", "service_heart"] => 0.40,
      Set["covenant_marriage", "family_values"] => 0.50,
      Set["covenant_marriage", "character_virtue"] => 0.35,
      Set["purpose_calling", "service_heart"] => 0.45,
      Set["spiritual_struggle", "surrender"] => 0.40,
      Set["spiritual_struggle", "sanctification"] => 0.35,
      Set["spiritual_struggle", "service_heart"] => 0.30,
    }.freeze

    # ── Faith maturity compatibility ──────────────────────────────────────
    MATURITY_COMPATIBILITY = {
      "new_believer"  => { "new_believer" => 1.0, "growing" => 0.7, "established" => 0.4, "mature" => 0.3, "in_crisis" => 0.5, "rebuilding" => 0.6 },
      "growing"       => { "new_believer" => 0.7, "growing" => 1.0, "established" => 0.8, "mature" => 0.6, "in_crisis" => 0.5, "rebuilding" => 0.7 },
      "established"   => { "new_believer" => 0.4, "growing" => 0.8, "established" => 1.0, "mature" => 0.9, "in_crisis" => 0.5, "rebuilding" => 0.6 },
      "mature"        => { "new_believer" => 0.3, "growing" => 0.6, "established" => 0.9, "mature" => 1.0, "in_crisis" => 0.5, "rebuilding" => 0.5 },
      "in_crisis"     => { "new_believer" => 0.5, "growing" => 0.5, "established" => 0.5, "mature" => 0.5, "in_crisis" => 0.6, "rebuilding" => 0.7 },
      "rebuilding"    => { "new_believer" => 0.6, "growing" => 0.7, "established" => 0.6, "mature" => 0.5, "in_crisis" => 0.7, "rebuilding" => 0.8 },
    }.freeze

    # ── Ministry season compatibility ─────────────────────────────────────
    MINISTRY_SEASON_COMPATIBILITY = {
      "active"             => { "active" => 1.0, "seeking" => 0.8, "stepping_back" => 0.4, "not_serving" => 0.3, "called_but_waiting" => 0.7, "hurt_withdrawn" => 0.3 },
      "seeking"            => { "active" => 0.8, "seeking" => 1.0, "stepping_back" => 0.6, "not_serving" => 0.4, "called_but_waiting" => 0.8, "hurt_withdrawn" => 0.4 },
      "stepping_back"      => { "active" => 0.4, "seeking" => 0.6, "stepping_back" => 0.8, "not_serving" => 0.7, "called_but_waiting" => 0.6, "hurt_withdrawn" => 0.6 },
      "not_serving"        => { "active" => 0.3, "seeking" => 0.4, "stepping_back" => 0.7, "not_serving" => 0.7, "called_but_waiting" => 0.5, "hurt_withdrawn" => 0.6 },
      "called_but_waiting" => { "active" => 0.7, "seeking" => 0.8, "stepping_back" => 0.6, "not_serving" => 0.5, "called_but_waiting" => 0.9, "hurt_withdrawn" => 0.5 },
      "hurt_withdrawn"     => { "active" => 0.3, "seeking" => 0.4, "stepping_back" => 0.6, "not_serving" => 0.6, "called_but_waiting" => 0.5, "hurt_withdrawn" => 0.7 },
    }.freeze

    # ══════════════════════════════════════════════════════════════════════
    # PUBLIC API
    # ══════════════════════════════════════════════════════════════════════

    def self.weights
      custom = SiteSetting.matchmaking_scoring_weights rescue nil
      if custom.present?
        begin
          parsed = JSON.parse(custom)
          DEFAULT_WEIGHTS.merge(parsed.symbolize_keys)
        rescue JSON::ParserError
          DEFAULT_WEIGHTS
        end
      else
        DEFAULT_WEIGHTS
      end
    end

    def self.denomination_family(denomination)
      DENOMINATION_FAMILIES[denomination.to_s] || :mainline
    end

    def self.denomination_compatibility(denom_a, denom_b)
      return 1.0 if denom_a == denom_b
      family_a = denomination_family(denom_a)
      family_b = denomination_family(denom_b)
      return 0.9 if family_a == family_b
      DEFAULT_FAMILY_MATRIX.dig(family_a, family_b) || 0.3
    end

    # ── Stage 1: SQL Hard-Filter ──────────────────────────────────────────
    def self.hard_filter(searcher)
      current_year = Date.today.year

      scope = MatchmakingProfile
        .searchable
        .where.not(user_id: searcher.user_id)
        .where(gender: searcher.seeking_gender)
        .where(seeking_gender: searcher.gender)

      if searcher.age_min_preference.present?
        scope = scope.where("birth_year <= ?", current_year - searcher.age_min_preference)
      end
      if searcher.age_max_preference.present?
        scope = scope.where("birth_year >= ?", current_year - searcher.age_max_preference)
      end

      if searcher.denomination_importance == "essential" && searcher.denomination.present?
        scope = scope.where(denomination: searcher.denomination)
      end

      dealbreakers = Array(searcher.dealbreakers)
      if dealbreakers.include?("no_church_attendance")
        scope = scope.where.not(church_attendance: [nil, ""])
      end
      if dealbreakers.include?("different_denomination") && searcher.denomination.present?
        scope = scope.where(denomination: searcher.denomination)
      end

      scope
    end

    # ── Stage 2: Weighted Scoring ─────────────────────────────────────────
    def self.score_candidate(searcher, candidate)
      w = weights
      breakdown = {}
      use_tags = searcher.has_faith_insight? && candidate.has_faith_insight?

      # 1. Denomination compatibility
      denom_raw = denomination_compatibility(searcher.denomination, candidate.denomination)
      if searcher.denomination_importance == "flexible"
        denom_raw = [denom_raw, 0.7].max * 0.8 + 0.2
      end
      breakdown[:denomination] = denom_raw

      # 2. Core theological alignment (structured checkboxes — always available)
      breakdown[:theology] = score_theological_views(searcher, candidate)

      if use_tags
        # ── Tag-based narrative scoring (LLM-processed profiles) ──────
        s_tags = searcher.faith_tags
        c_tags = candidate.faith_tags

        # 3. Faith alignment — spiritual posture overlap with strength weighting
        breakdown[:faith_alignment] = score_posture_alignment(s_tags, c_tags)

        # 4. Partner fit — cross-match priorities vs actual profile
        breakdown[:partner_fit] = score_partner_fit_tags(s_tags, c_tags)

        # 5. Maturity & season compatibility
        breakdown[:maturity_season] = score_maturity_season(s_tags, c_tags)

        # 6. Relational values overlap
        breakdown[:relational_values] = score_tag_array_overlap(
          s_tags["relational_values"], c_tags["relational_values"]
        )
      else
        # ── Fallback: keyword overlap for unprocessed profiles ────────
        # Consolidate the 4 narrative fields into faith_alignment
        testimony_score = score_narrative_field_fallback(searcher.testimony, candidate.testimony)
        life_goals_score = score_narrative_field_fallback(searcher.life_goals, candidate.life_goals)
        ministry_score = score_narrative_field_fallback(searcher.ministry_involvement, candidate.ministry_involvement)

        breakdown[:faith_alignment] = (testimony_score * 0.35 + life_goals_score * 0.40 + ministry_score * 0.25)
        breakdown[:partner_fit] = score_partner_fit_fallback(searcher, candidate)
        breakdown[:maturity_season] = 0.5 # neutral when no tags
        breakdown[:relational_values] = 0.3 # neutral when no tags
      end

      # 7. Location compatibility (always structured)
      breakdown[:location] = score_location(searcher, candidate)

      # 8. Age range mutual fit (always structured)
      breakdown[:age] = score_age_range(searcher, candidate)

      # 9. Church attendance + bible engagement (always structured)
      # CALIBRATION FIX (Search #12): Asymmetric engagement scoring.
      # A partner who attends church more often or reads Scripture more
      # frequently is not a compatibility problem — it's a blessing.
      # Only penalize when the CANDIDATE is LESS engaged than the searcher.
      # When the candidate is MORE engaged, score as if they match.
      breakdown[:attendance] = score_engagement_asymmetric(searcher, candidate)

      # 10. Shared interests + lifestyle (always structured)
      breakdown[:interests] = score_jaccard(
        Array(searcher.interests), Array(candidate.interests)
      ) * 0.7 + score_jaccard(
        Array(searcher.lifestyle), Array(candidate.lifestyle)
      ) * 0.3

      # Compute weighted total
      total = 0.0
      w.each do |criterion, weight|
        total += weight * (breakdown[criterion] || 0.0)
      end

      # Build dealbreaker flags
      flags = detect_dealbreaker_flags(searcher, candidate)

      {
        total: total.round(4),
        breakdown: breakdown.transform_values { |v| v.round(3) },
        flags: flags,
      }
    end

    # ── Full Search Pipeline ──────────────────────────────────────────────
    def self.search(searcher, max_results: nil)
      max_results ||= (SiteSetting.matchmaking_max_results_per_search rescue 25)

      candidates = hard_filter(searcher).includes(:user).to_a
      return [] if candidates.empty?

      scored = candidates.map do |candidate|
        result = score_candidate(searcher, candidate)
        {
          profile: candidate,
          score: result[:total],
          breakdown: result[:breakdown],
          flags: result[:flags],
        }
      end

      scored.sort_by! { |s| -s[:score] }
      top = scored.first(max_results)

      top.each_with_index.map do |entry, idx|
        label = ("A".ord + idx).chr
        hash = entry[:profile].to_llm_hash(
          candidate_label: label,
          score: entry[:score],
          score_breakdown: entry[:breakdown],
        )
        hash[:compatibility_flags] = entry[:flags] if entry[:flags].any?
        hash[:distance_miles] = compute_distance(searcher, entry[:profile])
        hash
      end
    end

    # ══════════════════════════════════════════════════════════════════════
    # PRIVATE — TAG-BASED SCORING (primary, when faith_tags available)
    # ══════════════════════════════════════════════════════════════════════

    private

    # ── Spiritual posture alignment ───────────────────────────────────────
    # CALIBRATION FIX (Search #11): Changed from union-denominator model
    # to coverage-ratio model.
    #
    # Problem with the old approach:
    #   The denominator was weighted_total = sum of max(s,c) for ALL
    #   activated postures across both profiles. This means two people
    #   who each activate 7 postures and share 4 score LOWER than two
    #   people who each activate 4 postures and share all 4 — even
    #   though the first pair has equal or greater spiritual compatibility.
    #   Spiritual richness was being penalized.
    #
    # New approach — coverage ratio:
    #   Score each person's posture set from the other's perspective.
    #   "How much of MY spiritual life does this person share or resonate
    #   with?" Average the two perspectives (weighted toward seeker).
    #   Unique postures contribute mildly via affinity, but they don't
    #   dilute the score of genuinely shared postures.
    #
    #   With 4 shared postures at moderate-to-high strength, this should
    #   produce scores in the 0.55-0.70 range depending on strength
    #   similarity, up from the 0.487 the old method produced.
    def self.score_posture_alignment(s_tags, c_tags)
      s_postures = s_tags["spiritual_posture_strength"] || {}
      c_postures = c_tags["spiritual_posture_strength"] || {}

      return 0.4 if s_postures.empty? && c_postures.empty?
      return 0.3 if s_postures.empty? || c_postures.empty?

      # Score from searcher's perspective: how much of MY spiritual life
      # does the candidate share or resonate with?
      forward = score_posture_coverage(s_postures, c_postures)

      # Score from candidate's perspective: how much of THEIR spiritual
      # life do I share or resonate with?
      reverse = score_posture_coverage(c_postures, s_postures)

      # Weight toward searcher's perspective (they're the one choosing)
      [[forward * 0.6 + reverse * 0.4, 1.0].min, 0.0].max
    end

    # Score one direction: for each of MY postures, how well does the
    # OTHER person match it — either directly or via affinity?
    def self.score_posture_coverage(my_postures, their_postures)
      return 0.3 if my_postures.empty?

      total_weight = 0.0
      total_match = 0.0

      my_postures.each do |posture, my_strength|
        my_str = my_strength.to_f
        next if my_str <= 0

        # This posture's importance = its strength in my profile.
        # Stronger postures matter more to the final score.
        total_weight += my_str

        their_str = their_postures[posture]&.to_f || 0.0

        if their_str > 0
          # Direct match — score by how similar our strengths are.
          # Two people at 0.7 and 0.8 are a better match than 0.4 and 0.9.
          strength_similarity = [my_str, their_str].min / [my_str, their_str].max
          total_match += my_str * strength_similarity
        else
          # No direct match — check affinity table for adjacent concepts.
          # Best affinity match wins (don't double-count).
          best_affinity = 0.0
          their_postures.each do |their_posture, t_str|
            t_str_f = t_str.to_f
            next if t_str_f <= 0
            aff = POSTURE_AFFINITY[Set[posture, their_posture]]
            next unless aff && aff > 0
            # Affinity credit = affinity_value * partner's strength in that posture.
            # A strong affinity to a strong posture gives more credit than
            # a weak affinity to a weak posture.
            credit = aff * ([my_str, t_str_f].min / [my_str, t_str_f].max)
            best_affinity = [best_affinity, credit].max
          end
          # Affinity contributes at reduced weight — it's resonance, not identity
          total_match += my_str * best_affinity * 0.6
        end
      end

      return 0.3 if total_weight == 0
      total_match / total_weight
    end

    # ── Partner fit from tags ─────────────────────────────────────────────
    # Cross-matches: does the candidate's spiritual profile match
    # what the searcher described wanting? Bidirectional.
    def self.score_partner_fit_tags(s_tags, c_tags)
      forward = score_partner_direction_tags(s_tags, c_tags)
      reverse = score_partner_direction_tags(c_tags, s_tags)

      # Weight toward searcher's perspective
      forward * 0.6 + reverse * 0.4
    end

    # CALIBRATION FIX (Search #11): Now uses posture strength instead of
    # binary presence.
    #
    # Problem with the old approach:
    #   If a priority mapped to [sanctification, identity_in_christ] and
    #   the candidate had either at ANY strength (even 0.1), they got
    #   full credit for that priority. A candidate with a barely-mentioned
    #   posture scored the same as one whose entire testimony centers on it.
    #   This produced 1.0 for Demo even though her profile has mixed
    #   faith/secular partner language.
    #
    # New approach — strength-weighted matching:
    #   For each priority, take the BEST matching posture's strength score.
    #   A priority satisfied by a posture at 0.9 scores much higher than
    #   one satisfied at 0.3. This naturally penalizes mixed-content
    #   partner descriptions where faith themes are present but not central.
    def self.score_partner_direction_tags(seeker_tags, candidate_tags)
      priorities = seeker_tags["partner_priorities"] || []
      absence_flags = seeker_tags["partner_absence_flags"] || []

      # Faith-silence penalty: partner description had no faith language
      if absence_flags.include?("faith_silent")
        candidate_postures = candidate_tags["spiritual_posture"] || []
        return 0.1 if candidate_postures.size >= 2
        return 0.2
      end

      return 0.3 if priorities.empty?

      # Map partner priorities to spiritual posture expectations
      priority_to_posture = {
        "faith_depth" => %w[sanctification salvation_atonement identity_in_christ scripture_devotion],
        "character" => %w[character_virtue sanctification],
        "shared_ministry" => %w[service_heart evangelism community],
        "theological_alignment" => [], # handled by theology score, not here
        "emotional_maturity" => %w[character_virtue surrender],
        "family_orientation" => %w[family_values covenant_marriage],
        "adventure" => %w[joy_peace],
        "humor" => %w[joy_peace],
        "companionship" => %w[community joy_peace],
      }

      candidate_strengths = candidate_tags["spiritual_posture_strength"] || {}
      match_total = 0.0
      checked = 0

      priorities.each do |priority|
        expected_postures = priority_to_posture[priority]
        next if expected_postures.nil? || expected_postures.empty?

        checked += 1

        # Find the best matching posture's strength — not just presence.
        # A priority mapped to [sanctification, identity_in_christ]:
        #   candidate has sanctification at 0.8 → credit = 0.8
        #   candidate has identity_in_christ at 0.4 → credit = 0.4
        #   candidate has both → take the best = 0.8
        #   candidate has neither → credit = 0.0
        best_strength = 0.0
        expected_postures.each do |ep|
          str = candidate_strengths[ep]&.to_f || 0.0
          best_strength = [best_strength, str].max
        end

        match_total += best_strength
      end

      return 0.4 if checked == 0

      # Scale: 0.2 base + up to 0.8 from matches.
      # With 3 priorities all matched at strength 0.7, score = 0.2 + 0.7*0.8 = 0.76
      # With 3 priorities, 2 matched at 0.8 and 1 at 0.0, avg=0.533, score = 0.627
      avg_match = match_total / checked
      0.2 + avg_match * 0.8
    end

    # ── Maturity & season compatibility ───────────────────────────────────
    def self.score_maturity_season(s_tags, c_tags)
      maturity_score = 0.5
      season_score = 0.5

      s_mat = s_tags["faith_maturity"]
      c_mat = c_tags["faith_maturity"]
      if s_mat.present? && c_mat.present?
        maturity_score = MATURITY_COMPATIBILITY.dig(s_mat, c_mat) || 0.5
      end

      s_sea = s_tags["ministry_season"]
      c_sea = c_tags["ministry_season"]
      if s_sea.present? && c_sea.present?
        season_score = MINISTRY_SEASON_COMPATIBILITY.dig(s_sea, c_sea) || 0.5
      end

      maturity_score * 0.6 + season_score * 0.4
    end

    # ── Tag array overlap (Jaccard on string arrays) ──────────────────────
    def self.score_tag_array_overlap(array_a, array_b)
      a = Array(array_a).map(&:to_s)
      b = Array(array_b).map(&:to_s)
      return 0.3 if a.empty? || b.empty?

      intersection = (a & b).size
      union_size = (a | b).size
      return 0.3 if union_size == 0

      0.2 + (intersection.to_f / union_size) * 0.8
    end

    # ══════════════════════════════════════════════════════════════════════
    # PRIVATE — CLUSTER ENGINE FALLBACK (when faith_tags not yet generated)
    # ══════════════════════════════════════════════════════════════════════

    # Simple keyword overlap for unprocessed narrative fields.
    # This is intentionally basic — it's a stopgap until the LLM
    # processes the profile. Good enough for rough ranking.
    def self.score_narrative_field_fallback(text_a, text_b)
      return 0.4 if text_a.blank? && text_b.blank?
      return 0.3 if text_a.blank? || text_b.blank?

      words_a = extract_keywords(text_a)
      words_b = extract_keywords(text_b)
      return 0.3 if words_a.empty? || words_b.empty?

      intersection = (words_a & words_b).size
      union_size = (words_a | words_b).size
      return 0.3 if union_size == 0

      raw = intersection.to_f / union_size
      0.2 + (raw * 0.8)
    end

    # Fallback partner fit — simple keyword cross-match
    def self.score_partner_fit_fallback(searcher, candidate)
      return 0.3 if searcher.partner_description.blank?

      actual_text = [
        candidate.testimony, candidate.life_goals,
        candidate.ministry_involvement,
      ].compact.join(" ")
      return 0.3 if actual_text.blank?

      forward = score_narrative_field_fallback(searcher.partner_description, actual_text)
      reverse = if candidate.partner_description.present?
        searcher_text = [
          searcher.testimony, searcher.life_goals,
          searcher.ministry_involvement,
        ].compact.join(" ")
        score_narrative_field_fallback(candidate.partner_description, searcher_text)
      else
        0.3
      end

      forward * 0.6 + reverse * 0.4
    end

    # ══════════════════════════════════════════════════════════════════════
    # PRIVATE — STRUCTURED FIELD SCORING (always active)
    # ══════════════════════════════════════════════════════════════════════

    # CALIBRATION FIX (Search #12): Per-topic marriage relevance weighting.
    #
    # Problem with the old approach:
    #   All 5 theological topics were averaged equally. But gender_roles
    #   (who leads in marriage, how decisions are made, whether wife works)
    #   has far more daily-life impact on a marriage than end_times views.
    #   Two people who disagree on eschatology can worship together happily;
    #   two people who disagree on gender roles will fight about household
    #   structure. Equal weighting hides this.
    #
    # New approach — marriage relevance multipliers:
    #   gender_roles:      2.5x — directly affects daily married life
    #   salvation_security: 1.5x — affects spiritual anxiety, child-rearing
    #   spiritual_gifts:   1.5x — determines worship style, church choice
    #   creation:          0.5x — rarely affects daily married life
    #   end_times:         0.5x — almost never causes marital conflict
    #
    # Weighted average ensures high-impact topics dominate the score when
    # they diverge, while low-impact topics contribute proportionally less.
    #
    # For BrianC/Demo (egal↔between, cont↔cont, YE↔OE, pre↔pan, ES↔undec):
    #   Old: (0.6+1.0+0.5+0.8+0.7)/5 = 0.72
    #   New: (0.6×2.5+1.0×1.5+0.5×0.5+0.8×0.5+0.7×1.5)/6.5 = 0.723
    #   Nearly identical here because high-weight mismatches and matches
    #   offset each other. But for a complementarian↔egalitarian pair,
    #   the 0.3 adjacency score at 2.5x weight would pull the total down
    #   significantly — which is the correct behavior for marriage matching.
    THEOLOGICAL_MARRIAGE_WEIGHTS = {
      "gender_roles"      => 2.5,
      "salvation_security" => 1.5,
      "spiritual_gifts"   => 1.5,
      "creation"          => 0.5,
      "end_times"         => 0.5,
    }.freeze

    def self.score_theological_views(searcher, candidate)
      stv = searcher.theological_views || {}
      ctv = candidate.theological_views || {}
      return 0.5 if stv.empty? && ctv.empty?

      weighted_total = 0.0
      weighted_score = 0.0

      MatchmakingProfile::THEOLOGICAL_KEYS.each do |key|
        sv = stv[key]
        cv = ctv[key]
        next if sv.blank? && cv.blank?

        topic_weight = THEOLOGICAL_MARRIAGE_WEIGHTS[key] || 1.0

        if sv.blank? || cv.blank?
          weighted_score += 0.5 * topic_weight
          weighted_total += topic_weight
          next
        end

        adjacency = THEOLOGICAL_ADJACENCY.dig(key, sv.to_s, cv.to_s)
        weighted_score += (adjacency || 0.5) * topic_weight
        weighted_total += topic_weight
      end

      weighted_total > 0 ? weighted_score / weighted_total : 0.5
    end

    def self.score_location(searcher, candidate)
      if searcher.zip_code.present? && candidate.zip_code.present? &&
         ActiveRecord::Base.connection.table_exists?(:zip_code_locations)
        distance = ZipCodeLocation.distance_between(searcher.zip_code, candidate.zip_code)
        if distance
          base = score_from_distance(distance)
          s_flex = flexibility_modifier(searcher.location_flexibility)
          c_flex = flexibility_modifier(candidate.location_flexibility)
          flex_boost = [s_flex, c_flex].max
          return [base + (1.0 - base) * flex_boost * 0.3, 1.0].min
        end
      end

      if searcher.city.present? && candidate.city.present? &&
         searcher.city.downcase.strip == candidate.city.downcase.strip &&
         searcher.state.present? && candidate.state.present? &&
         searcher.state.downcase.strip == candidate.state.downcase.strip
        return 1.0
      end

      if searcher.state.present? && candidate.state.present? &&
         searcher.state.downcase.strip == candidate.state.downcase.strip
        base = 0.7
      elsif searcher.country.present? && candidate.country.present? &&
            searcher.country.downcase.strip == candidate.country.downcase.strip
        base = 0.3
      else
        base = 0.1
      end

      s_flex = flexibility_modifier(searcher.location_flexibility)
      c_flex = flexibility_modifier(candidate.location_flexibility)
      flex_boost = [s_flex, c_flex].max
      [base + (1.0 - base) * flex_boost * 0.5, 1.0].min
    end

    def self.score_from_distance(miles)
      return 1.0  if miles <= 10
      return 0.9  if miles <= 25
      return 0.8  if miles <= 50
      return 0.65 if miles <= 100
      return 0.5  if miles <= 200
      return 0.35 if miles <= 500
      return 0.2  if miles <= 1000
      0.1
    end

    def self.flexibility_modifier(flexibility)
      case flexibility.to_s
      when "international" then 0.9
      when "national" then 0.7
      when "regional" then 0.4
      when "state" then 0.2
      when "local_only" then 0.0
      else 0.3
      end
    end

    # CALIBRATION FIX (Search #12): Gradient age scoring instead of binary.
    #
    # Problem with the old approach:
    #   Three buckets: both-in-range=1.0, one-sided=0.5, neither=0.0.
    #   A 38-year-old who misses a 25-35 range by 3 years scored the same
    #   0.5 as someone who misses by 15 years. In the 30s, a 4-year gap
    #   is negligible; the old method treated it as a 50% penalty.
    #
    # New approach — soft decay near boundaries:
    #   Score each direction separately. Within range = 1.0. Outside range,
    #   score decays based on how many years outside. Just barely outside
    #   (1-2 years) is still high (0.85-0.75). Further out decays more
    #   steeply. Average the two directions (60/40 toward searcher).
    #
    #   For BrianC (38) with Demo's range 25-35: 3 years outside → ~0.65
    #   For Demo (34) with BrianC's range 25-45: inside → 1.0
    #   Combined: 0.65 * 0.6 + 1.0 * 0.4 = 0.79 (up from 0.5)
    def self.score_age_range(searcher, candidate)
      return 0.5 unless searcher.birth_year.present? && candidate.birth_year.present?

      current_year = Date.today.year
      s_age = current_year - searcher.birth_year
      c_age = current_year - candidate.birth_year

      # Score from searcher's perspective: is candidate's age in my range?
      s_min = searcher.age_min_preference || 18
      s_max = searcher.age_max_preference || 80
      forward = age_fit_score(c_age, s_min, s_max)

      # Score from candidate's perspective: is searcher's age in their range?
      c_min = candidate.age_min_preference || 18
      c_max = candidate.age_max_preference || 80
      reverse = age_fit_score(s_age, c_min, c_max)

      # Weight toward searcher's perspective
      forward * 0.6 + reverse * 0.4
    end

    # How well does `actual_age` fit within the preferred [min, max] range?
    # Inside range = 1.0. Outside range, soft decay based on years outside.
    def self.age_fit_score(actual_age, min_pref, max_pref)
      return 1.0 if actual_age >= min_pref && actual_age <= max_pref

      # How many years outside the range?
      if actual_age < min_pref
        years_outside = min_pref - actual_age
      else
        years_outside = actual_age - max_pref
      end

      # Decay curve: each year outside the range reduces score.
      # 1 year outside = 0.85, 2 = 0.75, 3 = 0.65, 5 = 0.45, 8 = 0.15, 10+ ≈ 0
      # Formula: max(0, 1.0 - years_outside * 0.15) — then square-root
      # to make the curve gentle near the boundary and steeper further out.
      # Actually simpler: use a linear decay with a floor.
      #
      # 1yr → 0.85    4yr → 0.55
      # 2yr → 0.75    5yr → 0.45
      # 3yr → 0.65    7yr → 0.25
      #               10yr → 0.0
      raw = 1.0 - (years_outside * 0.10)
      [[raw, 0.0].max, 1.0].min
    end

    # Asymmetric engagement scoring for attendance + bible engagement.
    # Both level arrays are ordered most-engaged-first:
    #   ATTENDANCE_LEVELS: multiple_weekly, weekly, bi_weekly, monthly, occasional
    #   BIBLE_ENGAGEMENT_LEVELS: daily, several_weekly, weekly, occasional
    # A LOWER index = MORE engaged.
    #
    # Principle: a candidate who is MORE engaged than the searcher is not
    # a compatibility problem. "She attends more than I do" and "she reads
    # Scripture more than I do" are positives, not penalties. We only
    # penalize when the candidate is LESS engaged — that's where the
    # "unequally yoked" concern lives.
    #
    # Implementation: use ordered_proximity for the gap, but when the
    # candidate is more engaged, score as 1.0 (perfect match equivalent).
    def self.score_engagement_asymmetric(searcher, candidate)
      att_score = score_engagement_direction(
        searcher.church_attendance, candidate.church_attendance, ATTENDANCE_LEVELS
      )
      bible_score = score_engagement_direction(
        searcher.bible_engagement, candidate.bible_engagement, BIBLE_ENGAGEMENT_LEVELS
      )
      att_score * 0.6 + bible_score * 0.4
    end

    def self.score_engagement_direction(searcher_val, candidate_val, ordered_list)
      return 0.5 if searcher_val.blank? || candidate_val.blank?

      s_idx = ordered_list.index(searcher_val.to_s)
      c_idx = ordered_list.index(candidate_val.to_s)
      return 0.5 if s_idx.nil? || c_idx.nil?

      if c_idx <= s_idx
        # Candidate is equally or MORE engaged — no penalty
        1.0
      else
        # Candidate is LESS engaged — penalize by gap size
        distance = c_idx - s_idx
        return 0.7 if distance == 1
        return 0.4 if distance == 2
        0.1
      end
    end

    def self.score_ordered_proximity(value_a, value_b, ordered_list)
      return 0.5 if value_a.blank? || value_b.blank?

      idx_a = ordered_list.index(value_a.to_s)
      idx_b = ordered_list.index(value_b.to_s)

      return 0.5 if idx_a.nil? || idx_b.nil?

      distance = (idx_a - idx_b).abs
      return 1.0 if distance == 0
      return 0.7 if distance == 1
      return 0.4 if distance == 2
      0.1
    end

    def self.score_jaccard(set_a, set_b)
      return 0.0 if set_a.empty? || set_b.empty?

      a = set_a.map(&:to_s)
      b = set_b.map(&:to_s)

      intersection = (a & b).size
      union = (a | b).size

      return 0.0 if union == 0

      intersection.to_f / union
    end

    # ══════════════════════════════════════════════════════════════════════
    # PRIVATE — DEALBREAKER FLAGS & UTILITIES
    # ══════════════════════════════════════════════════════════════════════

    def self.detect_dealbreaker_flags(searcher, candidate)
      flags = []

      if searcher.relationship_intention.present? && candidate.relationship_intention.present?
        s = searcher.relationship_intention
        c = candidate.relationship_intention
        if s != c
          if s == "marriage_minded" && c == "friendship_first"
            flags << {
              type: "relationship_intention",
              severity: "notable",
              detail: "You're marriage-minded; #{candidate.first_name} is looking for friendship first. This doesn't mean incompatibility — many great marriages started as friendships — but the timeline expectations may differ.",
            }
          elsif s == "friendship_first" && c == "marriage_minded"
            flags << {
              type: "relationship_intention",
              severity: "notable",
              detail: "You're looking for friendship first; #{candidate.first_name} is marriage-minded. Worth a conversation about pace and expectations.",
            }
          elsif (s == "marriage_minded" && c == "exploring") || (s == "exploring" && c == "marriage_minded")
            flags << {
              type: "relationship_intention",
              severity: "minor",
              detail: "Different relationship intentions — one of you is marriage-minded, the other is still exploring. Could be a growth conversation.",
            }
          end
        end
      end

      if searcher.children_preference.present? && candidate.children_preference.present?
        s = searcher.children_preference
        c = candidate.children_preference
        wants = %w[want_children have_and_want_more]
        no_wants = %w[no_children have_done]
        if (wants.include?(s) && no_wants.include?(c)) || (no_wants.include?(s) && wants.include?(c))
          flags << {
            type: "children_preference",
            severity: "significant",
            detail: "There's a difference on children — one of you wants children, the other doesn't or is done. This is worth an honest conversation early.",
          }
        end
      end

      if searcher.denomination_importance == "essential" &&
         searcher.denomination.present? && candidate.denomination.present? &&
         searcher.denomination != candidate.denomination
        flags << {
          type: "denomination",
          severity: "notable",
          detail: "You marked denomination as essential, but #{candidate.first_name} is #{candidate.denomination.gsub('_', ' ')} while you're #{searcher.denomination.gsub('_', ' ')}.",
        }
      end

      # Struggle indicator flag (from faith_tags)
      if candidate.has_faith_insight?
        struggles = candidate.faith_tags["struggle_indicators"] || []
        if struggles.any?
          readable = struggles.map { |s| s.gsub("_", " ") }.join(", ")
          flags << {
            type: "spiritual_season",
            severity: "informational",
            detail: "#{candidate.first_name} may be in a season of #{readable}. This is context for compassionate conversation, not a disqualifier.",
          }
        end
      end

      # Partner description faith-silence flag (from faith_tags)
      if candidate.has_faith_insight?
        absence = candidate.faith_tags["partner_absence_flags"] || []
        if absence.include?("faith_silent")
          flags << {
            type: "partner_values",
            severity: "notable",
            detail: "#{candidate.first_name}'s partner description focuses on lifestyle rather than faith priorities. This may indicate different relational values worth exploring.",
          }
        end
      end

      Array(searcher.dealbreakers).each do |db|
        case db
        when "smoking"
          if Array(candidate.lifestyle).include?("smoker")
            flags << { type: "dealbreaker", severity: "notable", detail: "You listed smoking as a dealbreaker." }
          end
        when "heavy_drinking"
          if Array(candidate.lifestyle).include?("drinks_heavily")
            flags << { type: "dealbreaker", severity: "notable", detail: "You listed heavy drinking as a dealbreaker." }
          end
        when "no_children"
          if candidate.children_preference == "no_children"
            flags << { type: "dealbreaker", severity: "significant", detail: "You listed 'no children' as a dealbreaker, and this person has indicated they don't want children." }
          end
        end
      end

      flags
    end

    def self.compute_distance(searcher, candidate)
      return nil unless searcher.zip_code.present? && candidate.zip_code.present?
      return nil unless ActiveRecord::Base.connection.table_exists?(:zip_code_locations)
      ZipCodeLocation.distance_between(searcher.zip_code, candidate.zip_code)
    end

    # ── Keyword extraction (used in fallback scoring) ─────────────────────
    STOP_WORDS = Set.new(%w[
      a an the and or but in on at to for of is it my i me we us he she
      they them this that these those with from by as be was were been
      being am are has have had do does did will would could should may
      might can shall not no nor so if then than too very just about
      also into over after before between through during each some all
      any such only other up out his her its our their which what when
      where how who whom why own more most much many really want
      like know think feel believe need get make way find look come
      going have been doing getting making someone something
      always never still even though because since while until
      thing things lot lots kind right good great well
    ]).freeze

    def self.extract_keywords(text)
      return Set.new if text.blank?
      words = text.downcase.gsub(/[^a-z0-9\s]/, " ").split(/\s+/)
      words.reject! { |w| w.length < 3 || STOP_WORDS.include?(w) }
      Set.new(words)
    end
  end
end
