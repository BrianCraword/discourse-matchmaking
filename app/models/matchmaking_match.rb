# frozen_string_literal: true

class MatchmakingMatch < ActiveRecord::Base
  belongs_to :searcher, class_name: "User"
  belongs_to :candidate, class_name: "User"

  STATUSES = %w[presented interested mutual dismissed].freeze

  validates :searcher_id, presence: true
  validates :candidate_id, presence: true
  validates :searcher_id, uniqueness: { scope: :candidate_id }
  validates :compatibility_score, numericality: { greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0 }, allow_nil: true
  validates :status, inclusion: { in: STATUSES }

  scope :for_user, ->(user_id) { where("searcher_id = ? OR candidate_id = ?", user_id, user_id) }
  scope :presented, -> { where(status: "presented") }
  scope :interested, -> { where(status: "interested") }
  scope :mutual, -> { where(status: "mutual") }
  scope :dismissed, -> { where(status: "dismissed") }

  # Check if both users have expressed interest — if so, upgrade to mutual
  def check_mutual_interest!
    reciprocal = MatchmakingMatch.find_by(
      searcher_id: candidate_id,
      candidate_id: searcher_id,
      status: "interested",
    )
    if reciprocal
      update!(status: "mutual")
      reciprocal.update!(status: "mutual")
      true
    else
      false
    end
  end
end
