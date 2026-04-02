# frozen_string_literal: true

module Jobs
  class RecomputeCompatibilityCache < ::Jobs::Base
    sidekiq_options queue: "low"
    cluster_concurrency 1

    def execute(args)
      return unless SiteSetting.matchmaking_enabled

      # Phase 3: This job will pre-compute and cache compatibility scores
      # between profiles when profiles are updated, rather than computing
      # everything at search time.
      #
      # For Phase 1, this is a placeholder. The matching pipeline runs
      # synchronously inside the ToolRunnerExtension during search.
    end
  end
end
