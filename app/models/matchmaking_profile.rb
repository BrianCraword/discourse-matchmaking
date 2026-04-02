# frozen_string_literal: true

class MatchmakingProfile < ActiveRecord::Base
  belongs_to :user
  has_many :matches_as_searcher,
           class_name: "MatchmakingMatch",
           foreign_key: :searcher_id,
           dependent: :destroy
  has_many :matches_as_candidate,
           class_name: "MatchmakingMatch",
           foreign_key: :candidate_id,
           dependent: :destroy

  # ── Enums as constants (for validation, not Rails enum) ──────────────
  GENDERS = %w[male female].freeze
  LOCATION_FLEXIBILITIES = %w[local_only state regional national international].freeze
  DENOMINATIONS = %w[
    baptist reformed non_denominational catholic pentecostal
    methodist presbyterian lutheran anglican orthodox
    church_of_christ adventist other
  ].freeze
  DENOMINATION_IMPORTANCES = %w[essential preferred flexible].freeze
  CHURCH_ATTENDANCES = %w[multiple_weekly weekly bi_weekly monthly occasional].freeze
  BAPTISM_STATUSES = %w[baptized not_yet planning].freeze
  BIBLE_ENGAGEMENTS = %w[daily several_weekly weekly occasional].freeze
  RELATIONSHIP_INTENTIONS = %w[marriage_minded exploring friendship_first].freeze
  CHILDREN_PREFERENCES = %w[want_children have_and_want_more have_done open no_children].freeze

  THEOLOGICAL_KEYS = %w[spiritual_gifts creation gender_roles end_times salvation_security].freeze
  THEOLOGICAL_OPTIONS = {
    "spiritual_gifts" => %w[continuationist cessationist open_but_cautious],
    "creation" => %w[young_earth old_earth theistic_evolution undecided],
    "gender_roles" => %w[complementarian egalitarian somewhere_between],
    "end_times" => %w[premillennial amillennial postmillennial pan_millennial],
    "salvation_security" => %w[eternal_security conditional undecided],
  }.freeze

  TEXT_MAX_LENGTH = 500

  # ── Verification Status ────────────────────────────────────────────
  VERIFICATION_STATUSES = %w[unverified pending_interview verified flagged rejected].freeze

  # ── Validations ──────────────────────────────────────────────────────
  validates :user_id, presence: true, uniqueness: true

  validates :gender, inclusion: { in: GENDERS }, allow_blank: true
  validates :seeking_gender, inclusion: { in: GENDERS }, allow_blank: true
  validates :birth_year, numericality: { only_integer: true, greater_than_or_equal_to: 1930, less_than_or_equal_to: -> { Date.today.year - 18 } }, allow_nil: true
  validates :age_min_preference, numericality: { only_integer: true, greater_than_or_equal_to: 18, less_than_or_equal_to: 80 }, allow_nil: true
  validates :age_max_preference, numericality: { only_integer: true, greater_than_or_equal_to: 18, less_than_or_equal_to: 80 }, allow_nil: true

  validates :location_flexibility, inclusion: { in: LOCATION_FLEXIBILITIES }, allow_blank: true
  validates :zip_code, length: { maximum: 10 }, allow_blank: true
  validates :denomination, inclusion: { in: DENOMINATIONS }, allow_blank: true
  validates :denomination_importance, inclusion: { in: DENOMINATION_IMPORTANCES }, allow_blank: true
  validates :church_attendance, inclusion: { in: CHURCH_ATTENDANCES }, allow_blank: true
  validates :baptism_status, inclusion: { in: BAPTISM_STATUSES }, allow_blank: true
  validates :bible_engagement, inclusion: { in: BIBLE_ENGAGEMENTS }, allow_blank: true

  validates :relationship_intention, inclusion: { in: RELATIONSHIP_INTENTIONS }, allow_blank: true
  validates :children_preference, inclusion: { in: CHILDREN_PREFERENCES }, allow_blank: true

  validates :testimony, length: { maximum: TEXT_MAX_LENGTH }, allow_blank: true
  validates :life_goals, length: { maximum: TEXT_MAX_LENGTH }, allow_blank: true
  validates :ministry_involvement, length: { maximum: TEXT_MAX_LENGTH }, allow_blank: true
  validates :partner_description, length: { maximum: TEXT_MAX_LENGTH }, allow_blank: true

  validates :verification_status, inclusion: { in: VERIFICATION_STATUSES }, allow_blank: true

  validate :validate_age_range_consistency
  validate :validate_theological_views_structure

  # ── Callbacks ────────────────────────────────────────────────────────
  before_save :sanitize_jsonb_arrays
  after_save :schedule_insight_generation, if: :narrative_fields_changed?

  # ── Scopes ───────────────────────────────────────────────────────────
  scope :active_and_visible, -> { where(active: true, visible: true) }

  # Searchable scope: must be active, visible, verified, AND have AI matching consent
  scope :searchable, -> {
    active_and_visible
      .where(verification_status: "verified")
      .where(
        "matchmaking_profiles.user_id IN (SELECT user_id FROM matchmaking_consents " \
        "WHERE consent_type = 'ai_matching' AND granted = true AND withdrawn_at IS NULL)"
      )
  }

  # ── Verification Helpers ─────────────────────────────────────────────
  def verified?
    verification_status == "verified"
  end

  def needs_verification?
    verification_status.blank? || verification_status == "unverified" || verification_status == "pending_interview"
  end

  def awaiting_review?
    verification_status == "flagged"
  end

  def rejected?
    verification_status == "rejected"
  end

  def mark_pending_interview!
    update_column(:verification_status, "pending_interview")
  end

  def verify!(verified_by_label = "auto")
    update_columns(
      verification_status: "verified",
      verified_at: Time.current,
      verified_by: verified_by_label,
    )
    # Promote user to TL1 for full platform access
    if user.trust_level < 1
      user.change_trust_level!(1, log_action_for: Discourse.system_user)
    end
  end

  def flag_for_review!(assessment_data)
    update_columns(
      verification_status: "flagged",
      verification_data: assessment_data,
    )
  end

  def reject!(rejected_by_label = "admin")
    update_columns(
      verification_status: "rejected",
      verified_by: rejected_by_label,
    )
  end

  # ── Profile Completion ───────────────────────────────────────────────
  def completion_percentage
    score = 0.0

    # Identity fields (20%)
    identity_fields = [gender, seeking_gender, birth_year, age_min_preference, age_max_preference]
    identity_filled = identity_fields.count(&:present?)
    score += 20.0 * (identity_filled.to_f / identity_fields.size)

    # Location fields (10%)
    location_fields = [country, state, location_flexibility]
    location_filled = location_fields.count(&:present?)
    score += 10.0 * (location_filled.to_f / location_fields.size)

    # Faith foundation (30%)
    faith_fields = [denomination, church_attendance, testimony]
    faith_filled = faith_fields.count(&:present?)
    score += 30.0 * (faith_filled.to_f / faith_fields.size)

    # Theological views (10%) — at least 3 of 5 filled for full credit
    tv = theological_views || {}
    tv_filled = THEOLOGICAL_KEYS.count { |k| tv[k].present? }
    tv_score = [tv_filled.to_f / 3.0, 1.0].min
    score += 10.0 * tv_score

    # Values (15%)
    values_fields = [relationship_intention, children_preference, life_goals]
    values_filled = values_fields.count(&:present?)
    score += 15.0 * (values_filled.to_f / values_fields.size)

    # Partner description (15%)
    score += 15.0 if partner_description.present?

    score.round
  end

  def meets_minimum_completion?
    min = SiteSetting.respond_to?(:matchmaking_min_profile_completion) ? SiteSetting.matchmaking_min_profile_completion : 70
    completion_percentage >= min
  end

  # ── Faith Insight Status ─────────────────────────────────────────────
  def has_faith_insight?
    faith_tags.present? && faith_tags.is_a?(Hash) && faith_tags["spiritual_posture"].present?
  end

  # ── Age Calculation ──────────────────────────────────────────────────
  def age
    return nil unless birth_year.present?
    Date.today.year - birth_year
  end

  # ── First Name for LLM (privacy-safe) ───────────────────────────────
  def first_name
    user&.name&.split(" ")&.first || user&.username
  end

  # ── Anonymized profile hash for LLM consumption ─────────────────────
  def to_llm_hash(candidate_label: nil, score: nil, score_breakdown: nil)
    result = {
      first_name: first_name,
      age: age,
      state: state,
      country: country,
      zip_code: zip_code,
      denomination: denomination,
      church_attendance: church_attendance,
      # Raw narrative excerpts — user's actual words for authentic conversation
      testimony_excerpt: testimony.present? ? testimony[0..299] : nil,
      life_goals_excerpt: life_goals.present? ? life_goals[0..299] : nil,
      ministry_involvement_excerpt: ministry_involvement.present? ? ministry_involvement[0..299] : nil,
      partner_description_excerpt: partner_description.present? ? partner_description[0..299] : nil,
      # LLM-generated faith insight — analyzed context for informed presentation
      faith_summary: faith_summary,
      faith_tags: faith_tags.present? ? faith_tags.slice(
        "spiritual_posture", "faith_maturity", "ministry_season",
        "partner_priorities", "partner_absence_flags", "key_themes",
        "struggle_indicators"
      ) : nil,
      interests: interests || [],
      lifestyle: lifestyle || [],
      theological_views: theological_views || {},
      relationship_intention: relationship_intention,
      children_preference: children_preference,
      bible_engagement: bible_engagement,
      baptism_status: baptism_status,
    }
    result[:candidate_id] = candidate_label if candidate_label
    result[:compatibility_score] = score if score
    result[:score_breakdown] = score_breakdown if score_breakdown
    result
  end

  private

  def narrative_fields_changed?
    saved_change_to_testimony? || saved_change_to_life_goals? ||
    saved_change_to_ministry_involvement? || saved_change_to_partner_description?
  end

  def schedule_insight_generation
    Jobs.enqueue(:generate_profile_insight, profile_id: self.id)
  end

  def validate_age_range_consistency
    return unless age_min_preference.present? && age_max_preference.present?
    if age_min_preference > age_max_preference
      errors.add(:age_max_preference, "must be greater than or equal to minimum age preference")
    end
  end

  def validate_theological_views_structure
    return if theological_views.blank?
    unless theological_views.is_a?(Hash)
      errors.add(:theological_views, "must be a JSON object")
      return
    end
    theological_views.each do |key, value|
      unless THEOLOGICAL_KEYS.include?(key.to_s)
        errors.add(:theological_views, "contains unknown key: #{key}")
        next
      end
      allowed = THEOLOGICAL_OPTIONS[key.to_s]
      unless allowed&.include?(value.to_s)
        errors.add(:theological_views, "has invalid value '#{value}' for key '#{key}'")
      end
    end
  end

  def sanitize_jsonb_arrays
    self.interests = Array(interests).map(&:to_s).uniq.first(20) if interests.present?
    self.lifestyle = Array(lifestyle).map(&:to_s).uniq.first(20) if lifestyle.present?
    self.dealbreakers = Array(dealbreakers).map(&:to_s).uniq.first(20) if dealbreakers.present?
  end
end
