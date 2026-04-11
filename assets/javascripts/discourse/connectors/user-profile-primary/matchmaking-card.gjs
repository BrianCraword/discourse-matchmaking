import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { inject as service } from "@ember/service";
import { i18n } from "discourse-i18n";

export default class MatchmakingCard extends Component {
  @service router;

  @tracked profileData = null;
  @tracked loading = true;

  constructor() {
    super(...arguments);
    this.loadPublicProfile();
  }

  get user() {
    return this.args.outletArgs?.model;
  }

  get hasProfile() {
    return !!this.profileData;
  }

  get isOwnProfile() {
    const currentUser = this.args.outletArgs?.currentUser;
    return currentUser && this.user && currentUser.id === this.user.id;
  }

  // Only show on the Summary tab — not Activity, Messages, etc.
  get isSummaryTab() {
    const route = this.router.currentRouteName;
    return route === "user.summary" || route === "user.index";
  }

  // Only show if the user JSON contains matchmaking data AND we're on Summary
  get shouldShow() {
    return this.hasProfile && !this.loading && this.isSummaryTab;
  }

  // Show a prompt for own profile if no matchmaking profile exists
  get showSetupPrompt() {
    return this.isOwnProfile && !this.hasProfile && !this.loading && this.isSummaryTab;
  }

  get preferencesUrl() {
    if (!this.user) return "";
    return `/u/${this.user.username}/preferences/profile`;
  }

  // Field display helpers
  get denominationLabel() {
    const d = this.profileData?.denomination;
    if (!d) return null;
    return d.replace(/_/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
  }

  get churchAttendanceLabel() {
    const map = {
      multiple_weekly: "Multiple times/week",
      weekly: "Weekly",
      bi_weekly: "Every other week",
      monthly: "Monthly",
      occasional: "Occasionally",
    };
    return map[this.profileData?.church_attendance] || null;
  }

  get bibleEngagementLabel() {
    const map = {
      daily: "Daily",
      several_weekly: "Several times/week",
      weekly: "Weekly",
      occasional: "Occasionally",
    };
    return map[this.profileData?.bible_engagement] || null;
  }

  get relationshipIntentionLabel() {
    const map = {
      marriage_minded: "Marriage-minded",
      exploring: "Exploring possibilities",
      friendship_first: "Friendship first",
    };
    return map[this.profileData?.relationship_intention] || null;
  }

  get locationDisplay() {
    const parts = [];
    if (this.profileData?.state) parts.push(this.profileData.state);
    if (this.profileData?.country && this.profileData.country !== "United States") {
      parts.push(this.profileData.country);
    }
    return parts.join(", ") || null;
  }

  get faithSummaryOrTestimony() {
    return this.profileData?.faith_summary || this.profileData?.testimony_excerpt || null;
  }

  get theologicalViewsList() {
    const tv = this.profileData?.theological_views;
    if (!tv) return [];

    const labelMap = {
      spiritual_gifts: {
        label: "Spiritual Gifts",
        values: { continuationist: "Continuationist", cessationist: "Cessationist", open_but_cautious: "Open but cautious" },
      },
      creation: {
        label: "Creation",
        values: { young_earth: "Young earth", old_earth: "Old earth", theistic_evolution: "Theistic evolution", undecided: "Undecided" },
      },
      gender_roles: {
        label: "Gender Roles",
        values: { complementarian: "Complementarian", egalitarian: "Egalitarian", somewhere_between: "Somewhere between" },
      },
      end_times: {
        label: "End Times",
        values: { premillennial: "Premillennial", amillennial: "Amillennial", postmillennial: "Postmillennial", pan_millennial: "Pan-millennial" },
      },
      salvation_security: {
        label: "Salvation",
        values: { eternal_security: "Eternal security", conditional: "Conditional", undecided: "Undecided" },
      },
    };

    const views = [];
    for (const [key, config] of Object.entries(labelMap)) {
      if (tv[key] && config.values[tv[key]]) {
        views.push({ label: config.label, value: config.values[tv[key]] });
      }
    }
    return views;
  }

  get hasTheologicalViews() {
    return this.theologicalViewsList.length > 0;
  }

  get interestsList() {
    const interests = this.profileData?.interests;
    if (!interests || interests.length === 0) return [];
    return interests.map((i) => i.replace(/_/g, " "));
  }

  get hasInterests() {
    return this.interestsList.length > 0;
  }

  get isVerified() {
    return this.profileData?.verification_status === "verified";
  }

  async loadPublicProfile() {
    try {
      const profile = this.user?.matchmaking_public_profile;
      if (profile) {
        this.profileData = profile;
      }
    } catch (e) {
      // Silently fail — no card is fine
    } finally {
      this.loading = false;
    }
  }

  <template>
    {{#if this.shouldShow}}
      <div class="matchmaking-public-card">
        <div class="mpc-header">
          <h3 class="mpc-title">Faith Profile</h3>
          {{#if this.isVerified}}
            <span class="mpc-verified-badge" title="Verified member">✓ Verified</span>
          {{/if}}
          {{#if this.isOwnProfile}}
            <a href={{this.preferencesUrl}} class="mpc-edit-link">Edit</a>
          {{/if}}
        </div>

        {{! ── Faith Summary ── }}
        {{#if this.faithSummaryOrTestimony}}
          <div class="mpc-summary">
            <p>{{this.faithSummaryOrTestimony}}</p>
          </div>
        {{/if}}

        {{! ── Core Faith Info ── }}
        <div class="mpc-details">
          {{#if this.denominationLabel}}
            <div class="mpc-detail-item">
              <span class="mpc-detail-label">Denomination</span>
              <span class="mpc-detail-value">{{this.denominationLabel}}</span>
            </div>
          {{/if}}
          {{#if this.churchAttendanceLabel}}
            <div class="mpc-detail-item">
              <span class="mpc-detail-label">Church Attendance</span>
              <span class="mpc-detail-value">{{this.churchAttendanceLabel}}</span>
            </div>
          {{/if}}
          {{#if this.bibleEngagementLabel}}
            <div class="mpc-detail-item">
              <span class="mpc-detail-label">Bible Engagement</span>
              <span class="mpc-detail-value">{{this.bibleEngagementLabel}}</span>
            </div>
          {{/if}}
          {{#if this.relationshipIntentionLabel}}
            <div class="mpc-detail-item">
              <span class="mpc-detail-label">Looking For</span>
              <span class="mpc-detail-value">{{this.relationshipIntentionLabel}}</span>
            </div>
          {{/if}}
        </div>

        {{! ── Theological Views ── }}
        {{#if this.hasTheologicalViews}}
          <div class="mpc-section">
            <h4 class="mpc-section-title">Theological Views</h4>
            <div class="mpc-theology-grid">
              {{#each this.theologicalViewsList as |view|}}
                <div class="mpc-theology-item">
                  <span class="mpc-theology-label">{{view.label}}</span>
                  <span class="mpc-theology-value">{{view.value}}</span>
                </div>
              {{/each}}
            </div>
          </div>
        {{/if}}

        {{! ── Interests ── }}
        {{#if this.hasInterests}}
          <div class="mpc-section">
            <h4 class="mpc-section-title">Interests</h4>
            <div class="mpc-chips">
              {{#each this.interestsList as |interest|}}
                <span class="mpc-chip">{{interest}}</span>
              {{/each}}
            </div>
          </div>
        {{/if}}
      </div>

    {{else if this.showSetupPrompt}}
      <div class="matchmaking-public-card mpc-setup-prompt">
        <div class="mpc-header">
          <h3 class="mpc-title">Faith Profile</h3>
        </div>
        <p class="mpc-prompt-text">Complete your faith profile to share your beliefs and values with the community.</p>
        <a href={{this.preferencesUrl}} class="btn btn-primary btn-small">Set Up Faith Profile</a>
      </div>
    {{/if}}
  </template>
}
